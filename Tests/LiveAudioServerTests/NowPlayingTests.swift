// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServer

@Suite("NowPlaying store and Codable")
struct NowPlayingTests {

    @Test("Empty store has all-nil snapshot")
    func emptySnapshot() {
        let store = NowPlayingStore()
        let snap = store.snapshot
        #expect(snap.title == nil)
        #expect(snap.artist == nil)
        #expect(snap.station == nil)
        #expect(snap.note == nil)
        #expect(snap.updated == nil)
    }

    @Test("Replace sets fields and stamps updated")
    func replaceSetsAndStamps() {
        let store = NowPlayingStore()
        store.replace(with: NowPlayingMetadata(
            title: "Symphony No. 9",
            artist: "Beethoven",
            station: "WCRB",
            note: "Live from Symphony Hall",
            updated: nil
        ))
        let snap = store.snapshot
        #expect(snap.title   == "Symphony No. 9")
        #expect(snap.artist  == "Beethoven")
        #expect(snap.station == "WCRB")
        #expect(snap.note    == "Live from Symphony Hall")
        #expect(snap.updated != nil)
    }

    @Test("Empty strings normalize to nil")
    func emptyStringsClearFields() {
        let store = NowPlayingStore()
        store.replace(with: NowPlayingMetadata(title: "a", artist: "b", station: "c", note: "d"))
        store.replace(with: NowPlayingMetadata(title: "", artist: "", station: "", note: ""))
        let snap = store.snapshot
        #expect(snap.title   == nil)
        #expect(snap.artist  == nil)
        #expect(snap.station == nil)
        #expect(snap.note    == nil)
        #expect(snap.updated != nil)  // updated is always refreshed
    }

    @Test("Posting {} (empty body) clears everything except updated")
    func emptyReplaceClears() {
        let store = NowPlayingStore()
        store.replace(with: NowPlayingMetadata(title: "x"))
        store.replace(with: NowPlayingMetadata())
        let snap = store.snapshot
        #expect(snap.title   == nil)
        #expect(snap.artist  == nil)
        #expect(snap.updated != nil)
    }

    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let original = NowPlayingMetadata(
            title: "T", artist: "A", station: "S", note: "N",
            updated: "2026-05-19T18:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NowPlayingMetadata.self, from: data)
        #expect(decoded.title   == "T")
        #expect(decoded.artist  == "A")
        #expect(decoded.station == "S")
        #expect(decoded.note    == "N")
        #expect(decoded.updated == "2026-05-19T18:00:00Z")
    }

    @Test("JSON decoding tolerates partial bodies")
    func decodePartial() throws {
        let json = #"{"title":"only title"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NowPlayingMetadata.self, from: json)
        #expect(decoded.title  == "only title")
        #expect(decoded.artist == nil)
    }

    @Test("Updated timestamp is ISO 8601 formatted")
    func updatedIsISO8601() {
        let store = NowPlayingStore()
        store.replace(with: NowPlayingMetadata(title: "x"))
        let stamp = store.snapshot.updated ?? ""
        // Should round-trip through ISO8601DateFormatter.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        #expect(f.date(from: stamp) != nil)
    }
}
