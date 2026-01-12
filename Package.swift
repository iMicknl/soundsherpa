// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeadphoneBattery",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "HeadphoneBattery",
            targets: ["HeadphoneBattery"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "HeadphoneBattery",
            dependencies: []
        ),
    ]
)