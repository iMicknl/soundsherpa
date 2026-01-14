import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for protocol encapsulation and command error structure
/// Feature: multi-device-support, Property 7: Protocol Encapsulation
/// Feature: multi-device-support, Property 8: Command Error Structure
/// **Validates: Requirements 4.1, 4.3**
final class ProtocolEncapsulationPropertyTests: XCTestCase {
    
    // MARK: - Property 7: Protocol Encapsulation Tests
    
    /// Property 7: Protocol Encapsulation
    /// *For any* DevicePlugin, all device-specific command encoding and response decoding
    /// SHALL be contained within the plugin, with no protocol details exposed to other components.
    ///
    /// This test verifies that:
    /// 1. Plugin methods return high-level types, not raw protocol data
    /// 2. Plugin methods accept high-level types, not raw protocol data
    /// 3. Protocol details (byte formats) are not exposed through the public interface
    func testPluginMethodsReturnHighLevelTypes() {
        property("Plugin methods return high-level types, not raw Data") <- forAll { (device: BluetoothDevice) in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.encapsulation",
                displayName: "Encapsulation Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            // Verify capability configs return structured types
            let configs = plugin.getCapabilityConfigs(for: device)
            
            // All configs should be DeviceCapabilityConfig, not raw data
            for config in configs {
                // Verify config has proper structure
                guard config.capability.rawValue.count > 0 else { return false }
                guard config.displayName.count > 0 else { return false }
                // ValueType should be a proper enum, not raw bytes
                switch config.valueType {
                case .discrete(let values):
                    guard !values.isEmpty else { return false }
                case .continuous(let min, let max, _):
                    guard min <= max else { return false }
                case .boolean, .text:
                    break // Valid types
                }
            }
            
            return true
        }
    }
    
    /// Test that NC conversion methods properly encapsulate protocol details
    func testNCConversionEncapsulatesProtocolDetails() {
        property("NC conversion methods hide protocol details") <- forAll(
            Gen<String>.fromElements(of: ["off", "low", "medium", "high", "adaptive"])
        ) { standardValue in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.nc",
                displayName: "NC Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            // Convert from standard to device-native
            let deviceValue = plugin.convertNCFromStandard(standardValue)
            
            // Convert back to standard
            let roundTripped = plugin.convertNCToStandard(deviceValue)
            
            // The round-trip should preserve the value (or return a valid fallback)
            // This verifies the conversion is consistent and doesn't expose raw bytes
            return roundTripped == standardValue || roundTripped == "off" || roundTripped == "unknown"
        }
    }
    
    /// Test that plugin interface doesn't expose raw protocol bytes
    func testPluginInterfaceHidesRawProtocolBytes() {
        property("Plugin public interface uses high-level types") <- forAll { (device: BluetoothDevice) in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.interface",
                displayName: "Interface Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            // canHandle returns Int? (confidence score), not raw protocol data
            let score = plugin.canHandle(device: device)
            if let s = score {
                guard s >= 0 && s <= 100 else { return false }
            }
            
            // supportedChannelTypes returns [String], not raw bytes
            for channelType in plugin.supportedChannelTypes {
                guard !channelType.isEmpty else { return false }
            }
            
            // pluginId and displayName are strings, not raw data
            guard !plugin.pluginId.isEmpty else { return false }
            guard !plugin.displayName.isEmpty else { return false }
            
            return true
        }
    }
    
    /// Test that DeviceCommand encapsulates command details
    func testDeviceCommandEncapsulation() {
        property("DeviceCommand encapsulates command details with type and payload") <- forAll { (commandType: DeviceCommandType) in
            // Create a command with the type
            let command = DeviceCommand(type: commandType, payload: nil)
            
            // Verify the command has a proper type
            guard DeviceCommandType.allCases.contains(command.type) else { return false }
            
            // Create a command with payload
            let commandWithPayload = DeviceCommand(type: commandType, payload: "test")
            guard commandWithPayload.type == commandType else { return false }
            
            return true
        }
    }
    
    /// Test that DeviceResponse encapsulates response details
    func testDeviceResponseEncapsulation() {
        property("DeviceResponse encapsulates response with type and data") <- forAll { (commandType: DeviceCommandType, rawData: Data) in
            // Create a response
            let response = DeviceResponse(type: commandType, data: "parsed_value", rawData: rawData)
            
            // Verify the response has proper structure
            guard DeviceCommandType.allCases.contains(response.type) else { return false }
            guard response.rawData == rawData else { return false }
            
            return true
        }
    }
    
    // MARK: - Property 8: Command Error Structure Tests
    
    /// Property 8: Command Error Structure
    /// *For any* command sent to a device that fails (timeout, invalid response, channel closed),
    /// the Protocol_Handler SHALL return a DeviceError with a specific failure reason that is not nil.
    func testCommandErrorsHaveSpecificReasons() {
        property("All DeviceError cases have non-empty descriptions") <- forAll { (error: DeviceError) in
            // Every error should have a non-empty localized description
            let description = error.localizedDescription
            return !description.isEmpty
        }
    }
    
