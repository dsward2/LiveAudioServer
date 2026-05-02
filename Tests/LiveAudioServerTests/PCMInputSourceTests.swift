// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
@testable import LiveAudioServer

@Suite("PCMInputSource formatting")
struct PCMInputSourceTests {

    @Test("stdin description and displayName")
    func stdin() {
        let s: PCMInputSource = .stdin
        #expect(s.description == "stdin")
        #expect(s.displayName == "stdin")
    }

    @Test("UDP description and displayName")
    func udp() {
        let s: PCMInputSource = .udp(port: 7355)
        #expect(s.description == "udp:7355")
        #expect(s.displayName == "UDP port 7355")
    }

    @Test("TCP description and displayName")
    func tcp() {
        let s: PCMInputSource = .tcp(port: 7356)
        #expect(s.description == "tcp:7356")
        #expect(s.displayName == "TCP port 7356")
    }
}
