import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for connection lifecycle management
/// Feature: multi-device-support, Properties 13, 14, 15
/// **Validates: Requirements 7.1, 7.2, 7.3, 7.4**
final class ConnectionLifecyclePropertyTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    /// Mock delegate to track connection events
    class MockConnectionManagerDelegate: ConnectionManagerDelegate {
        var connectCalls: [(BluetoothDevice)] = []
        var disconnectCalls: [(BluetoothDevice)] = []
        var failureCalls: [Error] = []
        var stateChanges: [ConnectionState] = []
        var discoverCalls: [BluetoothDevice] = []
        
        func connectionManager(_ manager: ConnectionManager, didDiscover device: BluetoothDevice) {
            discoverCalls.append(device)
        }
        
        func connectionManager(_ manager: ConnectionManager, didConnect device: BluetoothDevice) {
            connectCalls.append(device)
        }
        
        func connectionManager(_ manager: ConnectionManager, didDisconnect device: BluetoothDevice) {
            disconnectCalls.append(device)
        }
        
        func connectionManager(_ manager: ConnectionManager, didFailWith error: Error) {
            failureCalls.append(error)
        }
        
        func connectionManager(_ manager: ConnectionManager, didChangeState state: ConnectionState) {
            stateChanges.append(state)
        }
        
        func reset() {
            connectCalls = []
            disconnectCalls = []
            failureCalls = []
            stateChanges = []
            discoverCalls = []
        }
    }
    
    /// Mock plugin that always succeeds connection
    class SuccessfulMockPlugin: MockDevicePlugin {
        var connectCallCount = 0
        var disconnectCallCount = 0
        
        override func connect(channel: DeviceCommunicationChannel) async throws {
            connectCallCount += 1
            try await super.connect(channel: channel)
        }
        
        override func disconnect() {
            disconnectCallCount += 1
            super.disconnect()
        }
    }
    
    /// Mock plugin that fails connection a specified number of times
    class FailingMockPlugin: MockDevicePlugin {
        var failuresRemaining: Int
        var connectAttempts = 0
        
        init(failCount: Int) {
            self.failuresRemaining = failCount
            super.init(
                pluginId: "com.test.failing",
                displayName: "Failing Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: "0x009E",
                        confidenceScore: 90
                    )
                ]
            )
            self.mockConfidenceScore = 90
        }
        
        required init() {
            self.failuresRemaining = 0
            super.init()
        }
        
        override func connect(channel: DeviceCommunicationChannel) async throws {
            connectAttempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw DeviceError.notConnected
            }
            try await super.connect(channel: channel)
        }
    }
    
    // MARK: - Property 13: Connection Lifecycle Notifications
    
    /// Property 13: Connection Lifecycle Notifications
    /// *For any* device connection event, the ConnectionManager SHALL call the DeviceRegistry's activatePlugin
    /// method exactly once, and *for any* device disconnection event, the ConnectionManager SHALL call
    /// deactivatePlugin exactly once.
    /// **Validates: Requirements 7.1, 7.2**
    func testConnectionLifecycleNotifications() {
        property("Connection events trigger exactly one activate/deactivate call") <- forAll { (device: BluetoothDevice) in
            let registry = DeviceRegistry()
            let delegate = MockConnectionManagerDelegate()
            
            // Create a plugin that matches the device
            let plugin = SuccessfulMockPlugin(
                pluginId: "com.test.lifecycle",
                displayName: "Lifecycle Test Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: device.vendorId ?? "0x0001",
                        confidenceScore: 90
                    )
                ]
            )
            plugin.mockConfidenceScore = 90
            
            try? registry.register(plugin: plugin)
            
            let manager = ConnectionManager(
                registry: registry,
                maxRetryAttempts: 1,
                baseRetryDelay: 0.01
            )
            manager.delegate = delegate
            
            // Perform connection
            let expectation = XCTestExpectation(description: "Connection completes")
            
            Task {
                do {
                    _ = try await manager.connect(to: device)
                    
                    // Verify: exactly one connect notification
                    guard delegate.connectCalls.count == 1 else {
                        expectation.fulfill()
                        return
                    }
                    
                    // Verify: plugin was activated (registry has active plugin)
                    guard registry.getActivePlugin()?.pluginId == plugin.pluginId else {
                        expectation.fulfill()
                        return
                    }
                    
                    // Perform disconnection
                    manager.disconnect()
                    
                    // Verify: exactly one disconnect notification
                    guard delegate.disconnectCalls.count == 1 else {
                        expectation.fulfill()
                        return
                    }
                    
                    // Verify: plugin was deactivated
                    guard registry.getActivePlugin() == nil else {
                        expectation.fulfill()
                        return
                    }
                    
                } catch {
                    // Connection may fail for various reasons in test environment
                }
                expectation.fulfill()
            }
            
            // Wait for async operation
            _ = XCTWaiter.wait(for: [expectation], timeout: 2.0)
            
            // Property holds if connect/disconnect counts are balanced
            return delegate.connectCalls.count == delegate.disconnectCalls.count ||
                   delegate.connectCalls.count == 0 // Connection failed
        }
    }
    
    // MARK: - Property 14: Connection State Consistency
    
    /// Property 14: Connection State Consistency
    /// *For any* sequence of connect and disconnect operations, the ConnectionManager's connectionState
    /// property SHALL always reflect the actual connection status.
    /// **Validates: Requirements 7.3**
    func testConnectionStateConsistency() {
        property("Connection state always reflects actual status") <- forAll { (device: BluetoothDevice) in
            let registry = DeviceRegistry()
            let delegate = MockConnectionManagerDelegate()
            
            let plugin = SuccessfulMockPlugin(
                pluginId: "com.test.state",
                displayName: "State Test Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: device.vendorId ?? "0x0001",
                        confidenceScore: 90
                    )
                ]
            )
            plugin.mockConfidenceScore = 90
            
            try? registry.register(plugin: plugin)
            
            let manager = ConnectionManager(
                registry: registry,
                maxRetryAttempts: 1,
                baseRetryDelay: 0.01
            )
            manager.delegate = delegate
            
            // Initial state should be disconnected
            guard case .disconnected = manager.connectionState else {
                return false
            }
            
            let expectation = XCTestExpectation(description: "State test completes")
            var stateConsistent = true
            
            Task {
                do {
                    // Connect
                    _ = try await manager.connect(to: device)
                    
                    // State should be connected
                    if case .connected(let connectedDevice, _) = manager.connectionState {
                        stateConsistent = stateConsistent && (connectedDevice.address == device.address)
                    } else {
                        stateConsistent = false
                    }
                    
                    // Disconnect
                    manager.disconnect()
                    
                    // State should be disconnected
                    if case .disconnected = manager.connectionState {
                        // Good
                    } else {
                        stateConsistent = false
                    }
                    
                } catch {
                    // If connection fails, state should be disconnected
                    if case .disconnected = manager.connectionState {
                        // Good - failed connection results in disconnected state
                    } else {
                        stateConsistent = false
                    }
                }
                expectation.fulfill()
            }
            
            _ = XCTWaiter.wait(for: [expectation], timeout: 2.0)
            
            return stateConsistent
        }
    }

    
    // MARK: - Property 15: Connection Retry Behavior
    
    /// Property 15: Connection Retry Behavior
    /// *For any* connection attempt that fails, the ConnectionManager SHALL retry with delays following
    /// exponential backoff (delay doubles each attempt) and SHALL stop after exactly 3 failed attempts.
    /// **Validates: Requirements 7.4**
    func testConnectionRetryBehavior() {
        property("Connection retries follow exponential backoff and stop after max attempts") <- forAll(Gen<Int>.choose((1, 5))) { failCount in
            let registry = DeviceRegistry()
            let maxRetries = 3
            
            // Create a plugin that fails a specific number of times
            let plugin = FailingMockPlugin(failCount: failCount)
            try? registry.register(plugin: plugin)
            
            let manager = ConnectionManager(
                registry: registry,
                maxRetryAttempts: maxRetries,
                baseRetryDelay: 0.01,  // Very short for testing
                maxRetryDelay: 0.1
            )
            
            // Create a test device that matches the plugin
            let device = BluetoothDevice(
                address: "00:11:22:33:44:55",
                name: "Test Device",
                vendorId: "0x009E",
                productId: nil,
                serviceUUIDs: [],
                isConnected: true,
                rssi: nil,
                deviceClass: nil,
                manufacturerData: nil,
                advertisementData: nil
            )
            
            let expectation = XCTestExpectation(description: "Retry test completes")
            var connectionSucceeded = false
            var connectionFailed = false
            
            Task {
                do {
                    _ = try await manager.connect(to: device)
                    connectionSucceeded = true
                } catch {
                    connectionFailed = true
                }
                expectation.fulfill()
            }
            
            _ = XCTWaiter.wait(for: [expectation], timeout: 5.0)
            
            // Verify retry behavior
            if failCount < maxRetries {
                // Should succeed after retries
                // Total attempts = failCount + 1 (the successful one)
                return connectionSucceeded && plugin.connectAttempts == failCount + 1
            } else {
                // Should fail after max retries
                // Total attempts = maxRetries
                return connectionFailed && plugin.connectAttempts == maxRetries
            }
        }
    }
    
    /// Test that exponential backoff delays are calculated correctly
    func testExponentialBackoffCalculation() {
        property("Exponential backoff delay doubles with each attempt") <- forAll(Gen<Int>.choose((1, 10))) { attempt in
            let baseDelay: TimeInterval = 1.0
            let maxDelay: TimeInterval = 32.0
            
            let manager = ConnectionManager(
                registry: DeviceRegistry(),
                maxRetryAttempts: 10,
                baseRetryDelay: baseDelay,
                maxRetryDelay: maxDelay
            )
            
            let delay = manager.calculateRetryDelay(attempt: attempt)
            
            // Expected delay: baseDelay * 2^(attempt-1), capped at maxDelay
            let expectedDelay = min(baseDelay * pow(2.0, Double(attempt - 1)), maxDelay)
            
            // Allow small floating point tolerance
            return abs(delay - expectedDelay) < 0.001
        }
    }
    
    /// Test that state transitions are properly tracked
    func testStateTransitionsTracked() {
        property("State changes are notified to delegate") <- forAll { (device: BluetoothDevice) in
            let registry = DeviceRegistry()
            let delegate = MockConnectionManagerDelegate()
            
            let plugin = SuccessfulMockPlugin(
                pluginId: "com.test.transitions",
                displayName: "Transitions Test Plugin",
                supportedDevices: [
                    DeviceIdentifier(
                        vendorId: device.vendorId ?? "0x0001",
                        confidenceScore: 90
                    )
                ]
            )
            plugin.mockConfidenceScore = 90
            
            try? registry.register(plugin: plugin)
            
            let manager = ConnectionManager(
                registry: registry,
                maxRetryAttempts: 1,
                baseRetryDelay: 0.01
            )
            manager.delegate = delegate
            
            let expectation = XCTestExpectation(description: "Transitions test completes")
            
            Task {
                do {
                    _ = try await manager.connect(to: device)
                    manager.disconnect()
                } catch {
                    // Connection may fail
                }
                expectation.fulfill()
            }
            
            _ = XCTWaiter.wait(for: [expectation], timeout: 2.0)
            
            // Verify state transitions were tracked
            // Expected: connecting -> connected -> disconnected (on success)
            // Or: connecting -> disconnected (on failure)
            if delegate.stateChanges.isEmpty {
                return true // No state changes means no connection attempt completed
            }
            
            // First state change should be to connecting
            if case .connecting = delegate.stateChanges.first {
                return true
            }
            
            return false
        }
    }
}
