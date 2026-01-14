import Foundation

// MARK: - DevicePlugin Protocol

/// Protocol that all device plugins must implement.
///
/// This protocol defines the contract for device-specific implementations, encapsulating
/// all device-specific command encoding and response decoding within the plugin.
/// No protocol details should be exposed to other components (Requirement 4.1).
///
/// The protocol provides async methods for sending commands and receiving responses,
/// with structured error handling for command failures (Requirement 4.2, 4.3).
///
/// **Protocol Encapsulation Principle:**
/// - All device-specific command encoding is contained within the plugin
/// - All response decoding is contained within the plugin
/// - The plugin exposes only high-level operations to other components
/// - Protocol details (byte formats, command structures) are never exposed
///
/// **Validates: Requirements 1.3, 4.1, 4.2**
public protocol DevicePlugin: AnyObject {
    
    // MARK: - Plugin Identity
    
    /// Required initializer for dynamic plugin loading
    init()
    
    /// Unique identifier for this plugin (e.g., "com.soundsherpa.bose")
    var pluginId: String { get }
    
    /// Human-readable name for this plugin (e.g., "Bose Headphones")
    var displayName: String { get }
    
    // MARK: - Device Identification
    
    /// Device identifiers this plugin can handle.
    /// Each identifier specifies criteria for matching devices to this plugin.
    var supportedDevices: [DeviceIdentifier] { get }
    
    /// Check if this plugin can handle the given device.
    /// - Parameter device: The Bluetooth device to check
    /// - Returns: Confidence score (0-100) or nil if device is not supported.
    ///           Higher scores indicate more specific matches.
    func canHandle(device: BluetoothDevice) -> Int?
    
    // MARK: - Communication Channel
    
    /// Supported communication channel types (e.g., ["RFCOMM", "BLE"])
    var supportedChannelTypes: [String] { get }
    
    /// Initialize connection with the device using the provided channel.
    /// The plugin encapsulates all protocol-specific initialization.
    /// - Parameter channel: The communication channel to use
    /// - Throws: DeviceError if connection fails
    func connect(channel: DeviceCommunicationChannel) async throws
    
    /// Disconnect from the device and clean up resources.
    func disconnect()
    
    /// Check if the plugin is currently connected to a device
    var isConnected: Bool { get }
    
    // MARK: - Capability Configuration
    
    /// Get device-specific capability configurations.
    /// This method returns the capabilities supported by the specific device model,
    /// allowing the UI to adapt to device-specific features.
    /// - Parameter device: The connected Bluetooth device
    /// - Returns: Array of capability configurations for this device
    func getCapabilityConfigs(for device: BluetoothDevice) -> [DeviceCapabilityConfig]
    
    // MARK: - Core Device Operations (Required)
    
    /// Get current battery level.
    /// - Returns: Battery level as percentage (0-100)
    /// - Throws: DeviceError if command fails
    func getBatteryLevel() async throws -> Int
    
    /// Get device-specific additional info.
    /// The returned dictionary contains device-specific information that varies per device.
    /// - Returns: Dictionary of device info (e.g., firmware version, model name)
    /// - Throws: DeviceError if command fails
    func getDeviceInfo() async throws -> [String: Any]
    
    // MARK: - Noise Cancellation (Required for NC-capable devices)
    
    /// Get noise cancellation value in device-native format.
    /// The returned value is device-specific and should be converted using convertNCToStandard.
    /// - Returns: Device-native NC value
    /// - Throws: DeviceError if command fails or not supported
    func getNoiseCancellation() async throws -> Any
    
    /// Set noise cancellation using device-native value.
    /// Use convertNCFromStandard to convert from standardized format.
    /// - Parameter value: Device-native NC value
    /// - Throws: DeviceError if command fails or not supported
    func setNoiseCancellation(_ value: Any) async throws
    
    /// Convert device-native NC value to standardized format for UI.
    /// - Parameter deviceValue: The device-native NC value
    /// - Returns: Standardized string representation (e.g., "off", "low", "high")
    func convertNCToStandard(_ deviceValue: Any) -> String
    
    /// Convert standardized NC value to device-native format.
    /// - Parameter standardValue: Standardized string (e.g., "off", "low", "high")
    /// - Returns: Device-native NC value
    func convertNCFromStandard(_ standardValue: String) -> Any
    
    // MARK: - Optional Capabilities (Default implementations provided)
    
    /// Get self-voice level (if supported).
    /// - Returns: Device-native self-voice value
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getSelfVoice() async throws -> Any
    
    /// Set self-voice level (if supported).
    /// - Parameter value: Device-native self-voice value
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setSelfVoice(_ value: Any) async throws
    
    /// Get auto-off setting.
    /// - Returns: Current auto-off setting
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getAutoOff() async throws -> AutoOffSetting
    
    /// Set auto-off setting.
    /// - Parameter setting: The auto-off setting to apply
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setAutoOff(_ setting: AutoOffSetting) async throws
    
    /// Get paired devices list.
    /// - Returns: Array of paired devices
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getPairedDevices() async throws -> [PairedDevice]
    
    /// Connect to a paired device.
    /// - Parameter address: MAC address of the device to connect
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func connectPairedDevice(address: String) async throws
    
    /// Disconnect a paired device.
    /// - Parameter address: MAC address of the device to disconnect
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func disconnectPairedDevice(address: String) async throws
    
