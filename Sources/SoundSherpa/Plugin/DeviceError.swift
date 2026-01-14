import Foundation
import os.log

// MARK: - Error Severity

/// Severity level for errors, used for logging and recovery decisions
public enum ErrorSeverity: String, Codable, CaseIterable {
    /// Informational - operation succeeded but with notes
    case info
    /// Warning - operation succeeded but with potential issues
    case warning
    /// Error - operation failed but recovery is possible
    case error
    /// Critical - operation failed and may affect system stability
    case critical
    /// Fatal - unrecoverable error requiring user intervention
    case fatal
}

// MARK: - Recovery Strategy

/// Strategy for recovering from errors
public enum RecoveryStrategy: String, Codable, CaseIterable {
    /// No recovery needed or possible
    case none
    /// Retry the operation
    case retry
    /// Retry with exponential backoff
    case retryWithBackoff
    /// Fall back to alternative method
    case fallback
    /// Reset connection and retry
    case reconnect
    /// Use cached/default values
    case useDefaults
    /// Graceful degradation - continue with reduced functionality
    case degraded
    /// Requires user intervention
    case userIntervention
}

// MARK: - DeviceError

/// Errors that can occur during device communication
///
/// Each error case includes:
/// - A descriptive message for logging
/// - A user-friendly message for display
/// - A severity level for prioritization
/// - A suggested recovery strategy
///
/// **Validates: Requirements 9.1, 9.2, 9.3**
public enum DeviceError: Error, Equatable {
    // Connection errors
    case notConnected
    case connectionFailed(String)
    case commandTimeout
    case channelClosed
    case unsupportedChannel(String)
    case bluetoothDisabled
    case bluetoothUnavailable
    
    // Response errors
    case invalidResponse
    case unexpectedResponse(String)
    case checksumMismatch
    
    // Command errors
    case unsupportedCommand
    case invalidParameter(String)
    case commandRejected(String)
    
    // Plugin errors
    case pluginValidationFailed(String)
    case pluginNotFound
    case registrationFailed(String)
    case pluginCrashed(String)
    case pluginUnrecoverableError(String)
    
    // Settings errors
    case settingsCorrupted(String)
    case settingsMigrationFailed(String)
    
    // General errors
    case unknown(String)
    
    // MARK: - Error Properties
    
    /// Technical description for logging
    public var localizedDescription: String {
        switch self {
        case .notConnected:
            return "Device is not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .commandTimeout:
            return "Command timed out"
        case .channelClosed:
            return "Communication channel was closed"
        case .unsupportedChannel(let channelType):
            return "Unsupported channel type: \(channelType)"
        case .bluetoothDisabled:
            return "Bluetooth is disabled"
        case .bluetoothUnavailable:
            return "Bluetooth is not available on this device"
        case .invalidResponse:
            return "Invalid response from device"
        case .unexpectedResponse(let details):
            return "Unexpected response: \(details)"
        case .checksumMismatch:
            return "Response checksum mismatch"
        case .unsupportedCommand:
            return "Command not supported by this device"
        case .invalidParameter(let param):
            return "Invalid parameter: \(param)"
        case .commandRejected(let reason):
            return "Command rejected: \(reason)"
        case .pluginValidationFailed(let reason):
            return "Plugin validation failed: \(reason)"
        case .pluginNotFound:
            return "No plugin found for device"
        case .registrationFailed(let reason):
            return "Plugin registration failed: \(reason)"
        case .pluginCrashed(let details):
            return "Plugin crashed: \(details)"
        case .pluginUnrecoverableError(let details):
            return "Plugin encountered unrecoverable error: \(details)"
        case .settingsCorrupted(let details):
            return "Settings file corrupted: \(details)"
        case .settingsMigrationFailed(let details):
            return "Settings migration failed: \(details)"
        case .unknown(let details):
            return "Unknown error: \(details)"
        }
    }
    
