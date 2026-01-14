import XCTest
@testable import SoundSherpa

/// Integration tests for the plugin architecture
/// Tests end-to-end device connection flow, device switching, and plugin lifecycle
///
/// **Validates: Requirements 1.2, 7.1, 7.2**
final class PluginArchitectureIntegrationTests: XCTestCase {
    
    var registry: DeviceRegistry!
    var connectionManager: ConnectionManager!
    var settingsStore: SettingsStore!
    var channelFactory: CommunicationChannelFactory!
    
    override func setUp() {
        super.setUp()
        
        // Create a temporary directory for plugins
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        registry = DeviceRegistry(pluginsDirectory: tempDir)
        channelFactory = CommunicationChannelFactory()
        settingsStore = SettingsStore()
        connectionManager = ConnectionManager(
            registry: registry,
            channelFactory: channelFactory,
            settingsStore: settingsStore,
            maxRetryAttempts: 3,
            baseRetryDelay: 0.1,
            maxRetryDelay: 0.5
        )
    }
    
    override func tearDown() {
        registry.disableHotSwapping()
        registry = nil
        connectionManager = nil
        settingsStore = nil
        channelFactory = nil
        super.tearDown()
    }
    
    // MARK: - End-to-End Device Connection Flow Tests
    
    /// Test that a device can be connected through the full plugin architecture
    func testEndToEndDeviceConnectionFlow() async throws {
        // Register a mock plugin
        let bosePlugin = MockDevicePlugin(
            pluginId: "com.test.bose",
            displayName: "Bose Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", productId: "0x4002", confidenceScore: 95)
            ]
        )
        bosePlugin.mockConfidenceScore = 95
        
        try registry.register(plugin: bosePlugin)
        
        // Create a test device
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        // Find plugin for device
        let foundPlugin = registry.findPlugin(for: device)
        XCTAssertNotNil(foundPlugin)
        XCTAssertEqual(foundPlugin?.pluginId, "com.test.bose")
        
        // Activate plugin
        registry.activatePlugin(foundPlugin!, for: device)
        
        // Verify active plugin
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.bose")
        XCTAssertEqual(registry.getActiveDevice()?.address, device.address)
    }
    
    /// Test that plugin discovery loads built-in plugins
    func testPluginDiscoveryLoadsBuiltInPlugins() throws {
        // Register built-in plugin factories
        registry.registerBuiltInPluginFactory {
            MockDevicePlugin(
                pluginId: "com.test.builtin1",
                displayName: "Built-in Plugin 1",
                supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
            )
        }
        
        registry.registerBuiltInPluginFactory {
            MockDevicePlugin(
                pluginId: "com.test.builtin2",
                displayName: "Built-in Plugin 2",
                supportedDevices: [DeviceIdentifier(vendorId: "0x0002", confidenceScore: 80)]
            )
        }
        
        // Discover and load plugins
        let result = try registry.discoverAndLoadPlugins()
        
        XCTAssertEqual(result.loadedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(registry.pluginCount, 2)
        XCTAssertTrue(registry.hasPlugin(withId: "com.test.builtin1"))
        XCTAssertTrue(registry.hasPlugin(withId: "com.test.builtin2"))
    }
    
    // MARK: - Device Switching Tests
    
    /// Test switching between devices of different brands
    func testDeviceSwitchingBetweenBrands() throws {
        // Create test devices
        let boseDevice = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E"
        )
        
        let sonyDevice = BluetoothDevice(
            address: "00:18:09:00:00:01",
            name: "Sony WH-1000XM4",
            vendorId: "0x054C"
        )
        
        // Register Bose plugin that only matches Bose devices
        let bosePlugin = MockDevicePlugin(
            pluginId: "com.test.bose",
            displayName: "Bose Plugin",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 95)]
        )
        
        // Register Sony plugin that only matches Sony devices
        let sonyPlugin = MockDevicePlugin(
            pluginId: "com.test.sony",
            displayName: "Sony Plugin",
            supportedDevices: [DeviceIdentifier(vendorId: "0x054C", confidenceScore: 95)]
        )
        
        try registry.register(plugin: bosePlugin)
        try registry.register(plugin: sonyPlugin)
        
        // Connect to Bose device - set mock score for Bose plugin
        bosePlugin.mockConfidenceScore = 95
        sonyPlugin.mockConfidenceScore = nil
        
        let boseFoundPlugin = registry.findPlugin(for: boseDevice)
        XCTAssertEqual(boseFoundPlugin?.pluginId, "com.test.bose")
        registry.activatePlugin(boseFoundPlugin!, for: boseDevice)
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.bose")
        
        // Switch to Sony device - update mock scores
        bosePlugin.mockConfidenceScore = nil
        sonyPlugin.mockConfidenceScore = 95
        
        let sonyFoundPlugin = registry.findPlugin(for: sonyDevice)
        XCTAssertEqual(sonyFoundPlugin?.pluginId, "com.test.sony")
        registry.activatePlugin(sonyFoundPlugin!, for: sonyDevice)
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.sony")
        XCTAssertEqual(registry.getActiveDevice()?.address, sonyDevice.address)
    }
    
    /// Test switching between different models of the same brand
    func testDeviceSwitchingBetweenModels() throws {
        // Create test devices
        let qc35Device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35",
            vendorId: "0x009E",
            productId: "0x4001"
        )
        
        let qc35iiDevice = BluetoothDevice(
            address: "04:52:C7:00:00:02",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        // Register model-specific plugins
        let qc35Plugin = MockDevicePlugin(
            pluginId: "com.test.bose.qc35",
            displayName: "Bose QC35",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", productId: "0x4001", confidenceScore: 95)]
        )
        
        let qc35iiPlugin = MockDevicePlugin(
            pluginId: "com.test.bose.qc35ii",
            displayName: "Bose QC35 II",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", productId: "0x4002", confidenceScore: 95)]
        )
        
        try registry.register(plugin: qc35Plugin)
        try registry.register(plugin: qc35iiPlugin)
        
        // Connect to QC35 - set mock scores
        qc35Plugin.mockConfidenceScore = 95
        qc35iiPlugin.mockConfidenceScore = nil
        
        let qc35FoundPlugin = registry.findPlugin(for: qc35Device)
        XCTAssertEqual(qc35FoundPlugin?.pluginId, "com.test.bose.qc35")
        registry.activatePlugin(qc35FoundPlugin!, for: qc35Device)
        
        // Switch to QC35 II - update mock scores
        qc35Plugin.mockConfidenceScore = nil
        qc35iiPlugin.mockConfidenceScore = 95
        
        let qc35iiFoundPlugin = registry.findPlugin(for: qc35iiDevice)
        XCTAssertEqual(qc35iiFoundPlugin?.pluginId, "com.test.bose.qc35ii")
        registry.activatePlugin(qc35iiFoundPlugin!, for: qc35iiDevice)
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.bose.qc35ii")
    }
    
    // MARK: - Plugin Lifecycle Tests
    
    /// Test plugin registration and unregistration
    func testPluginRegistrationAndUnregistration() throws {
        let plugin = MockDevicePlugin(
            pluginId: "com.test.lifecycle",
            displayName: "Lifecycle Test Plugin",
            supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
        )
        
        // Register plugin
        try registry.register(plugin: plugin)
        XCTAssertTrue(registry.hasPlugin(withId: "com.test.lifecycle"))
        XCTAssertEqual(registry.pluginCount, 1)
        
        // Unregister plugin
        registry.unregister(pluginId: "com.test.lifecycle")
        XCTAssertFalse(registry.hasPlugin(withId: "com.test.lifecycle"))
        XCTAssertEqual(registry.pluginCount, 0)
    }
    
    /// Test that unregistering active plugin deactivates it
    func testUnregisteringActivePluginDeactivatesIt() throws {
        let plugin = MockDevicePlugin(
            pluginId: "com.test.active",
            displayName: "Active Plugin",
            supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
        )
        plugin.mockConfidenceScore = 80
        
        try registry.register(plugin: plugin)
        
        let device = BluetoothDevice(
            address: "00:00:00:00:00:01",
            name: "Test Device",
            vendorId: "0x0001"
        )
        
        // Activate plugin
        registry.activatePlugin(plugin, for: device)
        XCTAssertNotNil(registry.getActivePlugin())
        
        // Unregister active plugin
        registry.unregister(pluginId: "com.test.active")
        
        // Verify plugin is deactivated
        XCTAssertNil(registry.getActivePlugin())
        XCTAssertNil(registry.getActiveDevice())
    }
    
    /// Test plugin reload preserves active plugin if still available
    func testPluginReloadPreservesActivePlugin() throws {
        // Register built-in plugin factory
        registry.registerBuiltInPluginFactory {
            let plugin = MockDevicePlugin(
                pluginId: "com.test.persistent",
                displayName: "Persistent Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
            )
            plugin.mockConfidenceScore = 80
            return plugin
        }
        
        // Initial discovery
        try registry.discoverAndLoadPlugins()
        
        let device = BluetoothDevice(
            address: "00:00:00:00:00:01",
            name: "Test Device",
            vendorId: "0x0001"
        )
        
        // Activate plugin
        let plugin = registry.findPlugin(for: device)!
        registry.activatePlugin(plugin, for: device)
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.persistent")
        
        // Reload plugins
        try registry.reloadPlugins()
        
        // Verify active plugin is restored
        XCTAssertEqual(registry.getActivePlugin()?.pluginId, "com.test.persistent")
    }
    
    // MARK: - Hot-Swapping Tests
    
    /// Test enabling and disabling hot-swapping
    func testHotSwappingEnableDisable() {
        XCTAssertFalse(registry.isHotSwappingEnabled)
        
        registry.enableHotSwapping()
        XCTAssertTrue(registry.isHotSwappingEnabled)
        
        registry.disableHotSwapping()
        XCTAssertFalse(registry.isHotSwappingEnabled)
    }
    
    /// Test that hot-swapping can be enabled multiple times safely
    func testHotSwappingMultipleEnables() {
        registry.enableHotSwapping()
        XCTAssertTrue(registry.isHotSwappingEnabled)
        
        // Enable again - should be safe
        registry.enableHotSwapping()
        XCTAssertTrue(registry.isHotSwappingEnabled)
        
        registry.disableHotSwapping()
        XCTAssertFalse(registry.isHotSwappingEnabled)
    }
    
    /// Test that plugins directory is accessible
    func testPluginsDirectoryAccessible() {
        let directory = registry.getPluginsDirectory()
        XCTAssertNotNil(directory)
    }
    
    // MARK: - Delegate Tests
    
    /// Test that delegate receives plugin load events
    func testDelegateReceivesPluginLoadEvents() throws {
        let delegate = MockRegistryDelegate()
        registry.delegate = delegate
        
        registry.registerBuiltInPluginFactory {
            MockDevicePlugin(
                pluginId: "com.test.delegate",
                displayName: "Delegate Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
            )
        }
        
        try registry.discoverAndLoadPlugins()
        
        XCTAssertEqual(delegate.loadedPlugins.count, 1)
        XCTAssertEqual(delegate.loadedPlugins.first?.pluginId, "com.test.delegate")
        XCTAssertTrue(delegate.discoveryCompleted)
        XCTAssertEqual(delegate.discoveryLoadedCount, 1)
        XCTAssertEqual(delegate.discoveryFailedCount, 0)
    }
    
    // MARK: - Error Handling Tests
    
    /// Test that duplicate plugin registration fails
    func testDuplicatePluginRegistrationFails() throws {
        let plugin1 = MockDevicePlugin(
            pluginId: "com.test.duplicate",
            displayName: "Plugin 1",
            supportedDevices: [DeviceIdentifier(vendorId: "0x0001", confidenceScore: 80)]
        )
        
        let plugin2 = MockDevicePlugin(
            pluginId: "com.test.duplicate",
            displayName: "Plugin 2",
            supportedDevices: [DeviceIdentifier(vendorId: "0x0002", confidenceScore: 80)]
        )
        
        try registry.register(plugin: plugin1)
        
        XCTAssertThrowsError(try registry.register(plugin: plugin2)) { error in
            guard case DeviceError.registrationFailed = error else {
                XCTFail("Expected registrationFailed error")
                return
            }
        }
    }
    
    /// Test that invalid plugin registration fails validation
    func testInvalidPluginRegistrationFails() {
        let invalidPlugin = InvalidMockPlugin()
        
        XCTAssertThrowsError(try registry.register(plugin: invalidPlugin)) { error in
            guard case DeviceError.pluginValidationFailed = error else {
                XCTFail("Expected pluginValidationFailed error")
                return
            }
        }
    }
}

