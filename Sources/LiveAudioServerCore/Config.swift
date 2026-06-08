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

// Sources/LiveAudioServerCore/Config.swift
// Configuration, shared types, and constants.

import Foundation

// MARK: - Server Configuration

public enum PCMInputSource: CustomStringConvertible {
    case stdin
    case udp(port: UInt16)
    case tcp(port: UInt16)

    public var description: String {
        switch self {
        case .stdin:
            return "stdin"
        case .udp(let port):
            return "udp:\(port)"
        case .tcp(let port):
            return "tcp:\(port)"
        }
    }

    /// Human-readable variant used in the status page UI.
    var displayName: String {
        switch self {
        case .stdin:
            return "stdin"
        case .udp(let port):
            return "UDP port \(port)"
        case .tcp(let port):
            return "TCP port \(port)"
        }
    }
}

/// All server-tunable knobs. Construct one with the default initializer to get
/// CLI-equivalent defaults, then override fields as needed before handing the
/// value to `LiveAudioServer(config:)`.
public struct ServerConfig {
    public var port: UInt16 = 8080
    public var channels: Int = 2          // 1 = mono, 2 = stereo
    public var sampleRate: Int = 48000    // Hz  (44100 or 48000 recommended)
    public var mp3Bitrate: Int = 128      // kbps
    public var aacBitrate: Int = 128_000  // bps (AudioToolbox uses bps)
    public var verbose: Bool = false
    public var stdinChunkFrames: Int = 4096  // PCM frames read per stdin iteration
    public var keepAliveOnInputEnd: Bool = false
    /// When the input stream is a FIFO/named pipe and `keepAliveOnInputEnd` is
    /// on, re-`open()` the same path on EOF so a new producer can attach.
    /// Plain pipes (e.g. shell `|`) cannot be reopened — this only takes
    /// effect when stdin is in fact a FIFO.
    public var reopenStdinFIFO: Bool = true
    /// Inject inaudible TPDF dither into the broadcast PCM stream when a long
    /// run of all-zero (digitally silent) samples is detected. Prevents
    /// downstream tools from seeing the stream as "dead" while keeping the
    /// added noise below the threshold of audibility.
    public var silenceDitherEnabled: Bool = false
    /// Number of consecutive all-zero samples (per channel, summed) that must
    /// elapse before dither kicks in. Default ~500 ms at 48 kHz stereo.
    public var silenceDitherThresholdSamples: Int = 48_000
    /// What the reader broadcasts during the keep-alive silence-fill window
    /// after stdin reaches EOF. Default `.silence` preserves the historical
    /// behavior (zero bytes, optionally TPDF-dithered). `.tone` substitutes a
    /// continuous sine wave so listeners hear an audible "test tone" placeholder
    /// instead of dead air.
    public var fillerMode: FillerMode = .silence
    /// Frequency in Hz of the sine wave emitted when `fillerMode == .tone`.
    /// Ignored otherwise. Default 1000 Hz is the broadcast convention for a
    /// reference test tone.
    public var fillerToneHz: Double = 1000.0
    /// Milliseconds of consecutive UDP/TCP input absence before the filler
    /// kicks in. Lets brief network jitter pass through unaltered while still
    /// covering longer gaps (Gqrx paused, station between feeds, etc.).
    /// Default 500 ms matches the silence-dither threshold.
    public var fillerAfterMs: Int = 500
    public var inputSource: PCMInputSource = .stdin
    public var mountMP3: String = "/stream.mp3"
    public var mountM4A: String = "/stream.m4a"
    public var mountHLSIndex: String = "/hls/index.m3u8"
    public var enableMP3: Bool = true
    public var enableAAC: Bool = true
    public var enableHLS: Bool = true
    public var tlsPort: UInt16? = nil
    public var tlsIdentityPath: String? = nil
    public var tlsPassword: String? = nil
    /// If non-nil, HTTP/HTTPS listeners bind to this specific local address
    /// instead of all interfaces. Use "127.0.0.1" for IPv4 localhost only,
    /// "::1" for IPv6 localhost only, or an explicit LAN address.
    public var bindHost: String? = nil
    /// Allow-list of source IPs (and CIDR ranges) for HTTP/HTTPS clients.
    /// `nil` (the default) means allow everyone — equivalent to
    /// `IPAllowList.allowAll`. Otherwise, connections whose source address
    /// doesn't match any entry are cancelled at accept time.
    public var allowedClientIPs: IPAllowList? = nil
    /// If set, publish a Bonjour (mDNS) service with this name advertising the
    /// HTTP (and HTTPS, if enabled) listeners on the LAN. `nil` disables.
    public var bonjourName: String? = nil
    /// If true and `bonjourName` is set, also publish a Bonjour record for the
    /// active UDP / TCP PCM input port so producers can discover it.
    public var bonjourAdvertiseInputs: Bool = false
    /// Cadence in seconds for the periodic stats log line. 0 disables the log
    /// (default). Set to e.g. 60 for one stats line per minute.
    public var statsIntervalSeconds: Int = 0
    /// Optional file path: write encoded MP3 chunks here while streaming.
    public var recordMP3Path: String? = nil
    /// Optional file path: write encoded ADTS AAC chunks here while streaming.
    public var recordAACPath: String? = nil
    /// If set together with `httpAuthPassword`, every HTTP/HTTPS request must
    /// carry an `Authorization: Basic` header whose decoded user:password
    /// matches these values. `nil` (the default) disables auth entirely.
    /// Credentials travel base64-encoded (effectively plaintext) — pair with
    /// `--tls-port` for real deployments.
    public var httpAuthUser: String? = nil
    public var httpAuthPassword: String? = nil
    /// Realm string surfaced in the `WWW-Authenticate` header on a 401. The
    /// browser uses this to decide whether to reuse cached credentials.
    public var httpAuthRealm: String = "LiveAudioServer"
    public var mountHLSSegmentPrefix: String = "/hls/seg-"
    public var hlsSegmentDuration: Double = 2.0
    public var hlsPlaylistWindowSize: Int = 5

