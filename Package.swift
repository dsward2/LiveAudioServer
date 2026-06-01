// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveAudioServer",
    platforms: [
        .macOS(.v13)
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
        .executableTarget(
            name: "LiveAudioServer",
            dependencies: ["CLame"],
            path: "Sources/LiveAudioServer"
        ),
        .testTarget(
            name: "LiveAudioServerTests",
            dependencies: [
                "LiveAudioServer",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/LiveAudioServerTests"
        )
    ]
)