    /// User-friendly message for display in UI
    /// **Validates: Requirements 9.1, 9.2**
    public var userMessage: String {
        switch self {
        case .notConnected:
            return "Device not connected"
        case .connectionFailed:
            return "Connection failed"
        case .commandTimeout:
            return "Request timed out"
        case .channelClosed:
            return "Connection lost"
        case .unsupportedChannel:
            return "Connection type not supported"
        case .bluetoothDisabled:
            return "Bluetooth Disabled"
        case .bluetoothUnavailable:
            return "Bluetooth not available"
        case .invalidResponse, .unexpectedResponse, .checksumMismatch:
            return "Communication error"
        case .unsupportedCommand:
            return "Feature not supported"
        case .invalidParameter:
            return "Invalid setting"
        case .commandRejected:
            return "Request rejected"
        case .pluginValidationFailed, .pluginNotFound, .registrationFailed:
            return "Device not supported"
        case .pluginCrashed, .pluginUnrecoverableError:
            return "Device error"
        case .settingsCorrupted, .settingsMigrationFailed:
            return "Settings error"
        case .unknown:
            return "An error occurred"
        }
    }
    
    /// Severity level for this error
    public var severity: ErrorSeverity {
        switch self {
        case .notConnected, .unsupportedCommand:
            return .warning
        case .commandTimeout, .channelClosed, .invalidResponse, .unexpectedResponse, .checksumMismatch:
            return .error
        case .connectionFailed, .unsupportedChannel, .invalidParameter, .commandRejected:
            return .error
        case .bluetoothDisabled, .bluetoothUnavailable:
            return .warning
        case .pluginValidationFailed, .registrationFailed, .pluginNotFound:
            return .error
        case .pluginCrashed:
            return .critical
        case .pluginUnrecoverableError:
            return .fatal
        case .settingsCorrupted, .settingsMigrationFailed:
            return .warning
        case .unknown:
            return .error
        }
    }
    
    /// Suggested recovery strategy for this error
    /// **Validates: Requirements 9.3**
    public var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .notConnected:
            return .reconnect
        case .connectionFailed:
            return .retryWithBackoff
        case .commandTimeout:
            return .retry
        case .channelClosed:
            return .reconnect
        case .unsupportedChannel:
            return .fallback
        case .bluetoothDisabled, .bluetoothUnavailable:
            return .userIntervention
        case .invalidResponse, .unexpectedResponse, .checksumMismatch:
            return .retry
        case .unsupportedCommand:
            return .degraded
        case .invalidParameter:
            return .none
        case .commandRejected:
            return .retry
        case .pluginValidationFailed, .registrationFailed:
            return .none
        case .pluginNotFound:
            return .degraded
        case .pluginCrashed:
            return .reconnect
        case .pluginUnrecoverableError:
            return .degraded
        case .settingsCorrupted:
            return .useDefaults
        case .settingsMigrationFailed:
            return .useDefaults
        case .unknown:
            return .retry
        }
    }
    
    /// Whether this error is recoverable
    public var isRecoverable: Bool {
        return recoveryStrategy != .none && recoveryStrategy != .userIntervention
    }
    
    /// Whether this error should be shown to the user
    public var shouldShowToUser: Bool {
        switch severity {
        case .info:
            return false
        case .warning, .error, .critical, .fatal:
            return true
        }
    }
}

// MARK: - CommandResult

/// Result of a command execution with device-specific data
public enum CommandResult: Equatable {
    case success(Data?)
    case failure(DeviceError)
    
    /// Whether the command succeeded
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    
    /// The error if the command failed
    public var error: DeviceError? {
        if case .failure(let error) = self { return error }
        return nil
    }
    
    /// The data if the command succeeded
    public var data: Data? {
        if case .success(let data) = self { return data }
        return nil
    }
}

// MARK: - ErrorLogger

/// Centralized error logging system for the application
///
/// Provides structured logging with severity levels and context information.
/// Logs are written to the system log and can be retrieved for debugging.
///
/// **Validates: Requirements 9.3**
public final class ErrorLogger {
    
    /// Shared instance for application-wide logging
    public static let shared = ErrorLogger()
    
