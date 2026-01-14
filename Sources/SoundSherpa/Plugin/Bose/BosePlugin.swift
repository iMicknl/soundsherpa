import Foundation

// MARK: - Bose Device Models

/// Bose device models with their specific capabilities and protocol variations
public enum BoseDeviceModel: String, CaseIterable, Equatable {
    case qc35 = "QC35"
    case qc35ii = "QC35 II"
    case qc45 = "QC45"
    case nc700 = "NC 700"
    case qcUltra = "QC Ultra"
    
    /// Capabilities supported by this specific model
    public var supportedCapabilities: Set<DeviceCapability> {
        switch self {
        case .qc35:
            return [.battery, .noiseCancellation, .autoOff, .language, .voicePrompts]
        case .qc35ii:
            return [.battery, .noiseCancellation, .selfVoice, .autoOff,
                    .language, .voicePrompts, .pairedDevices, .buttonAction]
        case .qc45:
            return [.battery, .noiseCancellation, .selfVoice, .autoOff,
                    .language, .voicePrompts, .pairedDevices]
        case .nc700:
            return [.battery, .noiseCancellation, .selfVoice, .autoOff,
                    .language, .voicePrompts, .pairedDevices, .equalizerPresets]
        case .qcUltra:
            return [.battery, .noiseCancellation, .selfVoice, .ambientSound,
                    .autoOff, .language, .voicePrompts, .pairedDevices]
        }
    }
    
    /// NC levels supported by this model
    public var supportedNCLevels: [NoiseCancellationLevel] {
        switch self {
        case .qc35, .qc35ii:
            return [.off, .low, .high]
        case .qc45, .nc700:
            return [.off, .low, .medium, .high]
        case .qcUltra:
            return [.off, .low, .medium, .high, .adaptive]
        }
    }
    
    /// Protocol version used by this model
    public var protocolVersion: BoseProtocolVersion {
        switch self {
        case .qc35, .qc35ii, .qc45:
            return .v1  // Original SPP protocol
        case .nc700, .qcUltra:
            return .v2  // Updated protocol with different command structure
        }
    }
    
    /// Product ID for this model
    public var productId: String {
        switch self {
        case .qc35: return "0x4001"
        case .qc35ii: return "0x4002"
        case .qc45: return "0x4003"
        case .nc700: return "0x400C"
        case .qcUltra: return "0x4010"
        }
    }
}

/// Protocol versions for different Bose generations
public enum BoseProtocolVersion: String, Equatable {
    case v1  // QC35/QC35II/QC45 - uses 4-byte header
    case v2  // NC700/QCUltra - uses extended header with checksums
}

// MARK: - Bose Command Structure

/// Bose protocol command structure
public struct BoseCommand: Equatable {
    public let functionBlock: UInt8
    public let function: UInt8
    public let operatorByte: UInt8
    public let payload: Data
    
    public init(functionBlock: UInt8, function: UInt8, operatorByte: UInt8, payload: Data = Data()) {
        self.functionBlock = functionBlock
        self.function = function
        self.operatorByte = operatorByte
        self.payload = payload
    }
    
    /// Encode the command to bytes for transmission
    public func encode() -> Data {
        var data = Data()
        data.append(functionBlock)
        data.append(function)
        data.append(operatorByte)
        data.append(contentsOf: payload)
        return data
    }
    
    /// Decode bytes into a BoseCommand
    public static func decode(_ data: Data) -> BoseCommand? {
        guard data.count >= 3 else { return nil }
        
        let functionBlock = data[0]
        let function = data[1]
        let operatorByte = data[2]
        let payload = data.count > 3 ? data.subdata(in: 3..<data.count) : Data()
        
        return BoseCommand(
            functionBlock: functionBlock,
            function: function,
            operatorByte: operatorByte,
            payload: payload
        )
    }
}

// MARK: - Bose Constants

