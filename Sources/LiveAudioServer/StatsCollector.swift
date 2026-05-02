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

// Sources/LiveAudioServer/StatsCollector.swift
// Lightweight counters powering the optional periodic stats log line.

import Foundation

final class StatsCollector {
    struct Snapshot {
        let mp3BytesEncoded: UInt64
        let aacBytesEncoded: UInt64
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var _mp3BytesEncoded: UInt64 = 0
    private var _aacBytesEncoded: UInt64 = 0
    private let startTime: Date

    init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    func recordMP3Bytes(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        _mp3BytesEncoded += UInt64(count)
    }

    func recordAACBytes(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        _aacBytesEncoded += UInt64(count)
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            mp3BytesEncoded: _mp3BytesEncoded,
            aacBytesEncoded: _aacBytesEncoded,
            uptime: now.timeIntervalSince(startTime)
        )
    }
}

/// Human-readable duration: "42s", "5m", "2h17m", "3d4h0m".
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)s" }
    let m = total / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    let mr = m % 60
    if h < 24 { return "\(h)h\(mr)m" }
    let d = h / 24
    let hr = h % 24
    return "\(d)d\(hr)h\(mr)m"
}

/// Bytes → "1.23 MB" / "456 KB" / "789 B".
func formatBytes(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000 {
        return String(format: "%.2f MB", Double(bytes) / 1_000_000)
    }
    if bytes >= 1_000 {
        return String(format: "%.1f KB", Double(bytes) / 1_000)
    }
    return "\(bytes) B"
}

/// Renders the periodic stats line emitted to stderr.
func formatStatsLine(snapshot: StatsCollector.Snapshot,
                     mp3Clients: Int,
                     aacClients: Int) -> String {
    return "[stats] mp3:\(mp3Clients)c aac:\(aacClients)c | "
         + "mp3 enc \(formatBytes(snapshot.mp3BytesEncoded)) | "
         + "aac enc \(formatBytes(snapshot.aacBytesEncoded)) | "
         + "uptime \(formatDuration(snapshot.uptime))"
}
