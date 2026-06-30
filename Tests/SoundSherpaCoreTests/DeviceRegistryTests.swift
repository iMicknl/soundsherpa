import XCTest
@testable import SoundSherpaCore

/// Tests for DeviceRegistry — the lookup that maps a connected device's advertised name to
/// the plugin that speaks its protocol. This is the extension point: adding Sony support is
/// registering one more plugin here, with zero changes to the channel/actor/UI layers.
final class DeviceRegistryTests: XCTestCase {

    func testResolvesBoseByDefault() {
        let registry = DeviceRegistry.standard
        let plugin = registry.plugin(forDeviceNamed: "Bose QC35 II")
        XCTAssertEqual(plugin?.identifier, "Bose")
    }

    func testReturnsNilForUnknownDevice() {
        let registry = DeviceRegistry.standard
        XCTAssertNil(registry.plugin(forDeviceNamed: "Generic BT Speaker"))
    }

    func testFirstMatchingPluginWins() {
        let registry = DeviceRegistry(plugins: [StubPlugin(id: "First"),
                                                StubPlugin(id: "Second")])
        // Both stubs claim every device; registration order decides the winner.
        XCTAssertEqual(registry.plugin(forDeviceNamed: "anything")?.identifier, "First")
    }

    func testCustomRegistryIsExtensible() {
        // Proves a new brand drops in without touching existing plugins: the registry is
        // just a list, and resolution is name-based.
        let registry = DeviceRegistry(plugins: [BosePlugin(),
                                                StubPlugin(id: "Sony", matches: { $0.contains("Sony") })])
        XCTAssertEqual(registry.plugin(forDeviceNamed: "Sony WH-1000XM4")?.identifier, "Sony")
        XCTAssertEqual(registry.plugin(forDeviceNamed: "Bose QC35 II")?.identifier, "Bose")
    }
}

extension DeviceRegistryTests {
    func testStandardRegistryResolvesSony() {
        let registry = DeviceRegistry.standard
        XCTAssertEqual(registry.plugin(forDeviceNamed: "WH-1000XM5")?.identifier, "Sony")
        XCTAssertEqual(registry.plugin(forDeviceNamed: "Sony WH-1000XM4")?.identifier, "Sony")
    }

    func testStandardRegistryStillResolvesBose() {
        XCTAssertEqual(DeviceRegistry.standard.plugin(forDeviceNamed: "Bose QC35 II")?.identifier, "Bose")
    }
}

/// A minimal DevicePlugin used to test registry resolution without any real protocol I/O.
private struct StubPlugin: DevicePlugin {
    let identifier: String
    let matcher: (String) -> Bool

    init(id: String, matches: @escaping (String) -> Bool = { _ in true }) {
        self.identifier = id
        self.matcher = matches
    }

    func handles(deviceNamed name: String) -> Bool { matcher(name) }
    func readBatteryLevel(over channel: DeviceChannel) async -> Int? { nil }
    func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata { DeviceMetadata() }
    var discoveryDescriptor: DiscoveryDescriptor { DiscoveryDescriptor(serviceMatchers: [], channelHints: []) }
    var supportedFeatures: Set<DeviceFeature> { [] }
    func readState(over channel: DeviceChannel) async -> DeviceState { DeviceState() }
    func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool { false }
}
