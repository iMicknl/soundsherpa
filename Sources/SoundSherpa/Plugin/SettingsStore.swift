import Foundation

// MARK: - DeviceSettings

/// Settings that can be persisted per device (supports round-trip serialization).
///
/// This struct stores device-specific settings keyed by device identifier,
/// supporting the addition of new setting types through the customSettings dictionary.
///
/// **Validates: Requirements 8.1, 8.2, 8.3**
public struct DeviceSettings: Codable, Equatable {
    /// Device identifier for keying settings (typically MAC address)
    public let deviceId: String
    
    /// Timestamp for settings version tracking
    public let lastModified: Date
    
    /// Noise cancellation level setting
    public var noiseCancellation: NoiseCancellationLevel?
    
    /// Self-voice level setting
    public var selfVoice: SelfVoiceLevel?
    
    /// Auto-off timer setting
    public var autoOff: AutoOffSetting?
    
    /// Device language setting
    public var language: DeviceLanguage?
    
    /// Voice prompts enabled state
    public var voicePromptsEnabled: Bool?
    
    /// Button action setting
    public var buttonAction: ButtonActionSetting?
    
    /// Ambient sound level (for Sony devices)
    public var ambientSoundLevel: Int?
    
    /// Equalizer preset name
    public var equalizerPreset: String?
    
    /// Plugin-specific custom settings (supports adding new setting types)
    public var customSettings: [String: String]
    
    /// Schema version for migration support
    public let schemaVersion: Int
    
    /// Current schema version
    public static let currentSchemaVersion = 1
    
    public init(
        deviceId: String,
        lastModified: Date = Date(),
        noiseCancellation: NoiseCancellationLevel? = nil,
        selfVoice: SelfVoiceLevel? = nil,
        autoOff: AutoOffSetting? = nil,
        language: DeviceLanguage? = nil,
        voicePromptsEnabled: Bool? = nil,
        buttonAction: ButtonActionSetting? = nil,
        ambientSoundLevel: Int? = nil,
        equalizerPreset: String? = nil,
        customSettings: [String: String] = [:],
        schemaVersion: Int = DeviceSettings.currentSchemaVersion
    ) {
        self.deviceId = deviceId
        self.lastModified = lastModified
        self.noiseCancellation = noiseCancellation
        self.selfVoice = selfVoice
        self.autoOff = autoOff
        self.language = language
        self.voicePromptsEnabled = voicePromptsEnabled
        self.buttonAction = buttonAction
        self.ambientSoundLevel = ambientSoundLevel
        self.equalizerPreset = equalizerPreset
        self.customSettings = customSettings
        self.schemaVersion = schemaVersion
    }
    
    /// Creates a copy with updated lastModified timestamp
    public func withUpdatedTimestamp() -> DeviceSettings {
        return DeviceSettings(
            deviceId: deviceId,
            lastModified: Date(),
            noiseCancellation: noiseCancellation,
            selfVoice: selfVoice,
            autoOff: autoOff,
            language: language,
            voicePromptsEnabled: voicePromptsEnabled,
            buttonAction: buttonAction,
            ambientSoundLevel: ambientSoundLevel,
            equalizerPreset: equalizerPreset,
            customSettings: customSettings,
            schemaVersion: schemaVersion
        )
    }
    
    /// Check if settings have any non-nil values
    public var hasAnySettings: Bool {
        return noiseCancellation != nil ||
               selfVoice != nil ||
               autoOff != nil ||
               language != nil ||
               voicePromptsEnabled != nil ||
               buttonAction != nil ||
               ambientSoundLevel != nil ||
               equalizerPreset != nil ||
               !customSettings.isEmpty
    }
}

// MARK: - SettingsStoreError

/// Errors that can occur during settings operations
public enum SettingsStoreError: Error, Equatable {
    case directoryCreationFailed(String)
    case serializationFailed(String)
    case deserializationFailed(String)
    case fileWriteFailed(String)
    case fileReadFailed(String)
    case fileDeleteFailed(String)
    case invalidDeviceId
    case corruptedSettingsFile(String)
    case migrationFailed(String)
}

// MARK: - SettingsStore

/// Stores device-specific settings with round-trip serialization support.
///
/// The SettingsStore persists and retrieves device-specific settings keyed by device identifier.
/// It uses JSON serialization that supports adding new setting types through the customSettings
/// dictionary, ensuring forward compatibility.
///
/// **Validates: Requirements 8.1, 8.2, 8.3**
public class SettingsStore {
    
