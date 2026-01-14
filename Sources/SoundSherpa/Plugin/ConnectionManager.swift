import Foundation

/// Connection state representing the current status of device connection
public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(BluetoothDevice, DeviceCommunicationChannel)
    
    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected):
            return true
        case (.connecting, .connecting):
            return true
        case let (.connected(device1, channel1), .connected(device2, channel2)):
            return device1.address == device2.address && channel1.deviceAddress == channel2.deviceAddress
        default:
            return false
        }
    }
    
    /// Whether currently connected to a device
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
    
    /// Whether currently attempting to connect
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
    
    /// The connected device, if any
    public var device: BluetoothDevice? {
        if case let .connected(device, _) = self { return device }
        return nil
    }
    
    /// The communication channel, if connected
    public var channel: DeviceCommunicationChannel? {
        if case let .connected(_, channel) = self { return channel }
        return nil
    }
}

/// Delegate protocol for receiving connection events
public protocol ConnectionManagerDelegate: AnyObject {
    /// Called when a device is discovered during scanning
    func connectionManager(_ manager: ConnectionManager, didDiscover device: BluetoothDevice)
    
    /// Called when successfully connected to a device
    func connectionManager(_ manager: ConnectionManager, didConnect device: BluetoothDevice)
    
    /// Called when disconnected from a device
    func connectionManager(_ manager: ConnectionManager, didDisconnect device: BluetoothDevice)
    
    /// Called when a connection attempt fails
    func connectionManager(_ manager: ConnectionManager, didFailWith error: Error)
    
    /// Called when connection state changes
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState)
}

/// Default empty implementations for optional delegate methods
public extension ConnectionManagerDelegate {
    func connectionManager(_ manager: ConnectionManager, didDiscover device: BluetoothDevice) {}
    func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState) {}
}

/// Manages Bluetooth device connections with retry logic and multi-transport support
public class ConnectionManager {
    
    // MARK: - Properties
    
    /// Delegate for connection events
    public weak var delegate: ConnectionManagerDelegate?
    
    /// Device registry for plugin management
    private let registry: DeviceRegistry
    
    /// Channel factory for creating communication channels
    private let channelFactory: CommunicationChannelFactory
    
    /// Settings store for persisting and restoring device settings
    private let settingsStore: SettingsStore?
    
    /// Whether to automatically restore settings on reconnection
    public var autoRestoreSettings: Bool = true
    
