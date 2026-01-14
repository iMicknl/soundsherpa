import Cocoa
import Foundation
import IOBluetooth

// MARK: - AppDelegate Integration Extension

/// Extension to AppDelegate that integrates the plugin-based architecture
/// with the existing monolithic implementation.
///
/// This provides a bridge between the legacy Bose-specific code and the new
/// modular plugin system, allowing gradual migration.
///
/// **Validates: Requirements 1.1, 7.1, 7.2**

// MARK: - Plugin Architecture Components

/// Manages the integration of plugin architecture components
/// This class serves as the central coordinator for the plugin-based architecture,
/// wiring together the DeviceRegistry, ConnectionManager, SettingsStore, and MenuController.
///
/// **Validates: Requirements 1.1, 7.1, 7.2**
public class PluginArchitectureManager {
    
    // MARK: - Singleton
    
    /// Shared instance for application-wide access
    public static let shared = PluginArchitectureManager()
    
    // MARK: - Components
    
    /// Device registry for plugin management
    /// Handles plugin discovery, registration, and device-to-plugin matching
    public private(set) var deviceRegistry: DeviceRegistry
    
    /// Connection manager for device connections
    /// Manages Bluetooth connections with retry logic and multi-transport support
    public private(set) var connectionManager: ConnectionManager
    
    /// Settings store for persisting device settings
    /// Handles device-specific settings with round-trip serialization
    public private(set) var settingsStore: SettingsStore
    
    /// Menu controller for capability-based UI (optional, can use legacy menu)
    /// Dynamically builds menus based on device capabilities
    public private(set) var menuController: MenuController?
    
    /// Channel factory for creating communication channels
    public private(set) var channelFactory: CommunicationChannelFactory
    
    // MARK: - State
    
    /// Whether the plugin architecture has been initialized
    public private(set) var isInitialized: Bool = false
    
    /// Whether Bluetooth is currently enabled
    public private(set) var isBluetoothEnabled: Bool = true
    
    /// Currently connected device (if any)
    public var connectedDevice: BluetoothDevice? {
        return connectionManager.connectionState.device
    }
    
    /// Currently active plugin (if any)
    public var activePlugin: DevicePlugin? {
        return deviceRegistry.getActivePlugin()
    }
    
    /// Current connection state
    public var connectionState: ConnectionState {
        return connectionManager.connectionState
    }
    
    // MARK: - Delegates
    
    /// Delegate for receiving plugin architecture events
    public weak var delegate: PluginArchitectureManagerDelegate?
    
    // MARK: - Update Timer
    
    /// Timer for periodic device state updates
    private var updateTimer: Timer?
    
    /// Interval for periodic updates (in seconds)
    public var updateInterval: TimeInterval = 30.0
    
    // MARK: - Initialization
    
    private init() {
        // Initialize channel factory
        self.channelFactory = CommunicationChannelFactory()
        
        // Initialize settings store
        self.settingsStore = SettingsStore()
        
        // Initialize device registry
        self.deviceRegistry = DeviceRegistry()
        
        // Initialize connection manager with registry, channel factory, and settings store
        self.connectionManager = ConnectionManager(
            registry: deviceRegistry,
            channelFactory: channelFactory,
            settingsStore: settingsStore,
            maxRetryAttempts: 3,
            baseRetryDelay: 1.0,
            maxRetryDelay: 8.0
        )
    }
    
    // MARK: - Setup
    
    /// Initialize the plugin architecture with built-in plugins
    /// Call this from applicationDidFinishLaunching
    ///
    /// This method:
    /// 1. Registers built-in plugin factories (Bose, Sony)
    /// 2. Discovers and loads plugins from the plugins directory
    /// 3. Sets up the connection manager delegate
    /// 4. Starts the periodic update timer
    ///
    /// **Validates: Requirements 1.1, 1.4**
    public func initialize() throws {
        guard !isInitialized else { return }
        
        // Register built-in plugin factories
        registerBuiltInPlugins()
        
        // Discover and load all plugins
        let result = try deviceRegistry.discoverAndLoadPlugins()
        
        // Log discovery results
        if result.failedCount > 0 {
            ErrorLogger.shared.log(
                .registrationFailed("\(result.failedCount) plugins failed to load"),
                context: "PluginArchitectureManager.initialize"
            )
        }
        
        // Set up connection manager delegate
        connectionManager.delegate = self
        
        // Set up error handler delegate
        PluginErrorHandler.shared.delegate = self
        
        isInitialized = true
        
        // Notify delegate
        delegate?.pluginArchitectureDidInitialize(self, loadedPlugins: result.loadedCount)
        
        // Log successful initialization
        print("[PluginArchitectureManager] Initialized with \(result.loadedCount) plugins")
    }
    
