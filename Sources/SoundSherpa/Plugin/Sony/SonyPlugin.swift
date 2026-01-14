import Foundation

// MARK: - Sony Device Models

/// Sony device models with their specific capabilities
/// **Validates: Requirements 6.1**
public enum SonyDeviceModel: String, CaseIterable, Equatable {
    case wh1000xm3 = "WH-1000XM3"
    case wh1000xm4 = "WH-1000XM4"
    case wh1000xm5 = "WH-1000XM5"
    case wf1000xm4 = "WF-1000XM4"
    case wf1000xm5 = "WF-1000XM5"
    
    /// Capabilities supported by this specific model
    public var supportedCapabilities: Set<DeviceCapability> {
        switch self {
        case .wh1000xm3:
            return [.battery, .noiseCancellation, .ambientSound, .equalizerPresets]
        case .wh1000xm4:
            return [.battery, .noiseCancellation, .ambientSound, .autoOff,
                    .equalizerPresets, .voicePrompts]
        case .wh1000xm5:
            return [.battery, .noiseCancellation, .ambientSound, .autoOff,
                    .equalizerPresets, .voicePrompts, .pairedDevices]
        case .wf1000xm4:
            return [.battery, .noiseCancellation, .ambientSound, .equalizerPresets]
        case .wf1000xm5:
            return [.battery, .noiseCancellation, .ambientSound, .autoOff,
                    .equalizerPresets, .voicePrompts]
        }
    }
    
    /// NC levels supported by this model (Sony uses continuous 0-20 range)
    public var supportedNCRange: (min: Int, max: Int) {
        return (0, 20)
    }
    
    /// Whether this is an over-ear (WH) or in-ear (WF) model
    public var isOverEar: Bool {
        return self.rawValue.hasPrefix("WH")
    }
    
    /// Product ID for this model
    public var productId: String {
        switch self {
        case .wh1000xm3: return "0x0C89"
        case .wh1000xm4: return "0x0CD3"
        case .wh1000xm5: return "0x0CE0"
        case .wf1000xm4: return "0x0D58"
        case .wf1000xm5: return "0x0D70"
        }
    }
    
    /// Protocol version used by this model
    public var protocolVersion: SonyProtocolVersion {
        switch self {
        case .wh1000xm3:
            return .v1
        case .wh1000xm4, .wh1000xm5, .wf1000xm4, .wf1000xm5:
            return .v2
        }
    }
    
    /// Whether this model supports multipoint connection
    public var supportsMultipoint: Bool {
        switch self {
        case .wh1000xm3, .wf1000xm4:
            return false
        case .wh1000xm4, .wh1000xm5, .wf1000xm5:
            return true
        }
    }
    
    /// Whether this model supports speak-to-chat
    public var supportsSpeakToChat: Bool {
        switch self {
        case .wh1000xm3:
            return false
        case .wh1000xm4, .wh1000xm5, .wf1000xm4, .wf1000xm5:
            return true
        }
    }
}

/// Protocol versions for different Sony generations
public enum SonyProtocolVersion: String, Equatable {
    case v1  // XM3 generation
    case v2  // XM4/XM5 generation with extended features
}

// MARK: - Sony Command Structure

/// Sony protocol command structure
public struct SonyCommand: Equatable {
    public let dataType: UInt8
    public let sequenceNumber: UInt8
    public let payload: Data
    
    public init(dataType: UInt8, sequenceNumber: UInt8, payload: Data = Data()) {
        self.dataType = dataType
        self.sequenceNumber = sequenceNumber
        self.payload = payload
    }
    
    /// Encode the command to bytes for transmission
    public func encode() -> Data {
        var data = Data()
        // Sony protocol: [start, dataType, seqNum, length, ...payload, checksum, end]
        data.append(SonyConstants.startByte)
        data.append(dataType)
        data.append(sequenceNumber)
        data.append(UInt8(payload.count))
        data.append(contentsOf: payload)
        data.append(calculateChecksum())
        data.append(SonyConstants.endByte)
        return data
    }
    
