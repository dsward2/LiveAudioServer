// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServer

@Suite("Filler generator")
struct FillerGeneratorTests {

    private static let sampleRate = 48_000
    private static let channels   = 2
    private static let toneHz     = 1000.0

    /// Decode `bytes` (interleaved s16le, `channels` samples per frame) into
    /// a flat array of mono samples by averaging the channels. Sufficient for
    /// the tests below — the generator emits the same value to all channels.
    private static func decodeMono(_ bytes: [UInt8], channels: Int) -> [Int16] {
        let samplesPerChannel = (bytes.count / 2) / channels
        var out = [Int16](repeating: 0, count: samplesPerChannel)
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Int16.self).baseAddress!
            for f in 0..<samplesPerChannel {
                var acc: Int32 = 0
                for ch in 0..<channels { acc += Int32(base[f * channels + ch]) }
                out[f] = Int16(acc / Int32(channels))
            }
        }
        return out
    }

    // MARK: - Silence mode

    @Test("Silence mode emits all zeros")
    func silenceModeIsZero() {
        var g = FillerGenerator(mode: .silence,
                                channels: Self.channels,
                                sampleRate: Self.sampleRate,
                                toneHz: Self.toneHz)
        var buf = [UInt8](repeating: 0xAA, count: Self.channels * 2 * 1024)   // poisoned
        g.fillChunk(&buf)
        #expect(buf.allSatisfy { $0 == 0 })
    }

    // MARK: - Tone mode

    @Test("Tone mode emits the same sample to every channel")
    func toneIsChannelLocked() {
        var g = FillerGenerator(mode: .tone,
                                channels: Self.channels,
                                sampleRate: Self.sampleRate,
                                toneHz: Self.toneHz)
        var buf = [UInt8](repeating: 0, count: Self.channels * 2 * 256)
        g.fillChunk(&buf)
        buf.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Int16.self).baseAddress!
            for f in 0..<256 {
                #expect(base[f * Self.channels + 0] == base[f * Self.channels + 1],
                        "Stereo channels should carry identical sine samples")
            }
        }
    }

    @Test("Tone mode peak amplitude ≈ -20 dBFS")
    func tonePeakAmplitudeIsAround20dBFS() {
        var g = FillerGenerator(mode: .tone,
                                channels: 1,
                                sampleRate: Self.sampleRate,
                                toneHz: Self.toneHz)
        // Render at least a full period to be sure we cover the peak.
        let frames = Self.sampleRate / Int(Self.toneHz) * 4     // 4 periods @ 1 kHz/48 kHz = 192 frames
        var buf = [UInt8](repeating: 0, count: frames * 2)
        g.fillChunk(&buf)
        let samples = Self.decodeMono(buf, channels: 1)
        let peak = samples.map { abs(Int32($0)) }.max() ?? 0
        // Expected peak ≈ round(32767 × 10^(-20/20)) = 3277.
        // Allow ±3 LSB for rounding at sample boundaries.
        #expect(abs(peak - 3277) <= 3,
                "Peak \(peak) is not within ±3 of the -20 dBFS reference (3277)")
    }

    @Test("Tone mode frequency matches --filler-tone-hz (zero-crossing test)")
    func toneFrequencyIsCorrect() {
        // Count zero-crossings (sign changes) in a 1-second buffer and
        // confirm we get ~2 per period. For a 1 kHz tone at 48 kHz over 1
        // second we expect ~2000 zero-crossings, ±10 for boundary jitter.
        let frames = Self.sampleRate
        var g = FillerGenerator(mode: .tone,
                                channels: 1,
                                sampleRate: Self.sampleRate,
                                toneHz: Self.toneHz)
        var buf = [UInt8](repeating: 0, count: frames * 2)
        g.fillChunk(&buf)
        let samples = Self.decodeMono(buf, channels: 1)

        var crossings = 0
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            if (a >= 0) != (b >= 0) { crossings += 1 }
        }
        let expected = Int(Self.toneHz) * 2     // 2 zero-crossings per cycle
        let tolerance = 20                       // boundary + rounding wiggle
        #expect(abs(crossings - expected) <= tolerance,
                "Got \(crossings) zero-crossings, expected ~\(expected) (±\(tolerance))")
    }

    @Test("Tone mode phase is continuous across chunk boundaries")
    func tonePhaseContinuesAcrossChunks() {
        // Render two consecutive chunks; the discontinuity between the last
        // sample of chunk #1 and the first sample of chunk #2 should be the
        // same magnitude as any other sample-to-sample step inside the
        // chunk. If phase reset between chunks, the discontinuity would be
        // huge (potentially full-scale swing).
        var g = FillerGenerator(mode: .tone,
                                channels: 1,
                                sampleRate: Self.sampleRate,
                                toneHz: Self.toneHz)
        let chunkFrames = 4096
        var buf1 = [UInt8](repeating: 0, count: chunkFrames * 2)
        var buf2 = [UInt8](repeating: 0, count: chunkFrames * 2)
        g.fillChunk(&buf1)
        g.fillChunk(&buf2)

        let s1 = Self.decodeMono(buf1, channels: 1)
        let s2 = Self.decodeMono(buf2, channels: 1)

        // Largest step inside a single chunk (acts as a safe upper bound).
        var maxInternalStep: Int32 = 0
        for i in 1..<s1.count {
            maxInternalStep = max(maxInternalStep, abs(Int32(s1[i]) - Int32(s1[i - 1])))
        }
        let boundaryStep = abs(Int32(s2[0]) - Int32(s1.last!))
        // Boundary step should not exceed the largest in-chunk step by much
        // (allowing 2 LSB for the float→int rounding wobble at the seam).
        #expect(boundaryStep <= maxInternalStep + 2,
                "Boundary step \(boundaryStep) exceeds in-chunk max \(maxInternalStep) — phase reset?")
    }
}
