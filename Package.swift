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
        // Pure, hardware-free core: models, protocol codecs, device identification.
        // Imports only Foundation — no IOBluetooth, no AppKit — so it is unit-testable.
        .target(
            name: "SoundSherpaCore",
            dependencies: []
        ),
        // Menu-bar executable: AppKit UI + IOBluetooth transport, built on the core.
        .executableTarget(
            name: "SoundSherpa",
            dependencies: ["SoundSherpaCore"]
        ),
        .testTarget(
            name: "SoundSherpaCoreTests",
            dependencies: ["SoundSherpaCore"]
        ),
    ]
)
