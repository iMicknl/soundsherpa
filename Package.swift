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
    dependencies: [
        // MenuBarExtra(.window) has no first-party API to focus Settings or dismiss the
        // panel from an .accessory app; these two libraries exist precisely to fill that
        // gap. See [[soundsherpa-...]] / SettingsPresentation for the why.
        .package(url: "https://github.com/orchetect/SettingsAccess", from: "2.1.0"),
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.3.0"),
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
            dependencies: [
                "SoundSherpaCore",
                .product(name: "SettingsAccess", package: "SettingsAccess"),
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
            ]
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
