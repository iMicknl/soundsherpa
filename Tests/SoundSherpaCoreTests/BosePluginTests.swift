import XCTest
@testable import SoundSherpaCore

/// Tests for BosePlugin — the Bose implementation of the brand-agnostic `DevicePlugin`.
/// It drives real command I/O through a `DeviceChannel` actor (against a scripted fake
/// transport, so no IOBluetooth and no hardware), proving the plugin can identify a Bose
/// device and read its battery + static metadata over the serialized channel.
final class BosePluginTests: XCTestCase {

    // MARK: - Identity

    func testHandlesBoseNamedDevices() {
        let plugin = BosePlugin()
        XCTAssertTrue(plugin.handles(deviceNamed: "Bose QC35 II"))
        XCTAssertTrue(plugin.handles(deviceNamed: "bose quietcomfort 35"))
        XCTAssertFalse(plugin.handles(deviceNamed: "Sony WH-1000XM4"))
        XCTAssertFalse(plugin.handles(deviceNamed: ""))
    }

    func testIdentifier() {
        XCTAssertEqual(BosePlugin().identifier, "Bose")
    }

    // MARK: - Battery

    func testReadBatteryLevelDecodesResponse() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let level = plugin.readBatteryLevel(over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x02, 0x02, 0x03, 0x01, 0x5A]) // 90%

        let result = await level
        XCTAssertEqual(result, 90)
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x02, 0x02, 0x01, 0x00]])
    }

    func testReadBatteryLevelReturnsNilOnTimeout() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        // No response is ingested; the plugin must swallow the timeout and report nil
        // rather than throwing or fabricating a value.
        let result = await plugin.readBatteryLevel(over: channel)
        XCTAssertNil(result)
    }

    // MARK: - Metadata

    func testReadMetadataAggregatesFirmwareSerialAndModel() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let metadata = plugin.readMetadata(over: channel)

        // Firmware comes back on the init-handshake reply (function 0x01): "1.0.4".
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x00, 0x01, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34])
        // Serial number "ABCD".
        try await transport.awaitWrite(count: 2)
        await channel.ingest([0x00, 0x07, 0x03, 0x04, 0x41, 0x42, 0x43, 0x44])
        // Bose model code 0x4014.
        try await transport.awaitWrite(count: 3)
        await channel.ingest([0x00, 0x03, 0x03, 0x03, 0x40, 0x14, 0x00])

        let result = await metadata
        XCTAssertEqual(result.firmware, "1.0.4")
        XCTAssertEqual(result.serial, "ABCD")
        XCTAssertEqual(result.modelId, 0x4014)
    }

    func testReadMetadataReturnsEmptyWhenNothingResponds() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        // Every query times out; metadata is empty, never a crash or partial garbage.
        let result = await plugin.readMetadata(over: channel)
        XCTAssertTrue(result.isEmpty)
    }
}
