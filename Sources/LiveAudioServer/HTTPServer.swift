// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

// Sources/LiveAudioServer/HTTPServer.swift
// NWListener-based HTTP/1.1 server.
// Routes:
//   GET /stream.mp3  → infinite MP3 Icecast-style stream
//   GET /stream.m4a  → infinite ADTS-AAC stream (audio/aac)
//   GET /hls/index.m3u8 → live HLS playlist backed by ADTS-AAC segments
//   GET /            → status page

import Foundation
import Network

// MARK: - HTTP Helpers

private func httpHeaders(status: Int, statusText: String,
                         fields: [String: String]) -> Data {
    var h = "HTTP/1.1 \(status) \(statusText)\r\n"
    for (k, v) in fields { h += "\(k): \(v)\r\n" }
    h += "\r\n"
    return h.data(using: .utf8)!
}

private func streamHeaders(format: AudioFormat) -> Data {
    httpHeaders(status: 200, statusText: "OK", fields: [
        "Content-Type":              format.mimeType,
        "Connection":                "keep-alive",
        "Cache-Control":             "no-cache, no-store",
        "X-Content-Type-Options":    "nosniff",
        "icy-name":                  "LiveAudioServer",
        "icy-br":                    "128",
        "icy-metaint":               "0",
        "Access-Control-Allow-Origin": "*"
    ])
}

private func notFoundResponse() -> Data {
    let body = "<html><body><h1>404 Not Found</h1></body></html>"
    let bodyData = body.data(using: .utf8)!
    return httpHeaders(status: 404, statusText: "Not Found", fields: [
        "Content-Type":   "text/html",
        "Content-Length": "\(bodyData.count)",
        "Connection":     "close"
    ]) + bodyData
}

// MARK: - HTTP Basic Auth Helpers

/// Sanitize a realm value for safe inclusion in a `WWW-Authenticate` header.
/// RFC 7617 realms are quoted-strings, so strip the characters that would
/// require escaping (`"` and `\`) and the CR/LF that would let a caller-supplied
/// realm inject extra headers.
private func sanitizedRealm(_ raw: String) -> String {
    raw.unicodeScalars.filter { scalar in
        scalar != "\"" && scalar != "\\" && scalar != "\r" && scalar != "\n"
    }.reduce(into: "") { $0.unicodeScalars.append($1) }
}

/// Pull the first `Authorization` header value (case-insensitive on the name)
/// out of a raw HTTP header block. Returns nil when absent.
private func parseAuthorizationHeader(_ headers: String) -> String? {
    for line in headers.components(separatedBy: "\r\n") {
        let pieces = line.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if pieces.count == 2, pieces[0].lowercased() == "authorization" {
            return pieces[1]
        }
    }
    return nil
}

/// Constant-time byte comparison. Length difference is folded in so callers
/// don't leak password length via early-exit timing.
private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var diff: UInt32 = UInt32(a.count) ^ UInt32(b.count)
    let n = min(a.count, b.count)
    for i in 0..<n {
        diff |= UInt32(a[i] ^ b[i])
    }
    return diff == 0
}

/// Validate an `Authorization: Basic …` header against expected credentials.
/// Returns true only when the scheme is `Basic`, the payload base64-decodes
/// cleanly, and both fields match.
func verifyBasicAuth(headerValue: String?, user: String, password: String) -> Bool {
    guard let value = headerValue else { return false }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0].lowercased() == "basic" else { return false }
    let b64 = parts[1].trimmingCharacters(in: .whitespaces)
    guard let decoded = Data(base64Encoded: b64),
          let pair = String(data: decoded, encoding: .utf8) else { return false }
    // The first ':' separates user from password. Passwords may legitimately
    // contain ':'; usernames per RFC 7617 may not.
    guard let colon = pair.firstIndex(of: ":") else { return false }
    let suppliedUser = String(pair[..<colon])
    let suppliedPass = String(pair[pair.index(after: colon)...])
    let userOK = constantTimeEqual(Array(suppliedUser.utf8), Array(user.utf8))
    let passOK = constantTimeEqual(Array(suppliedPass.utf8), Array(password.utf8))
    return userOK && passOK
}

// MARK: - Status Page

