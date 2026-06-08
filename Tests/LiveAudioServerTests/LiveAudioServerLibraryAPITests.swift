// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

// Tests/LiveAudioServerTests/LiveAudioServerLibraryAPITests.swift
// Drive the public `LiveAudioServer` API end-to-end the way a host app would:
// build a config, start the server on an ephemeral port, hit a real HTTP
// endpoint with URLSession, stop the server, assert clean shutdown.

import Testing
import Foundation
@testable import LiveAudioServerCore

@Suite("LiveAudioServer public API")
struct LiveAudioServerLibraryAPITests {

    /// Pick a high-numbered port unlikely to clash with anything else on the
    /// test runner. Not 0 because the public API doesn't expose the bound
    /// port back to callers — host apps choose their port up front.
    private static func ephemeralPort() -> UInt16 {
        UInt16.random(in: 49152...60000)
    }

    @Test("Default config initializer matches CLI defaults")
    func defaultsMatchCLI() {
        let cfg = LiveAudioServerConfig()
        #expect(cfg.port == 8080)
        #expect(cfg.sampleRate == 48000)
        #expect(cfg.channels == 2)
        #expect(cfg.mp3Bitrate == 128)
        #expect(cfg.aacBitrate == 128_000)
        #expect(cfg.enableMP3 == true)
        #expect(cfg.enableAAC == true)
        #expect(cfg.enableHLS == true)
        #expect(cfg.fillerMode == .silence)
        #expect(cfg.fillerAfterMs == 500)
    }

    @Test("Server lifecycle: start → status.json → stop → isRunning flips")
    func startStatusStopRoundTrip() async throws {
        // Bind to localhost only so we don't accidentally listen on the LAN
        // during CI. Use stdin input so the server doesn't try to open a
        // socket for PCM and clash with another test.
        var cfg = LiveAudioServerConfig()
        cfg.port = Self.ephemeralPort()
        cfg.bindHost = "127.0.0.1"
        cfg.bonjourName = nil           // no Bonjour during tests
        // Disable encoders during the lifecycle round-trip. lame_encode_flush
        // asserts internally when no PCM frames have been encoded in the
        // session — see "encoder lifecycle" note in the README. The HTTP +
        // start/stop machinery we want to exercise here doesn't need them.
        cfg.enableMP3 = false
        cfg.enableAAC = false
        cfg.enableHLS = false

        let server = LiveAudioServer(config: cfg)
        #expect(server.isRunning == false)

        try await server.start()
        #expect(server.isRunning == true)
        defer {
            // Belt-and-suspenders: if anything below throws, still stop.
            let g = DispatchSemaphore(value: 0)
            Task { await server.stop(); g.signal() }
            g.wait()
        }

        // Poll the status endpoint. NWListener.start() is asynchronous, so
        // give it up to a second to become reachable.
        let url = URL(string: "http://127.0.0.1:\(cfg.port)/status.json")!
        var lastError: Error?
        var bodyData: Data?
        for _ in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    bodyData = data
                    lastError = nil
                    break
                }
            } catch {
                lastError = error
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let lastError {
            Issue.record("Could not reach /status.json on port \(cfg.port): \(lastError)")
            return
        }
        guard let bodyData,
              let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            Issue.record("status.json was empty or not JSON")
            return
        }
        // Shape sanity-check: keys we documented on the public API.
        #expect(json["mp3Clients"] != nil)
        #expect(json["m4aClients"] != nil)

        await server.stop()
        #expect(server.isRunning == false)
    }

    @Test("stop() on a never-started server is a no-op")
    func stopWithoutStartIsNoop() async {
        let server = LiveAudioServer(config: LiveAudioServerConfig())
        await server.stop()
        #expect(server.isRunning == false)
    }

    @Test("start() while already running throws .alreadyRunning")
    func doubleStartThrows() async throws {
        var cfg = LiveAudioServerConfig()
        cfg.port = Self.ephemeralPort()
        cfg.bindHost = "127.0.0.1"
        cfg.enableMP3 = false
        cfg.enableAAC = false
        cfg.enableHLS = false

        let server = LiveAudioServer(config: cfg)
        try await server.start()
        defer {
            let g = DispatchSemaphore(value: 0)
            Task { await server.stop(); g.signal() }
            g.wait()
        }
        do {
            try await server.start()
            Issue.record("Expected .alreadyRunning to be thrown")
        } catch let err as LiveAudioServerError {
            if case .alreadyRunning = err {
                // good
            } else {
                Issue.record("Unexpected error: \(err)")
            }
        }
    }
}
