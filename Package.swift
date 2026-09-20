// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeControl",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VolumeControl",
            path: "Sources/VolumeControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
