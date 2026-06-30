import Foundation

// Bose-specific feature value types. Moved here from the app target so the brand-agnostic
// DeviceState / DeviceChange types in Core can reference them. Values and displayName text
// are unchanged from the original app-target definitions.

public enum PromptLanguage: UInt8, Sendable {
    case english = 0x21
    case french = 0x22
    case italian = 0x23
    case german = 0x24
    case spanish = 0x26
    case portuguese = 0x27
    case chinese = 0x28
    case korean = 0x29
    case polish = 0x2B
    case russian = 0x2A
    case dutch = 0x2e
    case japanese = 0x2f
    case swedish = 0x32
    case unknown = 0x00

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .italian: return "Italian"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese"
        case .korean: return "Korean"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .dutch: return "Dutch"
        case .japanese: return "Japanese"
        case .swedish: return "Swedish"
        case .unknown: return "Unknown"
        }
    }
}

public enum AutoOff: UInt8, Sendable {
    case never = 0x00
    case five = 0x05
    case twenty = 0x14
    case forty = 0x28
    case sixty = 0x3C
    case oneEighty = 0xB4
    case unknown = 0xFF

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .five: return "5 minutes"
        case .twenty: return "20 minutes"
        case .forty: return "40 minutes"
        case .sixty: return "60 minutes"
        case .oneEighty: return "180 minutes"
        case .unknown: return "Unknown"
        }
    }
}

public enum ButtonAction: UInt8, Sendable {
    case alexa = 0x01
    case noiseCancellation = 0x02
    case unknown = 0xFF

    public var displayName: String {
        switch self {
        case .alexa: return "Alexa"
        case .noiseCancellation: return "Noise Cancellation"
        case .unknown: return "Unknown"
        }
    }
}
