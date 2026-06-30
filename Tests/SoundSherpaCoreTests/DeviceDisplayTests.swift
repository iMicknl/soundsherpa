import XCTest
@testable import SoundSherpaCore

final class DeviceDisplayBatterySymbolTests: XCTestCase {
    func testBatterySymbolNameBoundaries() {
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 0), "battery.0percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 10), "battery.0percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 11), "battery.25percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 35), "battery.25percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 36), "battery.50percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 60), "battery.50percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 61), "battery.75percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 85), "battery.75percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 86), "battery.100percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 100), "battery.100percent")
    }
}
