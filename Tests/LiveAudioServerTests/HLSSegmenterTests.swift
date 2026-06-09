// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServerCore

@Suite("HLS segmenter")
struct HLSSegmenterTests {

    private func playlistText(_ segmenter: HLSSegmenter, indexPath: String = "/hls/index.m3u8") -> String {
        String(data: segmenter.playlistData(indexPath: indexPath), encoding: .utf8) ?? ""
    }

    @Test("Empty playlist has header and zero EXTINF entries")
    func emptyPlaylist() {
        let s = HLSSegmenter(sampleRate: 48000,
                             segmentDurationTarget: 2.0,
                             maxSegmentCount: 5,
                             segmentPathPrefix: "/hls/seg-")
        let text = playlistText(s)
        #expect(text.contains("#EXTM3U"))
        #expect(text.contains("#EXT-X-VERSION:3"))
        #expect(text.contains("#EXT-X-TARGETDURATION:2"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(!text.contains("#EXTINF:"))
    }

    @Test("Appending enough frames finalizes a segment")
    func segmentFinalizesAtTarget() {
        // At 48000 Hz the frame duration is 1024/48000 ≈ 21.33 ms.
        // A 2.0 s target requires ~94 frames. Push 100 to be safe.
        let s = HLSSegmenter(sampleRate: 48000,
                             segmentDurationTarget: 2.0,
                             maxSegmentCount: 5,
                             segmentPathPrefix: "/hls/seg-")
        let frame = Data(repeating: 0xAA, count: 256)
        for _ in 0..<100 { s.appendFrame(frame) }

        let text = playlistText(s)
        #expect(text.contains("#EXTINF:"))
        #expect(text.contains("/hls/seg-0.aac"))
        #expect(s.sequenceNumber(for: "/hls/seg-0.aac") == 0)
        #expect(s.segmentData(for: "/hls/seg-0.aac") != nil)
    }

    @Test("Playlist window is bounded by maxSegmentCount")
    func playlistWindowTrims() {
        // maxSegmentCount is clamped to at least 3 by the segmenter.
        let s = HLSSegmenter(sampleRate: 48000,
                             segmentDurationTarget: 0.05,   // small target so each finalize is fast
                             maxSegmentCount: 3,
                             segmentPathPrefix: "/hls/seg-")
        // Each appendFrame adds ~21.33 ms. Push enough frames to produce >3 segments
        // (force-finalize between to keep the math obvious).
        let frame = Data(repeating: 0xAA, count: 16)
        for _ in 0..<10 {
            for _ in 0..<3 { s.appendFrame(frame) }
            s.finalizePendingSegment()
        }
        // The playlist should now reference segments [7,8,9].
        let text = playlistText(s)
        #expect(text.contains("/hls/seg-7.aac"))
        #expect(text.contains("/hls/seg-8.aac"))
        #expect(text.contains("/hls/seg-9.aac"))
        #expect(!text.contains("/hls/seg-0.aac"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:7"))
    }

    @Test("sequenceNumber rejects non-matching paths")
    func sequenceNumberRejects() {
        let s = HLSSegmenter(sampleRate: 48000,
                             segmentDurationTarget: 2.0,
                             maxSegmentCount: 5,
                             segmentPathPrefix: "/hls/seg-")
        #expect(s.sequenceNumber(for: "/hls/index.m3u8") == nil)
        #expect(s.sequenceNumber(for: "/hls/seg-3.mp3") == nil)   // wrong extension
        #expect(s.sequenceNumber(for: "/other/seg-3.aac") == nil) // wrong prefix
        #expect(s.sequenceNumber(for: "/hls/seg-12.aac") == 12)
    }
}