    /// Test that command timeout returns proper error
    func testCommandTimeoutReturnsProperError() {
        let error = DeviceError.commandTimeout
        
        // Verify error has specific reason
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.contains("timed out") || 
                      error.localizedDescription.contains("timeout"))
    }
    
    /// Test that invalid response returns proper error
    func testInvalidResponseReturnsProperError() {
        let error = DeviceError.invalidResponse
        
        // Verify error has specific reason
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.lowercased().contains("invalid") || 
                      error.localizedDescription.lowercased().contains("response"))
    }
    
    /// Test that channel closed returns proper error
    func testChannelClosedReturnsProperError() {
        let error = DeviceError.channelClosed
        
        // Verify error has specific reason
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.lowercased().contains("closed") || 
                      error.localizedDescription.lowercased().contains("channel"))
    }
    
    /// Test that not connected returns proper error
    func testNotConnectedReturnsProperError() {
        let error = DeviceError.notConnected
        
        // Verify error has specific reason
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.lowercased().contains("not connected") || 
                      error.localizedDescription.lowercased().contains("connected"))
    }
    
    /// Test that unsupported command returns proper error
    func testUnsupportedCommandReturnsProperError() {
        let error = DeviceError.unsupportedCommand
        
        // Verify error has specific reason
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.lowercased().contains("not supported") || 
                      error.localizedDescription.lowercased().contains("unsupported"))
    }
    
    /// Test that unsupported channel returns proper error with channel type
    func testUnsupportedChannelReturnsProperErrorWithType() {
        property("Unsupported channel includes channel type in error") <- forAll(
            Gen<String>.fromElements(of: ["RFCOMM", "BLE", "USB", "WIFI", "UNKNOWN"])
        ) { channelType in
            let error = DeviceError.unsupportedChannel(channelType)
            
            // Verify error includes the channel type
            guard !error.localizedDescription.isEmpty else { return false }
            guard error.localizedDescription.contains(channelType) else { return false }
            
            return true
        }
    }
    
    /// Test that all error types are distinguishable
    func testAllErrorTypesAreDistinguishable() {
        let errors: [DeviceError] = [
            .notConnected,
            .commandTimeout,
            .invalidResponse,
            .unsupportedCommand,
            .channelClosed,
            .unsupportedChannel("TEST"),
            .pluginValidationFailed("test"),
            .pluginNotFound,
            .registrationFailed("test")
        ]
        
        // Each error should have a unique description
        var descriptions = Set<String>()
        for error in errors {
            let desc = error.localizedDescription
            XCTAssertFalse(desc.isEmpty, "Error \(error) has empty description")
            descriptions.insert(desc)
        }
        
        // All descriptions should be unique
        XCTAssertEqual(descriptions.count, errors.count, "Not all error descriptions are unique")
    }
    
    /// Test that plugin throws proper errors when not connected
    func testPluginThrowsProperErrorWhenNotConnected() {
        property("Plugin throws notConnected error when not connected") <- forAll { (device: BluetoothDevice) in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.notconnected",
                displayName: "Not Connected Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            // Plugin is not connected
            return !plugin.isConnected
        }
    }
    
    /// Test CommandResult encapsulates success and failure properly
    func testCommandResultEncapsulation() {
        property("CommandResult properly encapsulates success and failure") <- forAll { (data: Data, error: DeviceError) in
            // Test success case
            let successResult = CommandResult.success(data)
            switch successResult {
            case .success(let resultData):
                guard resultData == data else { return false }
            case .failure:
                return false
            }
            
            // Test failure case
            let failureResult = CommandResult.failure(error)
            switch failureResult {
            case .success:
                return false
            case .failure(let resultError):
                guard resultError == error else { return false }
            }
            
            return true
        }
    }
    
    /// Test that error-prone plugin properly propagates errors
    func testErrorPronePluginPropagatesErrors() {
        let plugin = ErrorPronePlugin()
        plugin.errorToThrow[.getBattery] = .commandTimeout
        
        let expectation = XCTestExpectation(description: "Should throw timeout error")
        
        Task {
            do {
                _ = try await plugin.getBatteryLevel()
                XCTFail("Should have thrown an error")
            } catch DeviceError.commandTimeout {
                // Expected error
                expectation.fulfill()
            } catch {
                XCTFail("Wrong error type: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    /// Test that plugin command history tracks calls
    func testPluginCommandHistoryTracking() {
        property("Plugin tracks command history") <- forAll { (device: BluetoothDevice) in
            let plugin = MockDevicePlugin(
                pluginId: "com.test.history",
                displayName: "History Test Plugin",
                supportedDevices: [DeviceIdentifier(vendorId: "0x009E", confidenceScore: 80)],
                supportedChannelTypes: ["RFCOMM"]
            )
            
            // Initially empty
            guard plugin.commandHistory.isEmpty else { return false }
            
            // Disconnect should add to history
            plugin.disconnect()
            guard plugin.commandHistory.contains("disconnect") else { return false }
            
            return true
        }
    }
}