    /// Calculate checksum for Sony protocol
    private func calculateChecksum() -> UInt8 {
        var checksum: UInt8 = dataType
        checksum = checksum &+ sequenceNumber
        checksum = checksum &+ UInt8(payload.count)
        for byte in payload {
            checksum = checksum &+ byte
        }
        return checksum
    }
    
    /// Decode bytes into a SonyCommand
    public static func decode(_ data: Data) -> SonyCommand? {
        guard data.count >= 6,
              data[0] == SonyConstants.startByte,
              data[data.count - 1] == SonyConstants.endByte else {
            return nil
        }
        
        let dataType = data[1]
        let sequenceNumber = data[2]
        let length = Int(data[3])
        
        guard data.count >= 5 + length else { return nil }
        
        let payload = length > 0 ? data.subdata(in: 4..<(4 + length)) : Data()
        
        return SonyCommand(
            dataType: dataType,
            sequenceNumber: sequenceNumber,
            payload: payload
        )
    }
}

// MARK: - Sony Constants

/// Constants for Sony protocol
public struct SonyConstants {
    /// Sony vendor ID
    public static let vendorId = "0x054C"
    
    /// Common Sony MAC address prefix
    public static let macAddressPrefix = "AC:80:0A"
    
    /// Alternative Sony MAC address prefix
    public static let altMacAddressPrefix = "94:DB:56"
    
    /// Audio Sink service UUID
    public static let audioSinkServiceUUID = "0000110B-0000-1000-8000-00805F9B34FB"
    
    /// Sony proprietary service UUID
    public static let sonyProprietaryServiceUUID = "96CC203E-5068-46AD-B32D-E316F5E069BA"
    
    /// Protocol start byte
    public static let startByte: UInt8 = 0x3E
    
    /// Protocol end byte
    public static let endByte: UInt8 = 0x3C
    
    // MARK: - Data Types
    public struct DataType {
        public static let command: UInt8 = 0x0C
        public static let ack: UInt8 = 0x01
        public static let data: UInt8 = 0x09
    }
    
    // MARK: - Command Categories
    public struct CommandCategory {
        public static let noiseCancellation: UInt8 = 0x66
        public static let ambientSound: UInt8 = 0x67
        public static let battery: UInt8 = 0x22
        public static let deviceInfo: UInt8 = 0x04
        public static let equalizer: UInt8 = 0x58
        public static let autoOff: UInt8 = 0x28
        public static let voiceGuidance: UInt8 = 0x48
        public static let multipoint: UInt8 = 0x3A
        public static let speakToChat: UInt8 = 0x68
    }
    
    // MARK: - Sub-commands
    public struct SubCommand {
        public static let get: UInt8 = 0x06
        public static let set: UInt8 = 0x07
        public static let notify: UInt8 = 0x0D
    }
}


// MARK: - Base Sony Plugin

/// Base class for all Sony devices with common functionality
/// Implements multi-criteria device identification using vendor/product IDs,
/// Sony proprietary service UUID matching, and MAC address prefix validation.
///
/// **Validates: Requirements 6.1**
open class SonyPlugin: DevicePlugin {
    
    // MARK: - Plugin Identity
    
    open var pluginId: String { "com.soundsherpa.sony" }
    open var displayName: String { "Sony Headphones" }
    public var supportedChannelTypes: [String] { ["RFCOMM", "BLE"] }
    
    // MARK: - Device Identification
    
