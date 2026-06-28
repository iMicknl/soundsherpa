import XCTest
@testable import SoundSherpaCore

final class DeviceLevelsTests: XCTestCase {
    func testNoiseCancellationByteMapping() {
        XCTAssertEqual(NoiseCancellationLevel.off.byte, 0x00)
        XCTAssertEqual(NoiseCancellationLevel.low.byte, 0x03)
        XCTAssertEqual(NoiseCancellationLevel.high.byte, 0x01)
    }

    func testNoiseCancellationRoundTrip() {
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x00), .off)
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x03), .low)
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x01), .high)
        XCTAssertNil(NoiseCancellationLevel(byte: 0xFF))
    }

    func testSelfVoiceByteMapping() {
        XCTAssertEqual(SelfVoiceLevel.off.rawValue, 0x00)
        XCTAssertEqual(SelfVoiceLevel.high.rawValue, 0x01)
        XCTAssertEqual(SelfVoiceLevel.medium.rawValue, 0x02)
        XCTAssertEqual(SelfVoiceLevel.low.rawValue, 0x03)
    }

    func testSelfVoiceDisplayOrder() {
        XCTAssertEqual(SelfVoiceLevel.displayOrder, [.off, .low, .medium, .high])
    }
}
