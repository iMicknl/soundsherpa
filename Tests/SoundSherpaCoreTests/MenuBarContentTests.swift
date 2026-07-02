import XCTest
@testable import SoundSherpaCore

final class MenuBarContentTests: XCTestCase {
    func testConnectionSymbolReflectsState() {
        for content in MenuBarContent.allCases {
            XCTAssertEqual(content.connectionSymbolName(isConnected: true), "headphones.over.ear")
            XCTAssertEqual(content.connectionSymbolName(isConnected: false), "headphones.slash")
        }
    }

    func testShowsBattery() {
        XCTAssertFalse(MenuBarContent.iconOnly.showsBattery)
        XCTAssertTrue(MenuBarContent.iconAndBattery.showsBattery)
        XCTAssertTrue(MenuBarContent.iconAndVerticalBattery.showsBattery)
    }

    func testBatteryStyle() {
        XCTAssertNil(MenuBarContent.iconOnly.batteryStyle)
        XCTAssertEqual(MenuBarContent.iconAndBattery.batteryStyle, .horizontalWithNumber)
        XCTAssertEqual(MenuBarContent.iconAndVerticalBattery.batteryStyle, .verticalGlyph)
    }

    func testAllCasesHaveDisplayNames() {
        for content in MenuBarContent.allCases {
            XCTAssertFalse(content.displayName.isEmpty)
        }
    }
}
