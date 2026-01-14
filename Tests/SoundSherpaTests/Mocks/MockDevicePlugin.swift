import Foundation
@testable import SoundSherpa

/// Mock communication channel for testing
class MockCommunicationChannel: DeviceCommunicationChannel {
    let channelType: String
    let deviceAddress: String
    
    private var _isOpen: Bool = false
    var isOpen: Bool { _isOpen }
    
    /// Response to return for sendCommand
    var mockResponse: Data = Data()
    
    /// Error to throw for sendCommand
    var mockError: DeviceError?
    
    /// Commands that were sent
    var sentCommands: [Data] = []
    
    init(channelType: String = "RFCOMM", deviceAddress: String = "00:00:00:00:00:00") {
        self.channelType = channelType
        self.deviceAddress = deviceAddress
    }
    
    func open() {
        _isOpen = true
    }
    
    func sendCommand(_ data: Data, expectedPrefix: Data?, timeout: TimeInterval) async throws -> Data {
        guard isOpen else {
            throw DeviceError.notConnected
        }
        
        sentCommands.append(data)
        
        if let error = mockError {
            throw error
        }
        
        return mockResponse
    }
    
    func close() {
        _isOpen = false
    }
}

/// Mock plugin for testing purposes
class MockDevicePlugin: DevicePlugin {
    let pluginId: String
    let displayName: String
    let supportedDevices: [DeviceIdentifier]
    let supportedChannelTypes: [String]
    
    private var channel: DeviceCommunicationChannel?
    private var _isConnected = false
    
    /// Confidence score to return for canHandle
    var mockConfidenceScore: Int?
    
    /// Whether canHandle should use actual matching logic
    var useActualMatching: Bool = false
    
    /// Mock battery level to return
    var mockBatteryLevel: Int = 75
    
    /// Mock error to throw for commands
    var mockCommandError: DeviceError?
    
    /// Track which commands were called
    var commandHistory: [String] = []
    
    /// Connection state (protocol requirement)
    var isConnected: Bool { _isConnected }
    
    /// Required initializer for protocol conformance
    required init() {
        self.pluginId = "com.test.mock"
        self.displayName = "Mock Plugin"
        self.supportedDevices = []
        self.supportedChannelTypes = ["RFCOMM"]
    }
    
    init(
        pluginId: String = "com.test.mock",
        displayName: String = "Mock Plugin",
        supportedDevices: [DeviceIdentifier] = [],
        supportedChannelTypes: [String] = ["RFCOMM"]
    ) {
        self.pluginId = pluginId
        self.displayName = displayName
        self.supportedDevices = supportedDevices
        self.supportedChannelTypes = supportedChannelTypes
    }
    
    func getCapabilityConfigs(for device: BluetoothDevice) -> [DeviceCapabilityConfig] {
        return [
            DeviceCapabilityConfig(
                capability: .battery,
                valueType: .continuous(min: 0, max: 100, step: 1),
                displayName: "Battery Level",
                isSupported: true
            ),
            DeviceCapabilityConfig(
                capability: .noiseCancellation,
                valueType: .discrete(["off", "low", "high"]),
                displayName: "Noise Cancellation",
                isSupported: true
            )
        ]
    }
    
    func canHandle(device: BluetoothDevice) -> Int? {
        // If mock score is set, return it
        if let mockScore = mockConfidenceScore {
            return mockScore > 0 ? mockScore : nil
        }
        
        // If using actual matching, use the DeviceMatchingService
        if useActualMatching {
            return DeviceMatchingService.calculateBestMatchScore(for: device, against: supportedDevices)
        }
        
        // Default: check if any supported device matches
        for identifier in supportedDevices {
            if matchesIdentifier(device: device, identifier: identifier) {
                return identifier.confidenceScore
            }
        }
        
        return nil
    }
    
    private func matchesIdentifier(device: BluetoothDevice, identifier: DeviceIdentifier) -> Bool {
        // Check vendor ID
        if let vendorId = identifier.vendorId, device.vendorId != vendorId {
            return false
        }
        
        // Check product ID
        if let productId = identifier.productId, device.productId != productId {
            return false
        }
        
        // Check name pattern
        if let pattern = identifier.namePattern {
            if device.name.range(of: pattern, options: .regularExpression) == nil {
                return false
            }
        }
        
        return true
    }
    
    func connect(channel: DeviceCommunicationChannel) async throws {
        commandHistory.append("connect")
        if let error = mockCommandError {
            throw error
        }
        self.channel = channel
        self._isConnected = true
    }
    
    func disconnect() {
        commandHistory.append("disconnect")
        self.channel = nil
        self._isConnected = false
    }
    
