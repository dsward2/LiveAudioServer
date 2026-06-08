// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
@testable import LiveAudioServerCore

@Suite("TPDF dither generator")
struct TPDFDitherTests {

    @Test("Output is bounded to ±1 LSB")
    func boundedRange() {
        var d = TPDFDither(seed: 42)
        for _ in 0..<100_000 {
            let n = d.nextNoiseSample()
            #expect(n >= -1 && n <= 1)
        }
    }

    @Test("Same seed yields identical sequence")
    func deterministic() {
        var a = TPDFDither(seed: 0xCAFEBABE)
        var b = TPDFDither(seed: 0xCAFEBABE)
        for _ in 0..<1024 {
            #expect(a.nextNoiseSample() == b.nextNoiseSample())
        }
    }

    @Test("Distribution is roughly triangular (mean ~0, includes all three buckets)")
    func roughlyTriangular() {
        var d = TPDFDither(seed: 0xDEADBEEF)
        var counts: [Int16: Int] = [-1: 0, 0: 0, 1: 0]
        var sum = 0
        let n = 200_000
        for _ in 0..<n {
            let s = d.nextNoiseSample()
            counts[s, default: 0] += 1
            sum += Int(s)
        }
        // All three buckets should be populated.
        #expect((counts[-1] ?? 0) > 0)
        #expect((counts[0]  ?? 0) > 0)
        #expect((counts[1]  ?? 0) > 0)
        // Triangular PDF over [-1,+1] integers (after rounding the sum of two
        // half-LSB uniforms) puts ~50% weight on 0 and ~25% on each of ±1.
        let mean = Double(sum) / Double(n)
        #expect(abs(mean) < 0.05)  // mean ≈ 0
    }

    @Test("Seed 0 falls back to a non-zero default")
    func zeroSeedReplaced() {
        var d = TPDFDither(seed: 0)
        // Should still produce a varied stream, not all the same value.
        var first = d.nextNoiseSample()
        var sawDifferent = false
        for _ in 0..<1000 {
            let n = d.nextNoiseSample()
            if n != first { sawDifferent = true; break }
            first = n
        }
        #expect(sawDifferent)
    }
}
