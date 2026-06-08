// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

// Sources/LiveAudioServerCore/LiveAudioServer.swift
// Public façade: a host app constructs `LiveAudioServer(config:)`, calls
// `start()`, and later `stop()`. All orchestration that used to live in the
// CLI's `main()` is encapsulated here, including teardown.

import Foundation
import AudioToolbox
import Network

/// Errors thrown from `LiveAudioServer.start()`. Replace the CLI's previous
/// `exit(1)` / `fputs(...stderr)` paths so host apps can react in Swift.
public enum LiveAudioServerError: Error, CustomStringConvertible {
    case tlsIdentityLoadFailed(String)
    case recorderStartFailed(String)
    case encoderStartFailed(String)
    case httpServerStartFailed(String)
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .tlsIdentityLoadFailed(let m): return "TLS identity load failed: \(m)"
        case .recorderStartFailed(let m):   return "Recorder start failed: \(m)"
        case .encoderStartFailed(let m):    return "Encoder init failed: \(m)"
        case .httpServerStartFailed(let m): return "HTTP server start failed: \(m)"
        case .alreadyRunning:               return "LiveAudioServer is already running"
        case .notRunning:                   return "LiveAudioServer is not running"
        }
    }
}

/// In-process façade for the live audio streaming pipeline.
///
/// Usage:
///
///     var cfg = LiveAudioServerConfig()
///     cfg.port = 9000
///     cfg.inputSource = .udp(port: 7355)
///     let server = LiveAudioServer(config: cfg)
///     try await server.start()
///     // ... do other work ...
///     await server.stop()
///
/// The server runs its PCM reader on a dedicated thread and the HTTP listener
/// on a Network.framework queue. `start()` returns once setup is done, with
/// the server running in the background. Multiple instances can coexist in
/// the same process — each owns its own listeners, encoders, and reader.
public final class LiveAudioServer {
    private let config: ServerConfig
    private let stateLock = NSLock()
    private var _isRunning = false

    // Components held for the lifetime of one start/stop cycle.
    private var statsCollector: StatsCollector?
    private var mp3Recorder: FileRecorder?
    private var aacRecorder: FileRecorder?
    private var mp3Broadcaster: ChunkBroadcaster?
    private var m4aBroadcaster: ChunkBroadcaster?
    private var hlsSegmenter: HLSSegmenter?
    private var mp3Encoder: MP3Encoder?
    private var aacEncoder: AACEncoder?
    private var pcmBroadcaster: PCMBroadcaster?
    private var nowPlayingStore: NowPlayingStore?
    private var httpServer: HTTPServer?
    private var bonjourPublisher: BonjourPublisher?
    private var pcmReader: PCMReader?
    private var readerThread: Thread?
    private var statsTimer: DispatchSourceTimer?

