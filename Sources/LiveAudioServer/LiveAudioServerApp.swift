// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Sources/LiveAudioServer/LiveAudioServerApp.swift
// CLI shim. Parses argv via the library, hands the resulting config to a
// `LiveAudioServer`, wires SIGINT/SIGTERM to a graceful shutdown, and blocks
// on the main RunLoop. All audio + HTTP + Bonjour orchestration lives in the
// library — keep this file thin so behavior changes happen in one place.

import Foundation
import Dispatch
import LiveAudioServerCore

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
      --auth-user <name>        Require HTTP Basic authentication on every
                                request. Must be paired with --auth-password
                                (or --auth-password-env). Credentials are
                                base64-encoded on the wire — pair with
                                --tls-port for non-localhost use.
      --auth-password <value>   Password for --auth-user.
      --auth-password-env <var> Read the auth password from the named env var
                                instead of the command line.
      --auth-realm <name>       Realm name shown in the browser login dialog
                                (default: "LiveAudioServer").
      --config <path>           Read defaults from a JSON config file. Any CLI
                                flag passed alongside it overrides the file's
                                value. See the README for the full schema.
      --keep-alive              Keep HTTP outputs available after stdin reaches EOF.
                                If stdin is a FIFO (created with mkfifo), the
                                reader also re-opens it on EOF so a new
                                producer can attach; gaps between producers
                                are filled with silence so encoders / HLS
                                stay live.
      --no-fifo-reopen          Disable the FIFO re-open behaviour above; the
                                reader will silence-fill after EOF instead.
      --exit-with-parent        Exit if the parent process dies (even on a
                                crash). Useful when launched as a helper by a
                                host app that needs this server reaped instead
                                of orphaned holding its HTTP port.
      --silence-dither          Inject inaudible TPDF dither (±1 LSB) once a
                                run of digitally-silent samples crosses
                                --silence-dither-ms. Prevents downstream
                                tools from treating the stream as dead.
      --silence-dither-ms <n>   Milliseconds of pure-silence before dither
                                kicks in (default: 500).
      --filler-mode <mode>      What to broadcast during the keep-alive
                                silence-fill window after stdin EOF.
                                "silence" (default) emits digital zero
                                (optionally TPDF-dithered via
                                --silence-dither). "tone" emits a continuous
                                sine wave at --filler-tone-hz so listeners
                                hear an audible "dead-air" placeholder.
                                Only effective with --keep-alive.
      --filler-tone-hz <hz>     Frequency of the sine-tone filler in Hz
                                (default: 1000). Ignored unless
                                --filler-mode tone.
      --filler-after-ms <n>     Milliseconds of consecutive UDP/TCP input
                                absence before the filler kicks in (default:
                                500). Brief network jitter passes through
                                unaltered; longer gaps switch to filler.
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

// MARK: - Entry point

@main
struct LiveAudioServerApp {
    static func main() {
        // The library defaults to a silent logger so host apps don't get
        // stderr output they didn't ask for. The CLI absolutely wants stderr.
        LiveAudioServerLogging.logger = StderrLogger()

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

        let server = LiveAudioServer(config: config)

        // Kick off start() in a Task so we can return from main() into the
        // RunLoop. start() throws only on synchronous setup failures (TLS
        // load, bind, encoder init); those map to exit(1) here so the CLI
        // surface is unchanged.
        let startupGate = DispatchSemaphore(value: 0)
        var startupError: Error?
        Task.detached {
            do {
                try await server.start()
            } catch {
                startupError = error
            }
            startupGate.signal()
        }
        startupGate.wait()
        if let startupError {
            fputs("❌ \(startupError)\n", stderr)
            exit(1)
        }

        // Graceful shutdown wired to SIGINT/SIGTERM. Ignoring the kernel
        // default first means the DispatchSourceSignal sees the signal
        // instead of the process being torn down.
        let runGracefulShutdown: (String) -> Void = { reason in
            log("\n\(reason) received — graceful shutdown")
            Task {
                await server.stop()
                log("Shutdown complete.")
                logQueue.sync {}
                exit(0)
            }
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: .main)
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigInt.setEventHandler  { runGracefulShutdown("SIGINT") }
        sigTerm.setEventHandler { runGracefulShutdown("SIGTERM") }
        sigInt.resume()
        sigTerm.resume()
        _ = sigInt; _ = sigTerm

        // Parent-death watchdog (--exit-with-parent). Polls getppid(); when the
        // launching app dies (quit or crash) this process is reparented to
        // launchd (pid 1), so getppid() changes — at which point we shut down
        // gracefully, freeing the HTTP port instead of orphaning it.
        var parentWatchdog: DispatchSourceTimer?
        if config.exitWithParent {
            let originalParent = getppid()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler {
                if getppid() != originalParent {
                    runGracefulShutdown("Parent process exit")
                }
            }
            timer.resume()
            parentWatchdog = timer
        }
        _ = parentWatchdog

        RunLoop.main.run()
    }
}