    /// Register built-in plugin factories for Bose and Sony devices
    /// These are the core plugins that ship with the application.
    private func registerBuiltInPlugins() {
        // Register Bose plugin factory
        deviceRegistry.registerBuiltInPluginFactory {
            BosePlugin()
        }
        
        // Register Sony plugin factory
        deviceRegistry.registerBuiltInPluginFactory {
            SonyPlugin()
        }
        
        print("[PluginArchitectureManager] Registered built-in plugins: Bose, Sony")
    }
    
    /// Set up the menu controller for capability-based UI
    /// - Parameter delegate: The delegate to receive menu controller events
    public func setupMenuController(delegate: MenuControllerDelegate?) {
        menuController = MenuController(delegate: delegate)
        print("[PluginArchitectureManager] Menu controller initialized")
    }
    
    /// Start periodic device state updates
    /// This timer periodically refreshes battery level and other device state
    public func startPeriodicUpdates() {
        stopPeriodicUpdates()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.updateMenuState()
            }
        }
        
        print("[PluginArchitectureManager] Started periodic updates (interval: \(updateInterval)s)")
    }
    
    /// Stop periodic device state updates
    public func stopPeriodicUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    /// Shutdown the plugin architecture
    /// Call this from applicationWillTerminate
    public func shutdown() {
        stopPeriodicUpdates()
        
        // Disable hot-swapping
        deviceRegistry.disableHotSwapping()
        
        // Save settings before disconnecting
        if let plugin = activePlugin, let device = connectedDevice {
            Task {
                do {
                    try await settingsStore.savePluginSettings(plugin, for: device)
                } catch {
                    ErrorLogger.shared.log(error, context: "PluginArchitectureManager.shutdown")
                }
            }
        }
        
        // Disconnect from current device
        disconnect()
        
        print("[PluginArchitectureManager] Shutdown complete")
    }
    
    // MARK: - Hot-Swapping
    
    /// Enable plugin hot-swapping
    /// When enabled, new plugins added to the plugins directory will be automatically loaded
    ///
    /// **Validates: Requirement 1.2**
    public func enableHotSwapping() {
        deviceRegistry.enableHotSwapping()
        print("[PluginArchitectureManager] Hot-swapping enabled")
    }
    
    /// Disable plugin hot-swapping
    public func disableHotSwapping() {
        deviceRegistry.disableHotSwapping()
        print("[PluginArchitectureManager] Hot-swapping disabled")
    }
    
    /// Check if hot-swapping is enabled
    public var isHotSwappingEnabled: Bool {
        return deviceRegistry.isHotSwappingEnabled
    }
    
    /// Get the plugins directory URL
    public var pluginsDirectory: URL? {
        return deviceRegistry.getPluginsDirectory()
    }
    
    // MARK: - Bluetooth State
    
    /// Update Bluetooth enabled state
    /// - Parameter enabled: Whether Bluetooth is enabled
    public func setBluetoothEnabled(_ enabled: Bool) {
        let wasEnabled = isBluetoothEnabled
        isBluetoothEnabled = enabled
        
        if !enabled && wasEnabled {
            // Bluetooth was disabled
            menuController?.showBluetoothDisabled()
            disconnect()
        } else if enabled && !wasEnabled {
            // Bluetooth was re-enabled
            menuController?.showDisconnected()
        }
    }
}


// MARK: - Device Connection

extension PluginArchitectureManager {
    
