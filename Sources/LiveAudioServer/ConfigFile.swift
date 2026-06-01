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

// Sources/LiveAudioServer/ConfigFile.swift
// Optional JSON configuration file consumed by `--config <path>`. All fields
// are optional; only the keys you want to override need appear. CLI flags
// still take precedence over file values.

import Foundation

enum ConfigFileError: Error, CustomStringConvertible {
    case fileNotReadable(String)
    case decodeFailed(String, message: String)
    case invalidOutputs(String)

    var description: String {
        switch self {
        case .fileNotReadable(let p):
            return "Config file not readable: \(p)"
        case .decodeFailed(let p, let m):
            return "Config file at \(p) is not valid JSON: \(m)"
        case .invalidOutputs(let token):
            return "Invalid value in config 'outputs': '\(token)'. Valid: mp3, aac, hls"
        }
    }
}

/// JSON shape consumed by `--config <path>`. Every field is optional: omit a
/// key and the built-in default (or a CLI flag) applies instead.
struct ServerConfigFile: Codable {
    var port: UInt16?
    var rate: Int?
    var channels: Int?
    var mp3Bitrate: Int?            // kbps (matches the --mp3-bitrate CLI convention)
    var aacBitrate: Int?            // kbps (matches the --aac-bitrate CLI convention)
    var outputs: [String]?          // any subset of ["mp3","aac","hls"]
    var bind: String?
    var udpInputPort: UInt16?
    var tcpInputPort: UInt16?
    var tlsPort: UInt16?
    var tlsIdentity: String?
    var tlsPassword: String?
    var statsInterval: Int?
    var recordMP3: String?
    var recordAAC: String?
    var mountMP3: String?
    var mountM4A: String?
    var mountHLS: String?
    var chunkFrames: Int?
    var keepAlive: Bool?
    var reopenFIFO: Bool?
    var silenceDither: Bool?
    var silenceDitherMs: Int?
    var verbose: Bool?
    var bonjour: String?
    var bonjourInputs: Bool?
    var authUser: String?
    var authPassword: String?
    var authRealm: String?
}

func loadConfigFile(at path: String) throws -> ServerConfigFile {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        throw ConfigFileError.fileNotReadable(path)
    }
    do {
        return try JSONDecoder().decode(ServerConfigFile.self, from: data)
    } catch {
        throw ConfigFileError.decodeFailed(path, message: "\(error)")
    }
}

/// Merge a `ServerConfigFile` into the given `ServerConfig`. Mutates in place.
/// Fields that are `nil` in the file are left untouched.
func applyConfigFile(_ file: ServerConfigFile, to config: inout ServerConfig) throws {
    if let v = file.port          { config.port = v }
    if let v = file.rate          { config.sampleRate = v }
    if let v = file.channels      { config.channels = v }
    if let v = file.mp3Bitrate    { config.mp3Bitrate = v }
    if let v = file.aacBitrate    { config.aacBitrate = v * 1000 }   // kbps -> bps (matches CLI)
    if let v = file.bind          { config.bindHost = v }
    if let v = file.tlsPort       { config.tlsPort = v }
    if let v = file.tlsIdentity   { config.tlsIdentityPath = v }
    if let v = file.tlsPassword   { config.tlsPassword = v }
    if let v = file.statsInterval { config.statsIntervalSeconds = v }
    if let v = file.recordMP3     { config.recordMP3Path = v }
    if let v = file.recordAAC     { config.recordAACPath = v }
    if let v = file.mountMP3      { config.mountMP3 = v }
    if let v = file.mountM4A      { config.mountM4A = v }
    if let v = file.mountHLS      { config.mountHLSIndex = v }
    if let v = file.chunkFrames   { config.stdinChunkFrames = v }
    if let v = file.keepAlive     { config.keepAliveOnInputEnd = v }
    if let v = file.reopenFIFO    { config.reopenStdinFIFO = v }
    if let v = file.silenceDither { config.silenceDitherEnabled = v }
    if let v = file.silenceDitherMs {
        // Convert ms → sample count using the (possibly already file-set)
        // rate and channel count. CLI-applied --rate / --channels later may
        // override these; the CLI parser re-derives the threshold in that
        // case via --silence-dither-ms.
        config.silenceDitherThresholdSamples = (v * config.sampleRate * config.channels) / 1000
    }
    if let v = file.verbose       { config.verbose = v }
    if let v = file.bonjour       { config.bonjourName = v.isEmpty ? nil : v }
    if let v = file.bonjourInputs { config.bonjourAdvertiseInputs = v }
    if let v = file.authUser      { config.httpAuthUser = v.isEmpty ? nil : v }
    if let v = file.authPassword  { config.httpAuthPassword = v.isEmpty ? nil : v }
    if let v = file.authRealm     { config.httpAuthRealm = v }

    // udpInputPort / tcpInputPort translate into config.inputSource.
    // If both are set in the file, tcp wins (matching last-CLI-flag-wins on CLI).
    if let p = file.udpInputPort { config.inputSource = .udp(port: p) }
    if let p = file.tcpInputPort { config.inputSource = .tcp(port: p) }

    // outputs: ["mp3", "aac", "hls"]. An empty array is rejected.
    if let outputs = file.outputs {
        config.enableMP3 = false
        config.enableAAC = false
        config.enableHLS = false
        for token in outputs {
            switch token.lowercased() {
            case "mp3":         config.enableMP3 = true
            case "aac", "m4a":  config.enableAAC = true
            case "hls":         config.enableHLS = true
            default:            throw ConfigFileError.invalidOutputs(token)
            }
        }
    }
}
