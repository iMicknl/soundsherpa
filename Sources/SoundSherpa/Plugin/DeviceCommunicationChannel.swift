import Foundation

/// Channel type identifiers
public enum ChannelType: String, CaseIterable, Equatable {
    case rfcomm = "RFCOMM"
    case ble = "BLE"
    
    public var displayName: String {
        switch self {
        case .rfcomm: return "RFCOMM (Serial Port Profile)"
        case .ble: return "Bluetooth Low Energy"
        }
    }
}

/// Generic communication interface to support different transport protocols
public protocol DeviceCommunicationChannel: AnyObject {
    /// Send data and wait for response
    /// - Parameters:
    ///   - data: The command data to send
    ///   - expectedPrefix: Optional prefix to match in the response
    ///   - timeout: Maximum time to wait for response
    /// - Returns: The response data from the device
    /// - Throws: DeviceError if communication fails
    func sendCommand(_ data: Data, expectedPrefix: Data?, timeout: TimeInterval) async throws -> Data
    
    /// Check if channel is open
    var isOpen: Bool { get }
    
    /// Close the channel
    func close()
    
    /// Get channel type identifier
    var channelType: String { get }
    
    /// Get the device address this channel is connected to
    var deviceAddress: String { get }
}

/// Delegate protocol for receiving channel events
public protocol DeviceCommunicationChannelDelegate: AnyObject {
    /// Called when the channel is opened successfully
    func channelDidOpen(_ channel: DeviceCommunicationChannel)
    
    /// Called when the channel is closed
    func channelDidClose(_ channel: DeviceCommunicationChannel)
    
    /// Called when data is received from the device
    func channel(_ channel: DeviceCommunicationChannel, didReceiveData data: Data)
    
    /// Called when an error occurs
    func channel(_ channel: DeviceCommunicationChannel, didFailWithError error: DeviceError)
}

/// RFCOMM implementation of communication channel for classic Bluetooth
public class RFCOMMChannel: DeviceCommunicationChannel {
    public let channelType: String = ChannelType.rfcomm.rawValue
    public let deviceAddress: String
    
    private var _isOpen: Bool = false
    public var isOpen: Bool { _isOpen }
    
    public weak var delegate: DeviceCommunicationChannelDelegate?
    
    /// Pending response continuation for async/await
    private var responseContinuation: CheckedContinuation<Data, Error>?
    
    /// Expected response prefix for filtering
    private var expectedResponsePrefix: Data?
    
    /// Buffer for incoming data
    private var receiveBuffer = Data()
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Initialize with device address
    /// - Parameter deviceAddress: The MAC address of the Bluetooth device
    public init(deviceAddress: String) {
        self.deviceAddress = deviceAddress
    }
    
    /// Open the RFCOMM channel
    /// - Throws: DeviceError if channel cannot be opened
    public func open() async throws {
        lock.lock()
        defer { lock.unlock() }
        
        // In a real implementation, this would use IOBluetooth to open the channel
        // For now, we simulate the channel opening
        _isOpen = true
        delegate?.channelDidOpen(self)
    }
    
