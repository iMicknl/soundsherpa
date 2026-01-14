import Foundation

// MARK: - SonyWF1000XM4Plugin

/// WF-1000XM4 (earbuds) specific implementation
/// Supports: battery, noise cancellation (0-20), ambient sound (0-20), equalizer presets
///
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
public class SonyWF1000XM4Plugin: SonyPlugin {
    
    public override var pluginId: String { "com.soundsherpa.sony.wf1000xm4" }
    public override var displayName: String { "Sony WF-1000XM4" }
    
    private let responseDecoder = SonyResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .wf1000xm4
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
    
    // MARK: - Battery (Earbuds specific - left/right/case)
    
    public override func getBatteryLevel() async throws -> Int {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeBatteryQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        // For earbuds, return the average of left and right
        return parseEarbudsBatteryResponse(response)
    }
    
    /// Get detailed battery info for earbuds (left, right, case)
    public func getDetailedBatteryInfo() async throws -> (left: Int, right: Int, case_: Int?) {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeBatteryQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseDetailedBatteryResponse(response)
    }
    
    private func parseEarbudsBatteryResponse(_ data: Data) -> Int {
        let detailed = parseDetailedBatteryResponse(data)
        // Return average of left and right
        return (detailed.left + detailed.right) / 2
    }
    
    private func parseDetailedBatteryResponse(_ data: Data) -> (left: Int, right: Int, case_: Int?) {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 5 else {
            return (0, 0, nil)
        }
        
        // Earbuds battery format: [category, subCmd, leftBattery, rightBattery, caseBattery?]
        let left = Int(command.payload[2])
        let right = Int(command.payload[3])
        let case_ = command.payload.count > 4 ? Int(command.payload[4]) : nil
        
        return (left, right, case_)
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
        
        // WF-1000XM4 specific info
        info["generation"] = "XM4"
        info["formFactor"] = "earbuds"
        info["supportsMultipoint"] = false
        info["supportsSpeakToChat"] = true
        
        // Get detailed battery info
        let batteryInfo = try await getDetailedBatteryInfo()
        info["leftBattery"] = batteryInfo.left
        info["rightBattery"] = batteryInfo.right
        if let caseBattery = batteryInfo.case_ {
            info["caseBattery"] = caseBattery
        }
        
        return info
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
