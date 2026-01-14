import Foundation

// MARK: - BoseQC35IIPlugin

/// QC35 II specific implementation with additional capabilities
/// Supports: battery, noise cancellation (3 levels), self-voice, auto-off, language, 
/// voice prompts, paired devices, button action
///
/// **Validates: Requirements 5.1, 5.2, 5.3, 5.7**
public class BoseQC35IIPlugin: BoseQC35Plugin {
    
    public override var pluginId: String { "com.soundsherpa.bose.qc35ii" }
    public override var displayName: String { "Bose QC35 II" }
    
    private let responseDecoder = BoseResponseDecoder()
    
    public required init() {
        super.init()
        self.deviceModel = .qc35ii
        self.commandEncoder = BoseV1CommandEncoder()
    }
    
    public override func createCapabilityConfigs(for model: BoseDeviceModel) -> [DeviceCapabilityConfig] {
        var configs = super.createCapabilityConfigs(for: model)
        
        // Add self-voice support (QC35 II specific)
        configs.append(DeviceCapabilityConfig(
            capability: .selfVoice,
            valueType: .discrete(["off", "low", "medium", "high"]),
            displayName: "Self Voice",
            isSupported: true,
            metadata: ["protocol": "v1"]
        ))
        
        // Add paired devices support
        configs.append(DeviceCapabilityConfig(
            capability: .pairedDevices,
            valueType: .text,
            displayName: "Paired Devices",
            isSupported: true,
            metadata: ["protocol": "v1"]
        ))
        
        // Add button action support (Alexa or NC toggle)
        configs.append(DeviceCapabilityConfig(
            capability: .buttonAction,
            valueType: .discrete(["voiceAssistant", "noiseCancellation"]),
            displayName: "Button Action",
            isSupported: true,
            metadata: ["protocol": "v1", "options": "alexa,nc"]
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
    
    public override func connectPairedDevice(address: String) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // Encode connect command with MAC address
        let macBytes = parseMACAddress(address)
        var command = Data([
            BoseConstants.FunctionBlock.deviceManagement,
            BoseConstants.Function.pairedDevices,
            BoseConstants.Operator.set,
            0x07,  // Length: 6 bytes MAC + 1 byte action
            0x01   // Action: connect
        ])
        command.append(contentsOf: macBytes)
        
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 10.0)
    }
    
    public override func disconnectPairedDevice(address: String) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // Encode disconnect command with MAC address
        let macBytes = parseMACAddress(address)
        var command = Data([
            BoseConstants.FunctionBlock.deviceManagement,
            BoseConstants.Function.pairedDevices,
            BoseConstants.Operator.set,
            0x07,  // Length: 6 bytes MAC + 1 byte action
            0x00   // Action: disconnect
        ])
        command.append(contentsOf: macBytes)
        
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 10.0)
    }
    
    // MARK: - Button Action
    
    public override func getButtonAction() async throws -> ButtonActionSetting {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeButtonActionQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseButtonActionResponse(response)
    }
    
    public override func setButtonAction(_ action: ButtonActionSetting) async throws {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        // QC35 II only supports voiceAssistant and noiseCancellation
        guard action == .voiceAssistant || action == .noiseCancellation else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeButtonActionCommand(action: action)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Response Parsing
    
    internal func parseSelfVoiceResponse(_ data: Data) -> SelfVoiceLevel {
        guard data.count >= 4 else { return .off }
        
        let levelByte = data[3]
        switch levelByte {
        case 0x00: return .off
        case 0x01: return .low
        case 0x02: return .medium
        case 0x03: return .high
        default: return .off
        }
    }
    
    internal func parseButtonActionResponse(_ data: Data) -> ButtonActionSetting {
        guard data.count >= 4 else { return .voiceAssistant }
        
        let actionByte = data[3]
        switch actionByte {
        case 0x00: return .voiceAssistant
        case 0x01: return .noiseCancellation
        default: return .voiceAssistant
        }
    }
    
    /// Parse MAC address string to bytes
    private func parseMACAddress(_ address: String) -> [UInt8] {
        let components = address.split(separator: ":")
        guard components.count == 6 else { return [0, 0, 0, 0, 0, 0] }
        
        return components.compactMap { UInt8($0, radix: 16) }
    }
}
