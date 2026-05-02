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

// Sources/LiveAudioServer/LiveAudioServerApp.swift
// Entry point: parse arguments, wire up the pipeline, and run.
//
// Pipeline:
//
//   stdin / UDP / TCP (raw 16-bit PCM)
//       │
//       ▼
//   PCMReader
//       │
//       ▼
//   PCMBroadcaster ──────────────────────────────┐
//       │                                         │
//       ▼                                         ▼
//   MP3Encoder (libmp3lame)            AACEncoder (AudioToolbox)
//       │                                         │
//       ▼                                         ▼
//   ChunkBroadcaster [mp3]         ChunkBroadcaster [m4a]
//       │                                         │
//       └──────────────┬──────────────────────────┘
//                      ▼
//                 HTTPServer (NWListener)
//                      │
//                 HTTP clients (VLC, browsers, ffmpeg…)

import Foundation
import AudioToolbox
import Network

// MARK: - Usage

func printUsage() {
    print(liveAudioServerVersionString)
    print(liveAudioServerNotice)
    print("")
    let usage = """
    Usage: LiveAudioServer [options]

    Reads raw 16-bit signed integer PCM from stdin or a UDP/TCP socket and streams it as MP3 and
    AAC/M4A over HTTP using libmp3lame and macOS AudioToolbox.

    Options:
      -p, --port <port>         HTTP port (default: 8080)
      -r, --rate <hz>           Input sample rate in Hz (default: 48000)
      -c, --channels <n>        Input channels: 1=mono, 2=stereo (default: 2)
      --mp3-bitrate <kbps>      MP3 output bitrate in kbps (default: 128)
      --aac-bitrate <kbps>      AAC output bitrate in kbps (default: 128)
      --mp3-mount <path>        HTTP mount point for MP3 (default: /stream.mp3)
      --m4a-mount <path>        HTTP mount point for M4A/AAC (default: /stream.m4a)
      --hls-mount <path>        HTTP mount point for HLS playlist (default: /hls/index.m3u8)
      --chunk-frames <n>        PCM frames per stdin read (default: 4096)
      --udp-input-port <port>   Receive PCM from UDP on the given port instead of stdin
      --tcp-input-port <port>   Receive PCM from TCP on the given port instead of stdin
      --outputs <list>          Comma-separated streaming outputs to enable from:
                                mp3, aac, hls (default: mp3,aac,hls). Encoders for
                                disabled outputs are skipped to save CPU.
      --tls-port <port>         If set, also listen for HTTPS on this port (in
                                addition to plain HTTP on --port). Requires
                                --tls-identity.
      --tls-identity <path>     Path to a PKCS#12 (.p12) file containing the TLS
                                certificate and private key.
      --tls-password <value>    Passphrase for --tls-identity. Note: mkcert -pkcs12
                                uses the password "changeit" by default.
      --tls-password-env <var>  Read the --tls-identity passphrase from the named
                                environment variable instead of the command line.
      --bind <host>             Restrict HTTP/HTTPS listeners to this address
                                (default: all interfaces). Use 127.0.0.1 for
                                IPv4 localhost only, ::1 for IPv6 localhost
                                only, or an explicit LAN address.
      --allow-ip <list>         Allow HTTP/HTTPS connections only from these
                                source IPs. Comma-separated list of single IPs
                                or CIDR ranges, e.g.
                                "127.0.0.1,192.168.0.0/24,::1". Default: allow
                                everyone (filtering is applied AFTER --bind).
      --bonjour <name>          Advertise HTTP/HTTPS listeners on the LAN via
                                Bonjour (mDNS) under this name, e.g.
                                "Studio Audio". Default: disabled.
      --bonjour-inputs          Also advertise the active UDP / TCP input port
                                via Bonjour (custom service type
                                _liveaudio-pcm). Requires --bonjour.
      --stats-interval <secs>   Emit a one-line stats summary to stderr every
                                <secs> seconds (default: 0 = disabled). A good
                                starting value is 60 for long-running sessions.
      --record-mp3 <path>       Also append the encoded MP3 stream to this file
                                while streaming. Requires mp3 in --outputs.
      --record-aac <path>       Also append the encoded ADTS AAC stream to this
                                file while streaming. Requires aac in --outputs.
      --config <path>           Read defaults from a JSON config file. Any CLI
                                flag passed alongside it overrides the file's
                                value. See the README for the full schema.
      --keep-alive              Keep HTTP outputs available after stdin reaches EOF
      -V, --verbose             Verbose logging
      -v, --version             Print version string and exit
      -h, --help                Show this help

    Examples:

      # Pipe from a file (for testing):
      ffmpeg -i input.wav -f s16le -ar 44100 -ac 2 - | LiveAudioServer

      # From a microphone (macOS, using ffmpeg):
      ffmpeg -f avfoundation -i ":0" -f s16le -ar 44100 -ac 1 - \\
        | LiveAudioServer --channels 1 --rate 44100

      # BlackHole virtual audio or system audio capture:
      ffmpeg -f avfoundation -i "BlackHole 2ch" -f s16le -ar 48000 -ac 2 - \\
        | LiveAudioServer --rate 48000

      # Custom port and bitrates:
      ffmpeg -i input.flac -f s16le -ar 44100 -ac 2 - \\
        | LiveAudioServer -p 9000 --mp3-bitrate 320 --aac-bitrate 256

      # Listen for PCM on UDP port 7355 instead of stdin:
      LiveAudioServer --udp-input-port 7355 --rate 48000 --channels 2

    Supported stream URLs (after launch):
      http://localhost:<port>/stream.mp3   — MP3 (browser, VLC, ffplay)
      http://localhost:<port>/stream.m4a   — AAC/ADTS (Safari, VLC, ffplay)
      http://localhost:<port>/hls/index.m3u8 — HLS AAC (Safari)
      http://localhost:<port>/             — Status page with built-in player
    """
    print(usage)
}

