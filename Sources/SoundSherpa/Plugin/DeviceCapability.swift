import Foundation

/// Represents a capability that a device may support
public enum DeviceCapability: String, CaseIterable, Codable, Equatable, Hashable {
    case battery
    case noiseCancellation
    case selfVoice
    case autoOff
    case voicePrompts
    case language
    case pairedDevices
    case buttonAction
    case ambientSound
    case equalizerPresets
    
    /// Default display name for this capability
    public var defaultDisplayName: String {
        switch self {
        case .battery: return "Battery Level"
        case .noiseCancellation: return "Noise Cancellation"
        case .selfVoice: return "Self Voice"
        case .autoOff: return "Auto-Off Timer"
        case .voicePrompts: return "Voice Prompts"
        case .language: return "Language"
        case .pairedDevices: return "Paired Devices"
        case .buttonAction: return "Button Action"
        case .ambientSound: return "Ambient Sound"
        case .equalizerPresets: return "Equalizer"
        }
    }
    
    /// System icon name for this capability
    public var iconName: String {
        switch self {
        case .battery: return "battery.100"
        case .noiseCancellation: return "speaker.wave.3"
        case .selfVoice: return "person.wave.2"
        case .autoOff: return "timer"
        case .voicePrompts: return "speaker.badge.exclamationmark"
        case .language: return "globe"
        case .pairedDevices: return "link"
        case .buttonAction: return "button.programmable"
        case .ambientSound: return "ear"
        case .equalizerPresets: return "slider.horizontal.3"
        }
    }
    
    /// Whether this capability should be shown in the main menu (vs submenu)
    public var isMainMenuCapability: Bool {
        switch self {
        case .battery, .noiseCancellation, .selfVoice, .ambientSound, .pairedDevices:
            return true
        case .autoOff, .voicePrompts, .language, .buttonAction, .equalizerPresets:
            return false
        }
    }
}

/// Represents different types of capability values to handle device-specific variations
public enum CapabilityValueType: Codable, Equatable {
    case discrete([String])                           // e.g., ["off", "low", "high"]
    case continuous(min: Int, max: Int, step: Int)    // e.g., 0-10 with step 1
    case boolean                                       // e.g., on/off
    case text                                          // e.g., language codes
    
    // Custom Codable implementation for associated values
    private enum CodingKeys: String, CodingKey {
        case type, values, min, max, step
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "discrete":
            let values = try container.decode([String].self, forKey: .values)
            self = .discrete(values)
        case "continuous":
            let min = try container.decode(Int.self, forKey: .min)
            let max = try container.decode(Int.self, forKey: .max)
            let step = try container.decode(Int.self, forKey: .step)
            self = .continuous(min: min, max: max, step: step)
        case "boolean":
            self = .boolean
        case "text":
            self = .text
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .discrete(let values):
            try container.encode("discrete", forKey: .type)
            try container.encode(values, forKey: .values)
        case .continuous(let min, let max, let step):
            try container.encode("continuous", forKey: .type)
            try container.encode(min, forKey: .min)
            try container.encode(max, forKey: .max)
            try container.encode(step, forKey: .step)
        case .boolean:
            try container.encode("boolean", forKey: .type)
        case .text:
            try container.encode("text", forKey: .type)
        }
    }
    
    /// Returns the type name as a string
    public var typeName: String {
        switch self {
        case .discrete: return "discrete"
        case .continuous: return "continuous"
        case .boolean: return "boolean"
        case .text: return "text"
        }
    }
    
    /// Returns the possible values for discrete types, or nil for other types
    public var discreteValues: [String]? {
        if case .discrete(let values) = self {
            return values
        }
        return nil
    }
    
    /// Returns the range for continuous types, or nil for other types
    public var continuousRange: (min: Int, max: Int, step: Int)? {
        if case .continuous(let min, let max, let step) = self {
            return (min, max, step)
        }
        return nil
    }
    
    /// Validates if a value is valid for this type
    public func isValidValue(_ value: Any) -> Bool {
        switch self {
        case .discrete(let values):
            guard let stringValue = value as? String else { return false }
            return values.contains(stringValue)
        case .continuous(let min, let max, _):
            guard let intValue = value as? Int else { return false }
            return intValue >= min && intValue <= max
        case .boolean:
            return value is Bool
        case .text:
            return value is String
        }
    }
}

