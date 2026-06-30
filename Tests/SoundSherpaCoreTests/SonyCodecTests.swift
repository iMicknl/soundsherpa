import XCTest
@testable import SoundSherpaCore

final class SonyCodecTests: XCTestCase {

    // MARK: - Init (asserted: encodeInit payload 00 00)
    func testInitQueryPayload() {
        XCTAssertEqual(SonyCodec.encodeInitQuery(), [0x00, 0x00])
    }

    // MARK: - Battery requests (asserted, SonyProtocolImplV1Test/V2Test getBattery)
    func testBatteryQueryV1() {
        XCTAssertEqual(SonyCodec.encodeBatteryQuery(version: .v1), [0x10, 0x00])
    }

    func testBatteryQueryV2() {
        XCTAssertEqual(SonyCodec.encodeBatteryQuery(version: .v2), [0x22, 0x00])
    }

    // MARK: - Battery reply decode
    // NEEDS-HARDWARE: handleBattery is a // TODO stub upstream — no asserted reply vector.
    // Fixture built from the documented index rule (response type = request+1; level at idx 2).
    func testBatteryReplyDecodeV1() {
        // [0x11, state, level, ...] per handleBattery index rule. VERIFY ON HARDWARE.
        XCTAssertEqual(SonyCodec.decodeBattery([0x11, 0x00, 0x5A, 0x01], version: .v1), 90)
    }

    func testBatteryReplyDecodeV2() {
        // V2 response type = request(0x22)+1 = 0x23. VERIFY ON HARDWARE.
        XCTAssertEqual(SonyCodec.decodeBattery([0x23, 0x00, 0x5A, 0x01], version: .v2), 90)
    }

    func testBatteryDecodeRejectsShortOrWrongPrefix() {
        XCTAssertNil(SonyCodec.decodeBattery([], version: .v1))
        XCTAssertNil(SonyCodec.decodeBattery([0x99, 0x00], version: .v1))
        XCTAssertNil(SonyCodec.decodeBattery([0x11], version: .v1))
    }
}
