import Foundation

// MARK: - BoseQCUltraPlugin

/// QC Ultra specific implementation with advanced features and V2 protocol
/// Supports: battery, noise cancellation (5 levels including adaptive), self-voice, 
/// ambient sound, auto-off, language, voice prompts, paired devices
///
/// **Validates: Requirements 5.1, 5.2**
public class BoseQCUltraPlugin: BosePlugin {
    
    public override var pluginId: String { "com.soundsherpa.bose.qcultra" }
    public override var displayName: String { "Bose QC Ultra" }
    
    private let responseDecoder = BoseResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .qcUltra
        self.commandEncoder = BoseV2CommandEncoder()
    }
    
    public override func createNCConfig(for model: BoseDeviceModel) -> DeviceCapabilityConfig {
        // QC Ultra has 5 NC levels including adaptive
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .discrete(["off", "low", "medium", "high", "adaptive"]),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "v2", "supportsAdaptive": "true"]
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
        
        // Noise Cancellation (5 levels including adaptive)
        configs.append(createNCConfig(for: model))
        
        // Self Voice
        configs.append(DeviceCapabilityConfig(
            capability: .selfVoice,
            valueType: .discrete(["off", "low", "medium", "high"]),
            displayName: "Self Voice",
            isSupported: true,
            metadata: ["protocol": "v2"]
        ))
        
        // Ambient Sound (QC Ultra specific)
        configs.append(DeviceCapabilityConfig(
            capability: .ambientSound,
            valueType: .continuous(min: 0, max: 10, step: 1),
            displayName: "Ambient Sound",
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
        
        return configs
    }
    
    // MARK: - Device Info (QC Ultra specific)
    
    public override func getDeviceInfo() async throws -> [String: Any] {
        var info = try await super.getDeviceInfo()
        
        // QC Ultra specific additional info
        info["adaptiveNCSupported"] = true
        info["ambientSoundSupported"] = true
        info["firmwareVersion"] = try await getFirmwareVersion()
        info["serialNumber"] = try await getSerialNumber()
        
        return info
    }
    
    /// Get firmware version (QC Ultra specific)
    private func getFirmwareVersion() async throws -> String {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // QC Ultra firmware query command
        let command = Data([
            0x00,  // Product info function block
            0x01,  // Firmware function
            0x01   // Get operator
        ])
        
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        return parseFirmwareResponse(response)
    }
    
    /// Get serial number (QC Ultra specific)
    private func getSerialNumber() async throws -> String {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // QC Ultra serial number query command
        let command = Data([
            0x00,  // Product info function block
            0x02,  // Serial number function
            0x01   // Get operator
        ])
        
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        return parseSerialNumberResponse(response)
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
    
    // MARK: - Ambient Sound (QC Ultra specific)
    
    public override func getAmbientSound() async throws -> Int {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // QC Ultra ambient sound query
        let command = Data([
            0x01,  // Settings function block
            0x09,  // Ambient sound function
            0x01   // Get operator
        ])
        
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        return parseAmbientSoundResponse(response)
    }
    
    public override func setAmbientSound(_ level: Int) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // Validate level is in range
        guard level >= 0 && level <= 10 else {
            throw DeviceError.invalidResponse
        }
        
        // QC Ultra ambient sound set command
        let command = Data([
            0x01,  // Settings function block
            0x09,  // Ambient sound function
            0x02,  // Set operator
            0x01,  // Length
            UInt8(level)
        ])
        
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
    
    // MARK: - Response Parsing (V2 protocol)
    
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
    
    internal func parseAmbientSoundResponse(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        return Int(data[3])
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
    
    internal func parseFirmwareResponse(_ data: Data) -> String {
        guard data.count >= 6 else { return "Unknown" }
        
        // Firmware version is typically in format: major.minor.patch
        let major = data[3]
        let minor = data[4]
        let patch = data[5]
        
        return "\(major).\(minor).\(patch)"
    }
    
    internal func parseSerialNumberResponse(_ data: Data) -> String {
        guard data.count > 3 else { return "Unknown" }
        
        // Serial number is a string starting at byte 3
        let serialData = data.subdata(in: 3..<data.count)
        return String(data: serialData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "Unknown"
    }
}
