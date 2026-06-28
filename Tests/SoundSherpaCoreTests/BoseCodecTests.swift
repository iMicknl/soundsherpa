import XCTest
@testable import SoundSherpaCore

/// Tests for BoseCodec — the pure (bytes <-> typed values) seam for the Bose QC35 / QC35 II
/// SPP control protocol. These lock in the exact wire format reverse-engineered from
/// Denton-L/based-connect and verified on-device, with NO IOBluetooth dependency.
///
/// Packet shape: [FBLOCK, FUNCTION, OPERATOR, PAYLOAD_LEN, <payload…>]
/// Operators of interest: 0x01 GET (queries), 0x03 STATUS (responses).
final class BoseCodecTests: XCTestCase {

    // MARK: - Query encoders

    func testEncodeBatteryQuery() {
        XCTAssertEqual(BoseCodec.encodeBatteryQuery(), [0x02, 0x02, 0x01, 0x00])
    }

    func testEncodeFirmwareQuery() {
        XCTAssertEqual(BoseCodec.encodeFirmwareQuery(), [0x00, 0x05, 0x01, 0x00])
    }

    func testEncodeSerialQuery() {
        XCTAssertEqual(BoseCodec.encodeSerialQuery(), [0x00, 0x07, 0x01, 0x00])
    }

    func testEncodeDeviceIdQuery() {
        XCTAssertEqual(BoseCodec.encodeDeviceIdQuery(), [0x00, 0x03, 0x01, 0x00])
    }

    // MARK: - Battery decode

    func testDecodeBattery() {
        // [0x02,0x02,0x03,0x01,<level>]
        XCTAssertEqual(BoseCodec.decodeBattery([0x02, 0x02, 0x03, 0x01, 0x64]), 100)
        XCTAssertEqual(BoseCodec.decodeBattery([0x02, 0x02, 0x03, 0x01, 0x00]), 0)
        XCTAssertEqual(BoseCodec.decodeBattery([0x02, 0x02, 0x03, 0x01, 0x2A]), 42)
    }

    func testDecodeBatteryRejectsWrongPrefix() {
        XCTAssertNil(BoseCodec.decodeBattery([0x00, 0x07, 0x03, 0x01, 0x64]))
    }

    func testDecodeBatteryRejectsTruncated() {
        XCTAssertNil(BoseCodec.decodeBattery([0x02, 0x02, 0x03, 0x01]))
        XCTAssertNil(BoseCodec.decodeBattery([]))
    }

    // MARK: - Firmware decode

    func testDecodeFirmwareFromQueryResponse() {
        // [0x00,0x05,0x03,0x05, "1.0.4"]
        let bytes: [UInt8] = [0x00, 0x05, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34]
        XCTAssertEqual(BoseCodec.decodeFirmware(bytes), "1.0.4")
    }

    func testDecodeFirmwareFromInitReply() {
        // The init handshake reply carries the firmware string under function 0x01:
        // [0x00,0x01,0x03,0x05, "1.0.4"]
        let bytes: [UInt8] = [0x00, 0x01, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34]
        XCTAssertEqual(BoseCodec.decodeFirmware(bytes), "1.0.4")
    }

    func testDecodeFirmwareRejectsWrongFunction() {
        let bytes: [UInt8] = [0x00, 0x07, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34]
        XCTAssertNil(BoseCodec.decodeFirmware(bytes))
    }

    func testDecodeFirmwareRejectsTruncated() {
        // Claims length 5 but only 3 payload bytes present.
        XCTAssertNil(BoseCodec.decodeFirmware([0x00, 0x05, 0x03, 0x05, 0x31, 0x2E, 0x30]))
        XCTAssertNil(BoseCodec.decodeFirmware([]))
    }

    // MARK: - Serial decode

    func testDecodeSerial() {
        // [0x00,0x07,0x03,<len>, <ascii…>] — "075382P30290631AE"-ish; use a short fixture.
        let serial = "ABC123"
        var bytes: [UInt8] = [0x00, 0x07, 0x03, UInt8(serial.count)]
        bytes.append(contentsOf: Array(serial.utf8))
        XCTAssertEqual(BoseCodec.decodeSerial(bytes), "ABC123")
    }

    func testDecodeSerialRejectsWrongPrefix() {
        XCTAssertNil(BoseCodec.decodeSerial([0x00, 0x05, 0x03, 0x02, 0x41, 0x42]))
    }

    func testDecodeSerialRejectsTruncated() {
        // Declares length 6 but supplies 2 bytes.
        XCTAssertNil(BoseCodec.decodeSerial([0x00, 0x07, 0x03, 0x06, 0x41, 0x42]))
        XCTAssertNil(BoseCodec.decodeSerial([]))
    }

    // MARK: - Device (Bose model) ID decode

    func testDecodeModelId() {
        // [0x00,0x03,0x03,0x03, <id-hi>, <id-lo>, <index>] — QC35 family code 0x4014.
        let bytes: [UInt8] = [0x00, 0x03, 0x03, 0x03, 0x40, 0x14, 0x01]
        XCTAssertEqual(BoseCodec.decodeModelId(bytes), 0x4014)
    }

    func testDecodeModelIdRejectsWrongPrefix() {
        XCTAssertNil(BoseCodec.decodeModelId([0x00, 0x05, 0x03, 0x03, 0x40, 0x14, 0x01]))
    }

    func testDecodeModelIdRejectsTruncated() {
        XCTAssertNil(BoseCodec.decodeModelId([0x00, 0x03, 0x03, 0x03, 0x40]))
        XCTAssertNil(BoseCodec.decodeModelId([]))
    }

    // MARK: - Robustness (decoders never crash on garbage)

    func testDecodersToleranceToRandomGarbage() {
        let garbageInputs: [[UInt8]] = [
            [], [0x00], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            Array(repeating: 0x00, count: 64),
            Array(repeating: 0xFF, count: 3),
        ]
        for input in garbageInputs {
            // Must return nil, never crash or trap.
            _ = BoseCodec.decodeBattery(input)
            _ = BoseCodec.decodeFirmware(input)
            _ = BoseCodec.decodeSerial(input)
            _ = BoseCodec.decodeModelId(input)
        }
    }
}
