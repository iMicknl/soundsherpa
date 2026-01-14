import Foundation

// MARK: - BoseNC700Plugin

/// NC 700 specific implementation with V2 protocol
/// Supports: battery, noise cancellation (4 levels), self-voice, auto-off, 
/// language, voice prompts, paired devices, equalizer presets
///
/// **Validates: Requirements 5.1, 5.2**
public class BoseNC700Plugin: BosePlugin {
    
    public override var pluginId: String { "com.soundsherpa.bose.nc700" }
    public override var displayName: String { "Bose NC 700" }
    
    private let responseDecoder = BoseResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .nc700
        self.commandEncoder = BoseV2CommandEncoder()
    }
    
    public override func createNCConfig(for model: BoseDeviceModel) -> DeviceCapabilityConfig {
        // NC 700 has 4 NC levels: off, low, medium, high
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .discrete(["off", "low", "medium", "high"]),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "v2", "maxLevel": "high"]
        )
    }
    
    public override func createCapabilityConfigs(for model: BoseDeviceModel) -> [DeviceCapabilityConfig] {
        var configs: [DeviceCapabilityConfig] = []
        
        // Battery
        configs.append(DeviceCapabilityConfig(
            capability: .battery,
            valueType: .continuous(min: 0, max: 100, step: 1),
            displayName: "Battery Level",
            isSupported: true,
            metadata: [:]
        ))
        
        // Noise Cancellation (4 levels)
        configs.append(createNCConfig(for: model))
        
        // Self Voice
        configs.append(DeviceCapabilityConfig(
            capability: .selfVoice,
            valueType: .discrete(["off", "low", "medium", "high"]),
            displayName: "Self Voice",
            isSupported: true,
            metadata: ["protocol": "v2"]
        ))
        
        // Auto-off
        configs.append(DeviceCapabilityConfig(
            capability: .autoOff,
            valueType: .discrete(["never", "5", "20", "40", "60", "180"]),
            displayName: "Auto-Off Timer",
            isSupported: true,
            metadata: [:]
        ))
        
        // Language
        configs.append(DeviceCapabilityConfig(
            capability: .language,
            valueType: .text,
            displayName: "Language",
            isSupported: true,
            metadata: [:]
        ))
        
        // Voice Prompts
        configs.append(DeviceCapabilityConfig(
            capability: .voicePrompts,
            valueType: .boolean,
            displayName: "Voice Prompts",
            isSupported: true,
            metadata: [:]
        ))
        
        // Paired Devices
        configs.append(DeviceCapabilityConfig(
            capability: .pairedDevices,
            valueType: .text,
            displayName: "Paired Devices",
            isSupported: true,
            metadata: ["protocol": "v2"]
        ))
        
        // Equalizer Presets (NC 700 specific)
        configs.append(DeviceCapabilityConfig(
            capability: .equalizerPresets,
            valueType: .discrete(["flat", "bass", "treble", "vocal"]),
            displayName: "Equalizer",
            isSupported: true,
            metadata: ["protocol": "v2"]
        ))
        
        return configs
    }
    
    // MARK: - Self Voice
    
    public override func getSelfVoice() async throws -> Any {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeSelfVoiceQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseSelfVoiceResponse(response)
    }
    
    public override func setSelfVoice(_ value: Any) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let level: SelfVoiceLevel
        if let svLevel = value as? SelfVoiceLevel {
            level = svLevel
        } else if let stringValue = value as? String,
                  let svLevel = SelfVoiceLevel(rawValue: stringValue) {
            level = svLevel
        } else {
            throw DeviceError.invalidResponse
        }
        
        let command = encoder.encodeSelfVoiceCommand(level: level)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Auto-Off
    
    public override func getAutoOff() async throws -> AutoOffSetting {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeAutoOffQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseAutoOffResponse(response)
    }
    
    public override func setAutoOff(_ setting: AutoOffSetting) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeAutoOffCommand(setting: setting)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Language
    
    public override func getLanguage() async throws -> DeviceLanguage {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeLanguageQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseLanguageResponse(response)
    }
    
    public override func setLanguage(_ language: DeviceLanguage) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let voicePromptsEnabled = try await getVoicePromptsEnabled()
        let command = encoder.encodeLanguageCommand(language: language, voicePromptsEnabled: voicePromptsEnabled)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Voice Prompts
    
    public override func getVoicePromptsEnabled() async throws -> Bool {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeLanguageQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseVoicePromptsResponse(response)
    }
    
    public override func setVoicePromptsEnabled(_ enabled: Bool) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let language = try await getLanguage()
        let command = encoder.encodeLanguageCommand(language: language, voicePromptsEnabled: enabled)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Paired Devices
    
    public override func getPairedDevices() async throws -> [PairedDevice] {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodePairedDevicesQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodePairedDevices(response)
    }
    
    // MARK: - Equalizer
    
    public override func getEqualizerPreset() async throws -> String {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // NC 700 specific equalizer query
        let command = Data([0x04, 0x01, 0x01])  // Audio management, EQ, get
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseEqualizerResponse(response)
    }
    
    public override func setEqualizerPreset(_ preset: String) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        let presetByte: UInt8
        switch preset.lowercased() {
        case "flat": presetByte = 0x00
        case "bass": presetByte = 0x01
        case "treble": presetByte = 0x02
        case "vocal": presetByte = 0x03
        default: throw DeviceError.invalidResponse
        }
        
        let command = Data([0x04, 0x01, 0x02, 0x01, presetByte])
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Response Parsing (V2 protocol - skip length byte)
    
    internal func parseSelfVoiceResponse(_ data: Data) -> SelfVoiceLevel {
        // V2 response: [length, functionBlock, function, operator, level]
        guard data.count >= 5 else { return .off }
        
        let levelByte = data[4]
        switch levelByte {
        case 0x00: return .off
        case 0x01: return .low
        case 0x02: return .medium
        case 0x03: return .high
        default: return .off
        }
    }
    
    internal func parseAutoOffResponse(_ data: Data) -> AutoOffSetting {
        guard data.count >= 5 else { return .never }
        
        let settingByte = data[4]
        switch settingByte {
        case 0x00: return .never
        case 0x05: return .fiveMinutes
        case 0x14: return .twentyMinutes
        case 0x28: return .fortyMinutes
        case 0x3C: return .sixtyMinutes
        case 0xB4: return .oneEightyMinutes
        default: return .never
        }
    }
    
    internal func parseLanguageResponse(_ data: Data) -> DeviceLanguage {
        guard data.count >= 5 else { return .english }
        
        let languageByte = data[4]
        switch languageByte {
        case 0x00: return .english
        case 0x01: return .french
        case 0x02: return .italian
        case 0x03: return .german
        case 0x04: return .spanish
        case 0x05: return .portuguese
        case 0x06: return .chinese
        case 0x07: return .korean
        case 0x08: return .polish
        case 0x09: return .russian
        case 0x0A: return .dutch
        case 0x0B: return .japanese
        case 0x0C: return .swedish
        default: return .english
        }
    }
    
    internal func parseVoicePromptsResponse(_ data: Data) -> Bool {
        guard data.count >= 6 else { return true }
        return data[5] != 0x00
    }
    
    internal func parseEqualizerResponse(_ data: Data) -> String {
        guard data.count >= 5 else { return "flat" }
        
        let presetByte = data[4]
        switch presetByte {
        case 0x00: return "flat"
        case 0x01: return "bass"
        case 0x02: return "treble"
        case 0x03: return "vocal"
        default: return "flat"
        }
    }
}
