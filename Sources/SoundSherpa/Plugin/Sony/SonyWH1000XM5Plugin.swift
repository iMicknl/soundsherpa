import Foundation

// MARK: - SonyWH1000XM5Plugin

/// WH-1000XM5 specific implementation with all advanced features
/// Supports: battery, noise cancellation (0-20), ambient sound (0-20), auto-off,
/// equalizer presets, voice prompts, paired devices, multipoint, speak-to-chat
///
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
public class SonyWH1000XM5Plugin: SonyWH1000XM4Plugin {
    
    public override var pluginId: String { "com.soundsherpa.sony.wh1000xm5" }
    public override var displayName: String { "Sony WH-1000XM5" }
    
    public required init() {
        super.init()
        self.deviceModel = .wh1000xm5
        self.commandEncoder = SonyV2CommandEncoder()
    }
    
    public override func createCapabilityConfigs(for model: SonyDeviceModel) -> [DeviceCapabilityConfig] {
        var configs = super.createCapabilityConfigs(for: model)
        
        // XM5 adds paired devices support
        configs.append(DeviceCapabilityConfig(
            capability: .pairedDevices,
            valueType: .text,
            displayName: "Paired Devices",
            isSupported: true,
            metadata: ["protocol": "sony-v2"]
        ))
        
        return configs
    }
    
    // MARK: - Paired Devices (XM5 specific)
    
    public override func getPairedDevices() async throws -> [PairedDevice] {
        guard isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        // Sony paired devices query command
        let command = buildPairedDevicesQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parsePairedDevicesResponse(response)
    }
    
    private func buildPairedDevicesQuery() -> Data {
        let payload = Data([
            SonyConstants.CommandCategory.multipoint,
            SonyConstants.SubCommand.get,
            0x00,  // Feature flags
            0x01   // Request paired devices list
        ])
        
        let command = SonyCommand(
            dataType: SonyConstants.DataType.command,
            sequenceNumber: nextSequenceNumber(),
            payload: payload
        )
        return command.encode()
    }
    
    private func parsePairedDevicesResponse(_ data: Data) -> [PairedDevice] {
        var devices: [PairedDevice] = []
        
        guard let command = SonyCommand.decode(data),
              command.payload.count > 4 else {
            return devices
        }
        
        // Parse device entries from payload
        var offset = 3  // Skip category, subCommand, flags
        let deviceCount = Int(command.payload[offset])
        offset += 1
        
        for _ in 0..<deviceCount {
            guard offset + 7 <= command.payload.count else { break }
            
            // Read MAC address (6 bytes)
            let macBytes = command.payload.subdata(in: offset..<(offset + 6))
            let macAddress = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            offset += 6
            
            // Read status byte
            let statusByte = command.payload[offset]
            offset += 1
            
            // Read name length and name
            guard offset < command.payload.count else { break }
            let nameLength = Int(command.payload[offset])
            offset += 1
            
            guard offset + nameLength <= command.payload.count else { break }
            let nameData = command.payload.subdata(in: offset..<(offset + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? "Unknown Device"
            offset += nameLength
            
            let isConnected = (statusByte & 0x01) != 0
            let isCurrentDevice = (statusByte & 0x02) != 0
            let deviceType = detectDeviceType(from: name)
            
            devices.append(PairedDevice(
                id: macAddress,
                name: name,
                isConnected: isConnected,
                isCurrentDevice: isCurrentDevice,
                deviceType: deviceType
            ))
        }
        
        return devices
    }
    
    private func detectDeviceType(from name: String) -> PairedDeviceType {
        let lowercaseName = name.lowercased()
        
        if lowercaseName.contains("iphone") { return .iPhone }
        if lowercaseName.contains("ipad") { return .iPad }
        if lowercaseName.contains("macbook") { return .macBook }
        if lowercaseName.contains("mac") { return .mac }
        if lowercaseName.contains("watch") { return .appleWatch }
        if lowercaseName.contains("apple tv") { return .appleTV }
        if lowercaseName.contains("airpods") { return .airPods }
        if lowercaseName.contains("windows") { return .windows }
        if lowercaseName.contains("android") || lowercaseName.contains("galaxy") || lowercaseName.contains("pixel") { return .android }
        if lowercaseName.contains("xperia") { return .android }
        
        return .unknown
    }
    
    // MARK: - Device Info (XM5 specific)
    
    public override func getDeviceInfo() async throws -> [String: Any] {
        var info = try await super.getDeviceInfo()
        
        // XM5 specific info
        info["generation"] = "XM5"
        info["supportsPairedDevices"] = true
        
        return info
    }
}