    /// Send data and wait for response
    public func sendCommand(_ data: Data, expectedPrefix: Data?, timeout: TimeInterval) async throws -> Data {
        guard isOpen else {
            throw DeviceError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.responseContinuation = continuation
            self.expectedResponsePrefix = expectedPrefix
            self.receiveBuffer = Data()
            lock.unlock()
            
            // In a real implementation, this would send data via IOBluetooth
            // For now, we simulate the send
            
            // Set up timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                if let continuation = self.responseContinuation {
                    self.responseContinuation = nil
                    self.lock.unlock()
                    continuation.resume(throwing: DeviceError.commandTimeout)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
    
    /// Called when data is received from the device (to be called by IOBluetooth delegate)
    public func handleReceivedData(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)
        
        // Check if we have a complete response
        if let prefix = expectedResponsePrefix {
            // Check if buffer starts with expected prefix
            if receiveBuffer.count >= prefix.count {
                let bufferPrefix = receiveBuffer.prefix(prefix.count)
                if bufferPrefix == prefix {
                    // We have a matching response
                    if let continuation = responseContinuation {
                        responseContinuation = nil
                        let response = receiveBuffer
                        receiveBuffer = Data()
                        lock.unlock()
                        continuation.resume(returning: response)
                        return
                    }
                }
            }
        } else {
            // No prefix expected, return any data received
            if let continuation = responseContinuation, !receiveBuffer.isEmpty {
                responseContinuation = nil
                let response = receiveBuffer
                receiveBuffer = Data()
                lock.unlock()
                continuation.resume(returning: response)
                return
            }
        }
        
        lock.unlock()
        delegate?.channel(self, didReceiveData: data)
    }
    
    /// Close the channel
    public func close() {
        lock.lock()
        _isOpen = false
        
        // Cancel any pending continuation
        if let continuation = responseContinuation {
            responseContinuation = nil
            lock.unlock()
            continuation.resume(throwing: DeviceError.channelClosed)
        } else {
            lock.unlock()
        }
        
        delegate?.channelDidClose(self)
    }
}

/// BLE implementation of communication channel for Bluetooth Low Energy
public class BLEChannel: DeviceCommunicationChannel {
    public let channelType: String = ChannelType.ble.rawValue
    public let deviceAddress: String
    
    private var _isOpen: Bool = false
    public var isOpen: Bool { _isOpen }
    
    public weak var delegate: DeviceCommunicationChannelDelegate?
    
    /// Service UUID for communication
    public let serviceUUID: String
    
    /// Characteristic UUID for writing commands
    public let writeCharacteristicUUID: String
    
    /// Characteristic UUID for reading responses
    public let readCharacteristicUUID: String
    
    /// Pending response continuation for async/await
    private var responseContinuation: CheckedContinuation<Data, Error>?
    
    /// Expected response prefix for filtering
    private var expectedResponsePrefix: Data?
    
    /// Buffer for incoming data
    private var receiveBuffer = Data()
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Initialize with device address and characteristic UUIDs
    /// - Parameters:
    ///   - deviceAddress: The MAC address or identifier of the BLE device
    ///   - serviceUUID: The service UUID for communication
    ///   - writeCharacteristicUUID: The characteristic UUID for writing commands
    ///   - readCharacteristicUUID: The characteristic UUID for reading responses
    public init(
        deviceAddress: String,
        serviceUUID: String,
        writeCharacteristicUUID: String,
        readCharacteristicUUID: String
    ) {
        self.deviceAddress = deviceAddress
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.readCharacteristicUUID = readCharacteristicUUID
    }
    
    /// Open the BLE channel and discover services/characteristics
    /// - Throws: DeviceError if channel cannot be opened
    public func open() async throws {
        lock.lock()
        defer { lock.unlock() }
        
        // In a real implementation, this would use CoreBluetooth to:
        // 1. Connect to the peripheral
        // 2. Discover services
        // 3. Discover characteristics
        // 4. Enable notifications on read characteristic
        _isOpen = true
        delegate?.channelDidOpen(self)
    }
    
