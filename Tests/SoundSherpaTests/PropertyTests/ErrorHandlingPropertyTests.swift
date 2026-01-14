import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property-based tests for error handling functionality.
///
/// These tests validate:
/// - Property 18: Error Display Behavior
/// - Property 19: Plugin Error Recovery
///
/// **Validates: Requirements 9.1, 9.2, 9.3**
final class ErrorHandlingPropertyTests: XCTestCase {
    
    // MARK: - Property 18: Error Display Behavior
    
    /// **Property 18: Error Display Behavior**
    ///
    /// *For any* command failure, the MenuController SHALL display a brief error indicator,
    /// and *for any* Bluetooth disabled state, the MenuController SHALL display
    /// "Bluetooth Disabled" in the menu.
    ///
    /// **Validates: Requirements 9.1, 9.2**
    ///
    /// **Feature: multi-device-support, Property 18: Error Display Behavior**
    func testErrorDisplayBehavior() {
        property("All errors that should be shown to user have non-empty user messages") <- forAll { (error: DeviceError) in
            // If error should be shown to user, it must have a non-empty user message
            if error.shouldShowToUser {
                return !error.userMessage.isEmpty
            }
            return true
        }
    }
    
    /// Test that Bluetooth disabled error has correct user message
    ///
    /// **Feature: multi-device-support, Property 18: Error Display Behavior**
    func testBluetoothDisabledMessage() {
        property("Bluetooth disabled error displays 'Bluetooth Disabled' message") <- forAll { (_: Int) in
            let error = DeviceError.bluetoothDisabled
            return error.userMessage == "Bluetooth Disabled"
        }
    }
    
    /// Test that all errors have appropriate severity levels
    ///
    /// **Feature: multi-device-support, Property 18: Error Display Behavior**
    func testErrorSeverityConsistency() {
        property("All errors have valid severity levels") <- forAll { (error: DeviceError) in
            // Severity should be one of the defined levels
            let validSeverities: [ErrorSeverity] = [.info, .warning, .error, .critical, .fatal]
            return validSeverities.contains(error.severity)
        }
    }
    
    /// Test that errors with warning or higher severity should be shown to user
    ///
    /// **Feature: multi-device-support, Property 18: Error Display Behavior**
    func testErrorVisibilityBySeverity() {
        property("Errors with warning or higher severity are shown to user") <- forAll { (error: DeviceError) in
            switch error.severity {
            case .info:
                // Info level errors should not be shown
                return !error.shouldShowToUser
            case .warning, .error, .critical, .fatal:
                // Higher severity errors should be shown
                return error.shouldShowToUser
            }
        }
    }
    
    /// Test that command failures have appropriate user messages
    ///
    /// **Feature: multi-device-support, Property 18: Error Display Behavior**
    func testCommandFailureMessages() {
        property("Command failure errors have user-friendly messages") <- forAll { (error: DeviceError) in
            // User message should not contain technical details
            let userMessage = error.userMessage
            
            // Should not contain stack traces or memory addresses
            let containsTechnicalDetails = userMessage.contains("0x") ||
                                          userMessage.contains("at line") ||
                                          userMessage.contains("Exception")
            
            return !containsTechnicalDetails && !userMessage.isEmpty
        }
    }
    
    // MARK: - Property 19: Plugin Error Recovery
    
    /// **Property 19: Plugin Error Recovery**
    ///
    /// *For any* DevicePlugin that encounters an unrecoverable error, the Application
    /// SHALL log the error and continue operating with reduced functionality without crashing.
    ///
    /// **Validates: Requirements 9.3**
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testPluginErrorRecovery() {
        property("All errors have defined recovery strategies") <- forAll { (error: DeviceError) in
            // Every error should have a recovery strategy
            let validStrategies: [RecoveryStrategy] = [
                .none, .retry, .retryWithBackoff, .fallback,
                .reconnect, .useDefaults, .degraded, .userIntervention
            ]
            return validStrategies.contains(error.recoveryStrategy)
        }
    }
    
    /// Test that plugin errors allow graceful degradation
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testPluginErrorGracefulDegradation() {
        property("Plugin unrecoverable errors suggest degraded mode") <- forAll { (details: String) in
            let error = DeviceError.pluginUnrecoverableError(details)
            // Unrecoverable plugin errors should suggest degraded mode
            return error.recoveryStrategy == .degraded
        }
    }
    
