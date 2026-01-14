import Foundation

// MARK: - BoseQC35Plugin

/// QC35 specific implementation
/// Supports: battery, noise cancellation (3 levels: off, low, high), auto-off, language, voice prompts
///
/// **Validates: Requirements 5.1, 5.2**
public class BoseQC35Plugin: BosePlugin {
    
    public override var pluginId: String { "com.soundsherpa.bose.qc35" }
    public override var displayName: String { "Bose QC35" }
    
    public required init() {
        super.init()
        self.deviceModel = .qc35
        self.commandEncoder = BoseV1CommandEncoder()
    }
    
    public override func createNCConfig(for model: BoseDeviceModel) -> DeviceCapabilityConfig {
        // QC35 only has 3 NC levels: off, low, high
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .discrete(["off", "low", "high"]),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "v1", "maxLevel": "high"]
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
        
        // Noise Cancellation (3 levels)
        configs.append(createNCConfig(for: model))
        
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
        
        // QC35 does NOT support self-voice, paired devices, or button action
        
        return configs
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
    
    // MARK: - Response Parsing
    
    internal func parseAutoOffResponse(_ data: Data) -> AutoOffSetting {
        guard data.count >= 4 else { return .never }
        
        let settingByte = data[3]
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
        guard data.count >= 4 else { return .english }
        
        let languageByte = data[3]
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
        guard data.count >= 5 else { return true }
        return data[4] != 0x00
    }
}
