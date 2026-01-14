import Foundation

// MARK: - SonyWF1000XM5Plugin

/// WF-1000XM5 (earbuds) specific implementation with all advanced features
/// Supports: battery, noise cancellation (0-20), ambient sound (0-20), auto-off,
/// equalizer presets, voice prompts, multipoint, speak-to-chat
///
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
public class SonyWF1000XM5Plugin: SonyWF1000XM4Plugin {
    
    public override var pluginId: String { "com.soundsherpa.sony.wf1000xm5" }
    public override var displayName: String { "Sony WF-1000XM5" }
    
    private let xm5ResponseDecoder = SonyResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .wf1000xm5
        self.commandEncoder = SonyV2CommandEncoder()
    }
    
    public override func createCapabilityConfigs(for model: SonyDeviceModel) -> [DeviceCapabilityConfig] {
        var configs: [DeviceCapabilityConfig] = []
        
        // Battery (earbuds have left/right/case battery)
        configs.append(DeviceCapabilityConfig(
            capability: .battery,
            valueType: .continuous(min: 0, max: 100, step: 1),
            displayName: "Battery Level",
            isSupported: true,
            metadata: ["formFactor": "earbuds", "hasCaseBattery": "true"]
        ))
        
        // Noise Cancellation (continuous 0-20)
        configs.append(DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "sony-v2", "range": "0-20", "formFactor": "earbuds"]
        ))
        
        // Ambient Sound (continuous 0-20)
        configs.append(DeviceCapabilityConfig(
            capability: .ambientSound,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Ambient Sound",
            isSupported: true,
            metadata: ["protocol": "sony-v2", "range": "0-20"]
        ))
        
        // Auto-off (XM5 adds this)
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
        
        // Voice Prompts (XM5 adds this)
        configs.append(DeviceCapabilityConfig(
            capability: .voicePrompts,
            valueType: .boolean,
            displayName: "Voice Guidance",
            isSupported: true,
            metadata: [:]
        ))
        
        return configs
    }
    
    // MARK: - Auto-Off (XM5 specific)
    
    public override func getAutoOff() async throws -> AutoOffSetting {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeAutoOffQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return xm5ResponseDecoder.decodeAutoOff(response)
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
    
    // MARK: - Voice Prompts (XM5 specific)
    
    public override func getVoicePromptsEnabled() async throws -> Bool {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeVoiceGuidanceQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return xm5ResponseDecoder.decodeVoiceGuidance(response)
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
    
    // MARK: - Multipoint (XM5 specific)
    
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
        
        return xm5ResponseDecoder.decodeMultipointStatus(response)
    }
    
    // MARK: - Device Info (XM5 specific)
    
    public override func getDeviceInfo() async throws -> [String: Any] {
        var info = try await super.getDeviceInfo()
        
        // WF-1000XM5 specific info
        info["generation"] = "XM5"
        info["formFactor"] = "earbuds"
        info["supportsMultipoint"] = true
        info["multipoint"] = try await getMultipointStatus()
        
        return info
    }
}
