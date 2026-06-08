// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveAudioServer",
    platforms: [
        .macOS(.v13)
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
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0")
    ],
    targets: [
        // Vendored libmp3lame as a universal (arm64 + x86_64) static
        // XCFramework. Regenerate by running scripts/build-mp3lame-xcframework.sh.
        .binaryTarget(
            name: "CLame",
            path: "Frameworks/Mp3Lame.xcframework"
        ),
        // Server + encoders + streaming + config. Reusable from a host app.
        .target(
            name: "LiveAudioServerCore",
            dependencies: ["CLame"],
            path: "Sources/LiveAudioServerCore"
        ),
        // Thin CLI shim: argument parsing, signal handling, process exit.
        .executableTarget(
            name: "LiveAudioServer",
            dependencies: ["LiveAudioServerCore"],
            path: "Sources/LiveAudioServer"
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