    /// Get current language setting.
    /// - Returns: Current device language
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getLanguage() async throws -> DeviceLanguage
    
    /// Set language.
    /// - Parameter language: The language to set
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setLanguage(_ language: DeviceLanguage) async throws
    
    /// Get voice prompts enabled state.
    /// - Returns: True if voice prompts are enabled
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getVoicePromptsEnabled() async throws -> Bool
    
    /// Set voice prompts enabled state.
    /// - Parameter enabled: Whether to enable voice prompts
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setVoicePromptsEnabled(_ enabled: Bool) async throws
    
    /// Get button action setting.
    /// - Returns: Current button action setting
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getButtonAction() async throws -> ButtonActionSetting
    
    /// Set button action.
    /// - Parameter action: The button action to set
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setButtonAction(_ action: ButtonActionSetting) async throws
    
    /// Get ambient sound level (if supported, primarily for Sony devices).
    /// - Returns: Ambient sound level (typically 0-20)
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getAmbientSound() async throws -> Int
    
    /// Set ambient sound level (if supported, primarily for Sony devices).
    /// - Parameter level: Ambient sound level to set
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setAmbientSound(_ level: Int) async throws
    
    /// Get equalizer preset (if supported).
    /// - Returns: Current equalizer preset name
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func getEqualizerPreset() async throws -> String
    
    /// Set equalizer preset (if supported).
    /// - Parameter preset: The equalizer preset to apply
    /// - Throws: DeviceError.unsupportedCommand if not supported
    func setEqualizerPreset(_ preset: String) async throws
}

// MARK: - Default Implementations

/// Default implementations for optional capabilities.
/// Plugins can override these methods to provide device-specific functionality.
/// Methods that are not supported by a device should throw DeviceError.unsupportedCommand.
public extension DevicePlugin {
    
    /// Default implementation returns false. Plugins should override to track connection state.
    var isConnected: Bool {
        return false
    }
    
    func getSelfVoice() async throws -> Any {
        throw DeviceError.unsupportedCommand
    }
    
    func setSelfVoice(_ value: Any) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getAutoOff() async throws -> AutoOffSetting {
        throw DeviceError.unsupportedCommand
    }
    
    func setAutoOff(_ setting: AutoOffSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getPairedDevices() async throws -> [PairedDevice] {
        throw DeviceError.unsupportedCommand
    }
    
    func connectPairedDevice(address: String) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func disconnectPairedDevice(address: String) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getLanguage() async throws -> DeviceLanguage {
        throw DeviceError.unsupportedCommand
    }
    
    func setLanguage(_ language: DeviceLanguage) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getVoicePromptsEnabled() async throws -> Bool {
        throw DeviceError.unsupportedCommand
    }
    
    func setVoicePromptsEnabled(_ enabled: Bool) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getButtonAction() async throws -> ButtonActionSetting {
        throw DeviceError.unsupportedCommand
    }
    
    func setButtonAction(_ action: ButtonActionSetting) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getAmbientSound() async throws -> Int {
        throw DeviceError.unsupportedCommand
    }
    
    func setAmbientSound(_ level: Int) async throws {
        throw DeviceError.unsupportedCommand
    }
    
    func getEqualizerPreset() async throws -> String {
        throw DeviceError.unsupportedCommand
    }
    
    func setEqualizerPreset(_ preset: String) async throws {
        throw DeviceError.unsupportedCommand
    }
}

// MARK: - Protocol Handler Support

/// Protocol handler abstraction for device-specific command encoding/decoding.
/// This protocol ensures all protocol details are encapsulated within plugins.
///
/// **Validates: Requirements 4.1, 4.2**
public protocol ProtocolHandler {
    /// Encode a command for the device
    /// - Parameter command: The command to encode
    /// - Returns: Encoded data ready to send
    func encode(command: DeviceCommand) -> Data
    
    /// Decode a response from the device
    /// - Parameter data: Raw response data
    /// - Returns: Decoded response or nil if invalid
    func decode(response data: Data) -> DeviceResponse?
    
    /// Get the expected response prefix for a command type
    /// - Parameter commandType: The type of command
    /// - Returns: Expected prefix data for response filtering
    func expectedResponsePrefix(for commandType: DeviceCommandType) -> Data?
}

/// Generic device command representation
public enum DeviceCommandType: String, CaseIterable {
    case getBattery
    case getNoiseCancellation
    case setNoiseCancellation
    case getSelfVoice
    case setSelfVoice
    case getAutoOff
    case setAutoOff
    case getPairedDevices
    case connectPairedDevice
    case disconnectPairedDevice
    case getLanguage
    case setLanguage
    case getVoicePrompts
    case setVoicePrompts
    case getButtonAction
    case setButtonAction
    case getAmbientSound
    case setAmbientSound
    case getEqualizerPreset
    case setEqualizerPreset
    case getDeviceInfo
}

/// Device command with type and optional payload
public struct DeviceCommand {
    public let type: DeviceCommandType
    public let payload: Any?
    
    public init(type: DeviceCommandType, payload: Any? = nil) {
        self.type = type
        self.payload = payload
    }
}

/// Device response with type and data
public struct DeviceResponse {
    public let type: DeviceCommandType
    public let data: Any
    public let rawData: Data
    
    public init(type: DeviceCommandType, data: Any, rawData: Data) {
        self.type = type
        self.data = data
        self.rawData = rawData
    }
}