// MARK: - CLI parsing (testable, side-effect-free)

/// Result of parsing argv. Either a fully populated ServerConfig (proceed to
/// run the server) or a directive to print usage / version and exit.
enum CLIParseResult {
    case run(ServerConfig)
    case printUsage
    case printVersion
    case error(String)
}

/// Extract `--config <path>` from argv, returning the path (if any) and the
/// remaining argv with the flag removed. Used by `parseCLI` so the file's
/// values can be loaded before CLI overrides are applied.
func extractConfigPath(_ args: [String]) -> (path: String?, remaining: [String]) {
    var remaining: [String] = []
    var path: String? = nil
    var i = 0
    while i < args.count {
        if args[i] == "--config" {
            i += 1
            if i < args.count {
                path = args[i]
                i += 1
                continue
            }
            // Missing value — leave the `--config` token in place so the
            // normal parser emits the canonical error.
            remaining.append("--config")
            continue
        }
        remaining.append(args[i])
        i += 1
    }
    return (path, remaining)
}

/// Parse argv (without the program name) into a `CLIParseResult`. Pure: no
/// process-wide side effects, no exits — the caller decides how to react.
/// Exposed at module scope so the tests can exercise it without launching the
/// server.
func parseCLI(_ args: [String]) -> CLIParseResult {
    var config = ServerConfig()

    // Pre-pass: load a config file if `--config <path>` was supplied. The
    // file populates the starting config; CLI flags processed below override.
    let (configPath, args) = extractConfigPath(args)
    if let path = configPath {
        do {
            let file = try loadConfigFile(at: path)
            try applyConfigFile(file, to: &config)
        } catch let err as ConfigFileError {
            return .error("\(err)")
        } catch {
            return .error("Failed to load --config \(path): \(error)")
        }
    }

    var i = 0
    while i < args.count {
        switch args[i] {
        case "-p", "--port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]) else { return .error("Bad port") }
            config.port = v
        case "-r", "--rate":
            i += 1
            guard i < args.count, let v = Int(args[i]),
                  [8000,11025,16000,22050,32000,44100,48000].contains(v)
            else { return .error("Bad sample rate (must be 8000/11025/16000/22050/32000/44100/48000)") }
            config.sampleRate = v
        case "-c", "--channels":
            i += 1
            guard i < args.count, let v = Int(args[i]), v == 1 || v == 2
            else { return .error("Bad channel count (must be 1 or 2)") }
            config.channels = v
        case "--mp3-bitrate":
            i += 1
            guard i < args.count, let v = Int(args[i]), v > 0
            else { return .error("Bad MP3 bitrate") }
            config.mp3Bitrate = v
        case "--aac-bitrate":
            i += 1
            guard i < args.count, let v = Int(args[i]), v > 0
            else { return .error("Bad AAC bitrate") }
            config.aacBitrate = v * 1000   // accept kbps, store as bps
        case "--mp3-mount":
            i += 1
            guard i < args.count else { return .error("Missing mp3 mount path") }
            config.mountMP3 = args[i]
        case "--m4a-mount":
            i += 1
            guard i < args.count else { return .error("Missing m4a mount path") }
            config.mountM4A = args[i]
        case "--hls-mount":
            i += 1
            guard i < args.count else { return .error("Missing hls mount path") }
            config.mountHLSIndex = args[i]
        case "--chunk-frames":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 512
            else { return .error("Bad chunk-frames (minimum 512)") }
            config.stdinChunkFrames = v
        case "--udp-input-port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]) else { return .error("Bad UDP input port") }
            config.inputSource = .udp(port: v)
        case "--tcp-input-port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]) else { return .error("Bad TCP input port") }
            config.inputSource = .tcp(port: v)
        case "--outputs":
            i += 1
            guard i < args.count else { return .error("Missing --outputs value (e.g. mp3,aac,hls)") }
            config.enableMP3 = false
            config.enableAAC = false
            config.enableHLS = false
            let tokens = args[i].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            for token in tokens where !token.isEmpty {
                switch token {
                case "mp3": config.enableMP3 = true
                case "aac", "m4a": config.enableAAC = true
                case "hls": config.enableHLS = true
                default:
                    return .error("Unknown output '\(token)' in --outputs. Valid: mp3, aac, hls")
                }
            }
            if !config.enableMP3 && !config.enableAAC && !config.enableHLS {
                return .error("--outputs requires at least one of: mp3, aac, hls")
            }
        case "--tls-port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]) else { return .error("Bad --tls-port value") }
            config.tlsPort = v
        case "--tls-identity":
            i += 1
            guard i < args.count else { return .error("Missing --tls-identity path") }
            config.tlsIdentityPath = args[i]
        case "--tls-password":
            i += 1
            guard i < args.count else { return .error("Missing --tls-password value") }
            config.tlsPassword = args[i]
        case "--tls-password-env":
            i += 1
            guard i < args.count else { return .error("Missing --tls-password-env name") }
            guard let v = ProcessInfo.processInfo.environment[args[i]] else {
                return .error("Env var \(args[i]) not set (referenced by --tls-password-env)")
            }
            config.tlsPassword = v
        case "--bind":
            i += 1
            guard i < args.count else { return .error("Missing --bind host (e.g. 127.0.0.1)") }
            config.bindHost = args[i]
        case "--allow-ip":
            i += 1
            guard i < args.count else { return .error("Missing --allow-ip value (e.g. 127.0.0.1,192.168.0.0/24)") }
            do {
                config.allowedClientIPs = try parseAllowList(args[i])
            } catch let err as IPACLParseError {
                return .error("\(err)")
            } catch {
                return .error("\(error)")
            }
        case "--bonjour":
            i += 1
            guard i < args.count else { return .error("Missing --bonjour name") }
            let name = args[i].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .error("--bonjour name cannot be empty") }
            config.bonjourName = name
        case "--bonjour-inputs":
            config.bonjourAdvertiseInputs = true
        case "--stats-interval":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 0
            else { return .error("Bad --stats-interval (must be ≥ 0; 0 disables)") }
            config.statsIntervalSeconds = v
        case "--config":
            // extractConfigPath() only leaves a bare "--config" here when its
            // value was missing — surface a useful error.
            return .error("Missing --config path")
        case "--record-mp3":
            i += 1
            guard i < args.count else { return .error("Missing --record-mp3 path") }
            config.recordMP3Path = args[i]
        case "--record-aac":
            i += 1
            guard i < args.count else { return .error("Missing --record-aac path") }
            config.recordAACPath = args[i]
        case "--keep-alive":
            config.keepAliveOnInputEnd = true
        case "-V", "--verbose":
            config.verbose = true
        case "-v", "--version":
            return .printVersion
        case "-h", "--help":
            return .printUsage
        default:
            return .error("Unknown option: \(args[i])")
        }
        i += 1
    }

    // Cross-flag validation.
    if config.tlsPort != nil && config.tlsIdentityPath == nil {
        return .error("--tls-port requires --tls-identity")
    }
    if config.tlsIdentityPath != nil && config.tlsPort == nil {
        return .error("--tls-identity requires --tls-port")
    }
    if config.recordMP3Path != nil && !config.enableMP3 {
        return .error("--record-mp3 requires mp3 in --outputs")
    }
    if config.recordAACPath != nil && !config.enableAAC {
        return .error("--record-aac requires aac in --outputs")
    }
    if config.bonjourAdvertiseInputs && config.bonjourName == nil {
        return .error("--bonjour-inputs requires --bonjour")
    }

    return .run(config)
}