    /// Connect to a Bluetooth device using the plugin architecture
    /// - Parameter ioDevice: The IOBluetooth device to connect to
    /// - Returns: True if connection was initiated successfully
    ///
    /// This method:
    /// 1. Converts the IOBluetoothDevice to a BluetoothDevice
    /// 2. Finds a plugin that can handle the device
    /// 3. Connects using the ConnectionManager with retry logic
    /// 4. Updates the menu with device capabilities
    /// 5. Restores saved settings
    ///
    /// **Validates: Requirements 7.1, 7.2**
    @discardableResult
    public func connectToDevice(_ ioDevice: IOBluetoothDevice) async throws -> Bool {
        guard isBluetoothEnabled else {
            menuController?.showBluetoothDisabled()
            throw DeviceError.bluetoothDisabled
        }
        
        // Convert IOBluetoothDevice to BluetoothDevice
        let device = convertToBluetoothDevice(ioDevice)
        
        // Find a plugin that can handle this device
        guard let plugin = deviceRegistry.findPlugin(for: device) else {
            // No plugin found - show as unsupported device
            menuController?.showUnsupportedDevice(device)
            delegate?.pluginArchitecture(self, didEncounterError: .pluginNotFound)
            return false
        }
        
        print("[PluginArchitectureManager] Found plugin '\(plugin.displayName)' for device '\(device.name)'")
        
        // Connect using the connection manager
        do {
            _ = try await connectionManager.connect(to: device)
            
            // Update menu with device capabilities
            let capabilities = plugin.getCapabilityConfigs(for: device)
            let capabilitySet = DeviceCapabilitySet(configs: capabilities)
            menuController?.rebuildMenu(for: capabilitySet, deviceName: device.name)
            
            // Start periodic updates
            startPeriodicUpdates()
            
            // Notify delegate
            delegate?.pluginArchitecture(self, didConnectToDevice: device, withPlugin: plugin)
            
            print("[PluginArchitectureManager] Connected to '\(device.name)' with \(capabilities.count) capabilities")
            
            return true
        } catch {
            let deviceError = (error as? DeviceError) ?? .connectionFailed(error.localizedDescription)
            menuController?.showError(deviceError)
            delegate?.pluginArchitecture(self, didEncounterError: deviceError)
            throw error
        }
    }
    
    /// Connect to a device by address
    /// - Parameter address: The Bluetooth address of the device
    /// - Returns: True if connection was initiated successfully
    @discardableResult
    public func connectToDevice(address: String) async throws -> Bool {
        guard let ioDevice = IOBluetoothDevice(addressString: address) else {
            throw DeviceError.connectionFailed("Invalid device address")
        }
        return try await connectToDevice(ioDevice)
    }
    
    /// Disconnect from the current device
    public func disconnect() {
        stopPeriodicUpdates()
        connectionManager.disconnect()
        menuController?.showDisconnected()
        delegate?.pluginArchitectureDidDisconnect(self)
        print("[PluginArchitectureManager] Disconnected")
    }
    
    /// Scan for supported devices
    /// This initiates Bluetooth scanning for devices that match registered plugins
    public func startScanning() {
        connectionManager.startScanning()
        print("[PluginArchitectureManager] Started scanning for devices")
    }
    
    /// Stop scanning for devices
    public func stopScanning() {
        connectionManager.stopScanning()
        print("[PluginArchitectureManager] Stopped scanning")
    }
    
    /// Check if a device is supported by any registered plugin
    /// - Parameter device: The device to check
    /// - Returns: The plugin that can handle the device, or nil if unsupported
    public func findSupportedPlugin(for device: BluetoothDevice) -> DevicePlugin? {
        return deviceRegistry.findPlugin(for: device)
    }
    
