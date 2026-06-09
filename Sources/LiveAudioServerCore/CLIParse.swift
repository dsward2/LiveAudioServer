// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

// Sources/LiveAudioServerCore/CLIParse.swift
// Argument-vector parsing for the `LiveAudioServer` CLI. Pure / testable: no
// process-wide side effects, no exits. The CLI shim and tests both call into
// this from outside the library.

import Foundation

/// Result of parsing argv. Either a fully populated `ServerConfig` (proceed
/// to run the server) or a directive to print usage / version and exit.
public enum CLIParseResult {
    case run(ServerConfig)
    case printUsage
    case printVersion
    case error(String)
}

/// Extract `--config <path>` from argv, returning the path (if any) and the
/// remaining argv with the flag removed. Used by `parseCLI` so the file's
/// values can be loaded before CLI overrides are applied.
public func extractConfigPath(_ args: [String]) -> (path: String?, remaining: [String]) {
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
public func parseCLI(_ args: [String]) -> CLIParseResult {
    var config = ServerConfig()
    // Deferred: --silence-dither-ms must be applied after --rate / --channels
    // so the sample-rate conversion uses the final values regardless of flag
    // order. nil = use the default threshold from ServerConfig.
    var silenceDitherMs: Int? = nil

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
        case "--auth-user":
            i += 1
            guard i < args.count else { return .error("Missing --auth-user value") }
            let u = args[i]
            guard !u.isEmpty else { return .error("--auth-user cannot be empty") }
            guard !u.contains(":") else { return .error("--auth-user cannot contain ':' (RFC 7617)") }
            config.httpAuthUser = u
        case "--auth-password":
            i += 1
            guard i < args.count else { return .error("Missing --auth-password value") }
            config.httpAuthPassword = args[i]
        case "--auth-password-env":
            i += 1
            guard i < args.count else { return .error("Missing --auth-password-env name") }
            guard let v = ProcessInfo.processInfo.environment[args[i]] else {
                return .error("Env var \(args[i]) not set (referenced by --auth-password-env)")
            }
            config.httpAuthPassword = v
        case "--auth-realm":
            i += 1
            guard i < args.count else { return .error("Missing --auth-realm value") }
            let r = args[i].trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty else { return .error("--auth-realm cannot be empty") }
            config.httpAuthRealm = r
        case "--keep-alive":
            config.keepAliveOnInputEnd = true
        case "--no-fifo-reopen":
            config.reopenStdinFIFO = false
        case "--silence-dither":
            config.silenceDitherEnabled = true
        case "--silence-dither-ms":
            i += 1
            guard i < args.count, let ms = Int(args[i]), ms >= 0 else {
                return .error("Bad --silence-dither-ms (must be a non-negative integer)")
            }
            silenceDitherMs = ms
        case "--filler-mode":
            i += 1
            guard i < args.count else { return .error("Missing --filler-mode value (silence|tone)") }
            guard let mode = FillerMode(cliArgument: args[i]) else {
                return .error("Bad --filler-mode '\(args[i])' (must be 'silence' or 'tone')")
            }
            config.fillerMode = mode
        case "--filler-tone-hz":
            i += 1
            guard i < args.count, let v = Double(args[i]), v > 0, v < Double(config.sampleRate) / 2.0 else {
                return .error("Bad --filler-tone-hz (must be > 0 and below the Nyquist frequency)")
            }
            config.fillerToneHz = v
        case "--filler-after-ms":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 0 else {
                return .error("Bad --filler-after-ms (must be a non-negative integer)")
            }
            config.fillerAfterMs = v
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

    // Apply deferred dither threshold once sample rate / channels are final.
    if let ms = silenceDitherMs {
        // Threshold counts individual Int16 samples across all channels.
        config.silenceDitherThresholdSamples = (ms * config.sampleRate * config.channels) / 1000
    }

    // Cross-flag validation.
    // Note: these checks only govern CLI inputs. Programmatic embedders may
    // instead assign `ServerConfig.tlsIdentity` directly (a pre-loaded
    // `sec_identity_t`) and skip `tlsIdentityPath` entirely; the library's
    // identity-resolution step honors that injected value.
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
    if config.httpAuthUser != nil && config.httpAuthPassword == nil {
        return .error("--auth-user requires --auth-password or --auth-password-env")
    }
    if config.httpAuthPassword != nil && config.httpAuthUser == nil {
        return .error("--auth-password requires --auth-user")
    }

    return .run(config)
}
