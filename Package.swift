// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoundSherpa",
    platforms: [
        .macOS(.v26)
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
    ],
    // Tools-version 6.2 is required for the .macOS(.v26) platform case, but it
    // defaults to the Swift 6 language mode. The Swift 6 / UI migration is a
    // later task, so pin the existing sources to the Swift 5 language mode for
    // now — this task only raises the platform floor, with no source changes.
    swiftLanguageModes: [.v5]
)
