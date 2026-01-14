import Foundation

/// Noise cancellation levels (common across brands)
public enum NoiseCancellationLevel: String, Codable, CaseIterable, Equatable {
    case off
    case low
    case medium
    case high
    case adaptive
}

/// Self-voice levels
public enum SelfVoiceLevel: String, Codable, CaseIterable, Equatable {
    case off
    case low
    case medium
    case high
}

/// Auto-off timer settings
public enum AutoOffSetting: Int, Codable, CaseIterable, Equatable {
    case never = 0
    case fiveMinutes = 5
    case twentyMinutes = 20
    case fortyMinutes = 40
    case sixtyMinutes = 60
    case oneEightyMinutes = 180
}

/// Device languages
public enum DeviceLanguage: String, Codable, CaseIterable, Equatable {
    case english
    case french
    case italian
    case german
    case spanish
    case portuguese
    case chinese
    case korean
    case polish
    case russian
    case dutch
    case japanese
    case swedish
}

/// Button action options
public enum ButtonActionSetting: String, Codable, CaseIterable, Equatable {
    case voiceAssistant
    case noiseCancellation
    case playPause
    case custom
}

/// Type of paired device (for icon selection)
public enum PairedDeviceType: String, Codable, Equatable {
    case iPhone
    case iPad
    case macBook
    case mac
    case appleWatch
    case appleTV
    case airPods
    case appleGeneric
    case windows
    case android
    case unknown
}

/// Paired device information
public struct PairedDevice: Codable, Identifiable, Equatable {
    /// MAC address
    public let id: String
    
    /// Device name
    public let name: String
    
    /// Connection status
    public let isConnected: Bool
    
    /// Whether this is the current device
    public let isCurrentDevice: Bool
    
    /// Device type for icon selection
    public let deviceType: PairedDeviceType
    
    public init(
        id: String,
        name: String,
        isConnected: Bool,
        isCurrentDevice: Bool,
        deviceType: PairedDeviceType
    ) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isCurrentDevice = isCurrentDevice
        self.deviceType = deviceType
    }
}