    // MARK: - Properties
    
    /// Directory where settings files are stored
    private let settingsDirectory: URL
    
    /// File extension for settings files
    private static let settingsFileExtension = "json"
    
    /// JSON encoder configured for pretty printing
    private let encoder: JSONEncoder
    
    /// JSON decoder
    private let decoder: JSONDecoder
    
    /// In-memory cache of loaded settings
    private var settingsCache: [String: DeviceSettings] = [:]
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    /// Default settings directory in Application Support
    public static var defaultSettingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SoundSherpa/Settings", isDirectory: true)
    }
    
    /// Initialize the settings store with a custom directory
    /// - Parameter settingsDirectory: Directory to store settings files
    public init(settingsDirectory: URL = SettingsStore.defaultSettingsDirectory) {
        self.settingsDirectory = settingsDirectory
        
        // Configure encoder for readable JSON
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        // Configure decoder
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Public Methods
    
    /// Save settings for a device (keyed by device identifier).
    ///
    /// - Parameters:
    ///   - settings: The settings to save
    ///   - deviceId: The device identifier (typically MAC address)
    /// - Throws: SettingsStoreError if save fails
    ///
    /// **Validates: Requirements 8.1**
    public func save(settings: DeviceSettings, for deviceId: String) throws {
        guard isValidDeviceId(deviceId) else {
            throw SettingsStoreError.invalidDeviceId
        }
        
        // Ensure directory exists
        try ensureDirectoryExists()
        
        // Update settings with current timestamp
        let updatedSettings = DeviceSettings(
            deviceId: deviceId,
            lastModified: Date(),
            noiseCancellation: settings.noiseCancellation,
            selfVoice: settings.selfVoice,
            autoOff: settings.autoOff,
            language: settings.language,
            voicePromptsEnabled: settings.voicePromptsEnabled,
            buttonAction: settings.buttonAction,
            ambientSoundLevel: settings.ambientSoundLevel,
            equalizerPreset: settings.equalizerPreset,
            customSettings: settings.customSettings,
            schemaVersion: DeviceSettings.currentSchemaVersion
        )
        
        // Serialize to JSON
        let data: Data
        do {
            data = try encoder.encode(updatedSettings)
        } catch {
            throw SettingsStoreError.serializationFailed(error.localizedDescription)
        }
        
        // Write to file
        let fileURL = settingsFileURL(for: deviceId)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SettingsStoreError.fileWriteFailed(error.localizedDescription)
        }
        
        // Update cache
        lock.lock()
        settingsCache[deviceId] = updatedSettings
        lock.unlock()
    }
    
    /// Load settings for a device (restored when device reconnects).
    ///
    /// - Parameter deviceId: The device identifier
    /// - Returns: The device settings, or nil if not found
    /// - Throws: SettingsStoreError if load fails (except for file not found)
    ///
    /// **Validates: Requirements 8.2**
    public func load(for deviceId: String) throws -> DeviceSettings? {
        guard isValidDeviceId(deviceId) else {
            throw SettingsStoreError.invalidDeviceId
        }
        
        // Check cache first
        lock.lock()
        if let cached = settingsCache[deviceId] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        let fileURL = settingsFileURL(for: deviceId)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        // Read file
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SettingsStoreError.fileReadFailed(error.localizedDescription)
        }
        
        // Deserialize
        let settings: DeviceSettings
        do {
            settings = try decoder.decode(DeviceSettings.self, from: data)
        } catch {
            // Try to recover from corrupted file
            if let recovered = try? recoverCorruptedSettings(from: data, deviceId: deviceId) {
                return recovered
            }
            throw SettingsStoreError.deserializationFailed(error.localizedDescription)
        }
        
        // Migrate if needed
        let migratedSettings = try migrateIfNeeded(settings)
        
        // Update cache
        lock.lock()
        settingsCache[deviceId] = migratedSettings
        lock.unlock()
        
        return migratedSettings
    }
    
    /// Delete settings for a device.
    ///
    /// - Parameter deviceId: The device identifier
    /// - Throws: SettingsStoreError if delete fails
    public func delete(for deviceId: String) throws {
        guard isValidDeviceId(deviceId) else {
            throw SettingsStoreError.invalidDeviceId
        }
        
        let fileURL = settingsFileURL(for: deviceId)
        
        // Remove from cache
        lock.lock()
        settingsCache.removeValue(forKey: deviceId)
        lock.unlock()
        
        // Delete file if exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw SettingsStoreError.fileDeleteFailed(error.localizedDescription)
            }
        }
    }
    
    /// List all device IDs that have saved settings.
    ///
    /// - Returns: Array of device identifiers
    public func listAllDeviceIds() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: settingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        
        return contents
            .filter { $0.pathExtension == Self.settingsFileExtension }
            .compactMap { deviceIdFromFileName($0.deletingPathExtension().lastPathComponent) }
    }
    
    /// Clear all cached settings (useful for testing).
    public func clearCache() {
        lock.lock()
        settingsCache.removeAll()
        lock.unlock()
    }
    
    /// Delete all settings files (useful for testing or reset).
    public func deleteAllSettings() throws {
        clearCache()
        
        guard FileManager.default.fileExists(atPath: settingsDirectory.path) else {
            return
        }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: settingsDirectory,
            includingPropertiesForKeys: nil
        )
        
        for fileURL in contents where fileURL.pathExtension == Self.settingsFileExtension {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
    
    // MARK: - Private Methods
    
    /// Ensure the settings directory exists
    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: settingsDirectory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: settingsDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw SettingsStoreError.directoryCreationFailed(error.localizedDescription)
            }
        }
    }
    
    /// Get the file URL for a device's settings
    private func settingsFileURL(for deviceId: String) -> URL {
        let safeFileName = sanitizeDeviceId(deviceId)
        return settingsDirectory
            .appendingPathComponent(safeFileName)
            .appendingPathExtension(Self.settingsFileExtension)
    }
    
    /// Sanitize device ID for use as filename (replace colons with underscores)
    private func sanitizeDeviceId(_ deviceId: String) -> String {
        return deviceId.replacingOccurrences(of: ":", with: "_")
    }
    
    /// Convert sanitized filename back to device ID
    private func deviceIdFromFileName(_ fileName: String) -> String? {
        let deviceId = fileName.replacingOccurrences(of: "_", with: ":")
        return isValidDeviceId(deviceId) ? deviceId : nil
    }
    
    /// Validate device ID format
    private func isValidDeviceId(_ deviceId: String) -> Bool {
        // Device ID should not be empty and should not contain path separators
        return !deviceId.isEmpty &&
               !deviceId.contains("/") &&
               !deviceId.contains("\\") &&
               deviceId.count <= 100
    }
    
    /// Attempt to recover settings from corrupted data
    /// **Validates: Requirements 9.3**
    private func recoverCorruptedSettings(from data: Data, deviceId: String) throws -> DeviceSettings? {
        // Log the corruption
        ErrorLogger.shared.log(
            .settingsCorrupted("Attempting recovery for device \(deviceId)"),
            context: "SettingsStore.recoverCorruptedSettings"
        )
        
        // Try to parse as dictionary and extract what we can
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ErrorLogger.shared.log(
                .settingsCorrupted("Could not parse JSON for device \(deviceId)"),
                context: "SettingsStore.recoverCorruptedSettings"
            )
            return nil
        }
        
        // Create default settings and populate what we can recover
        var settings = DeviceSettings(deviceId: deviceId)
        
        if let ncString = json["noiseCancellation"] as? String,
           let nc = NoiseCancellationLevel(rawValue: ncString) {
            settings.noiseCancellation = nc
        }
        
        if let svString = json["selfVoice"] as? String,
           let sv = SelfVoiceLevel(rawValue: svString) {
            settings.selfVoice = sv
        }
        
        if let aoInt = json["autoOff"] as? Int,
           let ao = AutoOffSetting(rawValue: aoInt) {
            settings.autoOff = ao
        }
        
        if let langString = json["language"] as? String,
           let lang = DeviceLanguage(rawValue: langString) {
            settings.language = lang
        }
        
        if let vpEnabled = json["voicePromptsEnabled"] as? Bool {
            settings.voicePromptsEnabled = vpEnabled
        }
        
        if let baString = json["buttonAction"] as? String,
           let ba = ButtonActionSetting(rawValue: baString) {
            settings.buttonAction = ba
        }
        
        if let ambientLevel = json["ambientSoundLevel"] as? Int {
            settings.ambientSoundLevel = ambientLevel
        }
        
        if let eqPreset = json["equalizerPreset"] as? String {
            settings.equalizerPreset = eqPreset
        }
        
        if let custom = json["customSettings"] as? [String: String] {
            settings.customSettings = custom
        }
        
        // Log successful recovery
        ErrorLogger.shared.log(
            DeviceError.settingsCorrupted("Partial recovery successful for device \(deviceId)"),
            context: "SettingsStore.recoverCorruptedSettings"
        )
        
        return settings
    }
    
    /// Migrate settings to current schema version if needed
    private func migrateIfNeeded(_ settings: DeviceSettings) throws -> DeviceSettings {
        guard settings.schemaVersion < DeviceSettings.currentSchemaVersion else {
            return settings
        }
        
        // Currently at version 1, no migrations needed yet
        // Future migrations would be handled here
        
        return DeviceSettings(
            deviceId: settings.deviceId,
            lastModified: settings.lastModified,
            noiseCancellation: settings.noiseCancellation,
            selfVoice: settings.selfVoice,
            autoOff: settings.autoOff,
            language: settings.language,
            voicePromptsEnabled: settings.voicePromptsEnabled,
            buttonAction: settings.buttonAction,
            ambientSoundLevel: settings.ambientSoundLevel,
            equalizerPreset: settings.equalizerPreset,
            customSettings: settings.customSettings,
            schemaVersion: DeviceSettings.currentSchemaVersion
        )
    }
}