    /// Send data and wait for response
    public func sendCommand(_ data: Data, expectedPrefix: Data?, timeout: TimeInterval) async throws -> Data {
        guard isOpen else {
            throw DeviceError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.responseContinuation = continuation
            self.expectedResponsePrefix = expectedPrefix
            self.receiveBuffer = Data()
            lock.unlock()
            
            // In a real implementation, this would write to the BLE characteristic
            // For now, we simulate the send
            
            // Set up timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                if let continuation = self.responseContinuation {
                    self.responseContinuation = nil
                    self.lock.unlock()
                    continuation.resume(throwing: DeviceError.commandTimeout)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
    
    /// Called when data is received from the BLE characteristic notification
    public func handleReceivedData(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)
        
        // Check if we have a complete response
        if let prefix = expectedResponsePrefix {
            if receiveBuffer.count >= prefix.count {
                let bufferPrefix = receiveBuffer.prefix(prefix.count)
                if bufferPrefix == prefix {
                    if let continuation = responseContinuation {
                        responseContinuation = nil
                        let response = receiveBuffer
                        receiveBuffer = Data()
                        lock.unlock()
                        continuation.resume(returning: response)
                        return
                    }
                }
            }
        } else {
            if let continuation = responseContinuation, !receiveBuffer.isEmpty {
                responseContinuation = nil
                let response = receiveBuffer
                receiveBuffer = Data()
                lock.unlock()
                continuation.resume(returning: response)
                return
            }
        }
        
        lock.unlock()
        delegate?.channel(self, didReceiveData: data)
    }
    
    /// Close the channel
    public func close() {
        lock.lock()
        _isOpen = false
        
        if let continuation = responseContinuation {
            responseContinuation = nil
            lock.unlock()
            continuation.resume(throwing: DeviceError.channelClosed)
        } else {
            lock.unlock()
        }
        
        delegate?.channelDidClose(self)
    }
}

/// Factory for creating appropriate communication channels
/// Implements channel type selection and creation logic for RFCOMM and BLE channels
public class CommunicationChannelFactory {
    
    /// Shared instance for convenience
    public static let shared = CommunicationChannelFactory()
    
    /// BLE configurations keyed by device address or identifier
    private var bleConfigs: [String: BLEChannelConfig] = [:]
    
    /// Default BLE configuration for devices without specific config
    private var defaultBLEConfig: BLEChannelConfig?
    
    public init() {}
    
    /// Register a BLE configuration for a specific device
    /// - Parameters:
    ///   - config: The BLE channel configuration
    ///   - deviceIdentifier: Device address or identifier to associate with this config
    public func registerBLEConfig(_ config: BLEChannelConfig, for deviceIdentifier: String) {
        bleConfigs[deviceIdentifier] = config
    }
    
    /// Set the default BLE configuration for devices without specific config
    /// - Parameter config: The default BLE channel configuration
    public func setDefaultBLEConfig(_ config: BLEChannelConfig?) {
        defaultBLEConfig = config
    }
    
    /// Get the BLE configuration for a device
    /// - Parameter device: The Bluetooth device
    /// - Returns: BLE configuration if available
    public func getBLEConfig(for device: BluetoothDevice) -> BLEChannelConfig? {
        return bleConfigs[device.address] ?? defaultBLEConfig
    }
    
    /// Create a channel based on device requirements and available transports
    /// - Parameters:
    ///   - device: The Bluetooth device to connect to
    ///   - preferredTypes: Ordered list of preferred channel types
    ///   - bleConfig: Optional BLE configuration for BLE channels (overrides registered config)
    /// - Returns: A communication channel appropriate for the device
    /// - Throws: DeviceError if no suitable channel type is available
    public func createChannel(
        for device: BluetoothDevice,
        preferredTypes: [String],
        bleConfig: BLEChannelConfig? = nil
    ) throws -> DeviceCommunicationChannel {
        
        let availableTypes = getAvailableChannelTypes(for: device)
        
        for channelType in preferredTypes {
            let normalizedType = channelType.uppercased()
            
            // Skip if this channel type is not available for the device
            guard availableTypes.contains(normalizedType) else {
                continue
            }
            
            switch normalizedType {
            case ChannelType.rfcomm.rawValue:
                return RFCOMMChannel(deviceAddress: device.address)
                
            case ChannelType.ble.rawValue:
                // Use provided config, or look up registered config, or use default
                let config = bleConfig ?? getBLEConfig(for: device)
                guard let bleConfiguration = config else {
                    continue // Skip BLE if no config available
                }
                return BLEChannel(
                    deviceAddress: device.address,
                    serviceUUID: bleConfiguration.serviceUUID,
                    writeCharacteristicUUID: bleConfiguration.writeCharacteristicUUID,
                    readCharacteristicUUID: bleConfiguration.readCharacteristicUUID
                )
                
            default:
                continue // Skip unknown channel types
            }
        }
        
        throw DeviceError.unsupportedChannel("No supported channel type found in: \(preferredTypes). Available: \(availableTypes)")
    }
    
