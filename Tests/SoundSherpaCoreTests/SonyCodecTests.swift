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

extension SonyCodecTests {

    // MARK: - ANC/ambient V1 (asserted, SonyProtocolImplV1Test.setAmbientSoundControl)
    // V1 layout: [0x68,0x02,<mode 0x00 off/0x11 on>,0x00,<nc>,0x01,<focus>,<level>]
    func testEncodeANCV1Off() {
        let s = ANCState(mode: .off)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    func testEncodeANCV1AmbientLevel10() {
        let s = ANCState(mode: .ambient, ambientLevel: 10, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x00, 0x01, 0x00, 0x0A])
    }

    func testEncodeANCV1AmbientFocusOnVoiceLevel15() {
        let s = ANCState(mode: .ambient, ambientLevel: 15, focusOnVoice: true)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x00, 0x01, 0x01, 0x0F])
    }

    func testEncodeANCV1NoiseCancelling() {
        let s = ANCState(mode: .noiseCancelling)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x01, 0x01, 0x00, 0x00])
    }

    // MARK: - ANC/ambient V2 (asserted bare payloads, SonyProtocolImplV2Test)
    // V2 layout: [0x68,0x17,0x01,<off 0x00/on 0x01>,<ambientFlag>,<focus>,<level>]
    func testEncodeANCV2AmbientLevel20() {
        let s = ANCState(mode: .ambient, ambientLevel: 20, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x14])
    }

    func testEncodeANCV2AmbientFocusOnVoice() {
        let s = ANCState(mode: .ambient, ambientLevel: 20, focusOnVoice: true)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14])
    }

    func testEncodeANCV2NoiseCancellingLevel20() {
        let s = ANCState(mode: .noiseCancelling, ambientLevel: 20)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14])
    }

    func testEncodeANCV2Off() {
        let s = ANCState(mode: .off, ambientLevel: 20)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x00, 0x00, 0x00, 0x14])
    }

    // Ambient level must be clamped to 0–20 regardless of input.
    func testEncodeANCClampsAmbientLevel() {
        let hi = ANCState(mode: .ambient, ambientLevel: 99, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(hi, version: .v2).last, 0x14)  // 20
        let lo = ANCState(mode: .ambient, ambientLevel: -5, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(lo, version: .v2).last, 0x00)
    }

    // MARK: - Ambient status query (asserted: 0x66 0x02 both dialects)
    func testAmbientStatusQuery() {
        XCTAssertEqual(SonyCodec.encodeAmbientStatusQuery(version: .v1), [0x66, 0x02])
        XCTAssertEqual(SonyCodec.encodeAmbientStatusQuery(version: .v2), [0x66, 0x02])
    }

    // MARK: - ANC reply decode
    // NEEDS-HARDWARE: ambient reply is a // TODO stub upstream. Fixture mirrors the V2 set
    // layout under response type 0x67 (request 0x66 + 1). VERIFY ON HARDWARE.
    func testDecodeANCV2Ambient() {
        let decoded = SonyCodec.decodeANC([0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0F], version: .v2)
        XCTAssertEqual(decoded?.mode, .ambient)
        XCTAssertEqual(decoded?.ambientLevel, 15)
        XCTAssertEqual(decoded?.focusOnVoice, false)
    }

    func testDecodeANCRejectsGarbage() {
        XCTAssertNil(SonyCodec.decodeANC([0x00], version: .v2))
        XCTAssertNil(SonyCodec.decodeANC([], version: .v1))
    }
}

extension SonyCodecTests {

    // MARK: - EQ preset (asserted, setEqualizerPreset; V1 byte1=0x01, V2 byte1=0x00)
    func testEncodeEQPresetV1Off() {
        let s = EqualizerState(presetId: 0x00, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1), [0x58, 0x01, 0x00, 0x00])
    }

    func testEncodeEQPresetV1BassBoost() {
        let s = EqualizerState(presetId: 0x16, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1), [0x58, 0x01, 0x16, 0x00])
    }

    func testEncodeEQPresetV2Off() {
        let s = EqualizerState(presetId: 0x00, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2), [0x58, 0x00, 0x00, 0x00])
    }

    func testEncodeEQPresetV2Bright() {
        let s = EqualizerState(presetId: 0x10, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2), [0x58, 0x00, 0x10, 0x00])
    }

    // MARK: - EQ custom bands (asserted; 6 bands, gain+10; V1 marker 0xFF, V2 marker 0xA0)
    func testEncodeEQCustomBandsV1Flat() {
        let s = EqualizerState(presetId: 0xA1, bands: [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1),
                       [0x58, 0x01, 0xFF, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A])
    }

    func testEncodeEQCustomBandsV2Mixed() {
        // gains [0,0,1,2,3,1] -> +10 -> [0x0A,0x0A,0x0B,0x0C,0x0D,0x0B]
        let s = EqualizerState(presetId: 0xA1, bands: [0, 0, 1, 2, 3, 1])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2),
                       [0x58, 0x00, 0xA0, 0x06, 0x0A, 0x0A, 0x0B, 0x0C, 0x0D, 0x0B])
    }

    // MARK: - EQ status query (asserted: V1 0x56 0x01; V2 0x56 0x00)
    func testEncodeEQStatusQuery() {
        XCTAssertEqual(SonyCodec.encodeEQStatusQuery(version: .v1), [0x56, 0x01])
        XCTAssertEqual(SonyCodec.encodeEQStatusQuery(version: .v2), [0x56, 0x00])
    }

    // MARK: - EQ status reply decode (asserted V2 full-frame payloads, handleEqualizer)
    // OFF reply payload: 59 00 00 06 0a 0a 0a 0a 0a 0a ; MANUAL: 59 00 a0 06 0a 0a 0a 0a 0a 0a
    func testDecodeEQV2OffPreset() {
        let payload: [UInt8] = [0x59, 0x00, 0x00, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A]
        let s = SonyCodec.decodeEQ(payload, version: .v2)
        XCTAssertEqual(s?.presetId, 0x00)
        XCTAssertEqual(s?.bands, [0, 0, 0, 0, 0, 0])
    }

    func testDecodeEQRejectsGarbage() {
        XCTAssertNil(SonyCodec.decodeEQ([0x00], version: .v2))
        XCTAssertNil(SonyCodec.decodeEQ([], version: .v1))
    }
}
