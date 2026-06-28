import Foundation

/// Pure encode/decode functions for the Bose QC35 / QC35 II SPP control protocol.
///
/// This is the *test seam*: no IOBluetooth, no AppKit — just bytes in, typed values out.
/// The wire format is reverse-engineered from `Denton-L/based-connect` and verified
/// on-device against a QC35 II.
///
/// Packet shape: `[FBLOCK, FUNCTION, OPERATOR, PAYLOAD_LEN, <payload…>]`
/// (no checksum, no framing). Operators used here: `0x01` GET (queries), `0x03` STATUS
/// (responses). Multiple messages can arrive concatenated in a single RFCOMM read, so
/// decoders match on the leading header and tolerate trailing bytes.
///
/// All decoders return `nil` on a wrong prefix or a truncated/garbage payload — they
/// never crash. Callers treat `nil` as "not available" rather than a fabricated value.
public enum BoseCodec {

    // MARK: - Query encoders

    /// Battery level query → response `[0x02,0x02,0x03,0x01,<level>]`.
    public static func encodeBatteryQuery() -> [UInt8] { [0x02, 0x02, 0x01, 0x00] }

    /// Firmware version query → response `[0x00,0x05,0x03,0x05,<5 ascii>]`.
    public static func encodeFirmwareQuery() -> [UInt8] { [0x00, 0x05, 0x01, 0x00] }

    /// Serial number query → response `[0x00,0x07,0x03,<len>,<ascii…>]`.
    public static func encodeSerialQuery() -> [UInt8] { [0x00, 0x07, 0x01, 0x00] }

    /// Bose model-ID query → response `[0x00,0x03,0x03,0x03,<id-hi>,<id-lo>,<index>]`.
    public static func encodeDeviceIdQuery() -> [UInt8] { [0x00, 0x03, 0x01, 0x00] }

    // MARK: - Decoders

    /// Battery percentage (0–100) from `[0x02,0x02,0x03,0x01,<level>]`.
    public static func decodeBattery(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 5,
              bytes[0] == 0x02, bytes[1] == 0x02, bytes[2] == 0x03 else { return nil }
        return Int(bytes[4])
    }

    /// Firmware version string. Accepts both the dedicated query response (function `0x05`)
    /// and the init-handshake reply (function `0x01`), which both carry the version as a
    /// length-prefixed ASCII payload after the 4-byte header.
    public static func decodeFirmware(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4,
              bytes[0] == 0x00,
              bytes[1] == 0x05 || bytes[1] == 0x01,
              bytes[2] == 0x03 else { return nil }
        return decodeLengthPrefixedASCII(bytes)
    }

    /// Serial number string from `[0x00,0x07,0x03,<len>,<ascii…>]`.
    public static func decodeSerial(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4,
              bytes[0] == 0x00, bytes[1] == 0x07, bytes[2] == 0x03 else { return nil }
        return decodeLengthPrefixedASCII(bytes)
    }

    /// Bose-internal 16-bit model code (big-endian) from
    /// `[0x00,0x03,0x03,0x03,<id-hi>,<id-lo>,<index>]`.
    ///
    /// This is a Bose hardware/model identifier (e.g. `0x4014` for the QC35 family),
    /// *not* a Bluetooth PnP / USB vendor+product ID.
    public static func decodeModelId(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6,
              bytes[0] == 0x00, bytes[1] == 0x03, bytes[2] == 0x03 else { return nil }
        return Int(bytes[4]) << 8 | Int(bytes[5])
    }

    // MARK: - Helpers

    /// Reads a `[…, length, <length ascii bytes>]` payload starting at index 3, returning
    /// the decoded string or `nil` if the declared length runs past the buffer.
    private static func decodeLengthPrefixedASCII(_ bytes: [UInt8]) -> String? {
        let length = Int(bytes[3])
        guard length > 0, bytes.count >= 4 + length else { return nil }
        let payload = Array(bytes[4..<(4 + length)])
        return String(bytes: payload, encoding: .utf8)
    }
}
