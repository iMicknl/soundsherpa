import Foundation

// MARK: - BoseQC45Plugin

/// QC45 specific implementation
/// Supports: battery, noise cancellation (4 levels: off, low, medium, high), self-voice, 
/// auto-off, language, voice prompts, paired devices
///
/// **Validates: Requirements 5.1, 5.2**
public class BoseQC45Plugin: BoseQC35IIPlugin {
    
    public override var pluginId: String { "com.soundsherpa.bose.qc45" }
    public override var displayName: String { "Bose QC45" }
    
    public required init() {
        super.init()
        self.deviceModel = .qc45
        self.commandEncoder = BoseV1CommandEncoder()
    }
    
    public override func createNCConfig(for model: BoseDeviceModel) -> DeviceCapabilityConfig {
        // QC45 has 4 NC levels: off, low, medium, high
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .discrete(["off", "low", "medium", "high"]),
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
        
        // Noise Cancellation (4 levels)
        configs.append(createNCConfig(for: model))
        
        // Self Voice
        configs.append(DeviceCapabilityConfig(
            capability: .selfVoice,
            valueType: .discrete(["off", "low", "medium", "high"]),
            displayName: "Self Voice",
            isSupported: true,
            metadata: ["protocol": "v1"]
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
            metadata: ["protocol": "v1"]
        ))
        
        // QC45 does NOT support button action (unlike QC35 II)
        
        return configs
    }
    
    // QC45 does not support button action
    public override func getButtonAction() async throws -> ButtonActionSetting {
        throw DeviceError.unsupportedCommand
    }
    
    public override func setButtonAction(_ action: ButtonActionSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
}