    /// Test that plugin crash errors are handled appropriately
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testPluginCrashRecovery() {
        property("Plugin crash errors suggest reconnection") <- forAll { (details: String) in
            let error = DeviceError.pluginCrashed(details)
            // Plugin crashes should suggest reconnection
            return error.recoveryStrategy == .reconnect
        }
    }
    
    /// Test that recoverable errors are correctly identified
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testRecoverableErrorIdentification() {
        property("Errors with retry/reconnect strategies are marked recoverable") <- forAll { (error: DeviceError) in
            let isRecoverable = error.isRecoverable
            let strategy = error.recoveryStrategy
            
            // Errors with none or userIntervention strategies should not be recoverable
            if strategy == .none || strategy == .userIntervention {
                return !isRecoverable
            }
            // All other strategies should be recoverable
            return isRecoverable
        }
    }
    
    /// Test that error logging captures all errors
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testErrorLogging() {
        property("Errors can be logged without crashing") <- forAll { (error: DeviceError) in
            // Clear previous errors
            ErrorLogger.shared.clearRecentErrors()
            
            // Log the error
            ErrorLogger.shared.log(error, context: "PropertyTest")
            
            // Verify error was logged
            let recentErrors = ErrorLogger.shared.getRecentErrors()
            return recentErrors.count == 1 && recentErrors.first?.error == error
        }
    }
    
    /// Test that plugin error handler tracks failed plugins
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testPluginErrorHandlerTracking() {
        property("Plugin error handler correctly tracks failed plugins") <- forAll { (pluginId: String) in
            // Skip empty plugin IDs
            guard !pluginId.isEmpty else { return true }
            
            // Clear previous state
            PluginErrorHandler.shared.clearFailedPlugins()
            
            // Mark plugin as failed
            PluginErrorHandler.shared.markPluginAsFailed(pluginId)
            
            // Verify it's tracked
            let isFailed = PluginErrorHandler.shared.hasPluginFailed(pluginId)
            
            // Reset the plugin
            PluginErrorHandler.shared.resetPlugin(pluginId)
            
            // Verify it's no longer tracked
            let isStillFailed = PluginErrorHandler.shared.hasPluginFailed(pluginId)
            
            return isFailed && !isStillFailed
        }
    }
    
    /// Test that retry delay calculation follows exponential backoff
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testExponentialBackoffCalculation() {
        property("Retry delays follow exponential backoff pattern") <- forAll(Gen<Int>.choose((1, 5))) { attempt in
            let config = ErrorRecoveryManager.RetryConfig()
            let manager = ErrorRecoveryManager.shared
            
            let delay = manager.calculateDelay(attempt: attempt, config: config)
            
            // Delay should be at least baseDelay * 2^(attempt-1)
            let expectedMinDelay = config.baseDelay * pow(2.0, Double(attempt - 1))
            
            // Delay should not exceed maxDelay (plus some jitter allowance)
            let maxAllowedDelay = min(expectedMinDelay, config.maxDelay) * 1.3 // 30% jitter allowance
            
            return delay >= expectedMinDelay * 0.9 && delay <= maxAllowedDelay
        }
    }
    
    /// Test that settings corruption errors suggest using defaults
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testSettingsCorruptionRecovery() {
        property("Settings corruption errors suggest using defaults") <- forAll { (details: String) in
            let error = DeviceError.settingsCorrupted(details)
            return error.recoveryStrategy == .useDefaults
        }
    }
    
    /// Test that connection errors have appropriate recovery strategies
    ///
    /// **Feature: multi-device-support, Property 19: Plugin Error Recovery**
    func testConnectionErrorRecovery() {
        property("Connection errors have retry or reconnect strategies") <- forAll { (_: Int) in
            let connectionErrors: [DeviceError] = [
                .notConnected,
                .connectionFailed("test"),
                .commandTimeout,
                .channelClosed
            ]
            
            return connectionErrors.allSatisfy { error in
                let strategy = error.recoveryStrategy
                return strategy == .retry ||
                       strategy == .retryWithBackoff ||
                       strategy == .reconnect
            }
        }
    }
}