    /// OS log for structured logging
    private let osLog: OSLog
    
    /// Recent errors for debugging (circular buffer)
    private var recentErrors: [ErrorLogEntry] = []
    private let maxRecentErrors = 100
    private let lock = NSLock()
    
    /// Delegate for error notifications
    public weak var delegate: ErrorLoggerDelegate?
    
    private init() {
        self.osLog = OSLog(subsystem: "com.soundsherpa", category: "errors")
    }
    
    /// Log a DeviceError with context
    /// - Parameters:
    ///   - error: The error to log
    ///   - context: Additional context about where the error occurred
    ///   - file: Source file (auto-populated)
    ///   - function: Function name (auto-populated)
    ///   - line: Line number (auto-populated)
    public func log(
        _ error: DeviceError,
        context: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let entry = ErrorLogEntry(
            error: error,
            context: context,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line,
            timestamp: Date()
        )
        
        // Log to OS log
        let logType: OSLogType
        switch error.severity {
        case .info:
            logType = .info
        case .warning:
            logType = .default
        case .error:
            logType = .error
        case .critical, .fatal:
            logType = .fault
        }
        
        let contextString = context.map { " [\($0)]" } ?? ""
        os_log("%{public}@%{public}@ - %{public}@ (%{public}@:%d)",
               log: osLog,
               type: logType,
               error.severity.rawValue.uppercased(),
               contextString,
               error.localizedDescription,
               entry.file,
               entry.line)
        
        // Store in recent errors
        lock.lock()
        recentErrors.append(entry)
        if recentErrors.count > maxRecentErrors {
            recentErrors.removeFirst()
        }
        lock.unlock()
        
        // Notify delegate
        delegate?.errorLogger(self, didLog: entry)
    }
    
    /// Log a general error with context
    public func log(
        _ error: Error,
        severity: ErrorSeverity = .error,
        context: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // Convert to DeviceError if possible
        if let deviceError = error as? DeviceError {
            log(deviceError, context: context, file: file, function: function, line: line)
        } else {
            log(.unknown(error.localizedDescription), context: context, file: file, function: function, line: line)
        }
    }
    
    /// Get recent error entries for debugging
    public func getRecentErrors() -> [ErrorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return recentErrors
    }
    
    /// Clear recent errors
    public func clearRecentErrors() {
        lock.lock()
        recentErrors.removeAll()
        lock.unlock()
    }
    
    /// Get errors filtered by severity
    public func getErrors(withSeverity severity: ErrorSeverity) -> [ErrorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return recentErrors.filter { $0.error.severity == severity }
    }
    
    /// Get errors from the last N minutes
    public func getErrors(fromLastMinutes minutes: Int) -> [ErrorLogEntry] {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        lock.lock()
        defer { lock.unlock() }
        return recentErrors.filter { $0.timestamp >= cutoff }
    }
}

// MARK: - ErrorLogEntry

/// A single error log entry with context information
public struct ErrorLogEntry {
    /// The error that occurred
    public let error: DeviceError
    
    /// Additional context about where/why the error occurred
    public let context: String?
    
    /// Source file where the error was logged
    public let file: String
    
    /// Function where the error was logged
    public let function: String
    
    /// Line number where the error was logged
    public let line: Int
    
    /// When the error occurred
    public let timestamp: Date
    
    /// Formatted description for display
    public var formattedDescription: String {
        let contextStr = context.map { " [\($0)]" } ?? ""
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timeStr = dateFormatter.string(from: timestamp)
        return "[\(timeStr)] \(error.severity.rawValue.uppercased())\(contextStr): \(error.localizedDescription)"
    }
}

// MARK: - ErrorLoggerDelegate

/// Delegate protocol for receiving error notifications
public protocol ErrorLoggerDelegate: AnyObject {
    /// Called when an error is logged
    func errorLogger(_ logger: ErrorLogger, didLog entry: ErrorLogEntry)
}

// MARK: - ErrorRecoveryManager