    /// Get available channel types for a device
    /// - Parameter device: The Bluetooth device to check
    /// - Returns: List of available channel type identifiers
    public func getAvailableChannelTypes(for device: BluetoothDevice) -> [String] {
        var types: [String] = []
        
        // RFCOMM is available for most classic Bluetooth devices
        // Check for SPP or Audio Sink service UUIDs
        let rfcommServiceUUIDs = [
            "00001101-0000-1000-8000-00805F9B34FB", // SPP (Serial Port Profile)
            "0000110B-0000-1000-8000-00805F9B34FB"  // Audio Sink
        ]
        
        for uuid in rfcommServiceUUIDs {
            if device.hasServiceUUID(uuid) {
                types.append(ChannelType.rfcomm.rawValue)
                break
            }
        }
        
        // If no specific service UUIDs but device is connected, assume RFCOMM is available
        // This handles devices that don't advertise their services
        if types.isEmpty && device.isConnected {
            types.append(ChannelType.rfcomm.rawValue)
        }
        
        // BLE is available if device has BLE-specific services or we have a BLE config
        let hasBLEConfig = getBLEConfig(for: device) != nil
        let hasBLEServices = device.serviceUUIDs.contains { uuid in
            // Check for common BLE service UUIDs (Battery Service, Generic Access, etc.)
            let bleServicePrefixes = ["0000180", "96CC203E"] // Battery, Sony proprietary
            return bleServicePrefixes.contains { uuid.uppercased().hasPrefix($0) }
        }
        
        if hasBLEConfig || hasBLEServices {
            types.append(ChannelType.ble.rawValue)
        }
        
        return types
    }
    
    /// Select the best channel type for a device based on plugin preferences and availability
    /// - Parameters:
    ///   - device: The Bluetooth device
    ///   - pluginPreferences: Ordered list of channel types preferred by the plugin
    /// - Returns: The best available channel type, or nil if none available
    public func selectBestChannelType(
        for device: BluetoothDevice,
        pluginPreferences: [String]
    ) -> String? {
        let availableTypes = getAvailableChannelTypes(for: device)
        
        // Return the first preferred type that is available
        for preferred in pluginPreferences {
            if availableTypes.contains(preferred.uppercased()) {
                return preferred.uppercased()
            }
        }
        
        // Fall back to first available type
        return availableTypes.first
    }
    
    // MARK: - Static convenience methods (for backward compatibility)
    
    /// Create a channel based on device requirements and available transports (static convenience)
    public static func createChannel(
        for device: BluetoothDevice,
        preferredTypes: [String],
        bleConfig: BLEChannelConfig? = nil
    ) throws -> DeviceCommunicationChannel {
        return try shared.createChannel(for: device, preferredTypes: preferredTypes, bleConfig: bleConfig)
    }
    
    /// Get available channel types for a device (static convenience)
    public static func getAvailableChannelTypes(for device: BluetoothDevice) -> [String] {
        return shared.getAvailableChannelTypes(for: device)
    }
}

/// Configuration for BLE channel creation
public struct BLEChannelConfig: Equatable {
    public let serviceUUID: String
    public let writeCharacteristicUUID: String
    public let readCharacteristicUUID: String
    
    public init(
        serviceUUID: String,
        writeCharacteristicUUID: String,
        readCharacteristicUUID: String
    ) {
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.readCharacteristicUUID = readCharacteristicUUID
    }
}
