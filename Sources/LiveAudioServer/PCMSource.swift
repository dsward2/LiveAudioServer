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

// Sources/LiveAudioServer/PCMSource.swift
// Reads raw 16-bit interleaved PCM from stdin and fans out to registered consumers.

import Foundation

// MARK: - PCM Frame Buffer

/// Thread-safe ring-buffer that distributes PCM chunks to multiple encoder pipelines.
final class PCMBroadcaster {
    typealias Consumer = (UnsafeBufferPointer<Int16>) -> Void

    private let lock = NSLock()
    private var consumers: [UUID: Consumer] = [:]

    func addConsumer(_ handler: @escaping Consumer) -> UUID {
        let id = UUID()
        lock.lock(); consumers[id] = handler; lock.unlock()
        return id
    }

    func removeConsumer(id: UUID) {
        lock.lock(); consumers.removeValue(forKey: id); lock.unlock()
    }

    /// Called by the stdin reader with each newly read PCM chunk.
    func broadcast(_ buffer: UnsafeBufferPointer<Int16>) {
        lock.lock()
        let snapshot = consumers
        lock.unlock()
        for (_, handler) in snapshot {
            handler(buffer)
        }
    }
}

// MARK: - PCM Reader

/// Continuously reads raw 16-bit little-endian interleaved PCM from stdin, UDP,
/// or TCP and broadcasts frames to all registered consumers.
final class PCMReader {
    private let config: ServerConfig
    private let broadcaster: PCMBroadcaster
    private var isRunning = false
    private var inputSocketFD: Int32 = -1
    private var listenSocketFD: Int32 = -1

    init(config: ServerConfig, broadcaster: PCMBroadcaster) {
        self.config = config
        self.broadcaster = broadcaster
    }

    /// Blocks the calling thread — run on a dedicated background thread.
    func run() {
        isRunning = true
        log("PCM reader: source=\(config.inputSource) channels=\(config.channels) sampleRate=\(config.sampleRate)Hz " +
            "chunkFrames=\(config.stdinChunkFrames) chunkBytes=\(config.stdinChunkBytes)")

        switch config.inputSource {
        case .stdin:
            runFromFileDescriptor(FileHandle.standardInput.fileDescriptor, eofLabel: "stdin EOF")
        case .udp(let port):
            runUDP(port: port)
        case .tcp(let port):
            runTCP(port: port)
        }

        log("PCM reader exited")
        // Signal encoders to flush
        broadcaster.broadcast(UnsafeBufferPointer(start: nil, count: 0))
    }

    func stop() {
        isRunning = false
        if inputSocketFD >= 0 { close(inputSocketFD); inputSocketFD = -1 }
        if listenSocketFD >= 0 { close(listenSocketFD); listenSocketFD = -1 }
    }

    private func runFromFileDescriptor(_ fd: Int32, eofLabel: String) {
        let chunkBytes = config.stdinChunkBytes
        var buf = [UInt8](repeating: 0, count: chunkBytes)

        while isRunning {
            var totalRead = 0
            while totalRead < chunkBytes {
                let n = buf.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return read(fd, baseAddress.advanced(by: totalRead), chunkBytes - totalRead)
                }
                if n <= 0 {
                    if n == 0 {
                        log("\(eofLabel) — shutting down")
                    } else if errno != EBADF {
                        log("PCM read error: \(String(cString: strerror(errno)))")
                    }
                    isRunning = false
                    break
                }
                totalRead += n
            }

            guard totalRead > 0 else { break }
            broadcastPCMBytes(Array(buf.prefix(totalRead)))
        }
    }

    private func runUDP(port: UInt16) {
        let socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            log("UDP socket creation failed: \(String(cString: strerror(errno)))")
            isRunning = false
            return
        }
        inputSocketFD = socketFD

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Dual-stack: accept both IPv4 (via v4-mapped addresses) and IPv6 senders.
        var v6only: Int32 = 0
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            log("UDP bind failed on port \(port): \(String(cString: strerror(errno)))")
            close(socketFD)
            inputSocketFD = -1
            isRunning = false
            return
        }

        log("Listening for UDP PCM on [::]:\(port) (IPv4 + IPv6)")
        let chunkBytes = config.stdinChunkBytes
        var readBuf = [UInt8](repeating: 0, count: max(chunkBytes, 65536))
        var pending = [UInt8]()

        while isRunning {
            var recvErrno: Int32 = 0
            let n = readBuf.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                let result = recv(socketFD, baseAddress, rawBuffer.count, 0)
                if result < 0 { recvErrno = errno }
                return result
            }
            if n < 0 {
                if recvErrno != EBADF {
                    log("UDP receive error: \(String(cString: strerror(recvErrno)))")
                }
                break
            }
            // n == 0 is a zero-length datagram (e.g. paused sender) — not an error;
            // keep waiting for more packets.
            if n == 0 { continue }

            pending.append(contentsOf: readBuf.prefix(n))
            drainPendingPCM(&pending, chunkBytes: chunkBytes)
        }
    }

    private func runTCP(port: UInt16) {
        let socketFD = socket(AF_INET6, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            log("TCP socket creation failed: \(String(cString: strerror(errno)))")
            isRunning = false
            return
        }
        listenSocketFD = socketFD

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Dual-stack: accept both IPv4 (via v4-mapped addresses) and IPv6 clients.
        var v6only: Int32 = 0
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            log("TCP bind failed on port \(port): \(String(cString: strerror(errno)))")
            close(socketFD)
            listenSocketFD = -1
            isRunning = false
            return
        }

        guard listen(socketFD, 4) == 0 else {
            log("TCP listen failed on port \(port): \(String(cString: strerror(errno)))")
            close(socketFD)
            listenSocketFD = -1
            isRunning = false
            return
        }

        log("Listening for TCP PCM on [::]:\(port) (IPv4 + IPv6)")
        while isRunning {
            let clientFD = accept(socketFD, nil, nil)
            if clientFD < 0 {
                if errno != EBADF {
                    log("TCP accept error: \(String(cString: strerror(errno)))")
                }
                break
            }

            inputSocketFD = clientFD
            log("TCP PCM client connected on port \(port)")
            runFromFileDescriptor(clientFD, eofLabel: "TCP PCM client disconnected")
            if clientFD >= 0 { close(clientFD) }
            inputSocketFD = -1

            if !config.keepAliveOnInputEnd {
                break
            }
            isRunning = true
            log("Waiting for next TCP PCM client because --keep-alive is enabled.")
        }
    }

    private func drainPendingPCM(_ pending: inout [UInt8], chunkBytes: Int) {
        while pending.count >= chunkBytes {
            let chunk = Array(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            broadcastPCMBytes(chunk)
        }
    }

    private func broadcastPCMBytes(_ bytes: [UInt8]) {
        let sampleCount = bytes.count / 2
        guard sampleCount > 0 else { return }
        bytes.withUnsafeBytes { rawPtr in
            let samples = rawPtr.bindMemory(to: Int16.self)
            broadcaster.broadcast(UnsafeBufferPointer(start: samples.baseAddress, count: sampleCount))
        }
    }
}
