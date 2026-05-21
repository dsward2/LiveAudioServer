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

// Sources/LiveAudioServer/Config.swift
// Configuration, shared types, and constants.

import Foundation

// MARK: - Server Configuration

enum PCMInputSource: CustomStringConvertible {
    case stdin
    case udp(port: UInt16)
    case tcp(port: UInt16)

    var description: String {
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

struct ServerConfig {
    var port: UInt16 = 8080
    var channels: Int = 2          // 1 = mono, 2 = stereo
    var sampleRate: Int = 48000    // Hz  (44100 or 48000 recommended)
    var mp3Bitrate: Int = 128      // kbps
    var aacBitrate: Int = 128_000  // bps (AudioToolbox uses bps)
    var verbose: Bool = false
    var stdinChunkFrames: Int = 4096  // PCM frames read per stdin iteration
    var keepAliveOnInputEnd: Bool = false
    var inputSource: PCMInputSource = .stdin
    var mountMP3: String = "/stream.mp3"
    var mountM4A: String = "/stream.m4a"
    var mountHLSIndex: String = "/hls/index.m3u8"
    var enableMP3: Bool = true
    var enableAAC: Bool = true
    var enableHLS: Bool = true
    var tlsPort: UInt16? = nil
    var tlsIdentityPath: String? = nil
    var tlsPassword: String? = nil
    /// If non-nil, HTTP/HTTPS listeners bind to this specific local address
    /// instead of all interfaces. Use "127.0.0.1" for IPv4 localhost only,
    /// "::1" for IPv6 localhost only, or an explicit LAN address.
    var bindHost: String? = nil
    /// Allow-list of source IPs (and CIDR ranges) for HTTP/HTTPS clients.
    /// `nil` (the default) means allow everyone — equivalent to
    /// `IPAllowList.allowAll`. Otherwise, connections whose source address
    /// doesn't match any entry are cancelled at accept time.
    var allowedClientIPs: IPAllowList? = nil
    /// If set, publish a Bonjour (mDNS) service with this name advertising the
    /// HTTP (and HTTPS, if enabled) listeners on the LAN. `nil` disables.
    var bonjourName: String? = nil
    /// If true and `bonjourName` is set, also publish a Bonjour record for the
    /// active UDP / TCP PCM input port so producers can discover it.
    var bonjourAdvertiseInputs: Bool = false
    /// Cadence in seconds for the periodic stats log line. 0 disables the log
    /// (default). Set to e.g. 60 for one stats line per minute.
    var statsIntervalSeconds: Int = 0
    /// Optional file path: write encoded MP3 chunks here while streaming.
    var recordMP3Path: String? = nil
    /// Optional file path: write encoded ADTS AAC chunks here while streaming.
    var recordAACPath: String? = nil
    /// If set together with `httpAuthPassword`, every HTTP/HTTPS request must
    /// carry an `Authorization: Basic` header whose decoded user:password
    /// matches these values. `nil` (the default) disables auth entirely.
    /// Credentials travel base64-encoded (effectively plaintext) — pair with
    /// `--tls-port` for real deployments.
    var httpAuthUser: String? = nil
    var httpAuthPassword: String? = nil
    /// Realm string surfaced in the `WWW-Authenticate` header on a 401. The
    /// browser uses this to decide whether to reuse cached credentials.
    var httpAuthRealm: String = "LiveAudioServer"
    var mountHLSSegmentPrefix: String = "/hls/seg-"
    var hlsSegmentDuration: Double = 2.0
    var hlsPlaylistWindowSize: Int = 5

    /// Bytes per interleaved PCM frame (2 bytes per sample × channels)
    var bytesPerFrame: Int { channels * 2 }

    /// Bytes per stdin read
    var stdinChunkBytes: Int { stdinChunkFrames * bytesPerFrame }
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

let logQueue = DispatchQueue(label: "log")

func log(_ msg: String, verbose: Bool = false, config: ServerConfig? = nil) {
    if verbose, let cfg = config, !cfg.verbose { return }
    logQueue.async {
        var ts = ""
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        ts = fmt.string(from: Date())
        fputs("[\(ts)] \(msg)\n", stderr)
    }
}
