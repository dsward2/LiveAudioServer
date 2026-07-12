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

// Sources/LiveAudioServer/Recorder.swift
// File recorder with a runtime state machine (idle / recording / paused),
// controllable both via CLI at launch and via /api/recorder/* at runtime.

import Foundation

enum RecorderError: Error, CustomStringConvertible {
    case cannotOpen(path: String)

    var description: String {
        switch self {
        case .cannotOpen(let p): return "Cannot open recording file for writing: \(p)"
        }
    }
}

final class FileRecorder {
    enum State: String, Codable {
        case idle
        case recording
        case paused
    }

    struct Status: Codable {
        let format: String      // "mp3" or "m4a"
        let state: State
        let path: String?
        let bytesWritten: UInt64
    }

    let format: AudioFormat
    /// All state mutations and writes are serialized on this queue so there's
    /// no race between a `stop()` and a queued `write()`.
    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var _path: String?
    private var _state: State = .idle
    private var _bytesWritten: UInt64 = 0

    init(format: AudioFormat) {
        self.format = format
        self.queue  = DispatchQueue(label: "recorder.\(format.rawValue)")
    }

    var status: Status {
        queue.sync {
            Status(format: format.rawValue, state: _state, path: _path, bytesWritten: _bytesWritten)
        }
    }

    /// Begin recording to `path`. Any existing recording (idle or otherwise)
    /// is stopped first. Truncates the destination file. Leading `~` is
    /// expanded to the process's home directory before the file is created.
    func start(path: String) throws {
        let resolvedPath = (path as NSString).expandingTildeInPath
        try queue.sync {
            closeHandleLocked()
            if !FileManager.default.createFile(atPath: resolvedPath, contents: nil) {
                throw RecorderError.cannotOpen(path: resolvedPath)
            }
            guard let h = FileHandle(forWritingAtPath: resolvedPath) else {
                throw RecorderError.cannotOpen(path: resolvedPath)
            }
            handle = h
            _path = resolvedPath
            _state = .recording
            _bytesWritten = 0
            log("📼 [\(format.rawValue.uppercased())] recording → \(resolvedPath)")
        }
    }

    /// Pause recording. Keeps the file open; subsequent writes are dropped
    /// until `resume()`. No-op unless currently recording.
    func pause() {
        queue.sync {
            if _state == .recording {
                _state = .paused
                log("📼 [\(format.rawValue.uppercased())] paused")
            }
        }
    }

    /// Resume recording into the existing file. No-op unless currently paused.
    func resume() {
        queue.sync {
            if _state == .paused {
                _state = .recording
                log("📼 [\(format.rawValue.uppercased())] resumed")
            }
        }
    }

    /// Stop recording and close the file. Returns to the `idle` state.
    /// `path` and `bytesWritten` are preserved so callers can report where
    /// the file was saved; they reset to nil/0 on the next `start()` call.
    func stop() {
        queue.sync {
            guard _state != .idle else { return }
            closeHandleLocked()
            let p = _path
            _state = .idle
            if let p = p {
                log("📼 [\(format.rawValue.uppercased())] stopped (\(p))")
            }
        }
    }

    /// Called from the broadcaster on each encoded chunk. Fire-and-forget;
    /// the actual write executes on the recorder's queue.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self._state == .recording, let h = self.handle else { return }
            do {
                try h.write(contentsOf: data)
                self._bytesWritten += UInt64(data.count)
            } catch {
                log("⚠ [\(self.format.rawValue.uppercased())] write failed (\(self._path ?? "?")): \(error)")
            }
        }
    }

    // MARK: - Internal

    private func closeHandleLocked() {
        if let h = handle {
            do {
                try h.close()
            } catch {
                log("⚠ [\(format.rawValue.uppercased())] close failed: \(error)")
            }
            handle = nil
        }
    }
}
