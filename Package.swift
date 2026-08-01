// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveAudioServer",
    platforms: [
        // Bumped from .v13: PipelineHelpers (AudioEncoders' package) requires
        // macOS 14 package-wide, for PipelineRunner's use of @Observable —
        // SwiftPM's platforms list is package-level, so any product from that
        // package carries the same floor regardless of what it itself uses.
        .macOS(.v14)
    ],
    products: [
        // Public library product so external SwiftPM packages (e.g. a SwiftUI
        // host app) can `.package(url: …)` this repo and consume the server
        // in-process. The CLI binary continues to exist as a separate
        // executable product.
        .library(name: "LiveAudioServerCore", targets: ["LiveAudioServerCore"]),
        .executable(name: "LiveAudioServer", targets: ["LiveAudioServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0"),
        // MP3/AAC encoding (AudioEncoders) — see scripts/build-mp3lame-xcframework.sh
        // for why this package no longer vendors its own libmp3lame copy.
        .package(url: "https://github.com/dsward2/PipelineHelpers", branch: "main")
    ],
    targets: [
        // Server + encoders + streaming + config. Reusable from a host app.
        .target(
            name: "LiveAudioServerCore",
            dependencies: [.product(name: "AudioEncoders", package: "PipelineHelpers")],
            path: "Sources/LiveAudioServerCore"
        ),
        // Thin CLI shim: argument parsing, signal handling, process exit.
        .executableTarget(
            name: "LiveAudioServer",
            dependencies: ["LiveAudioServerCore"],
            path: "Sources/LiveAudioServer",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "LiveAudioServerTests",
            dependencies: [
                "LiveAudioServerCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/LiveAudioServerTests"
        )
    ]
)