// MARK: - Mock Delegate

/// Mock delegate for testing registry events
class MockRegistryDelegate: DeviceRegistryDelegate {
    var loadedPlugins: [DevicePlugin] = []
    var failedURLs: [(URL, Error)] = []
    var discoveryCompleted = false
    var discoveryLoadedCount = 0
    var discoveryFailedCount = 0
    var hotLoadedPlugins: [DevicePlugin] = []
    var hotUnloadedPluginIds: [String] = []
    
    func registry(_ registry: DeviceRegistry, didLoadPlugin plugin: DevicePlugin) {
        loadedPlugins.append(plugin)
    }
    
    func registry(_ registry: DeviceRegistry, didFailToLoadPluginAt url: URL, error: Error) {
        failedURLs.append((url, error))
    }
    
    func registryDidCompleteDiscovery(_ registry: DeviceRegistry, loadedCount: Int, failedCount: Int) {
        discoveryCompleted = true
        discoveryLoadedCount = loadedCount
        discoveryFailedCount = failedCount
    }
    
    func registry(_ registry: DeviceRegistry, didHotLoadPlugin plugin: DevicePlugin) {
        hotLoadedPlugins.append(plugin)
    }
    
    func registry(_ registry: DeviceRegistry, didHotUnloadPluginId pluginId: String) {
        hotUnloadedPluginIds.append(pluginId)
    }
}
