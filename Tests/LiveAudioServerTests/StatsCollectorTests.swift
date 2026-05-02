// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServer

@Suite("StatsCollector and formatting")
struct StatsCollectorTests {

    @Test("formatDuration covers seconds, minutes, hours, days")
    func formatDurationRanges() {
        #expect(formatDuration(0)      == "0s")
        #expect(formatDuration(42)     == "42s")
        #expect(formatDuration(60)     == "1m")
        #expect(formatDuration(125)    == "2m")
        #expect(formatDuration(3600)   == "1h0m")
        #expect(formatDuration(3725)   == "1h2m")
        #expect(formatDuration(90061)  == "1d1h1m")  // 1 day, 1 hour, 1 minute, 1 second → "1d1h1m"
    }

    @Test("formatDuration clamps negative durations to 0s")
    func formatDurationNegative() {
        #expect(formatDuration(-5) == "0s")
    }

    @Test("formatBytes scales B / KB / MB")
    func formatBytesRanges() {
        #expect(formatBytes(0)             == "0 B")
        #expect(formatBytes(999)           == "999 B")
        #expect(formatBytes(1_000)         == "1.0 KB")
        #expect(formatBytes(12_345)        == "12.3 KB")
        #expect(formatBytes(1_000_000)     == "1.00 MB")
        #expect(formatBytes(4_200_000)     == "4.20 MB")
    }

    @Test("StatsCollector accumulates per-format bytes")
    func collectorAccumulates() {
        let collector = StatsCollector(startTime: Date(timeIntervalSinceReferenceDate: 0))
        collector.recordMP3Bytes(500)
        collector.recordMP3Bytes(1_500)
        collector.recordAACBytes(2_000)
        collector.recordAACBytes(0)  // should be ignored
        collector.recordMP3Bytes(-1) // should be ignored
        let snap = collector.snapshot(now: Date(timeIntervalSinceReferenceDate: 65))
        #expect(snap.mp3BytesEncoded == 2_000)
        #expect(snap.aacBytesEncoded == 2_000)
        #expect(snap.uptime == 65)
    }

    @Test("formatStatsLine produces the canonical stats string")
    func statsLine() {
        let snap = StatsCollector.Snapshot(
            mp3BytesEncoded: 4_200_000,
            aacBytesEncoded: 1_800_000,
            uptime: 17 * 60
        )
        let line = formatStatsLine(snapshot: snap, mp3Clients: 2, aacClients: 1)
        #expect(line == "[stats] mp3:2c aac:1c | mp3 enc 4.20 MB | aac enc 1.80 MB | uptime 17m")
    }
}
