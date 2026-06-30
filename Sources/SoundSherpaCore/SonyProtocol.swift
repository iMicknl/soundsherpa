import Foundation

/// Which Sony control-protocol dialect a connected device speaks. WH-1000XM4 → v1,
/// WH-1000XM5 → v2. Negotiated at runtime, never assumed from the model name.
public enum SonyProtocol: Sendable, Equatable {
    case v1
    case v2

    /// Classify by the init-handshake reply's payload length (Gadgetbridge rule):
    /// length 4 → v1, length 8 → v2. Any other length is unknown (nil).
    public static func classify(initReplyPayloadLength length: Int) -> SonyProtocol? {
        switch length {
        case 4: return .v1
        case 8: return .v2
        default: return nil
        }
    }
}