// MARK: - Entry point

@main
struct LiveAudioServerApp {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        let config: ServerConfig

        switch parseCLI(argv) {
        case .run(let c):
            config = c
        case .printUsage:
            printUsage(); exit(0)
        case .printVersion:
            print(liveAudioServerVersionString)
            print(liveAudioServerNotice)
            exit(0)
        case .error(let message):
            fputs("❌ \(message)\n", stderr)
            exit(1)
        }

        // Load the TLS identity up front so we fail fast on bad cert / passphrase.
        var tlsIdentity: sec_identity_t? = nil
        if let identityPath = config.tlsIdentityPath {
            do {
                tlsIdentity = try loadTLSIdentity(p12Path: identityPath, password: config.tlsPassword)
            } catch {
                fputs("❌ \(error)\n", stderr); exit(1)
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
        if let bname = config.bonjourName {
            let scope = config.bonjourAdvertiseInputs ? "outputs + inputs" : "outputs only"
            log("   Bonjour: \(bname) (\(scope))")
        }

        // Stats collector — totals encoded bytes and uptime. Always live; the
        // periodic emitter below decides whether to surface it.
        let statsCollector = StatsCollector()

        // File recorders — one per enabled output format, idle until started.
        // The `--record-X <path>` CLI flag, if provided, calls `start(path:)`
        // immediately so recording begins at launch.
        let mp3Recorder: FileRecorder? = config.enableMP3 ? FileRecorder(format: .mp3) : nil
        let aacRecorder: FileRecorder? = config.enableAAC ? FileRecorder(format: .m4a) : nil
        do {
            if let p = config.recordMP3Path { try mp3Recorder?.start(path: p) }
            if let p = config.recordAACPath { try aacRecorder?.start(path: p) }
        } catch {
            fputs("❌ \(error)\n", stderr); exit(1)
        }

        // 1. Broadcasters (fan-out encoded chunks to HTTP clients, stats, and
        //    optional file recorders).
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
        let hlsSegmenter: HLSSegmenter? = config.enableHLS
            ? HLSSegmenter(sampleRate: config.sampleRate,
                           segmentDurationTarget: config.hlsSegmentDuration,
                           maxSegmentCount: config.hlsPlaylistWindowSize,
                           segmentPathPrefix: config.mountHLSSegmentPrefix)
            : nil

        // 2. Encoders — only constructed for active outputs.
        //    The AAC encoder must also run when HLS is enabled, since HLS reuses its AAC frames.
        var mp3Encoder: MP3Encoder?
        var aacEncoder: AACEncoder?

        do {
            if config.enableMP3 {
                let enc = MP3Encoder(config: config, output: mp3Broadcaster)
                try enc.start()
                mp3Encoder = enc
            }
            if config.enableAAC || config.enableHLS {
                let enc = AACEncoder(config: config, output: m4aBroadcaster, hlsSegmenter: hlsSegmenter)
                try enc.start()
                aacEncoder = enc
            }
        } catch {
            fputs("❌ Encoder init failed: \(error)\n", stderr)
            exit(1)
        }

        // 3. PCM broadcaster (distributes raw PCM to the active encoders)
        let pcmBroadcaster = PCMBroadcaster()
        if let mp3Encoder {
            _ = pcmBroadcaster.addConsumer { samples in mp3Encoder.encode(samples: samples) }
        }
        if let aacEncoder {
            _ = pcmBroadcaster.addConsumer { samples in aacEncoder.encode(samples: samples) }
        }

        // 4. HTTP server
        let nowPlayingStore = NowPlayingStore()
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
            fputs("❌ HTTP server failed: \(error)\n", stderr)
            exit(1)
        }

        // Bonjour advertising. HTTP/HTTPS outputs are advertised by their
        // NWListener inside HTTPServer (well-known _http._tcp. / _https._tcp.
        // service types). This publisher adds:
        //   - A custom _liveaudio._tcp. service on the HTTP port carrying
        //     richer metadata (per-stream bitrates, sample rate, etc.) so a
        //     LiveAudioServer-aware client can filter discovery to that type.
        //   - The PCM input port (when --bonjour-inputs is set).
        let bonjourPublisher = BonjourPublisher()
        if let bname = config.bonjourName {
            bonjourPublisher.publishCustomOutput(name: bname, config: config)
            if config.bonjourAdvertiseInputs {
                bonjourPublisher.publishInputs(name: bname, config: config)
            }
        }

        // 5. PCM reader (runs on a background thread, blocking)
        let stdinReader = PCMReader(config: config, broadcaster: pcmBroadcaster)
        let readerThread = Thread {
            stdinReader.run()
            mp3Encoder?.stop()
            aacEncoder?.stop()
            if config.keepAliveOnInputEnd {
                log("Input ended. Encoders stopped; HTTP server remains available because --keep-alive is enabled.")
                return
            }
            log("All encoders stopped. Exiting.")
            exit(0)
        }
        readerThread.name             = "stdin-pcm-reader"
        readerThread.qualityOfService = .userInteractive
        readerThread.start()

        // Handle SIGPIPE (clients disconnect mid-stream)
        signal(SIGPIPE, SIG_IGN)

        // Single shutdown path used by both SIGINT and SIGTERM. The default
        // `signal()` handlers for SIGINT/SIGTERM would have killed the process
        // outright; the DispatchSourceSignal sources override that, but only
        // after we explicitly ignore the kernel default via `signal(SIGINT/TERM,
        // SIG_IGN)`. Without that, the first signal hits the default handler.
        let runGracefulShutdown: (String) -> Void = { reason in
            log("\n\(reason) received — graceful shutdown")
            // 1. Stop accepting new HTTP clients and close existing ones first
            //    so subsequent encoder flushes don't pile bytes onto dying
            //    sockets.
            httpServer.stop()
            // 2. Stop the PCM reader (releases the input socket / fd) and the
            //    encoders (flushes lame and AudioConverter).
            stdinReader.stop()
            mp3Encoder?.stop()
            aacEncoder?.stop()
            // 3. Stop any active recordings so their trailing bytes flush.
            mp3Recorder?.stop()
            aacRecorder?.stop()
            // 3b. Stop Bonjour publishers so clients see the service vanish
            //     instead of timing out.
            bonjourPublisher.stopAll()
            // 4. Give in-flight `NWConnection.send` completions a moment to
            //    fire on their own queues before the process exits.
            Thread.sleep(forTimeInterval: 0.2)
            log("Shutdown complete.")
            // Drain the async log queue so the final line actually reaches
            // stderr before exit().
            logQueue.sync {}
            exit(0)
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: .main)
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigInt.setEventHandler  { runGracefulShutdown("SIGINT") }
        sigTerm.setEventHandler { runGracefulShutdown("SIGTERM") }
        sigInt.resume()
        sigTerm.resume()
        _ = sigInt; _ = sigTerm   // keep alive for the lifetime of the process

        // Optional periodic stats line.
        var statsTimer: DispatchSourceTimer?
        if config.statsIntervalSeconds > 0 {
            let interval = DispatchTimeInterval.seconds(config.statsIntervalSeconds)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler {
                log(formatStatsLine(snapshot: statsCollector.snapshot(),
                                    mp3Clients: mp3Broadcaster.clientCount,
                                    aacClients: m4aBroadcaster.clientCount))
            }
            timer.resume()
            statsTimer = timer
        }
        _ = statsTimer  // keep alive for the lifetime of the process

        RunLoop.main.run()
    }
}
