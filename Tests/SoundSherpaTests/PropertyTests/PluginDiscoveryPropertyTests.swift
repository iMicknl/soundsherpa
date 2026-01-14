import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for plugin discovery and registration
/// Feature: multi-device-support, Property 1: Plugin Discovery and Loading
/// Feature: multi-device-support, Property 3: Plugin Interface Validation
/// **Validates: Requirements 1.1, 1.4**
final class PluginDiscoveryPropertyTests: XCTestCase {
    
    // MARK: - Generators
    
    /// Generate valid plugin IDs
    static let validPluginIdGen: Gen<String> = Gen<String>.compose { c in
        let prefix = c.generate(using: Gen<String>.fromElements(of: ["com", "org", "io"]))
        let company = c.generate(using: Gen<String>.fromElements(of: ["test", "example", "acme", "widget"]))
        let name = c.generate(using: Gen<String>.fromElements(of: ["plugin", "device", "headphones", "audio"]))
        let suffix = c.generate(using: Gen<Int>.choose((1, 999)))
        return "\(prefix).\(company).\(name)\(suffix)"
    }
    
    /// Generate valid display names
    static let validDisplayNameGen: Gen<String> = Gen<String>.compose { c in
        let brand = c.generate(using: Gen<String>.fromElements(of: ["Bose", "Sony", "Sennheiser", "JBL", "Beats"]))
        let type = c.generate(using: Gen<String>.fromElements(of: ["Plugin", "Driver", "Handler", "Support"]))
        return "\(brand) \(type)"
    }
    
    /// Generate valid channel types
    static let validChannelTypesGen: Gen<[String]> = Gen<[String]>.frequency([
        (3, Gen.pure(["RFCOMM"])),
        (2, Gen.pure(["BLE"])),
        (2, Gen.pure(["RFCOMM", "BLE"]))
    ])
    
    // MARK: - Property Tests
    
    /// Property 1: Plugin Discovery and Loading
    /// *For any* plugins directory containing N valid plugin files, the DeviceRegistry SHALL discover
    /// and load exactly N plugins at application startup.
    func testPluginDiscoveryLoadsAllValidPlugins() {
        property("Registry loads exactly N plugins when N valid plugins are registered") <- forAll(Gen<Int>.choose((1, 10))) { numPlugins in
            let registry = DeviceRegistry()
            
            // Register N valid plugins
            for i in 0..<numPlugins {
                let plugin = MockDevicePlugin(
                    pluginId: "com.test.plugin\(i)",
                    displayName: "Test Plugin \(i)",
                    supportedDevices: [
                        DeviceIdentifier(
                            vendorId: "0x000\(i)",
                            confidenceScore: 80
                        )
                    ],
                    supportedChannelTypes: ["RFCOMM"]
                )
                try? registry.register(plugin: plugin)
            }
            
            // Verify exactly N plugins are registered
            return registry.pluginCount == numPlugins
        }
    }
    