    /// Current connection state
    private var _connectionState: ConnectionState = .disconnected
    public var connectionState: ConnectionState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _connectionState
        }
    }
    
    /// Maximum number of retry attempts
    public let maxRetryAttempts: Int
    
    /// Base delay for exponential backoff (in seconds)
    public let baseRetryDelay: TimeInterval
    
    /// Maximum delay between retries (in seconds)
    public let maxRetryDelay: TimeInterval
    
    /// Whether currently scanning for devices
    private var isScanning: Bool = false
    
    /// Lock for thread-safe state access
    private let lock = NSLock()
    
    /// Current retry attempt count (use atomic operations for async safety)
    private var _currentRetryAttempt: Int = 0
    private var currentRetryAttempt: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _currentRetryAttempt
        }
        set {
            lock.lock()
            _currentRetryAttempt = newValue
            lock.unlock()
        }
    }
    
    /// Task for current connection attempt (for cancellation)
    private var connectionTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /// Initialize ConnectionManager with dependencies
    /// - Parameters:
    ///   - registry: Device registry for plugin management
    ///   - channelFactory: Factory for creating communication channels
    ///   - settingsStore: Optional settings store for persisting device settings
    ///   - maxRetryAttempts: Maximum number of connection retry attempts (default: 3)
    ///   - baseRetryDelay: Base delay for exponential backoff in seconds (default: 1.0)
    ///   - maxRetryDelay: Maximum delay between retries in seconds (default: 8.0)
    public init(
        registry: DeviceRegistry,
        channelFactory: CommunicationChannelFactory = CommunicationChannelFactory(),
        settingsStore: SettingsStore? = nil,
        maxRetryAttempts: Int = 3,
        baseRetryDelay: TimeInterval = 1.0,
        maxRetryDelay: TimeInterval = 8.0
    ) {
        self.registry = registry
        self.channelFactory = channelFactory
        self.settingsStore = settingsStore
        self.maxRetryAttempts = maxRetryAttempts
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
    }
    
    // MARK: - Scanning
    
    /// Start scanning for supported devices
    public func startScanning() {
        lock.lock()
        isScanning = true
        lock.unlock()
        
        // In a real implementation, this would use IOBluetooth or CoreBluetooth
        // to scan for nearby devices
    }
    
    /// Stop scanning for devices
    public func stopScanning() {
        lock.lock()
        isScanning = false
        lock.unlock()
    }
    
    // MARK: - Connection
    
    /// Connect to a specific device
    /// - Parameter device: The Bluetooth device to connect to
    /// - Returns: The communication channel for the connected device
    /// - Throws: DeviceError if connection fails after all retry attempts
    @discardableResult
    public func connect(to device: BluetoothDevice) async throws -> DeviceCommunicationChannel {
        // Cancel any existing connection attempt
        connectionTask?.cancel()
        
        // Reset retry counter
        currentRetryAttempt = 0
        
        // Update state to connecting
        updateState(.connecting)
        
        do {
            let channel = try await connectWithRetry(to: device, attempt: 1)
            return channel
        } catch {
            // Connection failed after all retries
            updateState(.disconnected)
            delegate?.connectionManager(self, didFailWith: error)
            throw error
        }
    }

    
    /// Connect with exponential backoff retry logic
    /// - Parameters:
    ///   - device: The device to connect to
    ///   - attempt: Current attempt number (1-based)
    /// - Returns: The communication channel
    /// - Throws: DeviceError if connection fails
    private func connectWithRetry(to device: BluetoothDevice, attempt: Int) async throws -> DeviceCommunicationChannel {
        currentRetryAttempt = attempt
        
        do {
            // Find the appropriate plugin for this device
            guard let plugin = registry.findPlugin(for: device) else {
                let error = DeviceError.pluginNotFound
                ErrorLogger.shared.log(error, context: "ConnectionManager.connectWithRetry")
                throw error
            }
            
            // Check if plugin has previously failed
            if PluginErrorHandler.shared.hasPluginFailed(plugin.pluginId) {
                let error = DeviceError.pluginUnrecoverableError("Plugin previously failed")
                ErrorLogger.shared.log(error, context: "ConnectionManager.connectWithRetry")
                throw error
            }
            
            // Get preferred channel types from the plugin
            let preferredTypes = plugin.supportedChannelTypes
            
            // Create the communication channel
            let channel = try channelFactory.createChannel(
                for: device,
                preferredTypes: preferredTypes
            )
            
            // Open the channel (for RFCOMM/BLE channels)
            if let rfcommChannel = channel as? RFCOMMChannel {
                try await rfcommChannel.open()
            } else if let bleChannel = channel as? BLEChannel {
                try await bleChannel.open()
            }
            
            // Connect the plugin to the channel
            do {
                try await plugin.connect(channel: channel)
            } catch {
                // Handle plugin connection error
                PluginErrorHandler.shared.handlePluginError(
                    error,
                    pluginId: plugin.pluginId,
                    operation: "connect"
                )
                throw error
            }
            
            // Activate the plugin in the registry
            registry.activatePlugin(plugin, for: device)
            
            // Restore settings if enabled and settings store is available
            if autoRestoreSettings, let store = settingsStore {
                do {
                    let restored = try await store.restorePluginSettings(plugin, for: device)
                    if restored {
                        // Settings were restored successfully
                    }
                } catch {
                    // Settings restoration failed, but connection succeeded
                    // Log error but don't fail the connection
                    ErrorLogger.shared.log(error, context: "ConnectionManager.restoreSettings")
                }
            }
            
            // Update state to connected
            updateState(.connected(device, channel))
            
            // Notify delegate
            delegate?.connectionManager(self, didConnect: device)
            
            return channel
            
        } catch {
            // Log the error
            let deviceError = (error as? DeviceError) ?? .connectionFailed(error.localizedDescription)
            ErrorLogger.shared.log(deviceError, context: "ConnectionManager.connectWithRetry attempt \(attempt)")
            
            // Check if we should retry based on recovery strategy
            let shouldRetry = deviceError.recoveryStrategy == .retry ||
                              deviceError.recoveryStrategy == .retryWithBackoff ||
                              deviceError.recoveryStrategy == .reconnect
            
            // Check if we should retry
            if shouldRetry && attempt < maxRetryAttempts {
                // Calculate delay with exponential backoff
                let delay = calculateRetryDelay(attempt: attempt)
                
                // Wait before retrying
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                // Check if task was cancelled during sleep
                try Task.checkCancellation()
                
                // Retry with next attempt
                return try await connectWithRetry(to: device, attempt: attempt + 1)
            } else {
                // All retries exhausted or error is not retryable
                throw error
            }
        }
    }
    
    /// Calculate retry delay using exponential backoff
    /// - Parameter attempt: Current attempt number (1-based)
    /// - Returns: Delay in seconds
    public func calculateRetryDelay(attempt: Int) -> TimeInterval {
        // Exponential backoff: baseDelay * 2^(attempt-1)
        let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
        return min(delay, maxRetryDelay)
    }
    
    /// Disconnect from the current device
    public func disconnect() {
        lock.lock()
        let currentState = _connectionState
        lock.unlock()
        
        // Cancel any ongoing connection attempt
        connectionTask?.cancel()
        connectionTask = nil
        
        guard case let .connected(device, channel) = currentState else {
            // Not connected, just update state
            updateState(.disconnected)
            return
        }
        
        // Save settings before disconnecting if settings store is available
        if let store = settingsStore, let plugin = registry.getActivePlugin() {
            Task {
                do {
                    try await store.savePluginSettings(plugin, for: device)
                } catch {
                    // Settings save failed, but continue with disconnect
                }
            }
        }
        
        // Close the channel
        channel.close()
        
        // Deactivate the plugin in the registry
        registry.deactivatePlugin()
        
        // Update state
        updateState(.disconnected)
        
        // Notify delegate
        delegate?.connectionManager(self, didDisconnect: device)
    }
    
    /// Save current device settings
    /// - Throws: SettingsStoreError if save fails
    public func saveCurrentSettings() async throws {
        guard case let .connected(device, _) = connectionState,
              let store = settingsStore,
              let plugin = registry.getActivePlugin() else {
            return
        }
        
        try await store.savePluginSettings(plugin, for: device)
    }
    
    /// Handle unexpected channel closure
    /// Called when the communication channel closes unexpectedly
    public func handleChannelClosed() {
        lock.lock()
        let currentState = _connectionState
        lock.unlock()
        
        guard case let .connected(device, _) = currentState else {
            return
        }
        
        // Deactivate the plugin
        registry.deactivatePlugin()
        
        // Update state to disconnected
        updateState(.disconnected)
        
        // Notify delegate
        delegate?.connectionManager(self, didDisconnect: device)
    }
    
    // MARK: - State Management
    
    /// Update connection state and notify delegate
    private func updateState(_ newState: ConnectionState) {
        lock.lock()
        let oldState = _connectionState
        _connectionState = newState
        lock.unlock()
        
        // Only notify if state actually changed
        if oldState != newState {
            delegate?.connectionManager(self, didChangeState: newState)
        }
    }
    
    // MARK: - Device Discovery Handling
    
    /// Handle a discovered device (called by Bluetooth scanning)
    /// - Parameter device: The discovered Bluetooth device
    public func handleDiscoveredDevice(_ device: BluetoothDevice) {
        delegate?.connectionManager(self, didDiscover: device)
    }
    
    // MARK: - Retry Information
    
    /// Get the current retry attempt number
    public var retryAttempt: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentRetryAttempt
    }
    
    /// Check if currently in a retry cycle
    public var isRetrying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentRetryAttempt > 1 && _connectionState == .connecting
    }
}

// MARK: - DeviceCommunicationChannelDelegate

extension ConnectionManager: DeviceCommunicationChannelDelegate {
    public func channelDidOpen(_ channel: DeviceCommunicationChannel) {
        // Channel opened successfully - handled in connect flow
    }
    
    public func channelDidClose(_ channel: DeviceCommunicationChannel) {
        // Handle unexpected channel closure
        handleChannelClosed()
    }
    
    public func channel(_ channel: DeviceCommunicationChannel, didReceiveData data: Data) {
        // Data received - forward to active plugin if needed
    }
    
    public func channel(_ channel: DeviceCommunicationChannel, didFailWithError error: DeviceError) {
        // Channel error - may trigger reconnection
        handleChannelClosed()
    }
}
