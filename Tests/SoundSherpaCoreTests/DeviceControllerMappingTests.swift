import XCTest
@testable import SoundSherpaCore

final class DeviceControllerMappingTests: XCTestCase {
    func testBatteryTiers() {
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 15), .critical)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 20), .critical)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 21), .low)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 50), .low)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 80), .normal)
    }

    func testPairedDeviceDisplayNameFallsBackToAddress() {
        // When the name is just the address, fall back to the address itself
        // rather than a vague "Unknown Device".
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "AC:07:75:42:C8:C0", address: "AC:07:75:42:C8:C0"),
            "AC:07:75:42:C8:C0")
        // When there is no name at all, show whatever we have: the address.
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "", address: "AC:07:75:42:C8:C0"),
            "AC:07:75:42:C8:C0")
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "Mick's MacBook Pro", address: "AC:07:75:42:C8:C0"),
            "Mick's MacBook Pro")
    }
}