/// Constants for Bose protocol
public struct BoseConstants {
    /// Bose vendor ID
    public static let vendorId = "0x009E"
    
    /// Common Bose MAC address prefix
    public static let macAddressPrefix = "04:52:C7"
    
    /// Audio Sink service UUID
    public static let audioSinkServiceUUID = "0000110B-0000-1000-8000-00805F9B34FB"
    
    /// Battery service UUID
    public static let batteryServiceUUID = "0000180F-0000-1000-8000-00805F9B34FB"
    
    // MARK: - Function Blocks
    public struct FunctionBlock {
        public static let productInfo: UInt8 = 0x00
        public static let settings: UInt8 = 0x01
        public static let status: UInt8 = 0x02
        public static let deviceManagement: UInt8 = 0x03
        public static let audioManagement: UInt8 = 0x04
    }
    
    // MARK: - Functions
    public struct Function {
        public static let noiseCancellation: UInt8 = 0x06
        public static let selfVoice: UInt8 = 0x07
        public static let autoOff: UInt8 = 0x04
        public static let language: UInt8 = 0x03
        public static let voicePrompts: UInt8 = 0x02
        public static let buttonAction: UInt8 = 0x08
        public static let battery: UInt8 = 0x02
        public static let pairedDevices: UInt8 = 0x05
        public static let deviceInfo: UInt8 = 0x01
    }
    
    // MARK: - Operators
    public struct Operator {
        public static let get: UInt8 = 0x01
        public static let set: UInt8 = 0x02
        public static let status: UInt8 = 0x03
        public static let result: UInt8 = 0x04
    }
}


// MARK: - Base Bose Plugin

/// Base class for all Bose devices with common functionality
/// Implements multi-criteria device identification using vendor/product IDs,
/// service UUID matching, and MAC address prefix validation.
///
/// **Validates: Requirements 2.2, 5.1**
open class BosePlugin: DevicePlugin {
    
    // MARK: - Plugin Identity
    
    open var pluginId: String { "com.soundsherpa.bose" }
    open var displayName: String { "Bose Headphones" }
    public var supportedChannelTypes: [String] { ["RFCOMM"] }
    
    // MARK: - Device Identification
    
