import XCTest
@testable import SoundSherpaCore

final class MenuBarIconStyleTests: XCTestCase {
    func testFollowConnectionReflectsState() {
        XCTAssertEqual(MenuBarIconStyle.followConnection.symbolName(isConnected: true), "headphones.over.ear")
        XCTAssertEqual(MenuBarIconStyle.followConnection.symbolName(isConnected: false), "headphones.slash")
    }

    func testAlwaysShowIgnoresState() {
        XCTAssertEqual(MenuBarIconStyle.alwaysShow.symbolName(isConnected: true), "headphones.over.ear")
        XCTAssertEqual(MenuBarIconStyle.alwaysShow.symbolName(isConnected: false), "headphones.over.ear")
    }

    func testAllCasesHaveDisplayNames() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
        }
    }
}
