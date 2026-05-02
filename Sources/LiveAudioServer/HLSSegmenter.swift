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

import Foundation

struct HLSSegment {
    let sequenceNumber: Int
    let duration: Double
    let data: Data
}

final class HLSSegmenter {
    private let lock = NSLock()
    private let segmentDurationTarget: Double
    private let maxSegmentCount: Int
    private let frameDuration: Double
    private let segmentPathPrefix: String

    private var segments = [HLSSegment]()
    private var currentSegmentData = Data()
    private var currentSegmentDuration: Double = 0
    private var nextSequenceNumber = 0

    init(sampleRate: Int,
         segmentDurationTarget: Double,
         maxSegmentCount: Int,
         segmentPathPrefix: String) {
        self.segmentDurationTarget = segmentDurationTarget
        self.maxSegmentCount = max(3, maxSegmentCount)
        self.frameDuration = 1024.0 / Double(sampleRate)
        self.segmentPathPrefix = segmentPathPrefix
    }

    func appendFrame(_ frame: Data) {
        lock.lock()
        currentSegmentData.append(frame)
        currentSegmentDuration += frameDuration
        if currentSegmentDuration >= segmentDurationTarget {
            finalizeCurrentSegmentLocked()
        }
        lock.unlock()
    }

    func finalizePendingSegment() {
        lock.lock()
        if !currentSegmentData.isEmpty {
            finalizeCurrentSegmentLocked()
        }
        lock.unlock()
    }

    func playlistData(indexPath: String) -> Data {
        lock.lock()
        let snapshot = segments
        let targetDuration = max(segmentDurationTarget, snapshot.map(\.duration).max() ?? segmentDurationTarget)
        lock.unlock()

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(ceil(targetDuration)))",
            "#EXT-X-MEDIA-SEQUENCE:\(snapshot.first?.sequenceNumber ?? 0)"
        ]

        for segment in snapshot {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segmentPath(for: segment.sequenceNumber))
        }

        lines.append("")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    func segmentData(for path: String) -> Data? {
        guard let sequenceNumber = sequenceNumber(for: path) else { return nil }
        lock.lock()
        let data = segments.first(where: { $0.sequenceNumber == sequenceNumber })?.data
        lock.unlock()
        return data
    }

    func sequenceNumber(for path: String) -> Int? {
        guard path.hasPrefix(segmentPathPrefix), path.hasSuffix(".aac") else { return nil }
        let start = path.index(path.startIndex, offsetBy: segmentPathPrefix.count)
        let end = path.index(path.endIndex, offsetBy: -4)
        return Int(path[start..<end])
    }

    private func segmentPath(for sequenceNumber: Int) -> String {
        "\(segmentPathPrefix)\(sequenceNumber).aac"
    }

    private func finalizeCurrentSegmentLocked() {
        let segment = HLSSegment(sequenceNumber: nextSequenceNumber,
                                 duration: currentSegmentDuration,
                                 data: currentSegmentData)
        segments.append(segment)
        if segments.count > maxSegmentCount {
            segments.removeFirst(segments.count - maxSegmentCount)
        }
        nextSequenceNumber += 1
        currentSegmentData = Data()
        currentSegmentDuration = 0
    }
}
