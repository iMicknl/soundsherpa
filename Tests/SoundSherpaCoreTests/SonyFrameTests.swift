import XCTest
@testable import SoundSherpaCore

final class SonyFrameTests: XCTestCase {

    // Verbatim asserted V2 vector (Gadgetbridge SonyProtocolImplV2Test.setEqualizerPreset, OFF):
    // 3e:0c:01:00:00:00:04:58:00:00:00:69:3c — checksum 0x69 = 0x0C+0x01+0x04+0x58.
    func testEncodeMatchesKnownV2Frame() {
        let frame = SonyFraming.encode(type: .command1, seq: 0x01,
                                       payload: [0x58, 0x00, 0x00, 0x00])
        XCTAssertEqual(frame, [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x04,
                               0x58, 0x00, 0x00, 0x00, 0x69, 0x3C])
    }

    func testRoundTripPreservesTypeSeqPayload() {
        let payload: [UInt8] = [0x68, 0x15, 0x01, 0x01, 0x00, 0x03, 0x01, 0x0F]
        let encoded = SonyFraming.encode(type: .command1, seq: 0x00, payload: payload)
        let decoded = SonyFraming.decode(encoded)
        XCTAssertEqual(decoded?.type, .command1)
        XCTAssertEqual(decoded?.seq, 0x00)
        XCTAssertEqual(decoded?.payload, payload)
    }

    // Escaping is DERIVED from the mask rule (no asserted escaping vector upstream):
    // payload byte 0x3E -> 0x3D,0x2E ; 0x3C -> 0x3D,0x2C ; 0x3D -> 0x3D,0x2D.
    func testEncodeEscapesSpecialPayloadBytes() {
        let encoded = SonyFraming.encode(type: .command1, seq: 0x00,
                                         payload: [0x3E, 0x3C, 0x3D])
        // Markers must appear only as the outer frame bounds.
        XCTAssertEqual(encoded.first, 0x3E)
        XCTAssertEqual(encoded.last, 0x3C)
        // The three special payload bytes appear escaped.
        let inner = Array(encoded.dropFirst().dropLast())
        XCTAssertTrue(inner.contains([0x3D, 0x2E]).isPresent)
        XCTAssertTrue(inner.contains([0x3D, 0x2C]).isPresent)
        XCTAssertTrue(inner.contains([0x3D, 0x2D]).isPresent)
        // And round-trips back to the original payload.
        XCTAssertEqual(SonyFraming.decode(encoded)?.payload, [0x3E, 0x3C, 0x3D])
    }

    func testDecodeRejectsBadChecksum() {
        var frame = SonyFraming.encode(type: .command1, seq: 0x01,
                                       payload: [0x58, 0x00, 0x00, 0x00])
        frame[11] = 0x00 // corrupt the checksum byte
        XCTAssertNil(SonyFraming.decode(frame))
    }

    func testDecodeRejectsTruncatedAndMissingMarkers() {
        XCTAssertNil(SonyFraming.decode([]))
        XCTAssertNil(SonyFraming.decode([0x3E, 0x0C]))                 // too short
        XCTAssertNil(SonyFraming.decode([0x00, 0x0C, 0x00, 0x3C]))     // no start marker
        let noEnd: [UInt8] = [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x04, 0x58, 0x00, 0x00, 0x00, 0x69]
        XCTAssertNil(SonyFraming.decode(noEnd))                        // no end marker
    }
}

// Small helper so the escaping test reads clearly.
private extension Array where Element == UInt8 {
    func contains(_ subsequence: [UInt8]) -> (isPresent: Bool, Void) {
        guard !subsequence.isEmpty, count >= subsequence.count else { return (false, ()) }
        for start in 0...(count - subsequence.count) where Array(self[start..<start+subsequence.count]) == subsequence {
            return (true, ())
        }
        return (false, ())
    }
}
