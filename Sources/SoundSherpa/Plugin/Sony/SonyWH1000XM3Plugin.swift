import Foundation

// MARK: - SonyWH1000XM3Plugin

/// WH-1000XM3 specific implementation (V1 protocol)
/// Supports: battery, noise cancellation (0-20), ambient sound (0-20), equalizer presets
///
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
public class SonyWH1000XM3Plugin: SonyPlugin {
    
    public override var pluginId: String { "com.soundsherpa.sony.wh1000xm3" }
    public override var displayName: String { "Sony WH-1000XM3" }
    
    private let responseDecoder = SonyResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .wh1000xm3
        self.commandEncoder = SonyV1CommandEncoder()
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
            metadata: ["protocol": "sony-v1", "range": "0-20"]
        ))
        
        // Ambient Sound (continuous 0-20)
        configs.append(DeviceCapabilityConfig(
            capability: .ambientSound,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Ambient Sound",
            isSupported: true,
            metadata: ["protocol": "sony-v1", "range": "0-20"]
        ))
        
        // Equalizer Presets
        configs.append(DeviceCapabilityConfig(
            capability: .equalizerPresets,
            valueType: .discrete(["off", "bright", "excited", "mellow", "relaxed", "vocal", "treble", "bass", "speech", "custom"]),
            displayName: "Equalizer",
            isSupported: true,
            metadata: [:]
        ))
        
        return configs
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
    
    // MARK: - Device Info
    
    public override func getDeviceInfo() async throws -> [String: Any] {
        var info = try await super.getDeviceInfo()
        
        // XM3 specific info
        info["generation"] = "XM3"
        info["supportsMultipoint"] = false
        info["supportsSpeakToChat"] = false
        
        return info
    }
}
