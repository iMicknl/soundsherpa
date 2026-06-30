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
}
