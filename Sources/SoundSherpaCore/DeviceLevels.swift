import Foundation

/// Noise-cancellation strength. Byte values are non-contiguous on the wire
/// (Off 0x00, Low 0x03, High 0x01), so the mapping is explicit rather than a raw enum.
public enum NoiseCancellationLevel: CaseIterable, Sendable {
    case off, low, high

    public var byte: UInt8 {
        switch self {
        case .off: return 0x00
        case .low: return 0x03
        case .high: return 0x01
        }
    }

    public init?(byte: UInt8) {
        switch byte {
        case 0x00: self = .off
        case 0x03: self = .low
        case 0x01: self = .high
        default: return nil
        }
    }
}

/// Self-voice (sidetone) level. Raw values match the device protocol directly.
public enum SelfVoiceLevel: UInt8, CaseIterable, Sendable {
    case off = 0x00
    case high = 0x01
    case medium = 0x02
    case low = 0x03

    /// Off → Low → Medium → High, the order the pills are displayed in.
    public static let displayOrder: [SelfVoiceLevel] = [.off, .low, .medium, .high]
}
