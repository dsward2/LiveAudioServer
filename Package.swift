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
        .systemLibrary(
            name: "CLame",
            pkgConfig: "mp3lame",
            providers: [
                .brew(["lame"])
            ]
        ),
        .executableTarget(
            name: "LiveAudioServer",
            dependencies: ["CLame"],
            path: "Sources/LiveAudioServer",
            linkerSettings: [
                .linkedLibrary("mp3lame")
            ]
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