/// Device-specific capability configuration
public struct DeviceCapabilityConfig: Codable, Equatable, Hashable {
    public let capability: DeviceCapability
    public let valueType: CapabilityValueType
    public let displayName: String
    public let isSupported: Bool
    
    /// Device-specific metadata for this capability
    public let metadata: [String: String]
    
    public init(
        capability: DeviceCapability,
        valueType: CapabilityValueType,
        displayName: String,
        isSupported: Bool,
        metadata: [String: String] = [:]
    ) {
        self.capability = capability
        self.valueType = valueType
        self.displayName = displayName
        self.isSupported = isSupported
        self.metadata = metadata
    }
    
    /// Returns the icon name for this capability
    public var iconName: String {
        capability.iconName
    }
    
    /// Whether this capability should appear in the main menu
    public var isMainMenuCapability: Bool {
        capability.isMainMenuCapability
    }
    
    /// Creates a default configuration for a capability
    public static func defaultConfig(for capability: DeviceCapability) -> DeviceCapabilityConfig {
        let valueType: CapabilityValueType
        switch capability {
        case .battery:
            valueType = .continuous(min: 0, max: 100, step: 1)
        case .noiseCancellation:
            valueType = .discrete(["off", "low", "high"])
        case .selfVoice:
            valueType = .discrete(["off", "low", "medium", "high"])
        case .autoOff:
            valueType = .discrete(["never", "5", "20", "40", "60", "180"])
        case .voicePrompts:
            valueType = .boolean
        case .language:
            valueType = .text
        case .pairedDevices:
            valueType = .text
        case .buttonAction:
            valueType = .discrete(["voiceAssistant", "noiseCancellation"])
        case .ambientSound:
            valueType = .continuous(min: 0, max: 20, step: 1)
        case .equalizerPresets:
            valueType = .discrete(["flat", "bass", "treble", "vocal"])
        }
        
        return DeviceCapabilityConfig(
            capability: capability,
            valueType: valueType,
            displayName: capability.defaultDisplayName,
            isSupported: true
        )
    }
    
    // MARK: - Hashable conformance
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(capability)
        hasher.combine(displayName)
        hasher.combine(isSupported)
    }
}

/// A set of capability configurations for a device
public struct DeviceCapabilitySet: Equatable {
    private var configs: [DeviceCapability: DeviceCapabilityConfig]
    
    public init(configs: [DeviceCapabilityConfig] = []) {
        self.configs = [:]
        for config in configs {
            self.configs[config.capability] = config
        }
    }
    
    /// Returns all supported capabilities
    public var supportedCapabilities: Set<DeviceCapability> {
        Set(configs.filter { $0.value.isSupported }.keys)
    }
    
    /// Returns all capability configs
    public var allConfigs: [DeviceCapabilityConfig] {
        Array(configs.values)
    }
    
    /// Returns configs for main menu capabilities only
    public var mainMenuConfigs: [DeviceCapabilityConfig] {
        configs.values.filter { $0.isMainMenuCapability && $0.isSupported }
    }
    
    /// Returns configs for submenu capabilities only
    public var submenuConfigs: [DeviceCapabilityConfig] {
        configs.values.filter { !$0.isMainMenuCapability && $0.isSupported }
    }
    
    /// Gets the config for a specific capability
    public func config(for capability: DeviceCapability) -> DeviceCapabilityConfig? {
        configs[capability]
    }
    
    /// Checks if a capability is supported
    public func isSupported(_ capability: DeviceCapability) -> Bool {
        configs[capability]?.isSupported ?? false
    }
    
    /// Adds or updates a capability config
    public mutating func setConfig(_ config: DeviceCapabilityConfig) {
        configs[config.capability] = config
    }
}
