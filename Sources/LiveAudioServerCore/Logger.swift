// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

// Sources/LiveAudioServerCore/Logger.swift
// Logger abstraction. The library never writes to stdout/stderr directly;
// every log line goes through `LiveAudioServerLogger.log(_:)`. The CLI shim
// installs a logger that prints to stderr (matching pre-refactor behavior),
// and a host app can install its own to forward into oslog, an in-app
// console, or /dev/null.

import Foundation

/// Sink for library log messages. Implementations are called from arbitrary
/// background queues — be thread-safe.
public protocol LiveAudioServerLogger: Sendable {
    /// Called with one timestamped, fully formatted line (no trailing newline).
    func log(_ message: String)
}

/// Discards every log line. Use as the default when running inside a host app
/// that doesn't want any library output.
public struct SilentLogger: LiveAudioServerLogger {
    public init() {}
    public func log(_ message: String) {}
}

/// Writes every log line + newline to `stderr`. Matches the pre-refactor
/// behavior; installed automatically by the CLI shim.
public struct StderrLogger: LiveAudioServerLogger {
    public init() {}
    public func log(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

/// Process-wide logger sink. Mutating it from multiple threads is safe; the
/// underlying lock serializes installs vs. log emission. Defaults to
/// `SilentLogger` so a library consumer never gets stderr output unless they
/// opt in.
public enum LiveAudioServerLogging {
    private static let lock = NSLock()
    private static var _logger: LiveAudioServerLogger = SilentLogger()

    public static var logger: LiveAudioServerLogger {
        get { lock.lock(); defer { lock.unlock() }; return _logger }
        set { lock.lock(); defer { lock.unlock() }; _logger = newValue }
    }
}
