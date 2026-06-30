import XCTest
@testable import SoundSherpaCore

final class SonyPluginTests: XCTestCase {

    func testIdentifier() {
        XCTAssertEqual(SonyPlugin().identifier, "Sony")
    }

    func testHandlesSonyNamedDevices() {
        let p = SonyPlugin()
        XCTAssertTrue(p.handles(deviceNamed: "WH-1000XM5"))
        XCTAssertTrue(p.handles(deviceNamed: "Sony WH-1000XM4"))
        XCTAssertTrue(p.handles(deviceNamed: "wh-1000xm3"))
        XCTAssertFalse(p.handles(deviceNamed: "Bose QC35 II"))
        XCTAssertFalse(p.handles(deviceNamed: ""))
    }

    func testDiscoveryDescriptorListsBothVendorUUIDsV2First() {
        let d = SonyPlugin().discoveryDescriptor
        XCTAssertEqual(d.serviceMatchers, [
            .uuid("956C7B26-D49A-4BA8-B03F-B17D393CB6E2"),  // V2 / XM5
            .uuid("96CC203E-5068-46AD-B32D-E316F5E069BA"),  // V1 / XM4
        ])
        XCTAssertEqual(d.channelHints, [])  // channel resolved from SDP, never hardcoded
    }

    func testSupportedFeatures() {
        let f = SonyPlugin().supportedFeatures
        XCTAssertEqual(f, [.noiseCancellation, .ambientLevel, .focusOnVoice, .equalizer])
        XCTAssertFalse(f.contains(.multipoint))   // deferred (no documented protocol)
        XCTAssertFalse(f.contains(.selfVoice))     // Bose-only
    }
}

extension SonyPluginTests {

    // Helper: build a full reply frame from a payload the test wants the "device" to send.
    private func frame(_ payload: [UInt8], seq: UInt8 = 0) -> [UInt8] {
        SonyFraming.encode(type: .command1, seq: seq, payload: payload)
    }

    func testReadBatteryNegotiatesV2ThenDecodes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = SonyPlugin()

        async let level = plugin.readBatteryLevel(over: channel)
        // 1) init query -> V2 reply (payload length 8)
        try await transport.awaitWrite(count: 1)
        await channel.ingest(frame([0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // 2) battery query -> reply payload [0x23,0x00,0x5A,...] = 90% (VERIFY ON HARDWARE)
        try await transport.awaitWrite(count: 2)
        await channel.ingest(frame([0x23, 0x00, 0x5A, 0x01]))

        let result = await level
        XCTAssertEqual(result, 90)

        // First write must be the framed init query (payload 00 00).
        let writes = await transport.writes
        XCTAssertEqual(writes.first, SonyFraming.encode(type: .command1, seq: 0, payload: [0x00, 0x00]))
        // Second write must be the V2 battery query payload, framed.
        XCTAssertEqual(writes[1], SonyFraming.encode(type: .command1, seq: writes[1][2], payload: [0x22, 0x00]))
    }

    func testReadBatteryReturnsNilWhenNegotiationFails() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        // No init reply ingested -> negotiation times out -> nil, never a throw/crash.
        let result = await SonyPlugin().readBatteryLevel(over: channel)
        XCTAssertNil(result)
    }
}