// MARK: - SettingsStore Extension for Plugin Integration

extension SettingsStore {
    
    /// Save settings from a plugin's current state
    /// - Parameters:
    ///   - plugin: The device plugin
    ///   - device: The connected device
    public func savePluginSettings(_ plugin: DevicePlugin, for device: BluetoothDevice) async throws {
        var settings = DeviceSettings(deviceId: device.uniqueIdentifier)
        
        // Try to get each setting, ignoring unsupported commands
        if let nc = try? await plugin.getNoiseCancellation() {
            let standardNC = plugin.convertNCToStandard(nc)
            settings.noiseCancellation = NoiseCancellationLevel(rawValue: standardNC)
        }
        
        if let sv = try? await plugin.getSelfVoice() as? SelfVoiceLevel {
            settings.selfVoice = sv
        }
        
        if let ao = try? await plugin.getAutoOff() {
            settings.autoOff = ao
        }
        
        if let lang = try? await plugin.getLanguage() {
            settings.language = lang
        }
        
        if let vp = try? await plugin.getVoicePromptsEnabled() {
            settings.voicePromptsEnabled = vp
        }
        
        if let ba = try? await plugin.getButtonAction() {
            settings.buttonAction = ba
        }
        
        if let ambient = try? await plugin.getAmbientSound() {
            settings.ambientSoundLevel = ambient
        }
        
        if let eq = try? await plugin.getEqualizerPreset() {
            settings.equalizerPreset = eq
        }
        
        try save(settings: settings, for: device.uniqueIdentifier)
    }
    
