// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
@testable import LiveAudioServer

@Suite("ADTS header")
struct ADTSHeaderTests {

    @Test("7-byte header with correct sync bytes")
    func headerHasSyncAndLength() {
        let header = adtsHeader(frameLength: 100, sampleRate: 48000, channels: 2)
        #expect(header.count == 7)
        // Sync word: 12 bits of 1s (0xFFF), low nibble of byte[1] encodes
        // MPEG version (0 = MPEG-4) and CRC absence (1 = no CRC), so 0xF1.
        #expect(header[0] == 0xFF)
        #expect(header[1] == 0xF1)
    }

    @Test("Profile field encodes AAC-LC")
    func profileEncodesAACLC() {
        // adtsHeader hard-codes aacProfile=2 (AAC-LC). Profile bits = (aacProfile - 1) << 6
        // → top two bits of byte[2] = 0b01_000000 = 0x40.
        let header = adtsHeader(frameLength: 100, sampleRate: 48000, channels: 2)
        #expect((header[2] & 0xC0) == 0x40)
    }

    @Test("Sample rate index is correct for 48 kHz")
    func sampleRateIndex48000() {
        // 48 kHz → index 3 → bits 5..2 of byte[2] = 0b0011 << 2 = 0x0C
        let header = adtsHeader(frameLength: 100, sampleRate: 48000, channels: 2)
        let freqIndex = (header[2] >> 2) & 0x0F
        #expect(freqIndex == 3)
    }

    @Test("Sample rate index is correct for 44.1 kHz")
    func sampleRateIndex44100() {
        let header = adtsHeader(frameLength: 100, sampleRate: 44100, channels: 2)
        let freqIndex = (header[2] >> 2) & 0x0F
        #expect(freqIndex == 4)
    }

    @Test("Channel configuration field reflects stereo")
    func channelConfigStereo() {
        // channelConfig occupies bit 0 of byte[2] (top bit) and bits 7..6 of byte[3].
        // For 2 channels (0b010), low bit goes to byte[2] LSB (0), high bits go to
        // byte[3] top two bits (0b10 << 6 = 0x80).
        let header = adtsHeader(frameLength: 100, sampleRate: 48000, channels: 2)
        let channelConfig = ((header[2] & 0x01) << 2) | ((header[3] >> 6) & 0x03)
        #expect(channelConfig == 2)
    }

    @Test("Channel configuration field reflects mono")
    func channelConfigMono() {
        let header = adtsHeader(frameLength: 100, sampleRate: 48000, channels: 1)
        let channelConfig = ((header[2] & 0x01) << 2) | ((header[3] >> 6) & 0x03)
        #expect(channelConfig == 1)
    }

    @Test("Frame length field encodes payload + 7-byte header")
    func frameLengthIncludesHeader() {
        let frameLength = 256
        let header = adtsHeader(frameLength: frameLength, sampleRate: 48000, channels: 2)
        // 13 bits of length packed across bytes [3]..[5]:
        //   byte[3] low 2 bits  = bits 12..11
        //   byte[4] all 8 bits  = bits 10..3
        //   byte[5] top 3 bits  = bits 2..0
        let hi    = UInt32(header[3] & 0x03) << 11
        let mid   = UInt32(header[4]) << 3
        let lo    = UInt32(header[5] >> 5) & 0x07
        let total = Int(hi | mid | lo)
        #expect(total == frameLength + 7)
    }
}