    /// Test that valid plugins with unique IDs are all registered
    func testValidPluginsWithUniqueIdsAreRegistered() {
        property("All valid plugins with unique IDs are successfully registered") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen,
            PluginDiscoveryPropertyTests.validDisplayNameGen,
            PluginDiscoveryPropertyTests.validChannelTypesGen
        ) { pluginId, displayName, channelTypes in
            let registry = DeviceRegistry()
            
            // Create a valid identifier
            let identifier = DeviceIdentifier(
                vendorId: "0x009E",
                productId: "0x4001",
                serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
                confidenceScore: 80
            )
            
            let plugin = MockDevicePlugin(
                pluginId: pluginId,
                displayName: displayName,
                supportedDevices: [identifier],
                supportedChannelTypes: channelTypes
            )
            
            do {
                try registry.register(plugin: plugin)
                return registry.pluginCount == 1 && registry.getAllPlugins().first?.pluginId == pluginId
            } catch {
                return false
            }
        }
    }
    
    /// Property 3: Plugin Interface Validation
    /// *For any* DevicePlugin submitted for registration, if the plugin does not implement all required
    /// protocol methods, the DeviceRegistry SHALL reject the registration and return an error.
    func testPluginValidationRejectsInvalidPlugins() {
        // Test empty plugin ID
        property("Plugins with empty pluginId are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validDisplayNameGen
        ) { displayName in
            let registry = DeviceRegistry()
            
            let identifier = DeviceIdentifier(
                vendorId: "0x009E",
                confidenceScore: 80
            )
            
            let plugin = MockDevicePlugin(
                pluginId: "",  // Invalid: empty
                displayName: displayName,
                supportedDevices: [identifier],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            do {
                try registry.register(plugin: plugin)
                return false  // Should have thrown
            } catch DeviceError.pluginValidationFailed(let reason) {
                return reason.contains("Plugin ID")
            } catch {
                return false
            }
        }
    }
    
    /// Test that plugins with empty display name are rejected
    func testPluginValidationRejectsEmptyDisplayName() {
        property("Plugins with empty displayName are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen
        ) { pluginId in
            let registry = DeviceRegistry()
            
            let identifier = DeviceIdentifier(
                vendorId: "0x009E",
                confidenceScore: 80
            )
            
            let plugin = MockDevicePlugin(
                pluginId: pluginId,
                displayName: "",  // Invalid: empty
                supportedDevices: [identifier],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            do {
                try registry.register(plugin: plugin)
                return false  // Should have thrown
            } catch DeviceError.pluginValidationFailed(let reason) {
                return reason.contains("display name")
            } catch {
                return false
            }
        }
    }
    
    /// Test that plugins with no supported devices are rejected
    func testPluginValidationRejectsNoSupportedDevices() {
        property("Plugins with no supported devices are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen,
            PluginDiscoveryPropertyTests.validDisplayNameGen
        ) { pluginId, displayName in
            let registry = DeviceRegistry()
            
            let plugin = MockDevicePlugin(
                pluginId: pluginId,
                displayName: displayName,
                supportedDevices: [],  // Invalid: empty
                supportedChannelTypes: ["RFCOMM"]
            )
            
            do {
                try registry.register(plugin: plugin)
                return false  // Should have thrown
            } catch DeviceError.pluginValidationFailed(let reason) {
                return reason.contains("at least one device")
            } catch {
                return false
            }
        }
    }
    
    /// Test that plugins with no supported channel types are rejected
    func testPluginValidationRejectsNoChannelTypes() {
        property("Plugins with no supported channel types are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen,
            PluginDiscoveryPropertyTests.validDisplayNameGen
        ) { pluginId, displayName in
            let registry = DeviceRegistry()
            
            let identifier = DeviceIdentifier(
                vendorId: "0x009E",
                confidenceScore: 80
            )
            
            let plugin = MockDevicePlugin(
                pluginId: pluginId,
                displayName: displayName,
                supportedDevices: [identifier],
                supportedChannelTypes: []  // Invalid: empty
            )
            
            do {
                try registry.register(plugin: plugin)
                return false  // Should have thrown
            } catch DeviceError.pluginValidationFailed(let reason) {
                return reason.contains("channel type")
            } catch {
                return false
            }
        }
    }
    
    /// Test that device identifiers without any identification criteria are rejected
    func testPluginValidationRejectsEmptyIdentifiers() {
        property("Plugins with device identifiers lacking identification criteria are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen,
            PluginDiscoveryPropertyTests.validDisplayNameGen
        ) { pluginId, displayName in
            let registry = DeviceRegistry()
            
            // Create identifier with no identification criteria
            let emptyIdentifier = DeviceIdentifier(
                vendorId: nil,
                productId: nil,
                serviceUUIDs: [],
                namePattern: nil,
                macAddressPrefix: nil,
                confidenceScore: 80,
                customIdentifiers: [:]
            )
            
            let plugin = MockDevicePlugin(
                pluginId: pluginId,
                displayName: displayName,
                supportedDevices: [emptyIdentifier],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            do {
                try registry.register(plugin: plugin)
                return false  // Should have thrown
            } catch DeviceError.pluginValidationFailed(let reason) {
                return reason.contains("identification criteria")
            } catch {
                return false
            }
        }
    }
    
    /// Test that duplicate plugin IDs are rejected
    func testPluginValidationRejectsDuplicateIds() {
        property("Duplicate plugin IDs are rejected") <- forAll(
            PluginDiscoveryPropertyTests.validPluginIdGen,
            PluginDiscoveryPropertyTests.validDisplayNameGen
        ) { pluginId, displayName in
            let registry = DeviceRegistry()
            
            let identifier = DeviceIdentifier(
                vendorId: "0x009E",
                confidenceScore: 80
            )
            
            let plugin1 = MockDevicePlugin(
                pluginId: pluginId,
                displayName: displayName,
                supportedDevices: [identifier],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            let plugin2 = MockDevicePlugin(
                pluginId: pluginId,  // Same ID
                displayName: "Another \(displayName)",
                supportedDevices: [identifier],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            do {
                try registry.register(plugin: plugin1)
                try registry.register(plugin: plugin2)
                return false  // Should have thrown on second registration
            } catch DeviceError.registrationFailed(let reason) {
                return reason.contains("already registered") && registry.pluginCount == 1
            } catch {
                return false
            }
        }
    }
    
    /// Test that unregistering a plugin removes it from the registry
    func testPluginUnregistration() {
        property("Unregistering a plugin removes it from the registry") <- forAll(Gen<Int>.choose((1, 5))) { numPlugins in
            let registry = DeviceRegistry()
            var pluginIds: [String] = []
            
            // Register plugins
            for i in 0..<numPlugins {
                let pluginId = "com.test.plugin\(i)"
                pluginIds.append(pluginId)
                
                let plugin = MockDevicePlugin(
                    pluginId: pluginId,
                    displayName: "Test Plugin \(i)",
                    supportedDevices: [
                        DeviceIdentifier(vendorId: "0x000\(i)", confidenceScore: 80)
                    ],
                    supportedChannelTypes: ["RFCOMM"]
                )
                try? registry.register(plugin: plugin)
            }
            
            // Unregister first plugin
            let removedId = pluginIds[0]
            registry.unregister(pluginId: removedId)
            
            // Verify plugin count decreased and removed plugin is gone
            let remainingPlugins = registry.getAllPlugins()
            return registry.pluginCount == numPlugins - 1 &&
                   !remainingPlugins.contains(where: { $0.pluginId == removedId })
        }
    }
}
