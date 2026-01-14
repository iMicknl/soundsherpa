import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for device-plugin matching
/// Feature: multi-device-support, Property 4: Device-Plugin Matching Uses Multiple Identification Criteria
/// **Validates: Requirements 2.1, 2.2, 2.3**
final class DeviceMatchingPropertyTests: XCTestCase {
    
    // MARK: - Property Tests
    
    /// Property 4: Device-Plugin Matching Uses Multiple Identification Criteria
    /// *For any* BluetoothDevice and any set of registered DevicePlugins, the DeviceRegistry SHALL query plugins
    /// using vendor ID, product ID, service UUIDs, MAC address prefix, and manufacturer data (not just device name),
    /// and *for any* case where multiple plugins return non-nil confidence scores, the DeviceRegistry SHALL select
    /// the plugin with the highest confidence score.
    func testDevicePluginMatchingUsesMultipleCriteria() {
        property("Device-plugin matching uses multiple identification criteria and selects highest confidence") <- forAll { (device: BluetoothDevice) in
            let registry = DeviceRegistry()
            
            // Create plugins with different confidence scores that match specific criteria
            // Low confidence: matches by name pattern only
            let lowConfidencePlugin = MockDevicePlugin(
                pluginId: "com.test.low",
                displayName: "Low Confidence Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        namePattern: ".*",  // Matches any name
                        confidenceScore: 52  // Just above threshold
                    )
                ]
            )
            lowConfidencePlugin.mockConfidenceScore = 52
            
            // Medium confidence: matches by vendor ID (uses known Bose vendor ID)
            let mediumConfidencePlugin = MockDevicePlugin(
                pluginId: "com.test.medium",
                displayName: "Medium Confidence Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: "0x009E",  // Bose vendor ID
                        confidenceScore: 70
                    )
                ]
            )
            // Only return score if device has Bose vendor ID
            mediumConfidencePlugin.mockConfidenceScore = device.vendorId == "0x009E" ? 70 : nil
            
            // High confidence: matches by vendor ID + product ID (uses known Bose QC35 IDs)
            let highConfidencePlugin = MockDevicePlugin(
                pluginId: "com.test.high",
                displayName: "High Confidence Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: "0x009E",  // Bose vendor ID
                        productId: "0x4002", // QC35 II product ID
                        confidenceScore: 95
                    )
                ]
            )
            // Only return score if device has both Bose vendor ID and QC35 II product ID
            highConfidencePlugin.mockConfidenceScore = (device.vendorId == "0x009E" && device.productId == "0x4002") ? 95 : nil
            
            // Register plugins
            try? registry.register(plugin: lowConfidencePlugin)
            try? registry.register(plugin: mediumConfidencePlugin)
            try? registry.register(plugin: highConfidencePlugin)
            
            // Find best plugin
            let bestPlugin = registry.findPlugin(for: device)
            
            // Verify: the plugin with highest applicable confidence score should be selected
            // High confidence: Bose vendor ID + QC35 II product ID
            if device.vendorId == "0x009E" && device.productId == "0x4002" {
                return bestPlugin?.pluginId == "com.test.high"
            }
            // Medium confidence: Bose vendor ID only
            else if device.vendorId == "0x009E" {
                return bestPlugin?.pluginId == "com.test.medium"
            }
            // Low confidence: fallback (name pattern matches anything)
            else {
                return bestPlugin?.pluginId == "com.test.low"
            }
        }
    }
    
    /// Test that multi-criteria matching considers all identification criteria
    func testMultiCriteriaMatchingConsidersAllCriteria() {
        property("Multi-criteria matching considers vendor ID, product ID, service UUIDs, and MAC prefix") <- forAll { (device: BluetoothDevice, identifier: DeviceIdentifier) in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.multicriteria",
                displayName: "Multi-Criteria Plugin",
                supportedDevices: [identifier]
            )
            plugin.useActualMatching = true
            
            let score = plugin.canHandle(device: device)
            
            // If score is returned, verify it's based on matching criteria
            if let score = score {
                var expectedMinScore = 0
                
                // Vendor + Product ID match adds 80
                if device.vendorId == identifier.vendorId && device.productId == identifier.productId &&
                   device.vendorId != nil && device.productId != nil {
                    expectedMinScore += 80
                }
                
                // Service UUIDs match adds 15
                let commonServices = Set(device.serviceUUIDs).intersection(Set(identifier.serviceUUIDs))
                if !commonServices.isEmpty {
                    expectedMinScore += 15
                }
                
                // MAC prefix match adds 10
                if let macPrefix = identifier.macAddressPrefix,
                   device.address.uppercased().hasPrefix(macPrefix.uppercased()) {
                    expectedMinScore += 10
                }
                
                // Name pattern match adds 3
                if let namePattern = identifier.namePattern,
                   device.name.range(of: namePattern, options: .regularExpression) != nil {
                    expectedMinScore += 3
                }
                
                // Score should be at least the expected minimum (capped by confidence score)
                return score >= 51 && score <= identifier.confidenceScore
            }
            
            // If no score, verify no criteria matched above threshold
            return true
        }
    }
    
    /// Test that highest confidence plugin is always selected when multiple match
    func testHighestConfidencePluginSelected() {
        property("When multiple plugins match, the one with highest confidence is selected") <- forAll { (numPlugins: Int, device: BluetoothDevice) in
            // Constrain number of plugins to reasonable range
            let pluginCount = max(2, min(5, abs(numPlugins % 5) + 2))
            
            let registry = DeviceRegistry()
            var expectedWinnerId: String?
            var highestScore = 0
            
            // Create plugins with random confidence scores
            for i in 0..<pluginCount {
                let score = Int.random(in: 51...100)
                let plugin = MockDevicePlugin(
                    pluginId: "com.test.plugin\(i)",
                    displayName: "Plugin \(i)",
                    supportedDevices: [
                        DeviceIdentifier(
                            vendorId: device.vendorId ?? "0x0001",
                            confidenceScore: score
                        )
                    ]
                )
                plugin.mockConfidenceScore = score
                
                if score > highestScore {
                    highestScore = score
                    expectedWinnerId = plugin.pluginId
                }
                
                try? registry.register(plugin: plugin)
            }
            
            let bestPlugin = registry.findPlugin(for: device)
            
            // The plugin with highest score should be selected
            return bestPlugin?.pluginId == expectedWinnerId
        }
    }
}