func statusPage(config: ServerConfig,
                mp3Clients: Int,
                m4aClients: Int) -> Data {
    func row(_ label: String, _ value: String) -> String {
        "<div class=\"row\"><span class=\"label\">\(label)</span><span class=\"value\">\(value)</span></div>"
    }
    func linkRow(_ label: String, _ href: String) -> String {
        "<div class=\"row\"><span class=\"label\">\(label)</span><a class=\"stream-link value\" href=\"\(href)\">\(href)</a></div>"
    }
    func badgeRow(_ label: String, _ id: String, _ count: Int) -> String {
        "<div class=\"row\"><span class=\"label\">\(label)</span><span class=\"badge\" id=\"\(id)\">\(count)</span></div>"
    }
    func urlRow(_ label: String, _ url: String) -> String {
        "<div class=\"row\"><span class=\"label\">\(label)</span><code style=\"color:#7c83e8;font-size:0.82rem\">\(url)</code></div>"
    }

    var streamRows = ""
    if config.enableMP3 {
        streamRows += linkRow("MP3 Stream", config.mountMP3)
        streamRows += badgeRow("MP3 Listeners", "mp3-listeners", mp3Clients)
    }
    if config.enableAAC {
        streamRows += linkRow("AAC/M4A Stream", config.mountM4A)
        streamRows += badgeRow("AAC Listeners", "aac-listeners", m4aClients)
    }
    if config.enableHLS {
        streamRows += linkRow("HLS Playlist", config.mountHLSIndex)
    }

    var players = ""
    if config.enableMP3 {
        players += """
        <p class="player-label">▶ MP3 Preview</p>
        <audio controls autoplay>
          <source src="\(config.mountMP3)" type="audio/mpeg">
          Your browser doesn't support audio playback.
        </audio>
        """
    }
    if config.enableAAC {
        players += """
        <p class="player-label" style="margin-top:20px">▶ AAC/M4A Preview</p>
        <audio controls>
          <source src="\(config.mountM4A)" type="audio/aac">
          Your browser doesn't support audio playback.
        </audio>
        """
    }
    if config.enableHLS {
        players += """
        <p class="player-label" style="margin-top:20px">▶ HLS Preview</p>
        <audio controls>
          <source src="\(config.mountHLSIndex)" type="application/vnd.apple.mpegurl">
          Your browser doesn't support audio playback.
        </audio>
        """
    }

    // For URL hints on the status page, prefer the explicit bind host when set;
    // fall back to "localhost". Wildcards like 0.0.0.0/:: aren't navigable, so
    // we leave the hint as "localhost" in those cases.
    let displayHost: String = {
        guard let h = config.bindHost, h != "0.0.0.0", h != "::" else { return "localhost" }
        return h.contains(":") ? "[\(h)]" : h   // bracket IPv6 literals
    }()

    func recorderCard(_ format: String, label: String) -> String {
        return """
        <div class="card" id="rec-\(format)-card">
          <p class="label" style="margin-bottom:8px">\(label) Recorder</p>
          <div class="row"><span class="label">State</span><span class="value" id="rec-\(format)-state">—</span></div>
          <div class="row"><span class="label">Bytes written</span><span class="value" id="rec-\(format)-bytes">0 B</span></div>
          <div style="margin-top:12px">
            <label class="label" for="rec-\(format)-path">Output path</label>
            <div class="path-row">
              <input type="text" id="rec-\(format)-path" placeholder="/path/to/output.\(format)" class="text-input">
              <button onclick="setRecorderDefaultPath('\(format)')" class="btn">Set Path</button>
            </div>
          </div>
          <div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap">
            <button id="rec-\(format)-start"  onclick="recorderStart('\(format)')"          class="btn">Start</button>
            <button id="rec-\(format)-pause"  onclick="recorderAction('\(format)','pause')" class="btn">Pause</button>
            <button id="rec-\(format)-resume" onclick="recorderAction('\(format)','resume')" class="btn">Resume</button>
            <button id="rec-\(format)-stop"   onclick="recorderAction('\(format)','stop')"  class="btn">Stop</button>
          </div>
        </div>
        """
    }

    var recorderCards = ""
    if config.enableMP3 { recorderCards += recorderCard("mp3", label: "MP3") }
    if config.enableAAC { recorderCards += recorderCard("aac", label: "AAC") }

    var urlRows = ""
    if config.enableMP3 {
        urlRows += urlRow("MP3 (HTTP)", "http://\(displayHost):\(config.port)\(config.mountMP3)")
        if let tlsPort = config.tlsPort {
            urlRows += urlRow("MP3 (HTTPS)", "https://\(displayHost):\(tlsPort)\(config.mountMP3)")
        }
    }
    if config.enableAAC {
        urlRows += urlRow("AAC (HTTP)", "http://\(displayHost):\(config.port)\(config.mountM4A)")
        if let tlsPort = config.tlsPort {
            urlRows += urlRow("AAC (HTTPS)", "https://\(displayHost):\(tlsPort)\(config.mountM4A)")
        }
    }
    if config.enableHLS {
        urlRows += urlRow("HLS (HTTP)", "http://\(displayHost):\(config.port)\(config.mountHLSIndex)")
        if let tlsPort = config.tlsPort {
            urlRows += urlRow("HLS (HTTPS)", "https://\(displayHost):\(tlsPort)\(config.mountHLSIndex)")
        }
    }

    let html = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>LiveAudioServer</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
               background: #0f1117; color: #e2e8f0; min-height: 100vh; padding: 40px 24px; }
        .card { background: #1e2130; border-radius: 12px; padding: 28px;
                max-width: 640px; margin: 0 auto 24px; border: 1px solid #2d3250; }
        h1 { font-size: 1.5rem; color: #7c83e8; margin-bottom: 4px; }
        .sub { color: #718096; font-size: 0.85rem; margin-bottom: 24px; }
        .row { display: flex; justify-content: space-between; align-items: center;
               padding: 12px 0; border-bottom: 1px solid #2d3250; }
        .row:last-child { border-bottom: none; }
        .label { color: #a0aec0; font-size: 0.9rem; }
        .value { font-weight: 600; color: #e2e8f0; }
        .badge { display: inline-block; background: #7c83e8; color: #fff;
                 border-radius: 20px; padding: 3px 12px; font-size: 0.8rem; }
        .stream-link { color: #7c83e8; text-decoration: none; font-size: 0.9rem; }
        .stream-link:hover { text-decoration: underline; }
        audio { width: 100%; margin-top: 12px; accent-color: #7c83e8; }
        .player-label { color: #a0aec0; font-size: 0.8rem; margin-top: 16px; margin-bottom: 4px; }
        .btn { padding: 8px 16px; background: #7c83e8; color: #fff; border: none;
               border-radius: 6px; cursor: pointer; font-family: inherit;
               font-size: 0.85rem; transition: background 0.1s ease; }
        .btn:disabled { background: #3a3f5e; cursor: not-allowed; opacity: 0.6; }
        .btn:hover:not(:disabled) { background: #9197f0; }
        .text-input { width: 100%; padding: 8px; margin-top: 4px;
                      background: #0f1117; color: #e2e8f0; border: 1px solid #2d3250;
                      border-radius: 6px; font-family: inherit; font-size: 0.9rem;
                      box-sizing: border-box; }
        .text-input:focus { outline: none; border-color: #7c83e8; }
        .path-row { display: flex; gap: 8px; margin-top: 4px; align-items: stretch; }
        .path-row .text-input { margin-top: 0; flex: 1; }
        .path-row .btn { white-space: nowrap; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>🎙 LiveAudioServer</h1>
        <p class="sub">Live audio streaming — listener counts update every 5s</p>

        <div class="row">
          <span class="label">Input Source</span>
          <span class="value">\(config.inputSource.displayName)</span>
        </div>
        <div class="row">
          <span class="label">Port</span>
          <span class="value">\(config.port)</span>
        </div>
        <div class="row">
          <span class="label">Sample Rate</span>
          <span class="value">\(config.sampleRate) Hz</span>
        </div>
        <div class="row">
          <span class="label">Channels</span>
          <span class="value">\(config.channels == 1 ? "Mono" : "Stereo")</span>
        </div>
        \(streamRows)
      </div>

      <div class="card">
        \(players)
      </div>

      <div class="card">
        <p class="label" style="margin-bottom:8px">Stream URLs for external players</p>
        \(urlRows)
      </div>

      \(recorderCards)

      <div class="card" id="now-playing-card" style="display:none">
        <p class="label" style="margin-bottom:8px">Now Playing</p>
        <div class="row"><span class="label">Title</span><span class="value" id="np-title">—</span></div>
        <div class="row"><span class="label">Artist</span><span class="value" id="np-artist">—</span></div>
        <div class="row"><span class="label">Station</span><span class="value" id="np-station">—</span></div>
        <div class="row"><span class="label">Note</span><span class="value" id="np-note">—</span></div>
        <div class="row"><span class="label">Updated</span><span class="value" id="np-updated">—</span></div>
      </div>

      <script>
        // Poll listener counts (and now-playing) in place so the <audio>
        // elements stay alive. Full page reloads tear down the MP3/AAC stream
        // and cause dropouts in Chrome.
        async function updateStatus() {
          try {
            const r = await fetch('/status.json', { cache: 'no-store' });
            if (!r.ok) return;
            const d = await r.json();
            const mp3 = document.getElementById('mp3-listeners');
            const aac = document.getElementById('aac-listeners');
            if (mp3 && typeof d.mp3Clients === 'number') mp3.textContent = d.mp3Clients;
            if (aac && typeof d.m4aClients === 'number') aac.textContent = d.m4aClients;

            const np = d.nowPlaying || {};
            const card = document.getElementById('now-playing-card');
            const hasData = !!(np.title || np.artist || np.station || np.note);
            if (card) card.style.display = hasData ? '' : 'none';
            const setNP = (id, val) => {
              const el = document.getElementById(id);
              if (el) el.textContent = (val && String(val).length) ? val : '—';
            };
            setNP('np-title',   np.title);
            setNP('np-artist',  np.artist);
            setNP('np-station', np.station);
            setNP('np-note',    np.note);
            setNP('np-updated', np.updated);

            applyRecorderEnvelope(d.recorder);
          } catch (_) {}
        }

        function humanBytes(b) {
          if (typeof b !== 'number') return '0 B';
          if (b >= 1e6) return (b / 1e6).toFixed(2) + ' MB';
          if (b >= 1e3) return (b / 1e3).toFixed(1) + ' KB';
          return b + ' B';
        }

        function applyRecorderEnvelope(env) {
          ['mp3', 'aac'].forEach(fmt => {
            const card = document.getElementById('rec-' + fmt + '-card');
            if (!card) return;                       // format not enabled
            const status = env && env[fmt];
            if (!status) { card.style.display = 'none'; return; }
            const stateEl = document.getElementById('rec-' + fmt + '-state');
            const bytesEl = document.getElementById('rec-' + fmt + '-bytes');
            const pathEl  = document.getElementById('rec-' + fmt + '-path');
            if (stateEl) stateEl.textContent = status.state;
            if (bytesEl) bytesEl.textContent = humanBytes(status.bytesWritten);
            // Don't clobber the path input while the user is editing it.
            if (pathEl && document.activeElement !== pathEl) {
              pathEl.value = status.path || '';
            }
            const isRec    = status.state === 'recording';
            const isPaused = status.state === 'paused';
            const isIdle   = status.state === 'idle';
            const setDis = (id, v) => {
              const el = document.getElementById(id);
              if (el) el.disabled = v;
            };
            setDis('rec-' + fmt + '-pause',  !isRec);
            setDis('rec-' + fmt + '-resume', !isPaused);
            setDis('rec-' + fmt + '-stop',   isIdle);
          });
        }

        async function recorderStart(fmt) {
          const pathEl = document.getElementById('rec-' + fmt + '-path');
          const path = (pathEl && pathEl.value || '').trim();
          if (!path) { alert('Please enter an output path first.'); return; }
          await recorderAction(fmt, 'start', { path: path });
        }

        // "Set Path" button: prefill the recorder's path input with a
        // sensible default `/tmp/LiveAudioServer-<fmt>-<YYYYMMDD-HHmmss>.<ext>`
        // (browsers can't open a native OS save dialog and feed a server-side
        // path back — see README.). Users can edit the result freely.
        function setRecorderDefaultPath(fmt) {
          const now = new Date();
          const pad = n => String(n).padStart(2, '0');
          const stamp = now.getFullYear()
                     + pad(now.getMonth() + 1)
                     + pad(now.getDate())
                     + '-'
                     + pad(now.getHours())
                     + pad(now.getMinutes())
                     + pad(now.getSeconds());
          const ext = (fmt === 'aac') ? 'aac' : fmt;
          const el = document.getElementById('rec-' + fmt + '-path');
          if (el) {
            el.value = '/tmp/LiveAudioServer-' + fmt + '-' + stamp + '.' + ext;
            el.focus();
            el.setSelectionRange(el.value.length, el.value.length);
          }
        }

        async function recorderAction(fmt, action, bodyObj) {
          try {
            const opts = { method: 'POST', cache: 'no-store' };
            if (bodyObj) {
              opts.headers = { 'Content-Type': 'application/json' };
              opts.body = JSON.stringify(bodyObj);
            }
            const resp = await fetch('/api/recorder/' + fmt + '/' + action, opts);
            if (!resp.ok) {
              alert(action + ' failed: HTTP ' + resp.status);
              return;
            }
            const env = await resp.json();
            applyRecorderEnvelope(env);
          } catch (e) {
            alert(action + ' error: ' + e);
          }
        }

        updateStatus();
        setInterval(updateStatus, 5000);
      </script>
    </body>
    </html>
    """
    return html.data(using: .utf8)!
}

// MARK: - Connection Handler

final class HTTPConnection {
    private let connection: NWConnection
    private let config: ServerConfig
    private let mp3Broadcaster: ChunkBroadcaster
    private let m4aBroadcaster: ChunkBroadcaster
    private let hlsSegmenter: HLSSegmenter?
    private let nowPlayingStore: NowPlayingStore
    private let mp3Recorder: FileRecorder?
    private let aacRecorder: FileRecorder?
    private let onClose: (() -> Void)?
    private var receiveBuffer = Data()
    private var clientID: UUID?
    private var streamFormat: AudioFormat?

    init(_ connection: NWConnection,
         config: ServerConfig,
         mp3Broadcaster: ChunkBroadcaster,
         m4aBroadcaster: ChunkBroadcaster,
         hlsSegmenter: HLSSegmenter?,
         nowPlayingStore: NowPlayingStore,
         mp3Recorder: FileRecorder?,
         aacRecorder: FileRecorder?,
         onClose: (() -> Void)? = nil) {
        self.connection      = connection
        self.config          = config
        self.mp3Broadcaster  = mp3Broadcaster
        self.m4aBroadcaster  = m4aBroadcaster
        self.hlsSegmenter    = hlsSegmenter
        self.nowPlayingStore = nowPlayingStore
        self.mp3Recorder     = mp3Recorder
        self.aacRecorder     = aacRecorder
        self.onClose         = onClose
    }

    /// Called by `HTTPServer.stop()` during graceful shutdown.
    func cancelConnection() {
        connection.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .cancelled, .failed:
                if let id = self.clientID {
                    let broadcaster = self.streamFormat == .mp3 ? self.mp3Broadcaster : self.m4aBroadcaster
                    broadcaster.removeClient(id: id)
                    self.clientID = nil
                }
                self.onClose?()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
        receiveRequest()
    }

    // MARK: - Receive

    /// 64 KB cap on request bodies — way more than `/api/now-playing` needs and
    /// keeps a misbehaving client from buffering unbounded memory.
    private static let maxRequestBodyBytes = 64 * 1024

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }
            if let d = data { self.receiveBuffer.append(d) }

            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let range = self.receiveBuffer.range(of: separator) {
                let headersData = self.receiveBuffer[..<range.lowerBound]
                let bodyStart   = range.upperBound
                let headers     = String(data: headersData, encoding: .utf8) ?? ""
                let contentLength = HTTPConnection.parseContentLength(headers) ?? 0

                if contentLength > HTTPConnection.maxRequestBodyBytes {
                    self.sendStatus(413, "Payload Too Large")
                    return
                }

                let bodyAvailable = self.receiveBuffer.count - bodyStart
                if bodyAvailable >= contentLength {
                    let body: Data = contentLength > 0
                        ? Data(self.receiveBuffer[bodyStart..<(bodyStart + contentLength)])
                        : Data()
                    self.handleRequest(headers: headers, body: body)
                    return
                }
            }

            if !isComplete { self.receiveRequest() }
        }
    }

    private static func parseContentLength(_ headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let pieces = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pieces.count == 2, pieces[0].lowercased() == "content-length" {
                return Int(pieces[1])
            }
        }
        return nil
    }

    // MARK: - Route

    private func handleRequest(headers: String, body: Data) {
        let firstLine = headers.components(separatedBy: "\r\n").first ?? ""
        let parts     = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = parts[0]
        let path   = (parts[1].components(separatedBy: "?").first ?? parts[1])
                       .removingPercentEncoding ?? parts[1]

        if config.verbose {
            log("\(method) \(path)")
        }

        // HTTP Basic auth gate. When credentials are configured every route
        // (including the streams and the status page) requires them. We
        // intentionally check before any routing so a 401 challenge is
        // returned uniformly, which is also what triggers the browser's
        // login dialog.
        if let user = config.httpAuthUser, let password = config.httpAuthPassword {
            let header = parseAuthorizationHeader(headers)
            if !verifyBasicAuth(headerValue: header, user: user, password: password) {
                sendUnauthorized(realm: config.httpAuthRealm)
                return
            }
        }

        // Methods other than GET/HEAD are only allowed for explicit POST routes.
        switch (method, path) {
        case ("POST", "/api/now-playing"):
            serveNowPlayingPost(body: body)
            return
        default:
            break
        }

        // /api/recorder/{mp3|aac}/{start|pause|resume|stop}
        if path.hasPrefix("/api/recorder/") {
            serveRecorderAction(path: path, method: method, body: body)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            sendStatus(405, "Method Not Allowed")
            return
        }

        switch path {
        case config.mountMP3 where config.enableMP3:
            beginStream(format: .mp3, headOnly: method == "HEAD")
        case config.mountM4A where config.enableAAC:
            beginStream(format: .m4a, headOnly: method == "HEAD")
        case config.mountHLSIndex where config.enableHLS:
            serveHLSPlaylist(headOnly: method == "HEAD")
        case "/", "/status", "/index.html":
            serveStatus(headOnly: method == "HEAD")
        case "/status.json":
            serveStatusJSON(headOnly: method == "HEAD")
        case "/api/now-playing":
            serveNowPlayingGet(headOnly: method == "HEAD")
        case "/api/recorder":
            serveRecorderStatus(headOnly: method == "HEAD")
        default:
            if config.enableHLS,
               let segmenter = hlsSegmenter,
               segmenter.sequenceNumber(for: path) != nil {
                serveHLSSegment(path: path, headOnly: method == "HEAD")
            } else {
                connection.send(content: notFoundResponse(), completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                })
            }
        }
    }

    private func sendStatus(_ code: Int, _ text: String) {
        let body = Data("\(code) \(text)\n".utf8)
        let headers = httpHeaders(status: code, statusText: text, fields: [
            "Content-Type":   "text/plain; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Connection":     "close"
        ])
        var response = headers
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    /// 401 Unauthorized with a `WWW-Authenticate: Basic` challenge so browsers
    /// prompt for credentials. The body is a small human-readable note.
    private func sendUnauthorized(realm: String) {
        let body = Data("401 Unauthorized\n".utf8)
        let headers = httpHeaders(status: 401, statusText: "Unauthorized", fields: [
            "Content-Type":     "text/plain; charset=utf-8",
            "Content-Length":   "\(body.count)",
            "Connection":       "close",
            "Cache-Control":    "no-store",
            "WWW-Authenticate": "Basic realm=\"\(sanitizedRealm(realm))\", charset=\"UTF-8\""
        ])
        var response = headers
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: - Stream

    private func beginStream(format: AudioFormat, headOnly: Bool) {
        streamFormat = format
        let headers  = streamHeaders(format: format)

        if headOnly {
            connection.send(content: headers, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }

        // Send headers, then register as a streaming client
        connection.send(content: headers, completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else { self?.connection.cancel(); return }

            let id     = UUID()
            self.clientID = id
            let client = StreamClient(id: id, connection: self.connection, format: format)
            let broadcaster = format == .mp3 ? self.mp3Broadcaster : self.m4aBroadcaster
            broadcaster.addClient(client)

            // Monitor for client disconnect
            _ = broadcaster
        })
    }

    // MARK: - Status Page

    private func serveStatus(headOnly: Bool) {
        let body = statusPage(config: config,
                              mp3Clients: mp3Broadcaster.clientCount,
                              m4aClients: m4aBroadcaster.clientCount)
        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type":   "text/html; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Connection":     "close",
            "Cache-Control":  "no-cache"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func serveStatusJSON(headOnly: Bool) {
        let np = nowPlayingStore.snapshot
        let npJSON: String
        if let encoded = try? JSONEncoder().encode(np),
           let s = String(data: encoded, encoding: .utf8) {
            npJSON = s
        } else {
            npJSON = "null"
        }
        let recorderEnv = recorderStatusEnvelope()
        let recJSON: String
        if let encoded = try? JSONEncoder().encode(recorderEnv),
           let s = String(data: encoded, encoding: .utf8) {
            recJSON = s
        } else {
            recJSON = "{}"
        }
        let json = "{\"mp3Clients\":\(mp3Broadcaster.clientCount),\"m4aClients\":\(m4aBroadcaster.clientCount),\"nowPlaying\":\(npJSON),\"recorder\":\(recJSON)}"
        let body = Data(json.utf8)
        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type":   "application/json; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Connection":     "close",
            "Cache-Control":  "no-cache, no-store"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func serveNowPlayingGet(headOnly: Bool) {
        let snapshot = nowPlayingStore.snapshot
        let body = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type":   "application/json; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Connection":     "close",
            "Cache-Control":  "no-cache, no-store"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func serveNowPlayingPost(body: Data) {
        do {
            let incoming = try JSONDecoder().decode(NowPlayingMetadata.self, from: body)
            nowPlayingStore.replace(with: incoming)
            let snapshot = nowPlayingStore.snapshot
            let responseBody = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
            let headers = httpHeaders(status: 200, statusText: "OK", fields: [
                "Content-Type":   "application/json; charset=utf-8",
                "Content-Length": "\(responseBody.count)",
                "Connection":     "close",
                "Cache-Control":  "no-cache, no-store"
            ])
            var response = headers
            response.append(responseBody)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        } catch {
            sendStatus(400, "Bad Request")
        }
    }

    // MARK: - Recorder API

    private struct RecorderStatusEnvelope: Codable {
        let mp3: FileRecorder.Status?
        let aac: FileRecorder.Status?
    }

    private struct RecorderStartBody: Codable {
        let path: String
    }

    private func recorderStatusEnvelope() -> RecorderStatusEnvelope {
        RecorderStatusEnvelope(mp3: mp3Recorder?.status, aac: aacRecorder?.status)
    }

    private func sendJSONResponse<T: Encodable>(_ value: T, headOnly: Bool = false) {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type":   "application/json; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Connection":     "close",
            "Cache-Control":  "no-cache, no-store"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func serveRecorderStatus(headOnly: Bool) {
        sendJSONResponse(recorderStatusEnvelope(), headOnly: headOnly)
    }

    private func serveRecorderAction(path: String, method: String, body: Data) {
        guard method == "POST" else {
            sendStatus(405, "Method Not Allowed")
            return
        }
        // path is "/api/recorder/{format}/{action}"
        let suffix = String(path.dropFirst("/api/recorder/".count))
        let parts  = suffix.split(separator: "/").map(String.init)
        guard parts.count == 2 else {
            sendStatus(404, "Not Found")
            return
        }
        let formatToken = parts[0].lowercased()
        let action      = parts[1].lowercased()

        // Resolve the format and ensure that recorder is actually live (i.e.
        // the matching output is enabled).
        let recorder: FileRecorder?
        switch formatToken {
        case "mp3":         recorder = mp3Recorder
        case "aac", "m4a":  recorder = aacRecorder
        default:
            sendStatus(404, "Not Found")
            return
        }
        guard let recorder = recorder else {
            // The format isn't enabled in --outputs, so there's no recorder.
            sendStatus(409, "Conflict")
            return
        }

        switch action {
        case "start":
            do {
                let req = try JSONDecoder().decode(RecorderStartBody.self, from: body)
                guard !req.path.isEmpty else { sendStatus(400, "Bad Request"); return }
                try recorder.start(path: req.path)
            } catch is RecorderError {
                sendStatus(500, "Internal Server Error")
                return
            } catch {
                sendStatus(400, "Bad Request")
                return
            }
        case "pause":
            recorder.pause()
        case "resume":
            recorder.resume()
        case "stop":
            recorder.stop()
        default:
            sendStatus(404, "Not Found")
            return
        }

        sendJSONResponse(recorderStatusEnvelope())
    }

    private func serveHLSPlaylist(headOnly: Bool) {
        guard let segmenter = hlsSegmenter else {
            connection.send(content: notFoundResponse(), completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        let body = segmenter.playlistData(indexPath: config.mountHLSIndex)
        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(body.count)",
            "Connection": "close",
            "Cache-Control": "no-cache, no-store"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func serveHLSSegment(path: String, headOnly: Bool) {
        guard let segmenter = hlsSegmenter,
              let body = segmenter.segmentData(for: path) else {
            connection.send(content: notFoundResponse(), completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }

        let headers = httpHeaders(status: 200, statusText: "OK", fields: [
            "Content-Type": "audio/aac",
            "Content-Length": "\(body.count)",
            "Connection": "close",
            "Cache-Control": "no-cache, no-store"
        ])
        var response = headers
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

// MARK: - HTTP Server

final class HTTPServer {
    private let config: ServerConfig
    private let mp3Broadcaster: ChunkBroadcaster
    private let m4aBroadcaster: ChunkBroadcaster
    private let hlsSegmenter: HLSSegmenter?
    private let nowPlayingStore: NowPlayingStore
    private let mp3Recorder: FileRecorder?
    private let aacRecorder: FileRecorder?
    private let tlsIdentity: sec_identity_t?
    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private let connectionLock = NSLock()
    private var activeConnections = [UUID: HTTPConnection]()

    init(config: ServerConfig,
         mp3Broadcaster: ChunkBroadcaster,
         m4aBroadcaster: ChunkBroadcaster,
         hlsSegmenter: HLSSegmenter?,
         nowPlayingStore: NowPlayingStore,
         mp3Recorder: FileRecorder?,
         aacRecorder: FileRecorder?,
         tlsIdentity: sec_identity_t? = nil) {
        self.config          = config
        self.mp3Broadcaster  = mp3Broadcaster
        self.m4aBroadcaster  = m4aBroadcaster
        self.hlsSegmenter    = hlsSegmenter
        self.nowPlayingStore = nowPlayingStore
        self.mp3Recorder     = mp3Recorder
        self.aacRecorder     = aacRecorder
        self.tlsIdentity     = tlsIdentity
    }

    /// Extract the remote host (IP literal) from an NWEndpoint, if present.
    /// Returns nil for non-IP endpoints (URLs, service endpoints, etc.).
    static func remoteHost(from endpoint: NWEndpoint) -> NWEndpoint.Host? {
        if case .hostPort(let host, _) = endpoint {
            return host
        }
        return nil
    }

    /// Cancel both listeners and close all active connections. Safe to call
    /// more than once. Does not exit the process — the caller is responsible
    /// for whatever comes next.
    func stop() {
        httpListener?.cancel()
        httpListener = nil
        httpsListener?.cancel()
        httpsListener = nil

        // Snapshot under lock, then cancel outside to avoid re-entrancy via
        // the onClose callbacks that mutate activeConnections.
        connectionLock.lock()
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        connectionLock.unlock()
        for conn in conns {
            conn.cancelConnection()
        }

        // Streaming clients live on the broadcasters separately from the
        // accepted-connection map (they're registered after headers).
        mp3Broadcaster.closeAll()
        m4aBroadcaster.closeAll()
    }

    func start() throws {
        // Plain HTTP listener (always on)
        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        httpListener = try makeListener(params: httpParams, port: config.port, scheme: "http")

        // Optional HTTPS listener
        if let tlsPort = config.tlsPort, let identity = tlsIdentity {
            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tlsOpts.securityProtocolOptions, .TLSv12)
            let tcpOpts = NWProtocolTCP.Options()
            let httpsParams = NWParameters(tls: tlsOpts, tcp: tcpOpts)
            httpsParams.allowLocalEndpointReuse = true
            httpsListener = try makeListener(params: httpsParams, port: tlsPort, scheme: "https")
        }
    }

    private func makeListener(params: NWParameters, port: UInt16, scheme: String) throws -> NWListener {
        let listener: NWListener
        if let bindHost = config.bindHost {
            // Restrict the listener to a specific local address (IPv4 or IPv6).
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(bindHost),
                port: NWEndpoint.Port(rawValue: port)!
            )
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }

        // Bonjour advertisement — well-known `_http._tcp.` / `_https._tcp.`
        // service types, with a TXT record listing the active stream paths.
        if let bonjourName = config.bonjourName {
            let serviceType = (scheme == "https") ? "_https._tcp" : "_http._tcp"
            let txt = bonjourTXTRecord(for: config)
            listener.service = NWListener.Service(
                name: bonjourName,
                type: serviceType,
                domain: "local.",
                txtRecord: txt
            )
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }

            // Source-IP allow-list check (default = allow all).
            if let acl = self.config.allowedClientIPs, !acl.allowAll {
                let remote = HTTPServer.remoteHost(from: conn.endpoint)
                if let host = remote, !acl.allows(host) {
                    if self.config.verbose {
                        log("Rejected connection from \(conn.endpoint) (not in --allow-ip)")
                    }
                    conn.cancel()
                    return
                }
                if remote == nil {
                    // Couldn't extract an IP literal — fail closed.
                    if self.config.verbose {
                        log("Rejected connection from \(conn.endpoint) (no IP available)")
                    }
                    conn.cancel()
                    return
                }
            }

            let id = UUID()
            let handler = HTTPConnection(conn,
                                         config: self.config,
                                         mp3Broadcaster: self.mp3Broadcaster,
                                         m4aBroadcaster: self.m4aBroadcaster,
                                         hlsSegmenter: self.hlsSegmenter,
                                         nowPlayingStore: self.nowPlayingStore,
                                         mp3Recorder: self.mp3Recorder,
                                         aacRecorder: self.aacRecorder,
                                         onClose: { [weak self] in
                                             self?.connectionLock.lock()
                                             self?.activeConnections.removeValue(forKey: id)
                                             self?.connectionLock.unlock()
                                         })
            self.connectionLock.lock()
            self.activeConnections[id] = handler
            self.connectionLock.unlock()
            handler.start()
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                log("✅ Listening on \(scheme)://\(self.config.bindHost ?? "localhost"):\(port)/")
                if self.config.enableMP3 {
                    log("   MP3 stream : \(scheme)://\(self.config.bindHost ?? "localhost"):\(port)\(self.config.mountMP3)")
                }
                if self.config.enableAAC {
                    log("   AAC stream : \(scheme)://\(self.config.bindHost ?? "localhost"):\(port)\(self.config.mountM4A)")
                }
                if self.config.enableHLS {
                    log("   HLS stream : \(scheme)://\(self.config.bindHost ?? "localhost"):\(port)\(self.config.mountHLSIndex)")
                }
                log("   Status page: \(scheme)://\(self.config.bindHost ?? "localhost"):\(port)/\n")
            case .failed(let error):
                log("❌ \(scheme.uppercased()) listener failed: \(error)")
                exit(1)
            default: break
            }
        }

        listener.start(queue: .global(qos: .userInteractive))
        return listener
    }
}
