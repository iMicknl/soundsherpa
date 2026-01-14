import Foundation

// MARK: - SonyWH1000XM4Plugin

/// WH-1000XM4 specific implementation with multipoint and speak-to-chat
/// Supports: battery, noise cancellation (0-20), ambient sound (0-20), auto-off,
/// equalizer presets, voice prompts, multipoint, speak-to-chat
///
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
public class SonyWH1000XM4Plugin: SonyPlugin {
    
    public override var pluginId: String { "com.soundsherpa.sony.wh1000xm4" }
    public override var displayName: String { "Sony WH-1000XM4" }
    
    private let responseDecoder = SonyResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .wh1000xm4
        self.commandEncoder = SonyV2CommandEncoder()
    }
    
    public override func createCapabilityConfigs(for model: SonyDeviceModel) -> [DeviceCapabilityConfig] {
        var configs: [DeviceCapabilityConfig] = []
        
        // Battery
        configs.append(DeviceCapabilityConfig(
            capability: .battery,
            valueType: .continuous(min: 0, max: 100, step: 1),
            displayName: "Battery Level",
            isSupported: true,
            metadata: [:]
        ))
        
        // Noise Cancellation (continuous 0-20)
        configs.append(DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "sony-v2", "range": "0-20"]
        ))
        
        // Ambient Sound (continuous 0-20)
        configs.append(DeviceCapabilityConfig(
            capability: .ambientSound,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Ambient Sound",
            isSupported: true,
            metadata: ["protocol": "sony-v2", "range": "0-20"]
        ))
        
        // Auto-off
        configs.append(DeviceCapabilityConfig(
            capability: .autoOff,
            valueType: .discrete(["never", "5", "20", "40", "60", "180"]),
            displayName: "Auto-Off Timer",
            isSupported: true,
            metadata: [:]
        ))
        
        // Equalizer Presets
        configs.append(DeviceCapabilityConfig(
            capability: .equalizerPresets,
            valueType: .discrete(["off", "bright", "excited", "mellow", "relaxed", "vocal", "treble", "bass", "speech", "custom"]),
            displayName: "Equalizer",
            isSupported: true,
            metadata: [:]
        ))
        
        // Voice Prompts
        configs.append(DeviceCapabilityConfig(
            capability: .voicePrompts,
            valueType: .boolean,
            displayName: "Voice Guidance",
            isSupported: true,
            metadata: [:]
        ))
        
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
        
        let command = encoder.encodeAutoOffQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodeAutoOff(response)
    }
    
    public override func setAutoOff(_ setting: AutoOffSetting) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeAutoOffCommand(setting: setting, sequenceNumber: nextSequenceNumber())
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
        
        let command = encoder.encodeVoiceGuidanceQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodeVoiceGuidance(response)
    }
    
    public override func setVoicePromptsEnabled(_ enabled: Bool) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeVoiceGuidanceCommand(enabled: enabled, sequenceNumber: nextSequenceNumber())
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Equalizer
    
    public override func getEqualizerPreset() async throws -> String {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeEqualizerQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodeEqualizerPreset(response)
    }
    
    public override func setEqualizerPreset(_ preset: String) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeEqualizerCommand(preset: preset, sequenceNumber: nextSequenceNumber())
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Device Info (XM4 specific)
    
    public override func getDeviceInfo() async throws -> [String: Any] {
        var info = try await super.getDeviceInfo()
        
        // XM4 specific info
        info["generation"] = "XM4"
        info["multipoint"] = try await getMultipointStatus()
        info["speakToChat"] = try await getSpeakToChatStatus()
        
        return info
    }
    
    /// Get multipoint connection status
    public func getMultipointStatus() async throws -> Bool {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder as? SonyV2CommandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeMultipointQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodeMultipointStatus(response)
    }
    
    /// Get speak-to-chat status
    public func getSpeakToChatStatus() async throws -> Bool {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder as? SonyV2CommandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeSpeakToChatQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return responseDecoder.decodeSpeakToChatStatus(response)
    }
    
    /// Set speak-to-chat enabled
    public func setSpeakToChat(_ enabled: Bool) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder as? SonyV2CommandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeSpeakToChatCommand(enabled: enabled, sequenceNumber: nextSequenceNumber())
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
}