    func getBatteryLevel() async throws -> Int {
        commandHistory.append("getBatteryLevel")
        guard _isConnected else { throw DeviceError.notConnected }
        if let error = mockCommandError {
            throw error
        }
        return mockBatteryLevel
    }
    
    func getDeviceInfo() async throws -> [String: Any] {
        commandHistory.append("getDeviceInfo")
        guard _isConnected else { throw DeviceError.notConnected }
        if let error = mockCommandError {
            throw error
        }
        return ["model": "Mock Device", "firmware": "1.0.0"]
    }
    
    func getNoiseCancellation() async throws -> Any {
        commandHistory.append("getNoiseCancellation")
        guard _isConnected else { throw DeviceError.notConnected }
        if let error = mockCommandError {
            throw error
        }
        return NoiseCancellationLevel.high
    }
    
    func setNoiseCancellation(_ value: Any) async throws {
        commandHistory.append("setNoiseCancellation")
        guard _isConnected else { throw DeviceError.notConnected }
        if let error = mockCommandError {
            throw error
        }
        // Mock implementation - just record the call
    }
    
    func convertNCToStandard(_ deviceValue: Any) -> String {
        guard let level = deviceValue as? NoiseCancellationLevel else { return "unknown" }
        return level.rawValue
    }
    
    func convertNCFromStandard(_ standardValue: String) -> Any {
        return NoiseCancellationLevel(rawValue: standardValue) ?? NoiseCancellationLevel.off
    }
}

/// Invalid plugin for testing validation
class InvalidMockPlugin: DevicePlugin {
    var pluginId: String = ""
    var displayName: String = ""
    var supportedDevices: [DeviceIdentifier] = []
    var supportedChannelTypes: [String] = []
    var isConnected: Bool = false
    
    required init() {}
    
    func getCapabilityConfigs(for device: BluetoothDevice) -> [DeviceCapabilityConfig] { [] }
    func canHandle(device: BluetoothDevice) -> Int? { nil }
    func connect(channel: DeviceCommunicationChannel) async throws {}
    func disconnect() {}
    func getBatteryLevel() async throws -> Int { 0 }
    func getDeviceInfo() async throws -> [String: Any] { [:] }
    func getNoiseCancellation() async throws -> Any { NoiseCancellationLevel.off }
    func setNoiseCancellation(_ value: Any) async throws {}
    func convertNCToStandard(_ deviceValue: Any) -> String { "off" }
    func convertNCFromStandard(_ standardValue: String) -> Any { NoiseCancellationLevel.off }
}

/// Mock plugin that simulates command errors for testing error handling
class ErrorPronePlugin: DevicePlugin {
    var pluginId: String = "com.test.errorprone"
    var displayName: String = "Error Prone Plugin"
    var supportedDevices: [DeviceIdentifier] = [
        DeviceIdentifier(vendorId: "0xFFFF", confidenceScore: 80)
    ]
    var supportedChannelTypes: [String] = ["RFCOMM"]
    
    private var _isConnected = false
    var isConnected: Bool { _isConnected }
    
    /// The error to throw for each command type
    var errorToThrow: [DeviceCommandType: DeviceError] = [:]
    
    required init() {}
    
    func getCapabilityConfigs(for device: BluetoothDevice) -> [DeviceCapabilityConfig] {
        return [DeviceCapabilityConfig.defaultConfig(for: .battery)]
    }
    
    func canHandle(device: BluetoothDevice) -> Int? {
        return device.vendorId == "0xFFFF" ? 80 : nil
    }
    
    func connect(channel: DeviceCommunicationChannel) async throws {
        if let error = errorToThrow[.getBattery] {
            throw error
        }
        _isConnected = true
    }
    
    func disconnect() {
        _isConnected = false
    }
    
    func getBatteryLevel() async throws -> Int {
        if let error = errorToThrow[.getBattery] {
            throw error
        }
        return 50
    }
    
    func getDeviceInfo() async throws -> [String: Any] {
        if let error = errorToThrow[.getDeviceInfo] {
            throw error
        }
        return [:]
    }
    
    func getNoiseCancellation() async throws -> Any {
        if let error = errorToThrow[.getNoiseCancellation] {
            throw error
        }
        return NoiseCancellationLevel.off
    }
    
    func setNoiseCancellation(_ value: Any) async throws {
        if let error = errorToThrow[.setNoiseCancellation] {
            throw error
        }
    }
    
    func convertNCToStandard(_ deviceValue: Any) -> String { "off" }
    func convertNCFromStandard(_ standardValue: String) -> Any { NoiseCancellationLevel.off }
}