    /// Convert IOBluetoothDevice to BluetoothDevice
    /// Extracts all available identification information from the IOBluetooth device
    internal func convertToBluetoothDevice(_ ioDevice: IOBluetoothDevice) -> BluetoothDevice {
        // Extract service UUIDs
        var serviceUUIDs: [String] = []
        if let services = ioDevice.services as? [IOBluetoothSDPServiceRecord] {
            for service in services {
                var handle: BluetoothSDPServiceRecordHandle = 0
                let result = service.getHandle(&handle)
                if result == kIOReturnSuccess {
                    serviceUUIDs.append(String(format: "%08X", handle))
                }
            }
        }
        
        // Extract vendor and product IDs from device name
        var vendorId: String? = nil
        var productId: String? = nil
        
        // Check if this is a Bose device by name
        if let name = ioDevice.name?.lowercased(), name.contains("bose") {
            vendorId = BoseConstants.vendorId
            // Try to determine product ID from name
            if name.contains("qc35 ii") || name.contains("qc35ii") {
                productId = BoseDeviceModel.qc35ii.productId
            } else if name.contains("qc35") {
                productId = BoseDeviceModel.qc35.productId
            } else if name.contains("qc45") {
                productId = BoseDeviceModel.qc45.productId
            } else if name.contains("nc 700") || name.contains("nc700") {
                productId = BoseDeviceModel.nc700.productId
            } else if name.contains("qc ultra") || name.contains("quietcomfort ultra") {
                productId = BoseDeviceModel.qcUltra.productId
            }
        }
        
        // Check if this is a Sony device by name
        if let name = ioDevice.name?.lowercased() {
            if name.contains("sony") || name.contains("wh-1000xm") || name.contains("wf-1000xm") {
                vendorId = SonyConstants.vendorId
                // Try to determine product ID from name
                if name.contains("wh-1000xm5") {
                    productId = SonyDeviceModel.wh1000xm5.productId
                } else if name.contains("wh-1000xm4") {
                    productId = SonyDeviceModel.wh1000xm4.productId
                } else if name.contains("wh-1000xm3") {
                    productId = SonyDeviceModel.wh1000xm3.productId
                } else if name.contains("wf-1000xm5") {
                    productId = SonyDeviceModel.wf1000xm5.productId
                } else if name.contains("wf-1000xm4") {
                    productId = SonyDeviceModel.wf1000xm4.productId
                }
            }
        }
        
        return BluetoothDevice(
            address: ioDevice.addressString ?? "",
            name: ioDevice.name ?? "Unknown Device",
            vendorId: vendorId,
            productId: productId,
            serviceUUIDs: serviceUUIDs,
            isConnected: ioDevice.isConnected(),
            rssi: nil,
            deviceClass: ioDevice.classOfDevice,
            manufacturerData: nil,
            advertisementData: nil
        )
    }
}


// MARK: - Device Operations

extension PluginArchitectureManager {
    
    /// Get battery level from the connected device
    /// - Returns: Battery level (0-100)
    /// - Throws: DeviceError if not connected or operation fails
    public func getBatteryLevel() async throws -> Int {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        return try await plugin.getBatteryLevel()
    }
    
    /// Get noise cancellation level from the connected device
    /// - Returns: The current noise cancellation level
    /// - Throws: DeviceError if not connected or operation fails
    public func getNoiseCancellation() async throws -> NoiseCancellationLevel {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        let value = try await plugin.getNoiseCancellation()
        let standardValue = plugin.convertNCToStandard(value)
        return NoiseCancellationLevel(rawValue: standardValue) ?? .off
    }
    
    /// Set noise cancellation level on the connected device
    /// - Parameter level: The noise cancellation level to set
    /// - Throws: DeviceError if not connected or operation fails
    public func setNoiseCancellation(_ level: NoiseCancellationLevel) async throws {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        try await plugin.setNoiseCancellation(level)
        
        // Save settings after change
        if let device = connectedDevice {
            try? await settingsStore.savePluginSettings(plugin, for: device)
        }
    }
    
    /// Get self-voice level from the connected device
    /// - Returns: The current self-voice level
    /// - Throws: DeviceError if not connected or operation fails
    public func getSelfVoice() async throws -> SelfVoiceLevel {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        let value = try await plugin.getSelfVoice()
        if let level = value as? SelfVoiceLevel {
            return level
        }
        throw DeviceError.invalidResponse
    }
    
