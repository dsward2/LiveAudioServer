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
import Network
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

    // MARK: - Injected TLS identity (programmatic embedders)

    /// Synthesize a fresh self-signed PKCS#12 in a temp dir using the system
    /// `/usr/bin/openssl`, then load it through the now-public
    /// `loadTLSIdentity`. Lets these tests exercise the real
    /// `sec_identity_t` injection path without checking a binary fixture
    /// into the repo. Returns nil (and the test should skip) if openssl is
    /// unavailable or the toolchain produces a .p12 that SecPKCS12Import
    /// doesn't accept on this host.
    private static func makeTestTLSIdentity() -> (identity: sec_identity_t, p12Path: String)? {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveAudioServerTLS-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let keyPath  = tmpDir.appendingPathComponent("key.pem").path
        let certPath = tmpDir.appendingPathComponent("cert.pem").path
        let p12Path  = tmpDir.appendingPathComponent("identity.p12").path
        let password = "test"

        func run(_ args: [String]) -> Bool {
            let p = Process()
            p.launchPath = openssl
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError  = Pipe()
            do {
                try p.run()
            } catch {
                return false
            }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }

        // Self-signed key + cert.
        guard run([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath, "-out", certPath,
            "-days", "1", "-subj", "/CN=LiveAudioServerTest"
        ]) else { return nil }

        // Package as PKCS#12. Force legacy ciphers so SecPKCS12Import on
        // macOS 13 accepts the bundle regardless of the host's openssl
        // version defaults.
        guard run([
            "pkcs12", "-export",
            "-inkey", keyPath, "-in", certPath,
            "-out", p12Path, "-passout", "pass:\(password)",
            "-name", "LiveAudioServerTest",
            "-keypbe", "PBE-SHA1-3DES",
            "-certpbe", "PBE-SHA1-3DES",
            "-macalg", "SHA1"
        ]) else { return nil }

        do {
            let identity = try loadTLSIdentity(p12Path: p12Path, password: password)
            return (identity, p12Path)
        } catch {
            return nil
        }
    }

    @Test("resolveTLSIdentity: injected identity satisfies config without tlsIdentityPath")
    func injectedTLSIdentityIsSufficient() throws {
        guard let fixture = Self.makeTestTLSIdentity() else {
            // openssl missing or produced a .p12 SecPKCS12Import can't read;
            // skip rather than fail the suite.
            return
        }

        var cfg = LiveAudioServerConfig()
        cfg.tlsPort = Self.ephemeralPort()
        cfg.tlsIdentity = fixture.identity
        // Deliberately leave tlsIdentityPath / tlsPassword nil — the injected
        // identity must be enough to produce a TLS-capable ServerConfig.
        #expect(cfg.tlsIdentityPath == nil)
        #expect(cfg.tlsPassword == nil)

        let resolved = try LiveAudioServer.resolveTLSIdentity(config: cfg)
        #expect(resolved != nil)
    }

    @Test("resolveTLSIdentity: injected identity wins over a bad tlsIdentityPath")
    func injectedTLSIdentityWinsOverPath() throws {
        guard let fixture = Self.makeTestTLSIdentity() else {
            return
        }

        var cfg = LiveAudioServerConfig()
        cfg.tlsPort = Self.ephemeralPort()
        cfg.tlsIdentity = fixture.identity
        // Path is set but points to a file that definitely won't load. If the
        // resolver were still going through the path branch, this would
        // throw. The injected identity should win and the resolver should
        // succeed.
        cfg.tlsIdentityPath = "/nonexistent/path/to/identity.p12"
        cfg.tlsPassword = "wrong"

        let resolved = try LiveAudioServer.resolveTLSIdentity(config: cfg)
        #expect(resolved != nil)
    }

    @Test("resolveTLSIdentity: no identity and no path returns nil")
    func noTLSIdentityReturnsNil() throws {
        let cfg = LiveAudioServerConfig()
        let resolved = try LiveAudioServer.resolveTLSIdentity(config: cfg)
        #expect(resolved == nil)
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
