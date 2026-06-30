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

    // MARK: - Control encoders

    /// Noise-cancellation set: `[0x01,0x06,0x02,0x01,<level byte>]`.
    public static func encodeNoiseCancellation(_ level: NoiseCancellationLevel) -> [UInt8] {
        [0x01, 0x06, 0x02, 0x01, level.byte]
    }

    /// Device-status query that provokes the language / NC / self-voice broadcasts.
    public static func encodeStatusQuery() -> [UInt8] { [0x01, 0x01, 0x05, 0x00] }

    public static func encodeAutoOffQuery() -> [UInt8] { [0x01, 0x04, 0x01, 0x00] }

    /// Auto-off set: `[0x01,0x04,0x02,0x01,<minutes byte>]`.
    public static func encodeAutoOff(_ value: AutoOff) -> [UInt8] {
        [0x01, 0x04, 0x02, 0x01, value.rawValue]
    }

    public static func encodeButtonActionQuery() -> [UInt8] { [0x01, 0x09, 0x01, 0x00] }

    /// Button-action set: `[0x01,0x09,0x02,0x03,0x10,0x04,<mode>]`.
    public static func encodeButtonAction(_ value: ButtonAction) -> [UInt8] {
        [0x01, 0x09, 0x02, 0x03, 0x10, 0x04, value.rawValue]
    }

    /// Self-voice set: `[0x01,0x0b,0x02,0x02,0x01,<level>,0x38]`.
    public static func encodeSelfVoice(_ level: SelfVoiceLevel) -> [UInt8] {
        [0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38]
    }

    /// Language set: `[0x01,0x03,0x02,0x01,<language byte incl. voice-prompt high bit>]`.
    public static func encodeLanguage(_ languageByte: UInt8) -> [UInt8] {
        [0x01, 0x03, 0x02, 0x01, languageByte]
    }

    // MARK: - Control decoders

    /// Auto-off from a STATUS reply `[0x01,0x04,0x03,<len>,<value>]`.
    public static func decodeAutoOff(_ bytes: [UInt8]) -> AutoOff? {
        guard bytes.count >= 5,
              bytes[0] == 0x01, bytes[1] == 0x04, bytes[2] == 0x03 else { return nil }
        return AutoOff(rawValue: bytes[4])
    }

    /// Button action from the ACK `[0x01,0x09,0x03,0x04,0x10,0x04,<mode>,0x07]` (mode at byte 6).
    public static func decodeButtonAction(_ bytes: [UInt8]) -> ButtonAction? {
        guard bytes.count >= 8,
              bytes[0] == 0x01, bytes[1] == 0x09, bytes[2] == 0x03,
              bytes[4] == 0x10, bytes[5] == 0x04 else { return nil }
        return ButtonAction(rawValue: bytes[6])
    }

    /// Parsed device-status snapshot from the collected broadcast buffer.
    public struct BoseStatus: Equatable, Sendable {
        public var noiseCancellation: NoiseCancellationLevel?
        public var selfVoice: SelfVoiceLevel?
        public var promptLanguage: PromptLanguage?
        public var voicePromptsEnabled: Bool?
        public var languageByte: UInt8?
        public init() {}
    }

    /// Scan the collected status buffer for the language (0x01 0x03 0x03), NC (0x01 0x06 0x03),
    /// and self-voice (0x01 0x0b 0x03) broadcasts. Mirrors the old parseDeviceStatusResponse:
    /// first match of each wins; non-matching/short buffers yield nil fields (never a crash).
    public static func decodeStatus(_ bytes: [UInt8]) -> BoseStatus {
        var status = BoseStatus()

        // Language (+ voice-prompt high bit): value at i+4.
        for i in 0..<bytes.count where i + 4 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x03, bytes[i+2] == 0x03 {
                let langByte = bytes[i+4]
                status.languageByte = langByte
                status.voicePromptsEnabled = (langByte & 0x80) != 0
                status.promptLanguage = PromptLanguage(rawValue: langByte & 0x7F)
                break
            }
        }
        // NC level: value at i+4.
        for i in 0..<bytes.count where i + 4 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x06, bytes[i+2] == 0x03 {
                status.noiseCancellation = NoiseCancellationLevel(byte: bytes[i+4])
                break
            }
        }
        // Self-voice: value at i+5.
        for i in 0..<bytes.count where i + 5 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x0b, bytes[i+2] == 0x03 {
                status.selfVoice = SelfVoiceLevel(rawValue: bytes[i+5])
                break
            }
        }
        return status
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
