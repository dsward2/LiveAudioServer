// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServer

@Suite("Config file loading and merge")
struct ConfigFileTests {

    /// Write `json` to a temp file and return its path. Cleanup is the
    /// caller's responsibility (typically via `defer`).
    private func writeTemp(_ json: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveaudio-config-\(UUID().uuidString).json").path
        try json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("Decoding a partial JSON populates only the present fields")
    func decodePartial() throws {
        let json = #"{"port": 9000, "outputs": ["mp3","hls"]}"#
        let path = try writeTemp(json)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let file = try loadConfigFile(at: path)
        #expect(file.port == 9000)
        #expect(file.outputs == ["mp3", "hls"])
        #expect(file.rate == nil)
        #expect(file.tlsPort == nil)
    }

    @Test("applyConfigFile merges populated fields and translates outputs")
    func mergePopulated() throws {
        var config = ServerConfig()
        let file = ServerConfigFile(
            port: 9001,
            rate: 44100,
            channels: 1,
            mp3Bitrate: 256,
            aacBitrate: 192,
            outputs: ["aac"],
            bind: "127.0.0.1",
            udpInputPort: 7355,
            statsInterval: 60,
            recordMP3: "/tmp/x.mp3",
            keepAlive: true
        )
        try applyConfigFile(file, to: &config)
        #expect(config.port == 9001)
        #expect(config.sampleRate == 44100)
        #expect(config.channels == 1)
        #expect(config.mp3Bitrate == 256)
        #expect(config.aacBitrate == 192_000) // kbps → bps
        #expect(config.enableMP3 == false)
        #expect(config.enableAAC == true)
        #expect(config.enableHLS == false)
        #expect(config.bindHost == "127.0.0.1")
        #expect(config.statsIntervalSeconds == 60)
        #expect(config.recordMP3Path == "/tmp/x.mp3")
        #expect(config.keepAliveOnInputEnd == true)
        if case .udp(let port) = config.inputSource {
            #expect(port == 7355)
        } else {
            Issue.record("Expected .udp(port:7355)")
        }
    }

    @Test("Unknown output token in the file is rejected")
    func invalidOutputToken() {
        var config = ServerConfig()
        let file = ServerConfigFile(outputs: ["mp3", "opus"])
        #expect(throws: ConfigFileError.self) {
            try applyConfigFile(file, to: &config)
        }
    }

    @Test("Malformed JSON returns a decodeFailed error")
    func malformedJSON() throws {
        let path = try writeTemp("{ this is not json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: ConfigFileError.self) {
            _ = try loadConfigFile(at: path)
        }
    }

    @Test("Missing file returns a fileNotReadable error")
    func missingFile() {
        let bogus = "/path/that/cannot/possibly/exist/\(UUID().uuidString).json"
        #expect(throws: ConfigFileError.self) {
            _ = try loadConfigFile(at: bogus)
        }
    }

    @Test("extractConfigPath strips --config and its value")
    func extractFlag() {
        let (path, remaining) = extractConfigPath(["--port", "9090", "--config", "/tmp/x.json", "--verbose"])
        #expect(path == "/tmp/x.json")
        #expect(remaining == ["--port", "9090", "--verbose"])
    }

    @Test("extractConfigPath leaves a bare --config when value is missing")
    func extractBareFlag() {
        let (path, remaining) = extractConfigPath(["--config"])
        #expect(path == nil)
        #expect(remaining == ["--config"])
    }

    @Test("parseCLI: CLI flags override file values")
    func cliOverridesFile() throws {
        // File: port 9000, channels 1. CLI: --port 9999 (channels not overridden).
        let json = #"{"port": 9000, "channels": 1, "outputs": ["mp3"]}"#
        let path = try writeTemp(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = parseCLI(["--config", path, "--port", "9999"])
        guard case .run(let config) = result else {
            Issue.record("Expected .run, got \(result)")
            return
        }
        #expect(config.port == 9999)           // CLI wins
        #expect(config.channels == 1)          // from file
        #expect(config.enableMP3 == true)
        #expect(config.enableAAC == false)
        #expect(config.enableHLS == false)
    }

    @Test("parseCLI: --config alone uses file values as the effective config")
    func fileOnlyConfig() throws {
        let json = #"{"port": 12345, "statsInterval": 30}"#
        let path = try writeTemp(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = parseCLI(["--config", path])
        guard case .run(let config) = result else {
            Issue.record("Expected .run, got \(result)")
            return
        }
        #expect(config.port == 12345)
        #expect(config.statsIntervalSeconds == 30)
    }

    @Test("parseCLI: --config without a value errors out")
    func missingConfigValue() {
        let result = parseCLI(["--config"])
        if case .error(let msg) = result {
            #expect(msg.contains("Missing --config path"))
        } else {
            Issue.record("Expected .error, got \(result)")
        }
    }

    @Test("parseCLI: bad file path produces an error")
    func badConfigPath() {
        let result = parseCLI(["--config", "/nope/does/not/exist.json"])
        if case .error = result {} else {
            Issue.record("Expected .error for missing --config file")
        }
    }
}
