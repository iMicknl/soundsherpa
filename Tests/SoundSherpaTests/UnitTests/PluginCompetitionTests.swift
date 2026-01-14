import XCTest
@testable import SoundSherpa

/// Unit tests for plugin competition scenarios
/// Tests scenarios where multiple plugins claim the same device
/// **Validates: Requirements 2.3**
final class PluginCompetitionTests: XCTestCase {
    
    var registry: DeviceRegistry!
    
    override func setUp() {
        super.setUp()
        registry = DeviceRegistry()
    }
    
    override func tearDown() {
        registry = nil
        super.tearDown()
    }
    
    // MARK: - Plugin Competition Tests
    
    /// Test that when multiple plugins match a device, the one with highest confidence wins
    func testHighestConfidencePluginWins() throws {
        // Create a device that matches multiple plugins
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        // Low confidence plugin (matches by name only)
        let lowPlugin = MockDevicePlugin(
            pluginId: "com.test.low",
            displayName: "Low Confidence",
            supportedDevices: [
                DeviceIdentifier(namePattern: "Bose.*", confidenceScore: 55)
            ]
        )
        lowPlugin.mockConfidenceScore = 55
        
        // Medium confidence plugin (matches by vendor ID)
        let mediumPlugin = MockDevicePlugin(
            pluginId: "com.test.medium",
            displayName: "Medium Confidence",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 75)
            ]
        )
        mediumPlugin.mockConfidenceScore = 75
        
        // High confidence plugin (matches by vendor + product ID)
        let highPlugin = MockDevicePlugin(
            pluginId: "com.test.high",
            displayName: "High Confidence",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", productId: "0x4002", confidenceScore: 95)
            ]
        )
        highPlugin.mockConfidenceScore = 95
        
        // Register in random order
        try registry.register(plugin: mediumPlugin)
        try registry.register(plugin: highPlugin)
        try registry.register(plugin: lowPlugin)
        
        // Find best plugin
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.high")
    }
    
    /// Test tie-breaking when plugins have equal confidence scores
    func testTieBreakingWithEqualScores() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Test Device",
            vendorId: "0x009E"
        )
        
        // Two plugins with same confidence score
        let plugin1 = MockDevicePlugin(
            pluginId: "com.test.first",
            displayName: "First Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)
            ]
        )
        plugin1.mockConfidenceScore = 80
        
        let plugin2 = MockDevicePlugin(
            pluginId: "com.test.second",
            displayName: "Second Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)
            ]
        )
        plugin2.mockConfidenceScore = 80
        
        // Register in order
        try registry.register(plugin: plugin1)
        try registry.register(plugin: plugin2)
        
        // Find best plugin - first registered should win in tie
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        // First registered plugin should win in a tie
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.first")
    }
    
    /// Test that plugins returning nil are not considered
    func testPluginsReturningNilAreIgnored() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Sony WH-1000XM4",
            vendorId: "0x054C",
            productId: "0x0CD3"
        )
        
        // Bose plugin that doesn't match Sony device
        let bosePlugin = MockDevicePlugin(
            pluginId: "com.test.bose",
            displayName: "Bose Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 95)
            ]
        )
        bosePlugin.mockConfidenceScore = nil  // Doesn't match
        
        // Sony plugin that matches
        let sonyPlugin = MockDevicePlugin(
            pluginId: "com.test.sony",
            displayName: "Sony Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x054C", productId: "0x0CD3", confidenceScore: 95)
            ]
        )
        sonyPlugin.mockConfidenceScore = 95
        
        try registry.register(plugin: bosePlugin)
        try registry.register(plugin: sonyPlugin)
        
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.sony")
    }
    
    /// Test that no plugin is returned when none match
    func testNoPluginWhenNoneMatch() throws {
        let device = BluetoothDevice(
            address: "00:00:00:00:00:01",
            name: "Unknown Device",
            vendorId: "0x0001"
        )
        
        // Plugin that doesn't match
        let plugin = MockDevicePlugin(
            pluginId: "com.test.bose",
            displayName: "Bose Plugin",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 95)
            ]
        )
        plugin.mockConfidenceScore = nil
        
        try registry.register(plugin: plugin)
        
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNil(bestPlugin)
    }
    
    /// Test findAllMatchingPlugins returns all matches sorted by score
    func testFindAllMatchingPluginsSortedByScore() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        let plugin60 = MockDevicePlugin(
            pluginId: "com.test.60",
            displayName: "Score 60",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 60)]
        )
        plugin60.mockConfidenceScore = 60
        
        let plugin90 = MockDevicePlugin(
            pluginId: "com.test.90",
            displayName: "Score 90",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 90)]
        )
        plugin90.mockConfidenceScore = 90
        
        let plugin75 = MockDevicePlugin(
            pluginId: "com.test.75",
            displayName: "Score 75",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 75)]
        )
        plugin75.mockConfidenceScore = 75
        
        let pluginNoMatch = MockDevicePlugin(
            pluginId: "com.test.nomatch",
            displayName: "No Match",
            supportedDevices: [DeviceIdentifier(vendorId: "0x054C", confidenceScore: 95)]
        )
        pluginNoMatch.mockConfidenceScore = nil
        
        try registry.register(plugin: plugin60)
        try registry.register(plugin: plugin90)
        try registry.register(plugin: plugin75)
        try registry.register(plugin: pluginNoMatch)
        
        let matches = registry.findAllMatchingPlugins(for: device)
        
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches[0].plugin.pluginId, "com.test.90")
        XCTAssertEqual(matches[0].score, 90)
        XCTAssertEqual(matches[1].plugin.pluginId, "com.test.75")
        XCTAssertEqual(matches[1].score, 75)
        XCTAssertEqual(matches[2].plugin.pluginId, "com.test.60")
        XCTAssertEqual(matches[2].score, 60)
    }
    
    /// Test competition with close confidence scores
    func testCompetitionWithCloseScores() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        // Plugins with very close scores
        let plugin94 = MockDevicePlugin(
            pluginId: "com.test.94",
            displayName: "Score 94",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 94)]
        )
        plugin94.mockConfidenceScore = 94
        
        let plugin95 = MockDevicePlugin(
            pluginId: "com.test.95",
            displayName: "Score 95",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 95)]
        )
        plugin95.mockConfidenceScore = 95
        
        let plugin93 = MockDevicePlugin(
            pluginId: "com.test.93",
            displayName: "Score 93",
            supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 93)]
        )
        plugin93.mockConfidenceScore = 93
        
        try registry.register(plugin: plugin94)
        try registry.register(plugin: plugin95)
        try registry.register(plugin: plugin93)
        
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.95")
    }
    
    /// Test that brand-specific plugins beat generic plugins
    func testBrandSpecificBeatsGeneric() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        // Generic audio plugin (matches any audio device)
        let genericPlugin = MockDevicePlugin(
            pluginId: "com.test.generic",
            displayName: "Generic Audio",
            supportedDevices: [
                DeviceIdentifier(
                    serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
                    confidenceScore: 60
                )
            ]
        )
        genericPlugin.mockConfidenceScore = 60
        
        // Bose-specific plugin
        let bosePlugin = MockDevicePlugin(
            pluginId: "com.test.bose",
            displayName: "Bose Plugin",
            supportedDevices: [
                DeviceIdentifier(
                    vendorId: "0x009E",
                    productId: "0x4002",
                    serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
                    confidenceScore: 95
                )
            ]
        )
        bosePlugin.mockConfidenceScore = 95
        
        try registry.register(plugin: genericPlugin)
        try registry.register(plugin: bosePlugin)
        
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.bose")
    }
    
    /// Test model-specific plugin beats brand-generic plugin
    func testModelSpecificBeatsBrandGeneric() throws {
        let device = BluetoothDevice(
            address: "04:52:C7:00:00:01",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        // Generic Bose plugin (matches any Bose device)
        let genericBosePlugin = MockDevicePlugin(
            pluginId: "com.test.bose.generic",
            displayName: "Generic Bose",
            supportedDevices: [
                DeviceIdentifier(vendorId: "0x009E", confidenceScore: 75)
            ]
        )
        genericBosePlugin.mockConfidenceScore = 75
        
        // QC35 II specific plugin
        let qc35iiPlugin = MockDevicePlugin(
            pluginId: "com.test.bose.qc35ii",
            displayName: "Bose QC35 II",
            supportedDevices: [
                DeviceIdentifier(
                    vendorId: "0x009E",
                    productId: "0x4002",
                    confidenceScore: 95
                )
            ]
        )
        qc35iiPlugin.mockConfidenceScore = 95
        
        try registry.register(plugin: genericBosePlugin)
        try registry.register(plugin: qc35iiPlugin)
        
        let bestPlugin = registry.findPlugin(for: device)
        
        XCTAssertNotNil(bestPlugin)
        XCTAssertEqual(bestPlugin?.pluginId, "com.test.bose.qc35ii")
    }
}
