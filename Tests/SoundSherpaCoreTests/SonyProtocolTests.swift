import XCTest
@testable import SoundSherpaCore

final class SonyProtocolTests: XCTestCase {
    func testClassifyByInitReplyLength() {
        // Gadgetbridge SonyHeadphonesProtocol: payload length 4 -> v1, 8 -> v2.
        XCTAssertEqual(SonyProtocol.classify(initReplyPayloadLength: 4), .v1)
        XCTAssertEqual(SonyProtocol.classify(initReplyPayloadLength: 8), .v2)
    }

    func testClassifyReturnsNilForUnknownLength() {
        XCTAssertNil(SonyProtocol.classify(initReplyPayloadLength: 0))
        XCTAssertNil(SonyProtocol.classify(initReplyPayloadLength: 6))
    }
}