/// Manages error recovery strategies and automatic retry logic
///
/// Provides centralized error recovery with configurable retry policies
/// and graceful degradation support.
///
/// **Validates: Requirements 9.3**
public final class ErrorRecoveryManager {
    
    /// Shared instance
    public static let shared = ErrorRecoveryManager()
    
    /// Configuration for retry behavior
    public struct RetryConfig {
        /// Maximum number of retry attempts
        public var maxAttempts: Int = 3
        
        /// Base delay between retries (seconds)
        public var baseDelay: TimeInterval = 1.0
        
        /// Maximum delay between retries (seconds)
        public var maxDelay: TimeInterval = 30.0
        
        /// Multiplier for exponential backoff
        public var backoffMultiplier: Double = 2.0
        
        /// Whether to add jitter to delays
        public var useJitter: Bool = true
        
        public init() {}
    }
    
    /// Default retry configuration
    public var defaultConfig = RetryConfig()
    
    private init() {}
    
    /// Calculate delay for a retry attempt using exponential backoff
    /// - Parameters:
    ///   - attempt: Current attempt number (1-based)
    ///   - config: Retry configuration to use
    /// - Returns: Delay in seconds before next retry
    public func calculateDelay(attempt: Int, config: RetryConfig = RetryConfig()) -> TimeInterval {
        let exponentialDelay = config.baseDelay * pow(config.backoffMultiplier, Double(attempt - 1))
        var delay = min(exponentialDelay, config.maxDelay)
        
        if config.useJitter {
            // Add up to 25% jitter
            let jitter = delay * Double.random(in: 0...0.25)
            delay += jitter
        }
        
        return delay
    }
    
