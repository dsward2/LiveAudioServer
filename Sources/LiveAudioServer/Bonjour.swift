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

// Sources/LiveAudioServer/Bonjour.swift
// Bonjour (mDNS/DNS-SD) advertising for HTTP/HTTPS output and (optionally)
// the PCM input ports. The HTTP/HTTPS listeners advertise via their
// NWListener.service property — see HTTPServer.makeListener. This module
// handles only the input-port advertisements, which run on POSIX sockets
// outside of Network.framework.

import Foundation

/// Build a TXT record (RFC 6763 §6) for the `_http._tcp.` / `_https._tcp.`
/// advertisements. Uses the conventional `path` key Safari's Bonjour
/// bookmarks recognize, plus a `status` alias and version.
/// `NetService.data(fromTXTRecord:)` formats one byte per pair followed by
/// "key=value" up to 255 bytes per pair.
func bonjourTXTRecord(for config: ServerConfig) -> Data {
    var dict: [String: Data] = [
        "ver":    Data(liveAudioServerVersion.utf8),
        "path":   Data("/".utf8),
        "status": Data("/".utf8),
    ]
    if config.enableMP3 { dict["mp3"] = Data(config.mountMP3.utf8) }
    if config.enableAAC { dict["aac"] = Data(config.mountM4A.utf8) }
    if config.enableHLS { dict["hls"] = Data(config.mountHLSIndex.utf8) }
    return NetService.data(fromTXTRecord: dict)
}

/// Build a richer TXT record for the custom `_liveaudio._tcp.` service.
/// LiveAudioServer-aware clients can read this once to enumerate all the
/// streams' paths, bitrates, sample-rate, channel count, and the optional
/// HTTPS port — no `/status.json` round-trip needed.
func bonjourCustomOutputTXT(for config: ServerConfig) -> Data {
    var dict: [String: Data] = [
        "ver":      Data(liveAudioServerVersion.utf8),
        "path":     Data("/".utf8),
        "status":   Data("/".utf8),
        "rate":     Data("\(config.sampleRate)".utf8),
        "channels": Data("\(config.channels)".utf8),
    ]
    if config.enableMP3 {
        dict["mp3"]         = Data(config.mountMP3.utf8)
        dict["mp3-bitrate"] = Data("\(config.mp3Bitrate)".utf8)   // kbps
    }
    if config.enableAAC {
        dict["aac"]         = Data(config.mountM4A.utf8)
        dict["aac-bitrate"] = Data("\(config.aacBitrate / 1000)".utf8)  // kbps
    }
    if config.enableHLS {
        dict["hls"] = Data(config.mountHLSIndex.utf8)
    }
    if let tlsPort = config.tlsPort {
        dict["tls-port"] = Data("\(tlsPort)".utf8)
    }
    return NetService.data(fromTXTRecord: dict)
}

/// Publishes NetService records for the active PCM input ports when
/// `--bonjour-inputs` is set. HTTP/HTTPS output advertisements live on the
/// NWListener directly; this class only owns the input services so their
/// `publish()` lifetime matches the process.
final class BonjourPublisher {
    private var services: [NetService] = []

    /// Publish a service per active input port for the given Bonjour name.
    /// Idempotent — call once at startup.
    func publishInputs(name: String, config: ServerConfig) {
        switch config.inputSource {
        case .stdin:
            return  // stdin has no port to advertise
        case .udp(let port):
            publish(name: name, type: "_liveaudio-pcm._udp.", port: port, role: "input-udp")
        case .tcp(let port):
            publish(name: name, type: "_liveaudio-pcm._tcp.", port: port, role: "input-tcp")
        }
    }

    /// Publish a custom `_liveaudio._tcp.` service on the HTTP port with a
    /// rich TXT record (paths, bitrates, sample rate, channels, tls hint).
    /// A LiveAudioServer-aware client can filter Bonjour discovery to this
    /// type instead of trawling all `_http._tcp.` services on the LAN.
    func publishCustomOutput(name: String, config: ServerConfig) {
        let svc = NetService(domain: "local.", type: "_liveaudio._tcp.", name: name, port: Int32(config.port))
        svc.setTXTRecord(bonjourCustomOutputTXT(for: config))
        svc.publish()
        services.append(svc)
        log("📡 Bonjour: published \(name)._liveaudio._tcp. on port \(config.port)")
    }

    private func publish(name: String, type: String, port: UInt16, role: String) {
        let svc = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        let txt: [String: Data] = [
            "role":     Data(role.utf8),
            "format":   Data("s16le".utf8),
            "rate":     Data("\(role.hasSuffix("udp") ? 48000 : 48000)".utf8),
        ]
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.publish()
        services.append(svc)
        log("📡 Bonjour: published \(name).\(type) on port \(port)")
    }

    /// Stop all published services. Safe to call multiple times.
    func stopAll() {
        for svc in services {
            svc.stop()
        }
        services.removeAll()
    }
}