    /// Restore settings to a plugin
    /// - Parameters:
    ///   - plugin: The device plugin
    ///   - device: The connected device
    /// - Returns: True if settings were restored, false if no settings found
    @discardableResult
    public func restorePluginSettings(_ plugin: DevicePlugin, for device: BluetoothDevice) async throws -> Bool {
        guard let settings = try load(for: device.uniqueIdentifier) else {
            return false
        }
        
        // Restore each setting, ignoring unsupported commands
        if let nc = settings.noiseCancellation {
            let deviceValue = plugin.convertNCFromStandard(nc.rawValue)
            try? await plugin.setNoiseCancellation(deviceValue)
        }
        
        if let sv = settings.selfVoice {
            try? await plugin.setSelfVoice(sv)
        }
        
        if let ao = settings.autoOff {
            try? await plugin.setAutoOff(ao)
        }
        
        if let lang = settings.language {
            try? await plugin.setLanguage(lang)
        }
        
        if let vp = settings.voicePromptsEnabled {
            try? await plugin.setVoicePromptsEnabled(vp)
        }
        
        if let ba = settings.buttonAction {
            try? await plugin.setButtonAction(ba)
        }
        
        if let ambient = settings.ambientSoundLevel {
            try? await plugin.setAmbientSound(ambient)
        }
        
        if let eq = settings.equalizerPreset {
            try? await plugin.setEqualizerPreset(eq)
        }
        
        return true
    }
}
