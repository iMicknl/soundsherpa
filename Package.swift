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
    dependencies: [
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "SoundSherpa",
            dependencies: []
        ),
        .testTarget(
            name: "SoundSherpaTests",
            dependencies: [
                "SoundSherpa",
                "SwiftCheck",
            ]
        ),
    ]
)