    /// Set self-voice level on the connected device
    /// - Parameter level: The self-voice level to set
    /// - Throws: DeviceError if not connected or operation fails
    public func setSelfVoice(_ level: SelfVoiceLevel) async throws {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        try await plugin.setSelfVoice(level)
        
        // Save settings after change
        if let device = connectedDevice {
            try? await settingsStore.savePluginSettings(plugin, for: device)
        }
    }
    
    /// Get auto-off setting from the connected device
    /// - Returns: The current auto-off setting
    /// - Throws: DeviceError if not connected or operation fails
    public func getAutoOff() async throws -> AutoOffSetting {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        return try await plugin.getAutoOff()
    }
    
    /// Set auto-off setting on the connected device
    /// - Parameter setting: The auto-off setting to set
    /// - Throws: DeviceError if not connected or operation fails
    public func setAutoOff(_ setting: AutoOffSetting) async throws {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        try await plugin.setAutoOff(setting)
        
        // Save settings after change
        if let device = connectedDevice {
            try? await settingsStore.savePluginSettings(plugin, for: device)
        }
    }
    
    /// Get paired devices from the connected device
    /// - Returns: List of paired devices
    /// - Throws: DeviceError if not connected or operation fails
    public func getPairedDevices() async throws -> [PairedDevice] {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        return try await plugin.getPairedDevices()
    }
    
    /// Connect to a paired device
    /// - Parameter address: The address of the paired device to connect
    /// - Throws: DeviceError if not connected or operation fails
    public func connectPairedDevice(address: String) async throws {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        try await plugin.connectPairedDevice(address: address)
    }
    
    /// Disconnect a paired device
    /// - Parameter address: The address of the paired device to disconnect
    /// - Throws: DeviceError if not connected or operation fails
    public func disconnectPairedDevice(address: String) async throws {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        try await plugin.disconnectPairedDevice(address: address)
    }
    
    /// Get device info from the connected device
    /// - Returns: Dictionary of device information
    /// - Throws: DeviceError if not connected or operation fails
    public func getDeviceInfo() async throws -> [String: Any] {
        guard let plugin = activePlugin else {
            throw DeviceError.notConnected
        }
        return try await plugin.getDeviceInfo()
    }
    
    /// Update the menu with current device state
    /// This is called periodically to refresh battery level and other state
    public func updateMenuState() async {
        guard let plugin = activePlugin, let device = connectedDevice else {
            menuController?.showDisconnected()
            return
        }
        
        // Update battery level
        if let battery = try? await plugin.getBatteryLevel() {
            menuController?.updateBattery(level: battery)
        }
        
        // Update noise cancellation
        if let nc = try? await plugin.getNoiseCancellation() {
            let configs = plugin.getCapabilityConfigs(for: device)
            if let ncConfig = configs.first(where: { $0.capability == .noiseCancellation }) {
                menuController?.updateCapabilityValue(nc, for: .noiseCancellation, config: ncConfig)
            }
        }
        
        // Update self-voice
        if let sv = try? await plugin.getSelfVoice() {
            let configs = plugin.getCapabilityConfigs(for: device)
            if let svConfig = configs.first(where: { $0.capability == .selfVoice }) {
                menuController?.updateCapabilityValue(sv, for: .selfVoice, config: svConfig)
            }
        }
        
        // Update paired devices
        if let pairedDevices = try? await plugin.getPairedDevices() {
            menuController?.updatePairedDevices(pairedDevices)
        }
    }
    
    /// Force refresh all device state
    /// This performs a full refresh of all device information
    public func refreshDeviceState() async {
        await updateMenuState()
    }
}


// MARK: - ConnectionManagerDelegate

extension PluginArchitectureManager: ConnectionManagerDelegate {
    
    public func connectionManager(_ manager: ConnectionManager, didDiscover device: BluetoothDevice) {
        delegate?.pluginArchitecture(self, didDiscoverDevice: device)
    }
    
    public func connectionManager(_ manager: ConnectionManager, didConnect device: BluetoothDevice) {
        // Connection handled in connectToDevice method
        print("[PluginArchitectureManager] ConnectionManager reported connection to '\(device.name)'")
    }
    