    /// Execute an operation with automatic retry on failure
    /// - Parameters:
    ///   - config: Retry configuration
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error if all retries fail
    public func withRetry<T>(
        config: RetryConfig = RetryConfig(),
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...config.maxAttempts {
            do {
                return try await operation()
            } catch let error as DeviceError {
                lastError = error
                
                // Check if we should retry based on recovery strategy
                guard error.recoveryStrategy == .retry || error.recoveryStrategy == .retryWithBackoff else {
                    throw error
                }
                
                // Don't delay after the last attempt
                if attempt < config.maxAttempts {
                    let delay = calculateDelay(attempt: attempt, config: config)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                
                ErrorLogger.shared.log(error, context: "Retry attempt \(attempt)/\(config.maxAttempts)")
            } catch {
                lastError = error
                
                // For non-DeviceError, retry with backoff
                if attempt < config.maxAttempts {
                    let delay = calculateDelay(attempt: attempt, config: config)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? DeviceError.unknown("All retry attempts failed")
    }
    
    /// Attempt recovery for a specific error
    /// - Parameters:
    ///   - error: The error to recover from
    ///   - fallback: Optional fallback value to use
    /// - Returns: Recovery result indicating what action was taken
    public func attemptRecovery<T>(
        for error: DeviceError,
        fallback: T? = nil
    ) -> RecoveryResult<T> {
        switch error.recoveryStrategy {
        case .none:
            return .failed(error)
        case .retry, .retryWithBackoff:
            return .shouldRetry
        case .fallback:
            if let fallback = fallback {
                return .usedFallback(fallback)
            }
            return .failed(error)
        case .reconnect:
            return .shouldReconnect
        case .useDefaults:
            if let fallback = fallback {
                return .usedFallback(fallback)
            }
            return .failed(error)
        case .degraded:
            return .degradedMode
        case .userIntervention:
            return .requiresUserAction(error.userMessage)
        }
    }
}

// MARK: - RecoveryResult

/// Result of an error recovery attempt
public enum RecoveryResult<T> {
    /// Recovery failed, error should be propagated
    case failed(DeviceError)
    
    /// Operation should be retried
    case shouldRetry
    
    /// Connection should be re-established
    case shouldReconnect
    
    /// Fallback value was used
    case usedFallback(T)
    
    /// Continuing in degraded mode
    case degradedMode
    
    /// User action is required
    case requiresUserAction(String)
}

// MARK: - PluginErrorHandler

/// Handles plugin-specific errors with graceful degradation
///
/// Ensures that plugin failures don't crash the application and
/// provides appropriate fallback behavior.
///
/// **Validates: Requirements 9.3**
public final class PluginErrorHandler {
    
    /// Shared instance
    public static let shared = PluginErrorHandler()
    
    /// Plugins that have encountered unrecoverable errors
    private var failedPlugins: Set<String> = []
    private let lock = NSLock()
    
    /// Delegate for plugin error notifications
    public weak var delegate: PluginErrorHandlerDelegate?
    
    private init() {}
    
    /// Handle an error from a plugin
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - pluginId: ID of the plugin that failed
    ///   - operation: Description of the operation that failed
    /// - Returns: Whether the application should continue operating
    @discardableResult
    public func handlePluginError(
        _ error: Error,
        pluginId: String,
        operation: String
    ) -> Bool {
        let deviceError: DeviceError
        if let de = error as? DeviceError {
            deviceError = de
        } else {
            deviceError = .pluginCrashed(error.localizedDescription)
        }
        
        ErrorLogger.shared.log(deviceError, context: "Plugin: \(pluginId), Operation: \(operation)")
        
        // Check if this is an unrecoverable error
        if deviceError.severity == .fatal || deviceError.severity == .critical {
            markPluginAsFailed(pluginId)
            delegate?.pluginErrorHandler(self, pluginDidFail: pluginId, error: deviceError)
            return true // Continue operating with reduced functionality
        }
        
        // Notify delegate of recoverable error
        delegate?.pluginErrorHandler(self, pluginDidEncounterError: pluginId, error: deviceError)
        
        return true
    }
    
    /// Mark a plugin as failed (unrecoverable)
    public func markPluginAsFailed(_ pluginId: String) {
        lock.lock()
        failedPlugins.insert(pluginId)
        lock.unlock()
        
        ErrorLogger.shared.log(
            .pluginUnrecoverableError("Plugin marked as failed"),
            context: "Plugin: \(pluginId)"
        )
    }
    
    /// Check if a plugin has failed
    public func hasPluginFailed(_ pluginId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedPlugins.contains(pluginId)
    }
    
    /// Reset a failed plugin (allow retry)
    public func resetPlugin(_ pluginId: String) {
        lock.lock()
        failedPlugins.remove(pluginId)
        lock.unlock()
    }
    
    /// Get all failed plugin IDs
    public func getFailedPlugins() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return failedPlugins
    }
    
    /// Clear all failed plugins
    public func clearFailedPlugins() {
        lock.lock()
        failedPlugins.removeAll()
        lock.unlock()
    }
    
    /// Execute a plugin operation with error handling
    /// - Parameters:
    ///   - pluginId: ID of the plugin
    ///   - operation: Description of the operation
    ///   - fallback: Fallback value if operation fails
    ///   - block: The operation to execute
    /// - Returns: Result of the operation or fallback value
    public func executeWithFallback<T>(
        pluginId: String,
        operation: String,
        fallback: T,
        block: () async throws -> T
    ) async -> T {
        // Check if plugin has already failed
        if hasPluginFailed(pluginId) {
            ErrorLogger.shared.log(
                .pluginUnrecoverableError("Plugin previously failed"),
                context: "Plugin: \(pluginId), Operation: \(operation)"
            )
            return fallback
        }
        
        do {
            return try await block()
        } catch {
            handlePluginError(error, pluginId: pluginId, operation: operation)
            return fallback
        }
    }
}

// MARK: - PluginErrorHandlerDelegate

/// Delegate protocol for plugin error notifications
public protocol PluginErrorHandlerDelegate: AnyObject {
    /// Called when a plugin encounters a recoverable error
    func pluginErrorHandler(_ handler: PluginErrorHandler, pluginDidEncounterError pluginId: String, error: DeviceError)
    
    /// Called when a plugin fails unrecoverably
    func pluginErrorHandler(_ handler: PluginErrorHandler, pluginDidFail pluginId: String, error: DeviceError)
}
