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

// MARK: - TPDF Dither

/// Triangular probability density function (TPDF) dither generator for 16-bit
/// PCM. TPDF dither is the textbook way to mask the "all zeros" pattern that
/// digital silence produces, without becoming audible:
///
///   • Two independent uniform random numbers in [-0.5, +0.5] are summed.
///   • The sum has a triangular PDF over [-1.0, +1.0] LSB.
///   • This decorrelates the noise from the signal (unlike pure rectangular
///     dither) and yields a flat, neutral hiss instead of a tonal artifact.
///
/// At ±1 LSB peak the resulting noise floor sits around -90 dBFS for 16-bit
/// PCM — well below the threshold of audibility for any realistic listening
/// environment, yet enough to make every emitted sample non-zero so the
/// stream never looks digitally dead to downstream tools.
struct TPDFDither {
    private var state: UInt64

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        // SplitMix64-style state — any non-zero seed is fine.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// Returns the next TPDF-distributed integer noise sample in
    /// {-1, 0, +1}. Internal RNG is a fast SplitMix64 — deterministic from
    /// the seed, which keeps tests reproducible.
    mutating func nextNoiseSample() -> Int16 {
        let r1 = Double(splitMix64() >> 11) * (1.0 / Double(1 << 53)) - 0.5
        let r2 = Double(splitMix64() >> 11) * (1.0 / Double(1 << 53)) - 0.5
        return Int16((r1 + r2).rounded())  // [-1.0, +1.0] → {-1, 0, +1}
    }

    private mutating func splitMix64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Filler Generator

/// Generates the PCM that the reader broadcasts during silence-fill — either
/// digital zero (silence) or a continuous sine wave (tone). The generator
/// owns its phase accumulator so successive chunks join without clicks.
struct FillerGenerator {
    /// Default tone amplitude: -20 dBFS. That's the BBC/EBU reference for a
    /// broadcast test tone — clearly audible without being painful. Kept fixed
    /// for the first cut; can be exposed as a CLI knob later if anyone asks.
    static let toneAmplitudePeakI16: Int32 = 3277   // round(32767 × 10^(-20/20))

    let mode: FillerMode
    let channels: Int
    let sampleRate: Int
    let toneHz: Double

    /// Radians per sample. Zero for `.silence`.
    private let phaseIncrement: Double
    /// Cumulative phase in radians, modulo 2π. Carried across chunks so the
    /// sine is continuous and won't click at chunk boundaries.
    private var phase: Double = 0

    init(mode: FillerMode, channels: Int, sampleRate: Int, toneHz: Double) {
        self.mode        = mode
        self.channels    = channels
        self.sampleRate  = sampleRate
        self.toneHz      = toneHz
        self.phaseIncrement = (mode == .tone)
            ? (2.0 * .pi * toneHz / Double(sampleRate))
            : 0.0
    }

    /// Write one chunk's worth of filler PCM into the caller's byte buffer
    /// (interleaved 16-bit little-endian). The buffer length must be a
    /// multiple of `bytesPerFrame`.
    mutating func fillChunk(_ bytes: inout [UInt8]) {
        switch mode {
        case .silence:
            // Zero-fill is the historical behavior. Cheaper than calling
            // memset, but bytes is already zero on first fill — re-zero in
            // case the caller reused a buffer.
            for i in 0..<bytes.count { bytes[i] = 0 }
        case .tone:
            let bytesPerFrame = channels * 2
            let frameCount    = bytes.count / bytesPerFrame
            let amp           = Double(Self.toneAmplitudePeakI16)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for f in 0..<frameCount {
                    let sample = Int16(truncatingIfNeeded: Int32((sin(phase) * amp).rounded()))
                    for ch in 0..<channels {
                        base[f * channels + ch] = sample
                    }
                    phase += phaseIncrement
                    if phase >= 2 * .pi { phase -= 2 * .pi }
                }
            }
        }
    }
}

