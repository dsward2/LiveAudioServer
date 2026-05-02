// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
@testable import LiveAudioServer

@Suite("CLI parsing")
struct CLIParseTests {

    /// Helper: assert the result is `.run` and return the config.
    private func runConfig(_ args: [String]) -> ServerConfig? {
        if case .run(let cfg) = parseCLI(args) { return cfg }
        return nil
    }

    private func parseError(_ args: [String]) -> String? {
        if case .error(let m) = parseCLI(args) { return m }
        return nil
    }

    @Test("No arguments yields defaults")
    func emptyArgs() {
        let cfg = runConfig([])
        #expect(cfg != nil)
        #expect(cfg?.port == 8080)
        #expect(cfg?.channels == 2)
        #expect(cfg?.sampleRate == 48000)
        #expect(cfg?.enableMP3 == true)
        #expect(cfg?.enableAAC == true)
        #expect(cfg?.enableHLS == true)
        #expect(cfg?.bindHost == nil)
        #expect(cfg?.tlsPort == nil)
    }

    @Test("--port sets port")
    func portFlag() {
        let cfg = runConfig(["--port", "9090"])
        #expect(cfg?.port == 9090)
    }

    @Test("Bad --port returns an error")
    func badPort() {
        #expect(parseError(["--port", "notanumber"]) != nil)
        #expect(parseError(["--port", "99999"]) != nil)   // overflows UInt16
    }

    @Test("--outputs mp3 disables AAC and HLS")
    func outputsMP3Only() {
        let cfg = runConfig(["--outputs", "mp3"])
        #expect(cfg?.enableMP3 == true)
        #expect(cfg?.enableAAC == false)
        #expect(cfg?.enableHLS == false)
    }

    @Test("--outputs aac,hls keeps both, disables MP3")
    func outputsAACAndHLS() {
        let cfg = runConfig(["--outputs", "aac,hls"])
        #expect(cfg?.enableMP3 == false)
        #expect(cfg?.enableAAC == true)
        #expect(cfg?.enableHLS == true)
    }

    @Test("--outputs m4a is accepted as an alias for aac")
    func outputsM4AAlias() {
        let cfg = runConfig(["--outputs", "m4a"])
        #expect(cfg?.enableAAC == true)
        #expect(cfg?.enableMP3 == false)
        #expect(cfg?.enableHLS == false)
    }

    @Test("Empty --outputs is rejected")
    func emptyOutputsErrors() {
        #expect(parseError(["--outputs", ""]) != nil)
    }

    @Test("Unknown --outputs token is rejected")
    func unknownOutputsErrors() {
        let msg = parseError(["--outputs", "mp3,opus"])
        #expect(msg?.contains("opus") == true)
    }

    @Test("--tls-port without --tls-identity is rejected")
    func tlsPortRequiresIdentity() {
        #expect(parseError(["--tls-port", "8443"]) != nil)
    }

    @Test("--tls-identity without --tls-port is rejected")
    func tlsIdentityRequiresPort() {
        #expect(parseError(["--tls-identity", "/tmp/cert.p12"]) != nil)
    }

    @Test("--tls-port + --tls-identity succeed together")
    func tlsPairAccepted() {
        let cfg = runConfig(["--tls-port", "8443", "--tls-identity", "/tmp/cert.p12"])
        #expect(cfg?.tlsPort == 8443)
        #expect(cfg?.tlsIdentityPath == "/tmp/cert.p12")
    }

    @Test("--bind sets the bind host")
    func bindHost() {
        let cfg = runConfig(["--bind", "127.0.0.1"])
        #expect(cfg?.bindHost == "127.0.0.1")
    }

    @Test("--stats-interval accepts non-negative integers")
    func statsIntervalAccepted() {
        let cfg = runConfig(["--stats-interval", "60"])
        #expect(cfg?.statsIntervalSeconds == 60)
        let cfg0 = runConfig(["--stats-interval", "0"])
        #expect(cfg0?.statsIntervalSeconds == 0)
    }

    @Test("--stats-interval rejects negative values")
    func statsIntervalRejectsNegative() {
        #expect(parseError(["--stats-interval", "-5"]) != nil)
    }

    @Test("--bonjour sets the published name")
    func bonjourName() {
        let cfg = runConfig(["--bonjour", "Studio A"])
        #expect(cfg?.bonjourName == "Studio A")
        #expect(cfg?.bonjourAdvertiseInputs == false)
    }

    @Test("--bonjour rejects empty name")
    func bonjourNameRejectsEmpty() {
        #expect(parseError(["--bonjour", ""]) != nil)
        #expect(parseError(["--bonjour", "   "]) != nil)
    }

    @Test("--bonjour-inputs without --bonjour is rejected")
    func bonjourInputsRequiresName() {
        #expect(parseError(["--bonjour-inputs"]) != nil)
    }

    @Test("--bonjour --bonjour-inputs combine cleanly")
    func bonjourPair() {
        let cfg = runConfig(["--bonjour", "Studio", "--bonjour-inputs"])
        #expect(cfg?.bonjourName == "Studio")
        #expect(cfg?.bonjourAdvertiseInputs == true)
    }

    @Test("Unknown option is reported")
    func unknownOption() {
        let msg = parseError(["--unknown-thing"])
        #expect(msg?.contains("--unknown-thing") == true)
    }

    @Test("--version returns printVersion directive")
    func versionDirective() {
        if case .printVersion = parseCLI(["--version"]) {} else {
            Issue.record("Expected .printVersion")
        }
    }

    @Test("-h returns printUsage directive")
    func helpDirective() {
        if case .printUsage = parseCLI(["-h"]) {} else {
            Issue.record("Expected .printUsage")
        }
    }
}