    public init(config: ServerConfig) {
        self.config = config
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    /// Wire up encoders, broadcasters, HTTP listener, Bonjour, and the PCM
    /// reader. Returns once all components are running. The reader / listener
    /// continue on background queues until `stop()` is called.
    public func start() async throws {
        stateLock.lock()
        if _isRunning {
            stateLock.unlock()
            throw LiveAudioServerError.alreadyRunning
        }
        stateLock.unlock()

        var tlsIdentity: sec_identity_t? = nil
        if let identityPath = config.tlsIdentityPath {
            do {
                tlsIdentity = try loadTLSIdentity(p12Path: identityPath, password: config.tlsPassword)
            } catch {
                throw LiveAudioServerError.tlsIdentityLoadFailed("\(error)")
            }
        }

        log("🎙 \(liveAudioServerVersionString)")
        log("   Input  : \(config.channels == 1 ? "Mono" : "Stereo") PCM, \(config.sampleRate) Hz, 16-bit signed via \(config.inputSource)")
        if config.enableMP3 { log("   MP3    : \(config.mp3Bitrate) kbps → \(config.mountMP3)") }
        if config.enableAAC { log("   AAC    : \(config.aacBitrate / 1000) kbps → \(config.mountM4A)") }
        if config.enableHLS { log("   HLS    : AAC playlist → \(config.mountHLSIndex)") }
        log("   Port   : \(config.port)")
        if let tlsPort = config.tlsPort {
            log("   TLS    : enabled on port \(tlsPort)")
        }
        if let bindHost = config.bindHost {
            log("   Bind   : \(bindHost) (listeners restricted to this address)")
        }
        if let acl = config.allowedClientIPs, !acl.allowAll {
            log("   ACL    : \(acl.matchers.count) allow-list entr\(acl.matchers.count == 1 ? "y" : "ies") — only matching client IPs accepted")
        }
        if let user = config.httpAuthUser, config.httpAuthPassword != nil {
            log("   Auth   : HTTP Basic enabled (user=\(user), realm=\"\(config.httpAuthRealm)\")")
            if config.tlsPort == nil {
                log("   ⚠️  HTTP Basic credentials travel base64-encoded; enable --tls-port for non-localhost use.")
            }
        }
        if let bname = config.bonjourName {
            let scope = config.bonjourAdvertiseInputs ? "outputs + inputs" : "outputs only"
            log("   Bonjour: \(bname) (\(scope))")
        }

        let statsCollector = StatsCollector()
        self.statsCollector = statsCollector

        let mp3Recorder: FileRecorder? = config.enableMP3 ? FileRecorder(format: .mp3) : nil
        let aacRecorder: FileRecorder? = config.enableAAC ? FileRecorder(format: .m4a) : nil
        do {
            if let p = config.recordMP3Path { try mp3Recorder?.start(path: p) }
            if let p = config.recordAACPath { try aacRecorder?.start(path: p) }
        } catch {
            throw LiveAudioServerError.recorderStartFailed("\(error)")
        }
        self.mp3Recorder = mp3Recorder
        self.aacRecorder = aacRecorder

        let mp3Broadcaster = ChunkBroadcaster(format: .mp3, verbose: config.verbose,
                                              onBroadcast: { data in
                                                  statsCollector.recordMP3Bytes(data.count)
                                                  mp3Recorder?.write(data)
                                              })
        let m4aBroadcaster = ChunkBroadcaster(format: .m4a, verbose: config.verbose,
                                              onBroadcast: { data in
                                                  statsCollector.recordAACBytes(data.count)
                                                  aacRecorder?.write(data)
                                              })
        self.mp3Broadcaster = mp3Broadcaster
        self.m4aBroadcaster = m4aBroadcaster

        let hlsSegmenter: HLSSegmenter? = config.enableHLS
            ? HLSSegmenter(sampleRate: config.sampleRate,
                           segmentDurationTarget: config.hlsSegmentDuration,
                           maxSegmentCount: config.hlsPlaylistWindowSize,
                           segmentPathPrefix: config.mountHLSSegmentPrefix)
            : nil
        self.hlsSegmenter = hlsSegmenter

        do {
            if config.enableMP3 {
                let enc = MP3Encoder(config: config, output: mp3Broadcaster)
                try enc.start()
                self.mp3Encoder = enc
            }
            if config.enableAAC || config.enableHLS {
                let enc = AACEncoder(config: config, output: m4aBroadcaster, hlsSegmenter: hlsSegmenter)
                try enc.start()
                self.aacEncoder = enc
            }
        } catch {
            throw LiveAudioServerError.encoderStartFailed("\(error)")
        }

        let pcmBroadcaster = PCMBroadcaster()
        if let mp3Encoder {
            _ = pcmBroadcaster.addConsumer { samples in mp3Encoder.encode(samples: samples) }
        }
        if let aacEncoder {
            _ = pcmBroadcaster.addConsumer { samples in aacEncoder.encode(samples: samples) }
        }
        self.pcmBroadcaster = pcmBroadcaster

        let nowPlayingStore = NowPlayingStore()
        self.nowPlayingStore = nowPlayingStore

        let httpServer = HTTPServer(config: config,
                                    mp3Broadcaster: mp3Broadcaster,
                                    m4aBroadcaster: m4aBroadcaster,
                                    hlsSegmenter: hlsSegmenter,
                                    nowPlayingStore: nowPlayingStore,
                                    mp3Recorder: mp3Recorder,
                                    aacRecorder: aacRecorder,
                                    tlsIdentity: tlsIdentity)
        do {
            try httpServer.start()
        } catch {
            throw LiveAudioServerError.httpServerStartFailed("\(error)")
        }
        self.httpServer = httpServer

        let bonjourPublisher = BonjourPublisher()
        if let bname = config.bonjourName {
            bonjourPublisher.publishCustomOutput(name: bname, config: config)
            if config.bonjourAdvertiseInputs {
                bonjourPublisher.publishInputs(name: bname, config: config)
            }
        }
        self.bonjourPublisher = bonjourPublisher

        let pcmReader = PCMReader(config: config, broadcaster: pcmBroadcaster)
        self.pcmReader = pcmReader

        // SIGPIPE: prevent the process from dying when a client disconnects
        // mid-stream. Setting it here keeps host apps from having to know.
        signal(SIGPIPE, SIG_IGN)

        let readerThread = Thread { [weak self] in
            pcmReader.run()
            guard let self else { return }
            self.mp3Encoder?.stop()
            self.aacEncoder?.stop()
            if self.config.keepAliveOnInputEnd {
                log("Input ended. Encoders stopped; HTTP server remains available because --keep-alive is enabled.")
                return
            }
            log("All encoders stopped.")
        }
        readerThread.name             = "stdin-pcm-reader"
        readerThread.qualityOfService = .userInteractive
        readerThread.start()
        self.readerThread = readerThread

        if config.statsIntervalSeconds > 0 {
            let interval = DispatchTimeInterval.seconds(config.statsIntervalSeconds)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard let stats = self.statsCollector,
                      let mp3 = self.mp3Broadcaster,
                      let m4a = self.m4aBroadcaster else { return }
                log(formatStatsLine(snapshot: stats.snapshot(),
                                    mp3Clients: mp3.clientCount,
                                    aacClients: m4a.clientCount))
            }
            timer.resume()
            self.statsTimer = timer
        }

        stateLock.lock()
        _isRunning = true
        stateLock.unlock()
    }

