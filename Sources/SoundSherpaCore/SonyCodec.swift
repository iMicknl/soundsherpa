import Foundation

/// Pure payload builders/parsers for the Sony WH-1000XM control protocol. These produce/parse
/// the PAYLOAD only; SonyFraming wraps them on the wire. Every builder takes the negotiated
/// `SonyProtocol` because the V1 (XM4) and V2 (XM5) dialects share commands but differ in
/// payload layout. Decoders validate before indexing and return nil on any mismatch.
///
/// Byte values anchored on Gadgetbridge (V1/V2 impl + tests), cross-checked vs Plutoberth.
/// Reply decoders flagged VERIFY ON HARDWARE are built from documented index rules where the
/// upstream test asserts no literal reply vector.
public enum SonyCodec {

    // MARK: - Init / negotiation
    /// Init/protocol-info request payload (type COMMAND_1 on the wire). Reply length → version.
    public static func encodeInitQuery() -> [UInt8] { [0x00, 0x00] }

    // MARK: - Battery
    public static func encodeBatteryQuery(version: SonyProtocol) -> [UInt8] {
        switch version {
        case .v1: return [0x10, 0x00]
        case .v2: return [0x22, 0x00]
        }
    }

    /// Battery percentage (0–100). VERIFY ON HARDWARE: response type byte and level index are
    /// from the documented rule (level at index 2), not an asserted upstream vector.
    public static func decodeBattery(_ payload: [UInt8], version: SonyProtocol) -> Int? {
        let expectedType: UInt8 = (version == .v1) ? 0x11 : 0x23
        guard payload.count >= 3, payload[0] == expectedType else { return nil }
        return Int(payload[2])
    }

    // MARK: - ANC / ambient (command 0x68)

    private static func clampLevel(_ level: Int?) -> UInt8 {
        UInt8(min(20, max(0, level ?? 0)))
    }

    /// Encode a sound-control change. V1 (XM4) and V2 (XM5) use different payload layouts for
    /// the same 0x68 command — see the per-dialect builders. The "no wind-noise capability"
    /// V1 form is used (byte[3]=0x00); wind-noise reduction is out of scope for v1.
    public static func encodeANC(_ state: ANCState, version: SonyProtocol) -> [UInt8] {
        let level = clampLevel(state.ambientLevel)
        let focus: UInt8 = (state.focusOnVoice == true) ? 0x01 : 0x00
        switch version {
        case .v1:
            // [0x68,0x02,<modeOn>,0x00,<nc>,0x01,<focus>,<level>]
            let modeOn: UInt8 = (state.mode == .off) ? 0x00 : 0x11
            let nc: UInt8 = (state.mode == .noiseCancelling) ? 0x01 : 0x00
            return [0x68, 0x02, modeOn, 0x00, nc, 0x01, focus, level]
        case .v2:
            // [0x68,0x17,0x01,<off 0x00/on 0x01>,<ambientFlag>,<focus>,<level>]
            let on: UInt8 = (state.mode == .off) ? 0x00 : 0x01
            let ambientFlag: UInt8 = (state.mode == .ambient) ? 0x01 : 0x00
            return [0x68, 0x17, 0x01, on, ambientFlag, focus, level]
        }
    }

    public static func encodeAmbientStatusQuery(version: SonyProtocol) -> [UInt8] {
        [0x66, 0x02]
    }

    /// Decode an ambient/ANC status reply. VERIFY ON HARDWARE: built from the V2 set layout
    /// under response type 0x67; the upstream reply decoder is a stub.
    public static func decodeANC(_ payload: [UInt8], version: SonyProtocol) -> ANCState? {
        switch version {
        case .v2:
            guard payload.count >= 7, payload[0] == 0x67, payload[1] == 0x17 else { return nil }
            let on = payload[3] != 0x00
            let ambient = payload[4] != 0x00
            let mode: ANCState.Mode = !on ? .off : (ambient ? .ambient : .noiseCancelling)
            return ANCState(mode: mode,
                            ambientLevel: Int(payload[6]),
                            focusOnVoice: payload[5] != 0x00)
        case .v1:
            guard payload.count >= 8, payload[0] == 0x67, payload[1] == 0x02 else { return nil }
            let on = payload[2] != 0x00
            let nc = payload[4] != 0x00
            let mode: ANCState.Mode = !on ? .off : (nc ? .noiseCancelling : .ambient)
            return ANCState(mode: mode,
                            ambientLevel: Int(payload[7]),
                            focusOnVoice: payload[6] != 0x00)
        }
    }

    // MARK: - Equalizer (command 0x58)

    private static let customPresetId = 0xA1  // CUSTOM_1

    /// Encode an EQ change. Preset IDs are the raw Sony values stored on `EqualizerState`.
    /// A custom preset (presetId 0xA1 with bands) emits the 6-band payload; gains are encoded
    /// as value+10. V1 vs V2 differ in the byte after the 0x58 command (V1=0x01, V2=0x00) and
    /// the custom-bands marker (V1=0xFF, V2=0xA0).
    public static func encodeEQ(_ state: EqualizerState, version: SonyProtocol) -> [UInt8] {
        let dialectByte: UInt8 = (version == .v1) ? 0x01 : 0x00
        let isCustom = (state.presetId == customPresetId) && !state.bands.isEmpty
        if isCustom {
            let marker: UInt8 = (version == .v1) ? 0xFF : 0xA0
            var out: [UInt8] = [0x58, dialectByte, marker, UInt8(state.bands.count)]
            out.append(contentsOf: state.bands.map { UInt8(min(255, max(0, $0 + 10))) })
            return out
        }
        let preset = UInt8(state.presetId ?? 0x00)
        return [0x58, dialectByte, preset, 0x00]
    }

    public static func encodeEQStatusQuery(version: SonyProtocol) -> [UInt8] {
        switch version {
        case .v1: return [0x56, 0x01]
        case .v2: return [0x56, 0x00]
        }
    }

    /// Decode an EQ status reply `[0x59, <dialect>, <presetId>, <count>, <bands…>]`.
    /// Bands are decoded from value+10 back to signed dB. Asserted against V2 vectors.
    public static func decodeEQ(_ payload: [UInt8], version: SonyProtocol) -> EqualizerState? {
        guard payload.count >= 4, payload[0] == 0x59 else { return nil }
        let presetId = Int(payload[2])
        let count = Int(payload[3])
        guard payload.count >= 4 + count else {
            return EqualizerState(presetId: presetId, bands: [])
        }
        let bands = payload[4..<(4 + count)].map { Int($0) - 10 }
        return EqualizerState(presetId: presetId, bands: Array(bands))
    }

    // MARK: - Metadata (firmware)
    //
    // NEEDS-HARDWARE: only the V1 firmware REQUEST (0x04 0x02) is asserted upstream; the reply
    // decoder and serial/model queries are stubs. We decode an ASCII firmware string from a
    // response prefixed 0x05; serial/model are deferred until a device confirms their frames.

    public static func encodeFirmwareQuery(version: SonyProtocol) -> [UInt8] { [0x04, 0x02] }

    public static func decodeFirmware(_ payload: [UInt8], version: SonyProtocol) -> String? {
        guard payload.count >= 3, payload[0] == 0x05 else { return nil }
        let ascii = Array(payload[2...])
        return String(bytes: ascii, encoding: .utf8)
    }
}
