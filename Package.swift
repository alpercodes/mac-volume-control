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
        ),
        // Measures macOS's call ducking for the app, which can't measure it itself (see Sources/DuckMeter).
        .executableTarget(
            name: "DuckMeter",
            path: "Sources/DuckMeter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