    /// Bose-specific device identifiers using multiple identification strategies
    public var supportedDevices: [DeviceIdentifier] {
        return [
            // QC35 identification
            DeviceIdentifier(
                vendorId: BoseConstants.vendorId,
                productId: BoseDeviceModel.qc35.productId,
                serviceUUIDs: [BoseConstants.audioSinkServiceUUID],
                namePattern: "Bose QC35(?! II).*",
                macAddressPrefix: BoseConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "QC35"]
            ),
            // QC35 II identification
            DeviceIdentifier(
                vendorId: BoseConstants.vendorId,
                productId: BoseDeviceModel.qc35ii.productId,
                serviceUUIDs: [BoseConstants.audioSinkServiceUUID],
                namePattern: "Bose QC35 II.*",
                macAddressPrefix: BoseConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "QC35II", "hasGoogleAssistant": "true"]
            ),
            // QC45 identification
            DeviceIdentifier(
                vendorId: BoseConstants.vendorId,
                productId: BoseDeviceModel.qc45.productId,
                serviceUUIDs: [BoseConstants.audioSinkServiceUUID],
                namePattern: "Bose QC45.*",
                macAddressPrefix: BoseConstants.macAddressPrefix,
                confidenceScore: 95,
                customIdentifiers: ["deviceFamily": "QC45"]
            ),
            // NC 700 identification
            DeviceIdentifier(
                vendorId: BoseConstants.vendorId,
                productId: BoseDeviceModel.nc700.productId,
                serviceUUIDs: [BoseConstants.audioSinkServiceUUID],
                namePattern: "Bose NC 700.*|Bose Noise Cancelling Headphones 700.*",
                macAddressPrefix: BoseConstants.macAddressPrefix,
                confidenceScore: 96,
                customIdentifiers: ["deviceFamily": "NC700", "protocolVersion": "v2"]
            ),
            // QC Ultra identification
            DeviceIdentifier(
                vendorId: BoseConstants.vendorId,
                productId: BoseDeviceModel.qcUltra.productId,
                serviceUUIDs: [BoseConstants.audioSinkServiceUUID, BoseConstants.batteryServiceUUID],
                namePattern: "Bose QuietComfort Ultra.*|Bose QC Ultra.*",
                macAddressPrefix: BoseConstants.macAddressPrefix,
                confidenceScore: 98,
                customIdentifiers: ["deviceFamily": "QCUltra", "protocolVersion": "v2"]
            )
        ]
    }
    
    // MARK: - Internal State
    
    /// The communication channel
    internal var channel: DeviceCommunicationChannel?
    
    /// The detected device model
    internal var deviceModel: BoseDeviceModel?
    
    /// The command encoder for the current device
    internal var commandEncoder: BoseCommandEncoder?
    
    /// Connection state
    private var _isConnected: Bool = false
    public var isConnected: Bool { _isConnected }
    
    // MARK: - Initialization
    
    public required init() {}
    
    // MARK: - Device Identification
    
    /// Enhanced device identification using multiple criteria
    /// Returns a confidence score based on vendor/product ID, service UUIDs,
    /// MAC address prefix, and name pattern matching.
    ///
    /// **Validates: Requirements 2.1, 2.2, 2.3**
    public func canHandle(device: BluetoothDevice) -> Int? {
        var bestScore = 0
        var matchedIdentifier: DeviceIdentifier?
        
        for identifier in supportedDevices {
            if let score = identifier.calculateMatchScore(for: device) {
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
        
        return bestScore >= IdentificationScoreWeights.minimumThreshold ? bestScore : nil
    }
    
    /// Detect specific model from matched identifier and device info
    internal func detectModelFromIdentifier(_ identifier: DeviceIdentifier, device: BluetoothDevice) -> BoseDeviceModel? {
        // First try to match by product ID (most reliable)
        if let productId = device.productId?.uppercased() {
            for model in BoseDeviceModel.allCases {
                if model.productId.uppercased() == productId {
                    return model
                }
            }
        }
        
        // Fall back to device family from identifier
        guard let family = identifier.customIdentifiers["deviceFamily"] else { return nil }
        
        switch family {
        case "QC35": return .qc35
        case "QC35II": return .qc35ii
        case "QC45": return .qc45
        case "NC700": return .nc700
        case "QCUltra": return .qcUltra
        default: return nil
        }
    }
    
    /// Factory method to create device-specific subclass
    public static func createPlugin(for device: BluetoothDevice) -> BosePlugin? {
        let basePlugin = BosePlugin()
        guard let score = basePlugin.canHandle(device: device),
              score >= IdentificationScoreWeights.minimumThreshold else {
            return nil
        }
        guard let model = basePlugin.deviceModel else { return nil }
        
        switch model {
        case .qc35:
            return BoseQC35Plugin()
        case .qc35ii:
            return BoseQC35IIPlugin()
        case .qc45:
            return BoseQC45Plugin()
        case .nc700:
            return BoseNC700Plugin()
        case .qcUltra:
            return BoseQCUltraPlugin()
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
    open func createCapabilityConfigs(for model: BoseDeviceModel) -> [DeviceCapabilityConfig] {
        var configs: [DeviceCapabilityConfig] = []
        
        // Battery (all Bose devices)
        configs.append(DeviceCapabilityConfig(
            capability: .battery,
            valueType: .continuous(min: 0, max: 100, step: 1),
            displayName: "Battery Level",
            isSupported: true,
            metadata: [:]
        ))
        
        // Noise Cancellation (device-specific levels)
        configs.append(createNCConfig(for: model))
        
        // Auto-off (most Bose devices)
        if model.supportedCapabilities.contains(.autoOff) {
            configs.append(DeviceCapabilityConfig(
                capability: .autoOff,
                valueType: .discrete(["never", "5", "20", "40", "60", "180"]),
                displayName: "Auto-Off Timer",
                isSupported: true,
                metadata: [:]
            ))
        }
        
        // Language (most Bose devices)
        if model.supportedCapabilities.contains(.language) {
            configs.append(DeviceCapabilityConfig(
                capability: .language,
                valueType: .text,
                displayName: "Language",
                isSupported: true,
                metadata: [:]
            ))
        }
        
        // Voice Prompts (most Bose devices)
        if model.supportedCapabilities.contains(.voicePrompts) {
            configs.append(DeviceCapabilityConfig(
                capability: .voicePrompts,
                valueType: .boolean,
                displayName: "Voice Prompts",
                isSupported: true,
                metadata: [:]
            ))
        }
        
        return configs
    }
    
    /// Create NC config - subclasses override for device-specific levels
    open func createNCConfig(for model: BoseDeviceModel) -> DeviceCapabilityConfig {
        let levels = model.supportedNCLevels.map { $0.rawValue }
        return DeviceCapabilityConfig(
            capability: .noiseCancellation,
            valueType: .discrete(levels),
            displayName: "Noise Cancellation",
            isSupported: true,
            metadata: ["protocol": model.protocolVersion.rawValue]
        )
    }

    
    // MARK: - Connection Management
    
    public func connect(channel: DeviceCommunicationChannel) async throws {
        self.channel = channel
        self._isConnected = true
        
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
    internal func createCommandEncoder(for model: BoseDeviceModel) -> BoseCommandEncoder {
        switch model.protocolVersion {
        case .v1:
            return BoseV1CommandEncoder()
        case .v2:
            return BoseV2CommandEncoder()
        }
    }
    
    // MARK: - Core Device Operations
    
    public func getBatteryLevel() async throws -> Int {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        let command = commandEncoder?.encodeBatteryQuery() ?? BoseV1CommandEncoder().encodeBatteryQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseBatteryResponse(response)
    }
    
    public func getDeviceInfo() async throws -> [String: Any] {
        guard _isConnected else {
            throw DeviceError.notConnected
        }
        
        var info: [String: Any] = [:]
        info["model"] = deviceModel?.rawValue ?? "Unknown Bose Device"
        info["protocolVersion"] = deviceModel?.protocolVersion.rawValue ?? "unknown"
        
        return info
    }
    
    // MARK: - Noise Cancellation
    
    public func getNoiseCancellation() async throws -> Any {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeNCQuery()
        let response = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
        
        return parseNCResponse(response)
    }
    
    public func setNoiseCancellation(_ value: Any) async throws {
        guard _isConnected, let channel = channel else {
            throw DeviceError.notConnected
        }
        
        guard let encoder = commandEncoder else {
            throw DeviceError.unsupportedCommand
        }
        
        let level: NoiseCancellationLevel
        if let ncLevel = value as? NoiseCancellationLevel {
            level = ncLevel
        } else if let stringValue = value as? String,
                  let ncLevel = NoiseCancellationLevel(rawValue: stringValue) {
            level = ncLevel
        } else {
            throw DeviceError.invalidResponse
        }
        
        // Validate level is supported by this model
        if let model = deviceModel, !model.supportedNCLevels.contains(level) {
            throw DeviceError.unsupportedCommand
        }
        
        let command = encoder.encodeNCCommand(level: level)
        _ = try await channel.sendCommand(command, expectedPrefix: nil, timeout: 5.0)
    }
    
    public func convertNCToStandard(_ deviceValue: Any) -> String {
        if let level = deviceValue as? NoiseCancellationLevel {
            return level.rawValue
        }
        return "unknown"
    }
    
    public func convertNCFromStandard(_ standardValue: String) -> Any {
        return NoiseCancellationLevel(rawValue: standardValue) ?? NoiseCancellationLevel.off
    }
    
    // MARK: - Response Parsing
    
    internal func parseBatteryResponse(_ data: Data) -> Int {
        // Bose battery response format: [functionBlock, function, operator, batteryLevel]
        guard data.count >= 4 else { return 0 }
        return Int(data[3])
    }
    
    internal func parseNCResponse(_ data: Data) -> NoiseCancellationLevel {
        // Bose NC response format: [functionBlock, function, operator, ncLevel]
        guard data.count >= 4 else { return .off }
        
        let ncByte = data[3]
        switch ncByte {
        case 0x00: return .off
        case 0x01: return .high
        case 0x02: return .medium
        case 0x03: return .low
        case 0x04: return .adaptive
        default: return .off
        }
    }
    
    // MARK: - Optional Capabilities (Base implementations - subclasses override)
    
    open func getAutoOff() async throws -> AutoOffSetting {
        throw DeviceError.unsupportedCommand
    }
    
    open func setAutoOff(_ setting: AutoOffSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getLanguage() async throws -> DeviceLanguage {
        throw DeviceError.unsupportedCommand
    }
    
    open func setLanguage(_ language: DeviceLanguage) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getVoicePromptsEnabled() async throws -> Bool {
        throw DeviceError.unsupportedCommand
    }
    
    open func setVoicePromptsEnabled(_ enabled: Bool) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getSelfVoice() async throws -> Any {
        throw DeviceError.unsupportedCommand
    }
    
    open func setSelfVoice(_ value: Any) async throws {
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
    
    open func getButtonAction() async throws -> ButtonActionSetting {
        throw DeviceError.unsupportedCommand
    }
    
    open func setButtonAction(_ action: ButtonActionSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getAmbientSound() async throws -> Int {
        throw DeviceError.unsupportedCommand
    }
    
    open func setAmbientSound(_ level: Int) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    open func getEqualizerPreset() async throws -> String {
        throw DeviceError.unsupportedCommand
    }
    
    open func setEqualizerPreset(_ preset: String) async throws {
        throw DeviceError.unsupportedCommand
    }
}

// MARK: - Bose Command Encoder Protocol

/// Protocol for encoding Bose commands
public protocol BoseCommandEncoder {
    func encodeNCCommand(level: NoiseCancellationLevel) -> Data
    func encodeNCQuery() -> Data
    func encodeSelfVoiceCommand(level: SelfVoiceLevel) -> Data
    func encodeSelfVoiceQuery() -> Data
    func encodeAutoOffCommand(setting: AutoOffSetting) -> Data
    func encodeAutoOffQuery() -> Data
    func encodeLanguageCommand(language: DeviceLanguage, voicePromptsEnabled: Bool) -> Data
    func encodeLanguageQuery() -> Data
    func encodeBatteryQuery() -> Data
    func encodePairedDevicesQuery() -> Data
    func encodeButtonActionCommand(action: ButtonActionSetting) -> Data
    func encodeButtonActionQuery() -> Data
}

// MARK: - V1 Command Encoder (QC35/QC35II/QC45)

/// V1 encoder for QC35/QC35II/QC45
public class BoseV1CommandEncoder: BoseCommandEncoder {
    
    public init() {}
    
    public func encodeNCCommand(level: NoiseCancellationLevel) -> Data {
        let levelByte: UInt8
        switch level {
        case .off: levelByte = 0x00
        case .low: levelByte = 0x03
        case .medium: levelByte = 0x02
        case .high: levelByte = 0x01
        case .adaptive: levelByte = 0x00 // V1 doesn't support adaptive
        }
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.noiseCancellation,
            BoseConstants.Operator.set,
            0x01,  // Length
            levelByte
        ])
    }
    
    public func encodeNCQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.noiseCancellation,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodeSelfVoiceCommand(level: SelfVoiceLevel) -> Data {
        let levelByte: UInt8
        switch level {
        case .off: levelByte = 0x00
        case .low: levelByte = 0x01
        case .medium: levelByte = 0x02
        case .high: levelByte = 0x03
        }
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.selfVoice,
            BoseConstants.Operator.set,
            0x01,
            levelByte
        ])
    }
    
    public func encodeSelfVoiceQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.selfVoice,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodeAutoOffCommand(setting: AutoOffSetting) -> Data {
        let settingByte: UInt8
        switch setting {
        case .never: settingByte = 0x00
        case .fiveMinutes: settingByte = 0x05
        case .twentyMinutes: settingByte = 0x14
        case .fortyMinutes: settingByte = 0x28
        case .sixtyMinutes: settingByte = 0x3C
        case .oneEightyMinutes: settingByte = 0xB4
        }
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.autoOff,
            BoseConstants.Operator.set,
            0x01,
            settingByte
        ])
    }
    
    public func encodeAutoOffQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.autoOff,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodeLanguageCommand(language: DeviceLanguage, voicePromptsEnabled: Bool) -> Data {
        let languageByte: UInt8
        switch language {
        case .english: languageByte = 0x00
        case .french: languageByte = 0x01
        case .italian: languageByte = 0x02
        case .german: languageByte = 0x03
        case .spanish: languageByte = 0x04
        case .portuguese: languageByte = 0x05
        case .chinese: languageByte = 0x06
        case .korean: languageByte = 0x07
        case .polish: languageByte = 0x08
        case .russian: languageByte = 0x09
        case .dutch: languageByte = 0x0A
        case .japanese: languageByte = 0x0B
        case .swedish: languageByte = 0x0C
        }
        let voicePromptsByte: UInt8 = voicePromptsEnabled ? 0x01 : 0x00
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.language,
            BoseConstants.Operator.set,
            0x02,
            languageByte,
            voicePromptsByte
        ])
    }
    
    public func encodeLanguageQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.language,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodeBatteryQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.status,
            BoseConstants.Function.battery,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodePairedDevicesQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.deviceManagement,
            BoseConstants.Function.pairedDevices,
            BoseConstants.Operator.get
        ])
    }
    
    public func encodeButtonActionCommand(action: ButtonActionSetting) -> Data {
        let actionByte: UInt8
        switch action {
        case .voiceAssistant: actionByte = 0x00
        case .noiseCancellation: actionByte = 0x01
        case .playPause: actionByte = 0x02
        case .custom: actionByte = 0x03
        }
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.buttonAction,
            BoseConstants.Operator.set,
            0x01,
            actionByte
        ])
    }
    
    public func encodeButtonActionQuery() -> Data {
        return Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.buttonAction,
            BoseConstants.Operator.get
        ])
    }
}


