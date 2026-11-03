// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources/VoiceInput"
        ),
        .testTarget(
            name: "VoiceInputTests",
            dependencies: ["VoiceInput"],
            path: "Tests/VoiceInputTests"
        ),
    ]
)
