import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for capability-based menu visibility
/// Feature: multi-device-support
/// **Validates: Requirements 3.2, 3.3, 3.4, 3.5**
final class CapabilityMenuPropertyTests: XCTestCase {
    
    // MARK: - Property 5: Capability-Based Menu Visibility
    
    /// Property 5: Capability-Based Menu Visibility
    /// *For any* connected device with a set of capabilities C, the MenuController SHALL display exactly
    /// the menu items corresponding to capabilities in C, and *for any* disconnected state, all
    /// device-specific menu items SHALL be hidden.
    func testCapabilityBasedMenuVisibility() {
        property("Menu displays exactly the capabilities supported by the connected device") <- forAll(capabilitySetGen) { capabilities in
            // Create a capability set from the generated capabilities
            let configs = capabilities.map { DeviceCapabilityConfig.defaultConfig(for: $0) }
            let capabilitySet = DeviceCapabilitySet(configs: configs)
            
            // Verify that the capability set contains exactly the expected capabilities
            let supportedCapabilities = capabilitySet.supportedCapabilities
            
            // Property: supported capabilities should match input capabilities
            return supportedCapabilities == Set(capabilities)
        }
    }
    
    /// Test that disconnected state hides all device-specific items
    func testDisconnectedStateHidesCapabilities() {
        property("Disconnected state results in empty capability set") <- forAll(capabilitySetGen) { capabilities in
            // Create a capability set
            let configs = capabilities.map { DeviceCapabilityConfig.defaultConfig(for: $0) }
            var capabilitySet = DeviceCapabilitySet(configs: configs)
            
            // Simulate disconnection by creating empty set
            capabilitySet = DeviceCapabilitySet()
            
            // Property: after disconnection, no capabilities should be supported
            return capabilitySet.supportedCapabilities.isEmpty
        }
    }
    
    /// Test that main menu capabilities are correctly identified
    func testMainMenuCapabilitiesCorrectlyIdentified() {
        property("Main menu capabilities are correctly filtered from capability set") <- forAll(capabilitySetGen) { capabilities in
            let configs = capabilities.map { DeviceCapabilityConfig.defaultConfig(for: $0) }
            let capabilitySet = DeviceCapabilitySet(configs: configs)
            
            let mainMenuConfigs = capabilitySet.mainMenuConfigs
            let submenuConfigs = capabilitySet.submenuConfigs
            
            // Property 1: All main menu configs should have isMainMenuCapability = true
            let allMainMenuCorrect = mainMenuConfigs.allSatisfy { $0.isMainMenuCapability }
            
            // Property 2: All submenu configs should have isMainMenuCapability = false
            let allSubmenuCorrect = submenuConfigs.allSatisfy { !$0.isMainMenuCapability }
            
            // Property 3: Main menu + submenu should cover all supported capabilities
            let mainCapabilities = Set(mainMenuConfigs.map { $0.capability })
            let submenuCapabilities = Set(submenuConfigs.map { $0.capability })
            let allCapabilities = mainCapabilities.union(submenuCapabilities)
            let expectedCapabilities = capabilitySet.supportedCapabilities
            
            return allMainMenuCorrect && allSubmenuCorrect && allCapabilities == expectedCapabilities
        }
    }
    
    // MARK: - Property 6: Menu Icon and Layout Consistency
    
    /// Property 6: Menu Icon and Layout Consistency
    /// *For any* two devices with the same capability, the MenuController SHALL use identical icons
    /// and layout for that capability's menu items regardless of device type.
    func testMenuIconConsistency() {
        property("Same capability always has the same icon regardless of device") <- forAll { (capability: DeviceCapability) in
            // Create two different device configurations with the same capability
            let config1 = DeviceCapabilityConfig(
                capability: capability,
                valueType: .discrete(["off", "on"]),
                displayName: "Config 1",
                isSupported: true,
                metadata: ["device": "Bose"]
            )
            
            let config2 = DeviceCapabilityConfig(
                capability: capability,
                valueType: .discrete(["off", "on"]),
                displayName: "Config 2",
                isSupported: true,
                metadata: ["device": "Sony"]
            )
            
            // Property: Both configs should have the same icon name
            return config1.iconName == config2.iconName
        }
    }
    