// MARK: - V2 Command Encoder (NC700/QCUltra)

/// V2 encoder for NC700/QCUltra with extended header and checksums
public class BoseV2CommandEncoder: BoseCommandEncoder {
    
    public init() {}
    
    /// Calculate checksum for V2 protocol
    private func calculateChecksum(_ data: Data) -> UInt8 {
        var checksum: UInt8 = 0
        for byte in data {
            checksum = checksum &+ byte
        }
        return ~checksum &+ 1
    }
    
    public func encodeNCCommand(level: NoiseCancellationLevel) -> Data {
        let levelByte: UInt8
        switch level {
        case .off: levelByte = 0x00
        case .low: levelByte = 0x03
        case .medium: levelByte = 0x02
        case .high: levelByte = 0x01
        case .adaptive: levelByte = 0x04
        }
        
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.noiseCancellation,
            BoseConstants.Operator.set,
            0x01,
            levelByte
        ])
        
        // V2 adds length prefix and checksum
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeNCQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.noiseCancellation,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeSelfVoiceCommand(level: SelfVoiceLevel) -> Data {
        let levelByte: UInt8
        switch level {
        case .off: levelByte = 0x00
        case .low: levelByte = 0x01
        case .medium: levelByte = 0x02
        case .high: levelByte = 0x03
        }
        
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.selfVoice,
            BoseConstants.Operator.set,
            0x01,
            levelByte
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeSelfVoiceQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.selfVoice,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeAutoOffCommand(setting: AutoOffSetting) -> Data {
        let settingByte: UInt8
        switch setting {
        case .never: settingByte = 0x00
        case .fiveMinutes: settingByte = 0x05
        case .twentyMinutes: settingByte = 0x14
        case .fortyMinutes: settingByte = 0x28
        case .sixtyMinutes: settingByte = 0x3C
        case .oneEightyMinutes: settingByte = 0xB4
        }
        
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.autoOff,
            BoseConstants.Operator.set,
            0x01,
            settingByte
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeAutoOffQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.autoOff,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeLanguageCommand(language: DeviceLanguage, voicePromptsEnabled: Bool) -> Data {
        let languageByte: UInt8
        switch language {
        case .english: languageByte = 0x00
        case .french: languageByte = 0x01
        case .italian: languageByte = 0x02
        case .german: languageByte = 0x03
        case .spanish: languageByte = 0x04
        case .portuguese: languageByte = 0x05
        case .chinese: languageByte = 0x06
        case .korean: languageByte = 0x07
        case .polish: languageByte = 0x08
        case .russian: languageByte = 0x09
        case .dutch: languageByte = 0x0A
        case .japanese: languageByte = 0x0B
        case .swedish: languageByte = 0x0C
        }
        let voicePromptsByte: UInt8 = voicePromptsEnabled ? 0x01 : 0x00
        
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.language,
            BoseConstants.Operator.set,
            0x02,
            languageByte,
            voicePromptsByte
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeLanguageQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.language,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeBatteryQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.status,
            BoseConstants.Function.battery,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodePairedDevicesQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.deviceManagement,
            BoseConstants.Function.pairedDevices,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeButtonActionCommand(action: ButtonActionSetting) -> Data {
        let actionByte: UInt8
        switch action {
        case .voiceAssistant: actionByte = 0x00
        case .noiseCancellation: actionByte = 0x01
        case .playPause: actionByte = 0x02
        case .custom: actionByte = 0x03
        }
        
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.buttonAction,
            BoseConstants.Operator.set,
            0x01,
            actionByte
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
    
    public func encodeButtonActionQuery() -> Data {
        var payload = Data([
            BoseConstants.FunctionBlock.settings,
            BoseConstants.Function.buttonAction,
            BoseConstants.Operator.get
        ])
        
        var command = Data()
        command.append(UInt8(payload.count))
        command.append(payload)
        command.append(calculateChecksum(payload))
        
        return command
    }
}

// MARK: - Bose Response Decoder

/// Decoder for Bose protocol responses
public class BoseResponseDecoder {
    
    public init() {}
    
    /// Decode a paired devices response
    /// - Parameter data: Raw response data
    /// - Returns: Array of PairedDevice objects
    public func decodePairedDevices(_ data: Data) -> [PairedDevice] {
        var devices: [PairedDevice] = []
        
        // Skip header bytes (functionBlock, function, operator)
        guard data.count > 4 else { return devices }
        
        var offset = 3
        let deviceCount = Int(data[offset])
        offset += 1
        
        for _ in 0..<deviceCount {
            guard offset + 8 <= data.count else { break }
            
            // Read MAC address (6 bytes)
            let macBytes = data.subdata(in: offset..<(offset + 6))
            let macAddress = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            offset += 6
            
            // Read status byte
            let statusByte = data[offset]
            offset += 1
            
            // Read name length and name
            let nameLength = Int(data[offset])
            offset += 1
            
            guard offset + nameLength <= data.count else { break }
            let nameData = data.subdata(in: offset..<(offset + nameLength))
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
    
    /// Detect device type from name
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
        
        return .unknown
    }
}
