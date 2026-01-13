// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundSherpa",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SoundSherpa",
            targets: ["SoundSherpa"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "SoundSherpa",
            dependencies: []
        ),
    ]
)