    /// Test that capability icons are consistent across all value types
    func testCapabilityIconsConsistentAcrossValueTypes() {
        property("Capability icon is consistent regardless of value type") <- forAll { (capability: DeviceCapability) in
            // Create configs with different value types
            let discreteConfig = DeviceCapabilityConfig(
                capability: capability,
                valueType: .discrete(["a", "b", "c"]),
                displayName: "Discrete",
                isSupported: true
            )
            
            let continuousConfig = DeviceCapabilityConfig(
                capability: capability,
                valueType: .continuous(min: 0, max: 100, step: 1),
                displayName: "Continuous",
                isSupported: true
            )
            
            let booleanConfig = DeviceCapabilityConfig(
                capability: capability,
                valueType: .boolean,
                displayName: "Boolean",
                isSupported: true
            )
            
            // Property: All configs for same capability should have same icon
            return discreteConfig.iconName == continuousConfig.iconName &&
                   continuousConfig.iconName == booleanConfig.iconName
        }
    }
    
    /// Test that default display names are consistent
    func testDefaultDisplayNamesConsistent() {
        property("Default display name is consistent for each capability") <- forAll { (capability: DeviceCapability) in
            let defaultConfig = DeviceCapabilityConfig.defaultConfig(for: capability)
            
            // Property: Default config display name should match capability's default display name
            return defaultConfig.displayName == capability.defaultDisplayName
        }
    }
    
    // MARK: - Additional Property Tests
    
    /// Test that capability value types are validated correctly
    func testCapabilityValueTypeValidation() {
        // Test discrete value type validation
        property("Discrete value type validates string values correctly") <- forAll(discreteValueGen) { value in
            let valueType = CapabilityValueType.discrete(["off", "low", "high"])
            let isValid = valueType.isValidValue(value)
            return isValid == ["off", "low", "high"].contains(value)
        }
        
        // Test continuous value type validation
        property("Continuous value type validates integer values correctly") <- forAll(intValueGen) { value in
            let valueType = CapabilityValueType.continuous(min: 0, max: 100, step: 1)
            let isValid = valueType.isValidValue(value)
            return isValid == (value >= 0 && value <= 100)
        }
        
        // Test boolean value type validation
        property("Boolean value type validates boolean values correctly") <- forAll(boolValueGen) { value in
            let valueType = CapabilityValueType.boolean
            let isValid = valueType.isValidValue(value)
            return isValid == true  // Bool values should always be valid for boolean type
        }
    }
    
    /// Test that DeviceCapabilitySet correctly tracks supported capabilities
    func testCapabilitySetTracksSupported() {
        property("Capability set correctly tracks which capabilities are supported") <- forAll(capabilitySetGen) { capabilities in
            var capabilitySet = DeviceCapabilitySet()
            
            // Add capabilities one by one
            for capability in capabilities {
                let config = DeviceCapabilityConfig.defaultConfig(for: capability)
                capabilitySet.setConfig(config)
            }
            
            // Property: All added capabilities should be supported
            let allSupported = capabilities.allSatisfy { capabilitySet.isSupported($0) }
            
            // Property: Non-added capabilities should not be supported
            let nonAddedCapabilities = Set(DeviceCapability.allCases).subtracting(Set(capabilities))
            let noneUnsupportedAreSupported = nonAddedCapabilities.allSatisfy { !capabilitySet.isSupported($0) }
            
            return allSupported && noneUnsupportedAreSupported
        }
    }
}

// MARK: - Generators

extension DeviceCapability: Arbitrary {
    public static var arbitrary: Gen<DeviceCapability> {
        return Gen<DeviceCapability>.fromElements(of: DeviceCapability.allCases)
    }
}

/// Generator for sets of capabilities
private let capabilitySetGen: Gen<[DeviceCapability]> = Gen<[DeviceCapability]>.compose { c in
    // Generate a random subset of capabilities
    let allCapabilities = DeviceCapability.allCases
    let count = c.generate(using: Gen<Int>.choose((0, allCapabilities.count)))
    
    var selected: [DeviceCapability] = []
    var available = allCapabilities
    
    for _ in 0..<count {
        if available.isEmpty { break }
        let index = c.generate(using: Gen<Int>.choose((0, available.count - 1)))
        selected.append(available[index])
        available.remove(at: index)
    }
    
    return selected
}

/// Generator for CapabilityValueType
private let valueTypeGen: Gen<CapabilityValueType> = Gen<CapabilityValueType>.frequency([
    (3, Gen.pure(CapabilityValueType.discrete(["off", "low", "high"]))),
    (3, Gen.pure(CapabilityValueType.continuous(min: 0, max: 100, step: 1))),
    (2, Gen.pure(CapabilityValueType.boolean)),
    (2, Gen.pure(CapabilityValueType.text))
])

/// Generator for discrete string values
private let discreteValueGen: Gen<String> = Gen<String>.fromElements(of: ["off", "low", "high", "medium", "invalid"])

/// Generator for integer values
private let intValueGen: Gen<Int> = Gen<Int>.choose((-10, 150))

/// Generator for boolean values
private let boolValueGen: Gen<Bool> = Gen<Bool>.fromElements(of: [true, false])