    public init() {}

    /// Bytes per interleaved PCM frame (2 bytes per sample × channels)
    var bytesPerFrame: Int { channels * 2 }

    /// Bytes per stdin read
    var stdinChunkBytes: Int { stdinChunkFrames * bytesPerFrame }
}

/// Spec-friendly alias: the public type name external callers see.
public typealias LiveAudioServerConfig = ServerConfig

// MARK: - Filler Mode

/// Content the silence-fill loop emits when input has ended (stdin EOF + `--keep-alive`).
public enum FillerMode: String {
    /// Continue the historical behavior: emit all-zero PCM (optionally TPDF-dithered).
    case silence
    /// Emit a continuous sine wave so listeners hear an audible placeholder.
    case tone

    public init?(cliArgument: String) {
        switch cliArgument.lowercased() {
        case "silence":                    self = .silence
        case "tone", "sine", "sine-tone":  self = .tone
        default:                           return nil
        }
    }
}

// MARK: - Encoded Chunk

/// A timestamped chunk of encoded audio bytes for one format.
struct EncodedChunk {
    let data: Data
}

// MARK: - Stream Format

enum AudioFormat: String, CaseIterable {
    case mp3 = "mp3"
    case m4a = "m4a"

    var mimeType: String {
        switch self {
        case .mp3: return "audio/mpeg"
        case .m4a: return "audio/aac"
        }
    }

    var icecastContentType: String { mimeType }
}

// MARK: - Logging

public let logQueue = DispatchQueue(label: "log")

public func log(_ msg: String, verbose: Bool = false, config: ServerConfig? = nil) {
    if verbose, let cfg = config, !cfg.verbose { return }
    logQueue.async {
        var ts = ""
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        ts = fmt.string(from: Date())
        fputs("[\(ts)] \(msg)\n", stderr)
    }
}
