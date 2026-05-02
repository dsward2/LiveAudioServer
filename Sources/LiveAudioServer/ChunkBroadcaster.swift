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

// Sources/LiveAudioServer/ChunkBroadcaster.swift
// Thread-safe broadcaster that fans out encoded audio chunks to all connected
// HTTP streaming clients for a given format.

import Foundation
import Network

// MARK: - Client Slot

final class StreamClient {
    let id: UUID
    let connection: NWConnection
    let format: AudioFormat
    private var isActive: Bool = true
    private let sendQueue = DispatchQueue(label: "client.send")
    private var pendingBytes: Int = 0
    private let maxPendingBytes = 2 * 1024 * 1024  // 2MB back-pressure limit

    init(id: UUID, connection: NWConnection, format: AudioFormat) {
        self.id = id
        self.connection = connection
        self.format = format
    }

    /// Send a chunk to this client. Returns false if the client is congested / dead.
    func send(_ data: Data, verbose: Bool) -> Bool {
        guard isActive else { return false }
        guard pendingBytes < maxPendingBytes else {
            if verbose { log("Client \(id.uuidString.prefix(8)) congested, dropping chunk") }
            return true  // still alive, just slow
        }

        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.pendingBytes -= data.count
            if let error = error {
                if verbose { log("Client \(self.id.uuidString.prefix(8)) send error: \(error)") }
                self.isActive = false
            }
        })
        return true
    }

    func close() {
        isActive = false
        connection.cancel()
    }
}

// MARK: - ChunkBroadcaster

/// One broadcaster instance per audio format (MP3, M4A/AAC).
/// Receives encoded chunks and fans them out to all connected clients.
final class ChunkBroadcaster {
    let format: AudioFormat
    private let lock    = NSLock()
    private var clients = [UUID: StreamClient]()
    private let verbose: Bool
    /// Invoked synchronously with each broadcast chunk's bytes. Callers can
    /// use this to accumulate per-format counters (StatsCollector), tee to
    /// disk (FileRecorder), or any other side channel, without coupling the
    /// broadcaster to those subsystems.
    private let onBroadcast: ((Data) -> Void)?

    init(format: AudioFormat, verbose: Bool = false, onBroadcast: ((Data) -> Void)? = nil) {
        self.format      = format
        self.verbose     = verbose
        self.onBroadcast = onBroadcast
    }

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.count
    }

    // MARK: - Client Management

    func addClient(_ client: StreamClient) {
        lock.lock(); clients[client.id] = client; lock.unlock()
        log("[\(format.rawValue.uppercased())] Client connected: \(client.id.uuidString.prefix(8)) " +
            "(total: \(clientCount))")
    }

    func removeClient(id: UUID) {
        lock.lock()
        clients.removeValue(forKey: id)
        lock.unlock()
        log("[\(format.rawValue.uppercased())] Client disconnected: \(id.uuidString.prefix(8)) " +
            "(remaining: \(clientCount))")
    }

    /// Cancel every active client and clear the map. Called during graceful
    /// shutdown so in-flight stream connections are closed deterministically
    /// instead of being torn down mid-write by `exit()`.
    func closeAll() {
        lock.lock()
        let snapshot = clients
        clients.removeAll()
        lock.unlock()
        for (_, client) in snapshot {
            client.close()
        }
        if !snapshot.isEmpty {
            log("[\(format.rawValue.uppercased())] Closed \(snapshot.count) client(s) on shutdown")
        }
    }

    // MARK: - Broadcast

    /// Called by an encoder with each freshly encoded chunk.
    func broadcast(_ data: Data) {
        guard !data.isEmpty else { return }
        onBroadcast?(data)
        lock.lock()
        let snapshot = clients
        lock.unlock()

        var toRemove = [UUID]()
        for (id, client) in snapshot {
            if !client.send(data, verbose: verbose) {
                toRemove.append(id)
            }
        }
        if !toRemove.isEmpty {
            lock.lock()
            toRemove.forEach { clients.removeValue(forKey: $0) }
            lock.unlock()
            log("[\(format.rawValue.uppercased())] Removed \(toRemove.count) dead client(s)")
        }
    }
}
