// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

// Sources/LiveAudioServer/NowPlaying.swift
// In-memory store for "now playing" metadata, surfaced through the status
// page and updated by external processes via POST /api/now-playing.

import Foundation

/// Free-form "now playing" record. All fields are optional. The `updated`
/// field is server-set when the store is mutated.
struct NowPlayingMetadata: Codable {
    var title: String?
    var artist: String?
    var station: String?
    var note: String?
    /// ISO 8601 timestamp of the last mutation. Server-managed.
    var updated: String?
}

/// Thread-safe holder for the current `NowPlayingMetadata`. The store is
/// replaced as a whole on POST — there's no per-field patching.
final class NowPlayingStore {
    private let lock = NSLock()
    private var current = NowPlayingMetadata()

    var snapshot: NowPlayingMetadata {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Replace the current record with `incoming`. Empty strings are normalized
    /// to nil so omitted fields render as "—" on the status page.
    func replace(with incoming: NowPlayingMetadata) {
        lock.lock(); defer { lock.unlock() }
        func cleaned(_ s: String?) -> String? {
            guard let s = s, !s.isEmpty else { return nil }
            return s
        }
        current.title   = cleaned(incoming.title)
        current.artist  = cleaned(incoming.artist)
        current.station = cleaned(incoming.station)
        current.note    = cleaned(incoming.note)
        current.updated = Date.now.ISO8601Format()
    }
}