// MARK: - PCM Reader

/// Continuously reads raw 16-bit little-endian interleaved PCM from stdin, UDP,
/// or TCP and broadcasts frames to all registered consumers.
final class PCMReader: @unchecked Sendable {
    private let config: ServerConfig
    private let broadcaster: PCMBroadcaster
    private var isRunning = false
    /// Set by `stop()` to break out of every loop unconditionally. Distinct
    /// from `isRunning` so we can tell "natural EOF" (isRunning flipped by
    /// the read loop) apart from "user asked us to quit".
    private var shutdownRequested = false
    private var inputSocketFD: Int32 = -1
    private var listenSocketFD: Int32 = -1
    private var dither = TPDFDither()
    /// Counter of consecutive all-zero samples observed in the broadcast
    /// stream. Reset to zero whenever any non-zero sample is encountered.
    private var consecutiveZeroSamples: Int = 0

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
            runStdin()
        case .udp(let port):
            runUDP(port: port)
        case .tcp(let port):
            runTCP(port: port)
        }

        log("PCM reader exited")
        // Signal encoders to flush
        broadcaster.broadcast(UnsafeBufferPointer(start: nil, count: 0))
    }

    /// Drive the stdin input. Reads until EOF; if `--keep-alive` is on we
    /// either (a) re-open the underlying FIFO so a new producer can attach,
    /// or (b) generate silence at chunk cadence so encoders / HLS keep
    /// producing output until `stop()` is called. Plain pipes (shell `|`) are
    /// not reopenable; only true FIFOs (made with `mkfifo`) qualify.
    private func runStdin() {
        let stdinFD = FileHandle.standardInput.fileDescriptor
        let isFIFO = fileDescriptorIsFIFO(stdinFD)
        let fifoPath = isFIFO ? resolveFIFOPath(forFD: stdinFD) : nil

        runFromFileDescriptor(stdinFD, eofLabel: "stdin EOF")

        guard config.keepAliveOnInputEnd else { return }

        // After EOF: hold the broadcast open until stop() is called. If
        // stdin was a real FIFO we try to reopen it each time a producer
        // disconnects, falling back to silence-fill between attaches.
        while !shutdownRequested {
            if let path = fifoPath, config.reopenStdinFIFO {
                log("stdin FIFO closed — reopening \(path) for next producer")
                let newFD = open(path, O_RDONLY)
                if newFD >= 0 {
                    isRunning = true
                    runFromFileDescriptor(newFD, eofLabel: "stdin FIFO EOF")
                    close(newFD)
                    continue
                }
                log("Reopen failed (\(String(cString: strerror(errno)))) — falling back to silence-fill")
            }

            log("Holding stream open with silence-fill until stop")
            isRunning = true
            runSilenceFill()
            // After silence-fill returns, fall through to the next loop
            // iteration. If stdin is a FIFO and reopen is allowed, the next
            // pass will try to reattach; otherwise we'll silence-fill again.
        }
    }

    /// Returns true if the given file descriptor refers to a FIFO (named
    /// pipe). Plain pipes from a shell `|` are *also* FIFOs from the kernel's
    /// perspective but they have no path on disk, so `resolveFIFOPath` will
    /// return nil for them.
    private func fileDescriptorIsFIFO(_ fd: Int32) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFIFO
    }

    /// Try to recover the on-disk path of a FIFO via `F_GETPATH`. Returns nil
    /// if the FIFO has no path (i.e. is an anonymous shell pipe) or the
    /// fcntl fails.
    private func resolveFIFOPath(forFD fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return fcntl(fd, F_GETPATH, base)
        }
        guard result == 0 else { return nil }
        let path = String(cString: buffer)
        // Anonymous pipes resolve to paths like "pipe:[12345]" or fail.
        if path.isEmpty || path.hasPrefix("pipe:") { return nil }
        return path
    }

    /// Generate filler PCM at the same cadence as a real input would, so
    /// encoders see a continuous stream. Filler is either digital silence
    /// (default, optionally TPDF-dithered downstream) or a continuous sine
    /// wave when `--filler-mode tone` is configured.
    /// Returns when `shutdownRequested` flips true.
    private func runSilenceFill() {
        let chunkBytes = config.stdinChunkBytes
        var fillerBuf  = [UInt8](repeating: 0, count: chunkBytes)
        var generator  = FillerGenerator(mode: config.fillerMode,
                                         channels: config.channels,
                                         sampleRate: config.sampleRate,
                                         toneHz: config.fillerToneHz)
        // Inter-chunk delay = chunkFrames / sampleRate seconds, converted to
        // microseconds for usleep. Sleeping for exactly one chunk's duration
        // keeps the broadcast paced like live input.
        let chunkPeriodUSec = UInt32(
            (Double(config.stdinChunkFrames) / Double(config.sampleRate)) * 1_000_000
        )

        if config.fillerMode == .tone {
            log(String(format: "Filler: %.0f Hz sine tone at -20 dBFS until input resumes",
                       config.fillerToneHz))
        }

        while !shutdownRequested {
            generator.fillChunk(&fillerBuf)
            broadcastPCMBytes(fillerBuf)
            usleep(chunkPeriodUSec)
        }
    }

    func stop() {
        shutdownRequested = true
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

        // SO_RCVTIMEO turns recv() into a polling call — it returns EAGAIN
        // every chunk period when no packets arrive. We use that signal both
        // for pacing the broadcast (so encoders see a continuous stream when
        // the sender is idle) and to drive filler emission once the
        // `fillerAfterMs` debounce window elapses.
        applyChunkPeriodRecvTimeout(socketFD)

        log("Listening for UDP PCM on [::]:\(port) (IPv4 + IPv6)")
        let chunkBytes = config.stdinChunkBytes
        var readBuf = [UInt8](repeating: 0, count: max(chunkBytes, 65536))
        var pending = [UInt8]()

        var fillerGen = FillerGenerator(mode: config.fillerMode,
                                        channels: config.channels,
                                        sampleRate: config.sampleRate,
                                        toneHz: config.fillerToneHz)
        var fillerBuf = [UInt8](repeating: 0, count: chunkBytes)
        let timeoutsBeforeFiller = max(1, config.fillerAfterMs / chunkPeriodMs)
        var consecutiveTimeouts = 0
        var fillerActive = false

        while isRunning {
            var recvErrno: Int32 = 0
            let n = readBuf.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                let result = recv(socketFD, baseAddress, rawBuffer.count, 0)
                if result < 0 { recvErrno = errno }
                return result
            }
            if n < 0 {
                if recvErrno == EAGAIN || recvErrno == EWOULDBLOCK {
                    // recv timeout — no UDP traffic this chunk period.
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts >= timeoutsBeforeFiller {
                        if !fillerActive {
                            log("UDP input idle — emitting \(config.fillerMode) filler until traffic resumes")
                            fillerActive = true
                        }
                        fillerGen.fillChunk(&fillerBuf)
                        broadcastPCMBytes(fillerBuf)
                    }
                    continue
                }
                if recvErrno != EBADF {
                    log("UDP receive error: \(String(cString: strerror(recvErrno)))")
                }
                break
            }
            // n == 0 is a zero-length datagram (e.g. paused sender) — not an error;
            // keep waiting for more packets.
            if n == 0 { continue }

            if fillerActive {
                log("UDP input resumed — filler ended")
                fillerActive = false
                // Drop accumulated pending bytes from before the gap; they're
                // stale and would inject a small time-warp into the live audio.
                pending.removeAll(keepingCapacity: true)
            }
            consecutiveTimeouts = 0
            pending.append(contentsOf: readBuf.prefix(n))
            drainPendingPCM(&pending, chunkBytes: chunkBytes)
        }
    }

    /// Chunk period in milliseconds, used both as the socket recv timeout and
    /// as the unit for the filler-after-ms debounce.
    private var chunkPeriodMs: Int {
        max(1, (config.stdinChunkFrames * 1000) / config.sampleRate)
    }

    /// Configure SO_RCVTIMEO so `recv()` / `read()` on the given socket returns
    /// EAGAIN every chunk period when no data is arriving.
    private func applyChunkPeriodRecvTimeout(_ fd: Int32) {
        var tv = timeval()
        let totalUSec = chunkPeriodMs * 1000
        tv.tv_sec  = __darwin_time_t(totalUSec / 1_000_000)
        tv.tv_usec = __darwin_suseconds_t(totalUSec % 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
    }

    /// Read-and-broadcast loop for a connected TCP client. Mirrors `runUDP`'s
    /// SO_RCVTIMEO + debounce + filler pattern: when the client connects but
    /// stops sending data for `fillerAfterMs`, switch to filler emission;
    /// resume normal forwarding as soon as bytes arrive again.
    private func runTCPClientLoop(_ fd: Int32) {
        let chunkBytes = config.stdinChunkBytes
        var readBuf    = [UInt8](repeating: 0, count: max(chunkBytes, 8192))
        var pending    = [UInt8]()

        var fillerGen = FillerGenerator(mode: config.fillerMode,
                                        channels: config.channels,
                                        sampleRate: config.sampleRate,
                                        toneHz: config.fillerToneHz)
        var fillerBuf = [UInt8](repeating: 0, count: chunkBytes)
        let timeoutsBeforeFiller = max(1, config.fillerAfterMs / chunkPeriodMs)
        var consecutiveTimeouts = 0
        var fillerActive = false

        while isRunning {
            var readErrno: Int32 = 0
            let n = readBuf.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                let result = read(fd, baseAddress, rawBuffer.count)
                if result < 0 { readErrno = errno }
                return result
            }
            if n == 0 {
                log("TCP PCM client disconnected")
                break
            }
            if n < 0 {
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts >= timeoutsBeforeFiller {
                        if !fillerActive {
                            log("TCP input idle — emitting \(config.fillerMode) filler until traffic resumes")
                            fillerActive = true
                        }
                        fillerGen.fillChunk(&fillerBuf)
                        broadcastPCMBytes(fillerBuf)
                    }
                    continue
                }
                if readErrno != EBADF {
                    log("TCP read error: \(String(cString: strerror(readErrno)))")
                }
                break
            }

            if fillerActive {
                log("TCP input resumed — filler ended")
                fillerActive = false
                pending.removeAll(keepingCapacity: true)
            }
            consecutiveTimeouts = 0
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
            applyChunkPeriodRecvTimeout(clientFD)
            runTCPClientLoop(clientFD)
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
        var mutable = bytes
        mutable.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            let buffer = UnsafeMutableBufferPointer(start: base, count: sampleCount)
            applyDitherIfSilent(buffer)
            broadcaster.broadcast(UnsafeBufferPointer(buffer))
        }
    }

    /// If `silenceDitherEnabled` is on, count consecutive zero samples and —
    /// once the threshold is crossed — replace each subsequent zero with a
    /// ±1 LSB TPDF dither sample so the broadcast signal is no longer
    /// digitally silent. Non-zero samples reset the counter so real audio
    /// passes through untouched.
    private func applyDitherIfSilent(_ buffer: UnsafeMutableBufferPointer<Int16>) {
        guard config.silenceDitherEnabled else { return }
        let threshold = config.silenceDitherThresholdSamples
        for i in 0..<buffer.count {
            if buffer[i] == 0 {
                consecutiveZeroSamples &+= 1
                if consecutiveZeroSamples > threshold {
                    buffer[i] = dither.nextNoiseSample()
                }
            } else {
                consecutiveZeroSamples = 0
            }
        }
    }
}