    public func connectionManager(_ manager: ConnectionManager, didDisconnect device: BluetoothDevice) {
        stopPeriodicUpdates()
        menuController?.showDisconnected()
        delegate?.pluginArchitectureDidDisconnect(self)
        print("[PluginArchitectureManager] ConnectionManager reported disconnection from '\(device.name)'")
    }
    
    public func connectionManager(_ manager: ConnectionManager, didFailWith error: Error) {
        let deviceError = (error as? DeviceError) ?? .connectionFailed(error.localizedDescription)
        menuController?.showError(deviceError)
        delegate?.pluginArchitecture(self, didEncounterError: deviceError)
        print("[PluginArchitectureManager] ConnectionManager reported error: \(deviceError.localizedDescription)")
    }
    
    public func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState) {
        switch state {
        case .disconnected:
            stopPeriodicUpdates()
            menuController?.showDisconnected()
        case .connecting:
            // Could show a connecting indicator
            print("[PluginArchitectureManager] Connecting...")
        case .connected(let device, _):
            // Update menu with device info
            if let plugin = activePlugin {
                let capabilities = plugin.getCapabilityConfigs(for: device)
                let capabilitySet = DeviceCapabilitySet(configs: capabilities)
                menuController?.rebuildMenu(for: capabilitySet, deviceName: device.name)
            }
            print("[PluginArchitectureManager] Connected to '\(device.name)'")
        }
    }
}

// MARK: - PluginErrorHandlerDelegate

extension PluginArchitectureManager: PluginErrorHandlerDelegate {
    
    public func pluginErrorHandler(_ handler: PluginErrorHandler, pluginDidEncounterError pluginId: String, error: DeviceError) {
        // Show error to user if appropriate
        if error.shouldShowToUser {
            menuController?.showError(error)
        }
        
        // Notify delegate
        delegate?.pluginArchitecture(self, didEncounterError: error)
        
        print("[PluginArchitectureManager] Plugin '\(pluginId)' encountered error: \(error.localizedDescription)")
    }
    
    public func pluginErrorHandler(_ handler: PluginErrorHandler, pluginDidFail pluginId: String, error: DeviceError) {
        // Plugin failed unrecoverably - continue with reduced functionality
        menuController?.showError(error)
        delegate?.pluginArchitecture(self, didEncounterError: error)
        
        print("[PluginArchitectureManager] Plugin '\(pluginId)' failed unrecoverably: \(error.localizedDescription)")
        
        // If the failed plugin is the active one, disconnect
        if activePlugin?.pluginId == pluginId {
            disconnect()
        }
    }
}

// MARK: - PluginArchitectureManagerDelegate

/// Delegate protocol for receiving plugin architecture events
public protocol PluginArchitectureManagerDelegate: AnyObject {
    /// Called when the plugin architecture has been initialized
    func pluginArchitectureDidInitialize(_ manager: PluginArchitectureManager, loadedPlugins: Int)
    
    /// Called when a device is discovered
    func pluginArchitecture(_ manager: PluginArchitectureManager, didDiscoverDevice device: BluetoothDevice)
    
    /// Called when connected to a device
    func pluginArchitecture(_ manager: PluginArchitectureManager, didConnectToDevice device: BluetoothDevice, withPlugin plugin: DevicePlugin)
    
    /// Called when disconnected from a device
    func pluginArchitectureDidDisconnect(_ manager: PluginArchitectureManager)
    
    /// Called when an error occurs
    func pluginArchitecture(_ manager: PluginArchitectureManager, didEncounterError error: DeviceError)
}

/// Default implementations for optional delegate methods
public extension PluginArchitectureManagerDelegate {
    func pluginArchitectureDidInitialize(_ manager: PluginArchitectureManager, loadedPlugins: Int) {}
    func pluginArchitecture(_ manager: PluginArchitectureManager, didDiscoverDevice device: BluetoothDevice) {}
    func pluginArchitecture(_ manager: PluginArchitectureManager, didConnectToDevice device: BluetoothDevice, withPlugin plugin: DevicePlugin) {}
    func pluginArchitectureDidDisconnect(_ manager: PluginArchitectureManager) {}
    func pluginArchitecture(_ manager: PluginArchitectureManager, didEncounterError error: DeviceError) {}
}