    /// Graceful shutdown: stop accepting new HTTP clients, flush encoders,
    /// stop recordings, retire Bonjour. Idempotent — calling on a stopped
    /// instance is a no-op.
    public func stop() async {
        stateLock.lock()
        if !_isRunning {
            stateLock.unlock()
            return
        }
        _isRunning = false
        stateLock.unlock()

        statsTimer?.cancel()
        statsTimer = nil

        // 1. Stop accepting new HTTP clients and close existing ones first
        //    so subsequent encoder flushes don't pile bytes onto dying sockets.
        httpServer?.stop()
        // 2. Stop the PCM reader (releases the input socket / fd) and the
        //    encoders (flushes lame and AudioConverter).
        pcmReader?.stop()
        mp3Encoder?.stop()
        aacEncoder?.stop()
        // 3. Stop any active recordings so their trailing bytes flush.
        mp3Recorder?.stop()
        aacRecorder?.stop()
        // 4. Stop Bonjour publishers so clients see the service vanish.
        bonjourPublisher?.stopAll()
        // 5. Give in-flight `NWConnection.send` completions a moment to fire
        //    on their own queues.
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Drain the async log queue so the final line actually reaches stderr.
        logQueue.sync {}

        // Release references — next start() rebuilds everything fresh.
        statsCollector   = nil
        mp3Recorder      = nil
        aacRecorder      = nil
        mp3Broadcaster   = nil
        m4aBroadcaster   = nil
        hlsSegmenter     = nil
        mp3Encoder       = nil
        aacEncoder       = nil
        pcmBroadcaster   = nil
        nowPlayingStore  = nil
        httpServer       = nil
        bonjourPublisher = nil
        pcmReader        = nil
        readerThread     = nil
    }
}