    /// Sony-specific device identifiers using multiple identification strategies
    public var supportedDevices: [DeviceIdentifier] {
        return [
            // WH-1000XM3 identification
            DeviceIdentifier(
                vendorId: SonyConstants.vendorId,
                productId: SonyDeviceModel.wh1000xm3.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                namePattern: "WH-1000XM3.*",
                macAddressPrefix: SonyConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "WH1000XM3", "generation": "XM3"]
            ),
            // WH-1000XM4 identification
            DeviceIdentifier(
                vendorId: SonyConstants.vendorId,
                productId: SonyDeviceModel.wh1000xm4.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                namePattern: "WH-1000XM4.*",
                macAddressPrefix: SonyConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "WH1000XM4", "generation": "XM4"]
            ),
            // WH-1000XM5 identification
            DeviceIdentifier(
                vendorId: SonyConstants.vendorId,
                productId: SonyDeviceModel.wh1000xm5.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                namePattern: "WH-1000XM5.*",
                macAddressPrefix: SonyConstants.macAddressPrefix,
                confidenceScore: 98,
                customIdentifiers: ["deviceFamily": "WH1000XM5", "generation": "XM5", "supportsBLE": "true"]
            ),
            // WF-1000XM4 (earbuds) identification
            DeviceIdentifier(
                vendorId: SonyConstants.vendorId,
                productId: SonyDeviceModel.wf1000xm4.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                namePattern: "WF-1000XM4.*",
                macAddressPrefix: SonyConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "WF1000XM4", "formFactor": "earbuds"]
            ),
            // WF-1000XM5 (earbuds) identification
            DeviceIdentifier(
                vendorId: SonyConstants.vendorId,
                productId: SonyDeviceModel.wf1000xm5.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                namePattern: "WF-1000XM5.*",
                macAddressPrefix: SonyConstants.macAddressPrefix,
                confidenceScore: 98,
                customIdentifiers: ["deviceFamily": "WF1000XM5", "formFactor": "earbuds", "supportsBLE": "true"]
            )
        ]
    }
    
    // MARK: - Internal State
    
    /// The communication channel
    internal var channel: DeviceCommunicationChannel?
    
    /// The detected device model
    internal var deviceModel: SonyDeviceModel?
    
    /// The command encoder for the current device
    internal var commandEncoder: SonyCommandEncoder?
    
    /// Connection state
    private var _isConnected: Bool = false
    public var isConnected: Bool { _isConnected }
    
    /// Sequence number for commands
    internal var sequenceNumber: UInt8 = 0
    
    // MARK: - Initialization
    
    public required init() {}
    
    // MARK: - Device Identification
    
    /// Enhanced device identification using multiple criteria
    /// Sony devices have very reliable vendor/product ID combinations.
    /// Also checks for Sony proprietary service UUID which is very distinctive.
    ///
    /// **Validates: Requirements 6.1**
    public func canHandle(device: BluetoothDevice) -> Int? {
        var bestScore = 0
        var matchedIdentifier: DeviceIdentifier?
        
        for identifier in supportedDevices {
            var score = 0
            
            // Primary: Vendor + Product ID (highest confidence for Sony)
            if let deviceVendorId = device.vendorId,
               let deviceProductId = device.productId,
               let identifierVendorId = identifier.vendorId,
               let identifierProductId = identifier.productId,
               deviceVendorId.uppercased() == identifierVendorId.uppercased(),
               deviceProductId.uppercased() == identifierProductId.uppercased() {
                score += 90  // Higher confidence for Sony due to reliable IDs
            }
            
            // Secondary: Sony proprietary service UUID (very distinctive)
            if device.serviceUUIDs.contains(where: { $0.uppercased() == SonyConstants.sonyProprietaryServiceUUID.uppercased() }) {
                score += 20
            }
            
            // Tertiary: MAC address prefix
            if let macPrefix = identifier.macAddressPrefix,
               device.address.uppercased().hasPrefix(macPrefix.uppercased()) {
                score += 5
            }
            
            // Also check alternative MAC prefix
            if device.address.uppercased().hasPrefix(SonyConstants.altMacAddressPrefix.uppercased()) {
                score += 5
            }
            
            // Quaternary: BLE advertisement data check for newer models
            if let advData = device.advertisementData,
               let modelData = advData["kCBAdvDataManufacturerData"] as? Data {
                if modelData.count > 4 {
                    score += 3
                }
            }
            
            // Fallback: Name pattern (lowest confidence)
            if let pattern = identifier.namePattern,
               device.name.range(of: pattern, options: .regularExpression) != nil {
                score += IdentificationScoreWeights.namePatternMatch
            }
            
            // Apply confidence cap
            if score > 0 {
                score = min(score, identifier.confidenceScore)
                if score > bestScore {
                    bestScore = score
                    matchedIdentifier = identifier
                }
            }
        }
        
        // Store detected model for later use
        if let matched = matchedIdentifier {
            deviceModel = detectModelFromIdentifier(matched, device: device)
        }
        
        // Sony threshold is 60 (slightly higher than Bose due to more reliable IDs)
        return bestScore >= 60 ? bestScore : nil
    }
    
    /// Detect specific model from matched identifier and device info
    internal func detectModelFromIdentifier(_ identifier: DeviceIdentifier, device: BluetoothDevice) -> SonyDeviceModel? {
        // First try to match by product ID (most reliable for Sony)
        if let productId = device.productId?.uppercased() {
            for model in SonyDeviceModel.allCases {
                if model.productId.uppercased() == productId {
                    return model
                }
            }
        }
        
        // Fall back to device family from identifier
        guard let family = identifier.customIdentifiers["deviceFamily"] else { return nil }
        
        switch family {
        case "WH1000XM3": return .wh1000xm3
        case "WH1000XM4": return .wh1000xm4
        case "WH1000XM5": return .wh1000xm5
        case "WF1000XM4": return .wf1000xm4
        case "WF1000XM5": return .wf1000xm5
        default: return nil
        }
    }
    
    /// Factory method to create device-specific subclass
    /// **Validates: Requirements 6.1**
    public static func createPlugin(for device: BluetoothDevice) -> SonyPlugin? {
        let basePlugin = SonyPlugin()
        guard let score = basePlugin.canHandle(device: device),
              score >= 60 else {
            return nil
        }
        guard let model = basePlugin.deviceModel else { return nil }
        
        switch model {
        case .wh1000xm3:
            return SonyWH1000XM3Plugin()
        case .wh1000xm4:
            return SonyWH1000XM4Plugin()
        case .wh1000xm5:
            return SonyWH1000XM5Plugin()
        case .wf1000xm4:
            return SonyWF1000XM4Plugin()
        case .wf1000xm5:
            return SonyWF1000XM5Plugin()
        }
    }
    
    // MARK: - Capability Configuration
    
    /// Get device-specific capability configurations
    open func getCapabilityConfigs(for device: BluetoothDevice) -> [DeviceCapabilityConfig] {
        // Ensure we have detected the model
        if deviceModel == nil {
            _ = canHandle(device: device)
        }
        
        guard let model = deviceModel else { return [] }
        return createCapabilityConfigs(for: model)
    }
    
    /// Template method - subclasses override for model-specific configurations
    open func createCapabilityConfigs(for model: SonyDeviceModel) -> [DeviceCapabilityConfig] {
        var configs: [DeviceCapabilityConfig] = []
        
        // Battery (all Sony devices)
        configs.append(DeviceCapabilityConfig(
            capability: .battery,
            valueType: .continuous(min: 0, max: 100, step: 1),
            displayName: "Battery Level",
            isSupported: true,
            metadata: [:]
        ))
        
        // Noise Cancellation (continuous 0-20 range for Sony)
        configs.append(createNCConfig(for: model))
        
        // Ambient Sound (continuous 0-20 range)
        if model.supportedCapabilities.contains(.ambientSound) {
            configs.append(DeviceCapabilityConfig(
                capability: .ambientSound,
                valueType: .continuous(min: 0, max: 20, step: 1),
                displayName: "Ambient Sound",
                isSupported: true,
                metadata: ["protocol": "sony", "range": "0-20"]
            ))
        }
        
        // Equalizer Presets
        if model.supportedCapabilities.contains(.equalizerPresets) {
            configs.append(DeviceCapabilityConfig(
                capability: .equalizerPresets,
                valueType: .discrete(["off", "bright", "excited", "mellow", "relaxed", "vocal", "treble", "bass", "speech", "custom"]),
                displayName: "Equalizer",
                isSupported: true,
                metadata: [:]
            ))
        }
        
        return configs
    }
    
    /// Create NC config - Sony uses continuous 0-20 range
    /// **Validates: Requirements 6.3**
    open func createNCConfig(for model: SonyDeviceModel) -> DeviceCapabilityConfig {
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .continuous(min: 0, max: 20, step: 1),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": "sony", "range": "0-20"]
        )
    }
    
    // MARK: - Connection Management
    
    public func connect(channel: DeviceCommunicationChannel) async throws {
        self.channel = channel
        self._isConnected = true
        self.sequenceNumber = 0
        
        // Initialize the appropriate command encoder based on device model
        if let model = deviceModel {
            commandEncoder = createCommandEncoder(for: model)
        }
    }
    
    public func disconnect() {
        channel?.close()
        channel = nil
        _isConnected = false
    }
    
    /// Create the appropriate command encoder for the device model
    internal func createCommandEncoder(for model: SonyDeviceModel) -> SonyCommandEncoder {
        switch model.protocolVersion {
        case .v1:
            return SonyV1CommandEncoder()
        case .v2:
            return SonyV2CommandEncoder()
        }
    }
    
    /// Get next sequence number
    internal func nextSequenceNumber() -> UInt8 {
        sequenceNumber = sequenceNumber &+ 1
        return sequenceNumber
    }
    
    // MARK: - Core Device Operations
    
    public func getBatteryLevel() async throws -> Int {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        let command = commandEncoder?.encodeBatteryQuery(sequenceNumber: nextSequenceNumber())
            ?? SonyV1CommandEncoder().encodeBatteryQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseBatteryResponse(response)
    }
    
    public func getDeviceInfo() async throws -> [String: Any] {
        guard _isConnected else {
            throw DeviceError.notConnected
        }
        
        var info: [String: Any] = [:]
        info["model"] = deviceModel?.rawValue ?? "Unknown Sony Device"
        info["protocolVersion"] = deviceModel?.protocolVersion.rawValue ?? "unknown"
        info["isOverEar"] = deviceModel?.isOverEar ?? true
        info["supportsMultipoint"] = deviceModel?.supportsMultipoint ?? false
        info["supportsSpeakToChat"] = deviceModel?.supportsSpeakToChat ?? false
        
        return info
    }
    
    // MARK: - Noise Cancellation
    
    /// Get noise cancellation level (0-20 for Sony)
    /// **Validates: Requirements 6.3**
    public func getNoiseCancellation() async throws -> Any {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeNCQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseNCResponse(response)
    }
    
    /// Set noise cancellation level (0-20 for Sony)
    /// **Validates: Requirements 6.3**
    public func setNoiseCancellation(_ value: Any) async throws {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let level: Int
        if let intValue = value as? Int {
            level = intValue
        } else if let stringValue = value as? String, let intValue = Int(stringValue) {
            level = intValue
        } else {
            throw DeviceError.invalidResponse
        }
        
        // Validate level is in range (0-20)
        guard level >= 0 && level <= 20 else {
            throw DeviceError.invalidResponse
        }
        
        let command = encoder.encodeNCCommand(level: level, sequenceNumber: nextSequenceNumber())
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    public func convertNCToStandard(_ deviceValue: Any) -> String {
        if let level = deviceValue as? Int {
            return String(level)
        }
        return "0"
    }
    
    public func convertNCFromStandard(_ standardValue: String) -> Any {
        return Int(standardValue) ?? 0
    }
    
    // MARK: - Ambient Sound
    
    /// Get ambient sound level (0-20 for Sony)
    /// **Validates: Requirements 6.4**
    open func getAmbientSound() async throws -> Int {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeAmbientSoundQuery(sequenceNumber: nextSequenceNumber())
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseAmbientSoundResponse(response)
    }
    
    /// Set ambient sound level (0-20 for Sony)
    /// **Validates: Requirements 6.4**
    open func setAmbientSound(_ level: Int) async throws {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        // Validate level is in range (0-20)
        guard level >= 0 && level <= 20 else {
            throw DeviceError.invalidResponse
        }
        
        let command = encoder.encodeAmbientSoundCommand(level: level, sequenceNumber: nextSequenceNumber())
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    // MARK: - Response Parsing
    
    internal func parseBatteryResponse(_ data: Data) -> Int {
        // Sony battery response format varies by protocol version
        // Basic format: [start, dataType, seqNum, length, category, subCmd, batteryLevel, ..., checksum, end]
        guard data.count >= 7 else { return 0 }
        
        // Find battery level in response (typically at offset 6)
        if data.count > 6 {
            return Int(data[6])
        }
        return 0
    }
    
    internal func parseNCResponse(_ data: Data) -> Int {
        // Sony NC response: level is typically at offset 6
        guard data.count >= 7 else { return 0 }
        return Int(data[6])
    }
    
    internal func parseAmbientSoundResponse(_ data: Data) -> Int {
        // Sony ambient sound response: level is typically at offset 6
        guard data.count >= 7 else { return 0 }
        return Int(data[6])
    }
    
    // MARK: - Optional Capabilities (Base implementations - subclasses override)
    
    open func getAutoOff() async throws -> AutoOffSetting {
        throw DeviceError.unsupportedCommand
    }
    
    open func setAutoOff(_ setting: AutoOffSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getVoicePromptsEnabled() async throws -> Bool {
        throw DeviceError.unsupportedCommand
    }
    
    open func setVoicePromptsEnabled(_ enabled: Bool) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getPairedDevices() async throws -> [PairedDevice] {
        throw DeviceError.unsupportedCommand
    }
    
    open func connectPairedDevice(address: String) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func disconnectPairedDevice(address: String) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getEqualizerPreset() async throws -> String {
        throw DeviceError.unsupportedCommand
    }
    
    open func setEqualizerPreset(_ preset: String) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    // Not applicable to Sony devices
    open func getSelfVoice() async throws -> Any {
        throw DeviceError.unsupportedCommand
    }
    
    open func setSelfVoice(_ value: Any) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getLanguage() async throws -> DeviceLanguage {
        throw DeviceError.unsupportedCommand
    }
    
    open func setLanguage(_ language: DeviceLanguage) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getButtonAction() async throws -> ButtonActionSetting {
        throw DeviceError.unsupportedCommand
    }
    
    open func setButtonAction(_ action: ButtonActionSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
}


// MARK: - Sony Command Encoder Protocol

/// Protocol for encoding Sony commands
/// **Validates: Requirements 6.3**
public protocol SonyCommandEncoder {
    func encodeNCCommand(level: Int, sequenceNumber: UInt8) -> Data
    func encodeNCQuery(sequenceNumber: UInt8) -> Data
    func encodeAmbientSoundCommand(level: Int, sequenceNumber: UInt8) -> Data
    func encodeAmbientSoundQuery(sequenceNumber: UInt8) -> Data
    func encodeBatteryQuery(sequenceNumber: UInt8) -> Data
    func encodeEqualizerCommand(preset: String, sequenceNumber: UInt8) -> Data
    func encodeEqualizerQuery(sequenceNumber: UInt8) -> Data
    func encodeAutoOffCommand(setting: AutoOffSetting, sequenceNumber: UInt8) -> Data
    func encodeAutoOffQuery(sequenceNumber: UInt8) -> Data
    func encodeVoiceGuidanceCommand(enabled: Bool, sequenceNumber: UInt8) -> Data
    func encodeVoiceGuidanceQuery(sequenceNumber: UInt8) -> Data
}

// MARK: - V1 Command Encoder (WH-1000XM3)

/// V1 encoder for WH-1000XM3
public class SonyV1CommandEncoder: SonyCommandEncoder {
    
    public init() {}
    
    /// Build a Sony command with proper framing
    private func buildCommand(category: UInt8, subCommand: UInt8, payload: [UInt8], sequenceNumber: UInt8) -> Data {
        var fullPayload = Data([category, subCommand])
        fullPayload.append(contentsOf: payload)
        
        let command = SonyCommand(
            dataType: SonyConstants.DataType.command,
            sequenceNumber: sequenceNumber,
            payload: fullPayload
        )
        return command.encode()
    }
    
    public func encodeNCCommand(level: Int, sequenceNumber: UInt8) -> Data {
        // Sony NC command: category 0x66, subCommand 0x07 (set), level byte
        return buildCommand(
            category: SonyConstants.CommandCategory.noiseCancellation,
            subCommand: SonyConstants.SubCommand.set,
            payload: [UInt8(min(max(level, 0), 20))],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeNCQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.noiseCancellation,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAmbientSoundCommand(level: Int, sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.ambientSound,
            subCommand: SonyConstants.SubCommand.set,
            payload: [UInt8(min(max(level, 0), 20))],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAmbientSoundQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.ambientSound,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeBatteryQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.battery,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeEqualizerCommand(preset: String, sequenceNumber: UInt8) -> Data {
        let presetByte: UInt8
        switch preset.lowercased() {
        case "off": presetByte = 0x00
        case "bright": presetByte = 0x10
        case "excited": presetByte = 0x11
        case "mellow": presetByte = 0x12
        case "relaxed": presetByte = 0x13
        case "vocal": presetByte = 0x14
        case "treble": presetByte = 0x15
        case "bass": presetByte = 0x16
        case "speech": presetByte = 0x17
        case "custom": presetByte = 0xA0
        default: presetByte = 0x00
        }
        
        return buildCommand(
            category: SonyConstants.CommandCategory.equalizer,
            subCommand: SonyConstants.SubCommand.set,
            payload: [presetByte],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeEqualizerQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.equalizer,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAutoOffCommand(setting: AutoOffSetting, sequenceNumber: UInt8) -> Data {
        let settingByte: UInt8
        switch setting {
        case .never: settingByte = 0x00
        case .fiveMinutes: settingByte = 0x05
        case .twentyMinutes: settingByte = 0x14
        case .fortyMinutes: settingByte = 0x28
        case .sixtyMinutes: settingByte = 0x3C
        case .oneEightyMinutes: settingByte = 0xB4
        }
        
        return buildCommand(
            category: SonyConstants.CommandCategory.autoOff,
            subCommand: SonyConstants.SubCommand.set,
            payload: [settingByte],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAutoOffQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.autoOff,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeVoiceGuidanceCommand(enabled: Bool, sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.voiceGuidance,
            subCommand: SonyConstants.SubCommand.set,
            payload: [enabled ? 0x01 : 0x00],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeVoiceGuidanceQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.voiceGuidance,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
}

// MARK: - V2 Command Encoder (WH-1000XM4/XM5, WF-1000XM4/XM5)

/// V2 encoder for XM4/XM5 generation with extended features
public class SonyV2CommandEncoder: SonyCommandEncoder {
    
    public init() {}
    
    /// Build a Sony V2 command with proper framing and extended header
    private func buildCommand(category: UInt8, subCommand: UInt8, payload: [UInt8], sequenceNumber: UInt8) -> Data {
        // V2 adds an extra byte for feature flags
        var fullPayload = Data([category, subCommand, 0x00])  // 0x00 is feature flags
        fullPayload.append(contentsOf: payload)
        
        let command = SonyCommand(
            dataType: SonyConstants.DataType.command,
            sequenceNumber: sequenceNumber,
            payload: fullPayload
        )
        return command.encode()
    }
    
    public func encodeNCCommand(level: Int, sequenceNumber: UInt8) -> Data {
        // V2 NC command includes mode byte (0x02 = NC mode)
        return buildCommand(
            category: SonyConstants.CommandCategory.noiseCancellation,
            subCommand: SonyConstants.SubCommand.set,
            payload: [0x02, UInt8(min(max(level, 0), 20))],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeNCQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.noiseCancellation,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAmbientSoundCommand(level: Int, sequenceNumber: UInt8) -> Data {
        // V2 ambient sound includes mode byte (0x01 = ambient mode)
        return buildCommand(
            category: SonyConstants.CommandCategory.ambientSound,
            subCommand: SonyConstants.SubCommand.set,
            payload: [0x01, UInt8(min(max(level, 0), 20))],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAmbientSoundQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.ambientSound,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeBatteryQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.battery,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeEqualizerCommand(preset: String, sequenceNumber: UInt8) -> Data {
        let presetByte: UInt8
        switch preset.lowercased() {
        case "off": presetByte = 0x00
        case "bright": presetByte = 0x10
        case "excited": presetByte = 0x11
        case "mellow": presetByte = 0x12
        case "relaxed": presetByte = 0x13
        case "vocal": presetByte = 0x14
        case "treble": presetByte = 0x15
        case "bass": presetByte = 0x16
        case "speech": presetByte = 0x17
        case "custom": presetByte = 0xA0
        default: presetByte = 0x00
        }
        
        return buildCommand(
            category: SonyConstants.CommandCategory.equalizer,
            subCommand: SonyConstants.SubCommand.set,
            payload: [presetByte],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeEqualizerQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.equalizer,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAutoOffCommand(setting: AutoOffSetting, sequenceNumber: UInt8) -> Data {
        let settingByte: UInt8
        switch setting {
        case .never: settingByte = 0x00
        case .fiveMinutes: settingByte = 0x05
        case .twentyMinutes: settingByte = 0x14
        case .fortyMinutes: settingByte = 0x28
        case .sixtyMinutes: settingByte = 0x3C
        case .oneEightyMinutes: settingByte = 0xB4
        }
        
        return buildCommand(
            category: SonyConstants.CommandCategory.autoOff,
            subCommand: SonyConstants.SubCommand.set,
            payload: [settingByte],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeAutoOffQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.autoOff,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeVoiceGuidanceCommand(enabled: Bool, sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.voiceGuidance,
            subCommand: SonyConstants.SubCommand.set,
            payload: [enabled ? 0x01 : 0x00],
            sequenceNumber: sequenceNumber
        )
    }
    
    public func encodeVoiceGuidanceQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.voiceGuidance,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    // V2-specific commands
    
    /// Encode multipoint status query
    public func encodeMultipointQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.multipoint,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
    
    /// Encode speak-to-chat command
    public func encodeSpeakToChatCommand(enabled: Bool, sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.speakToChat,
            subCommand: SonyConstants.SubCommand.set,
            payload: [enabled ? 0x01 : 0x00],
            sequenceNumber: sequenceNumber
        )
    }
    
    /// Encode speak-to-chat query
    public func encodeSpeakToChatQuery(sequenceNumber: UInt8) -> Data {
        return buildCommand(
            category: SonyConstants.CommandCategory.speakToChat,
            subCommand: SonyConstants.SubCommand.get,
            payload: [],
            sequenceNumber: sequenceNumber
        )
    }
}

// MARK: - Sony Response Decoder

/// Decoder for Sony protocol responses
public class SonyResponseDecoder {
    
    public init() {}
    
    /// Decode a battery response
    public func decodeBattery(_ data: Data) -> Int {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return 0
        }
        // Battery level is typically at payload offset 2
        return Int(command.payload[2])
    }
    
    /// Decode NC level response
    public func decodeNCLevel(_ data: Data) -> Int {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return 0
        }
        return Int(command.payload[2])
    }
    
    /// Decode ambient sound level response
    public func decodeAmbientSoundLevel(_ data: Data) -> Int {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return 0
        }
        return Int(command.payload[2])
    }
    
    /// Decode equalizer preset response
    public func decodeEqualizerPreset(_ data: Data) -> String {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return "off"
        }
        
        let presetByte = command.payload[2]
        switch presetByte {
        case 0x00: return "off"
        case 0x10: return "bright"
        case 0x11: return "excited"
        case 0x12: return "mellow"
        case 0x13: return "relaxed"
        case 0x14: return "vocal"
        case 0x15: return "treble"
        case 0x16: return "bass"
        case 0x17: return "speech"
        case 0xA0: return "custom"
        default: return "off"
        }
    }
    
    /// Decode auto-off setting response
    public func decodeAutoOff(_ data: Data) -> AutoOffSetting {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return .never
        }
        
        let settingByte = command.payload[2]
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
    
    /// Decode voice guidance enabled response
    public func decodeVoiceGuidance(_ data: Data) -> Bool {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return true
        }
        return command.payload[2] != 0x00
    }
    
    /// Decode multipoint status response
    public func decodeMultipointStatus(_ data: Data) -> Bool {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return false
        }
        return command.payload[2] != 0x00
    }
    
    /// Decode speak-to-chat status response
    public func decodeSpeakToChatStatus(_ data: Data) -> Bool {
        guard let command = SonyCommand.decode(data),
              command.payload.count >= 3 else {
            return false
        }
        return command.payload[2] != 0x00
    }
}
