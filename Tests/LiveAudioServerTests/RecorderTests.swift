// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
@testable import LiveAudioServerCore

@Suite("FileRecorder state machine")
struct RecorderTests {

    /// Returns a fresh, unique scratch path inside the OS temp directory.
    private func tempPath(suffix: String = ".bin") -> String {
        let dir = FileManager.default.temporaryDirectory
        let name = "liveaudio-recorder-\(UUID().uuidString)\(suffix)"
        return dir.appendingPathComponent(name).path
    }

    /// Wait for fire-and-forget writes on the recorder's queue to drain.
    /// Status reads are sync on the same queue, so checking `.status` is the
    /// natural fence we use throughout the tests.
    private func drain(_ recorder: FileRecorder) {
        _ = recorder.status
    }

    @Test("Initial state is idle")
    func initialIdle() {
        let r = FileRecorder(format: .mp3)
        let s = r.status
        #expect(s.state == .idle)
        #expect(s.path == nil)
        #expect(s.bytesWritten == 0)
        #expect(s.format == "mp3")
    }

    @Test("start opens the file and flips to recording")
    func startBeginsRecording() throws {
        let path = tempPath(suffix: ".mp3")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = FileRecorder(format: .mp3)
        try r.start(path: path)
        let s = r.status
        #expect(s.state == .recording)
        #expect(s.path == path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Writes while recording reach disk and bump bytesWritten")
    func writesAreCounted() throws {
        let path = tempPath(suffix: ".mp3")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = FileRecorder(format: .mp3)
        try r.start(path: path)
        r.write(Data([0x01, 0x02, 0x03, 0x04]))
        r.write(Data(repeating: 0xAA, count: 10))
        drain(r)
        #expect(r.status.bytesWritten == 14)
        // Verify the file contents.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(onDisk.count == 14)
        #expect(onDisk.prefix(4) == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("pause drops subsequent writes; resume restores them")
    func pauseAndResume() throws {
        let path = tempPath(suffix: ".mp3")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = FileRecorder(format: .mp3)
        try r.start(path: path)
        r.write(Data(repeating: 0x11, count: 5))
        drain(r)

        r.pause()
        #expect(r.status.state == .paused)
        r.write(Data(repeating: 0x22, count: 5))   // should NOT land
        drain(r)
        #expect(r.status.bytesWritten == 5)

        r.resume()
        #expect(r.status.state == .recording)
        r.write(Data(repeating: 0x33, count: 5))
        drain(r)
        #expect(r.status.bytesWritten == 10)
    }

    @Test("stop closes the file and returns to idle")
    func stopReturnsToIdle() throws {
        let path = tempPath(suffix: ".mp3")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = FileRecorder(format: .mp3)
        try r.start(path: path)
        r.write(Data(repeating: 0xCC, count: 8))
        drain(r)
        r.stop()
        let s = r.status
        #expect(s.state == .idle)
        #expect(s.path == nil)
        #expect(s.bytesWritten == 0)
        // The file should still exist on disk with the bytes we wrote before stop.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(onDisk.count == 8)
    }

    @Test("start while already recording rotates to the new path")
    func startWhileRecordingRotates() throws {
        let firstPath  = tempPath(suffix: "-first.mp3")
        let secondPath = tempPath(suffix: "-second.mp3")
        defer {
            try? FileManager.default.removeItem(atPath: firstPath)
            try? FileManager.default.removeItem(atPath: secondPath)
        }
        let r = FileRecorder(format: .mp3)
        try r.start(path: firstPath)
        r.write(Data(repeating: 0xFE, count: 100))
        drain(r)

        try r.start(path: secondPath)
        #expect(r.status.path == secondPath)
        #expect(r.status.bytesWritten == 0)

        r.write(Data(repeating: 0xFF, count: 7))
        drain(r)
        #expect(r.status.bytesWritten == 7)

        // First file still has its 100 bytes; the second file has the 7.
        let first  = try Data(contentsOf: URL(fileURLWithPath: firstPath))
        let second = try Data(contentsOf: URL(fileURLWithPath: secondPath))
        #expect(first.count == 100)
        #expect(second.count == 7)
    }

    @Test("Bad path returns a RecorderError")
    func badPathThrows() {
        let r = FileRecorder(format: .mp3)
        // A path under a non-existent directory should fail.
        let bad = "/this/does/not/exist/and/cannot/be/created/\(UUID().uuidString).mp3"
        #expect(throws: RecorderError.self) {
            try r.start(path: bad)
        }
        #expect(r.status.state == .idle)
    }

    @Test("Status is Codable in both directions")
    func statusCodable() throws {
        let s = FileRecorder.Status(format: "mp3", state: .recording, path: "/tmp/x.mp3", bytesWritten: 42)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(FileRecorder.Status.self, from: data)
        #expect(decoded.format == "mp3")
        #expect(decoded.state == .recording)
        #expect(decoded.path == "/tmp/x.mp3")
        #expect(decoded.bytesWritten == 42)
    }
}
