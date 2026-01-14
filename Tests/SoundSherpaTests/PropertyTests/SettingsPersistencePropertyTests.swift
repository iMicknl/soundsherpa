import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property-based tests for settings persistence functionality.
///
/// These tests validate:
/// - Property 16: Settings Persistence by Device ID
/// - Property 17: Settings Round-Trip Serialization
///
/// **Validates: Requirements 8.1, 8.2, 8.3**
final class SettingsPersistencePropertyTests: XCTestCase {
    
    /// Temporary directory for test settings
    private var testDirectory: URL!
    
    /// Settings store under test
    private var settingsStore: SettingsStore!
    
    override func setUp() {
        super.setUp()
        
        // Create a unique temporary directory for each test
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent("SettingsTests-\(UUID().uuidString)", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        
        settingsStore = SettingsStore(settingsDirectory: testDirectory)
    }
    
    override func tearDown() {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDirectory)
        
        settingsStore = nil
        testDirectory = nil
        
        super.tearDown()
    }
    
    // MARK: - Property 16: Settings Persistence by Device ID
    
    /// **Property 16: Settings Persistence by Device ID**
    ///
    /// *For any* DeviceSettings object and device identifier, saving the settings
    /// and then loading by the same device identifier SHALL return an equivalent
    /// DeviceSettings object.
    ///
    /// **Validates: Requirements 8.1, 8.2**
    ///
    /// **Feature: multi-device-support, Property 16: Settings Persistence by Device ID**
    func testSettingsPersistenceByDeviceId() {
        property("Saving and loading settings by device ID returns equivalent settings") <- forAll { (settings: DeviceSettings) in
            let deviceId = settings.deviceId
            
            // Save settings
            do {
                try self.settingsStore.save(settings: settings, for: deviceId)
            } catch {
                return false
            }
            
            // Clear cache to force file read
            self.settingsStore.clearCache()
            
            // Load settings
            guard let loadedSettings = try? self.settingsStore.load(for: deviceId) else {
                return false
            }
            
            // Verify all fields match (except lastModified which is updated on save)
            return loadedSettings.deviceId == settings.deviceId &&
                   loadedSettings.noiseCancellation == settings.noiseCancellation &&
                   loadedSettings.selfVoice == settings.selfVoice &&
                   loadedSettings.autoOff == settings.autoOff &&
                   loadedSettings.language == settings.language &&
                   loadedSettings.voicePromptsEnabled == settings.voicePromptsEnabled &&
                   loadedSettings.buttonAction == settings.buttonAction &&
                   loadedSettings.ambientSoundLevel == settings.ambientSoundLevel &&
                   loadedSettings.equalizerPreset == settings.equalizerPreset &&
                   loadedSettings.customSettings == settings.customSettings &&
                   loadedSettings.schemaVersion == settings.schemaVersion
        }
    }
    
    /// Test that different device IDs maintain separate settings
    ///
    /// **Feature: multi-device-support, Property 16: Settings Persistence by Device ID**
    func testDifferentDeviceIdsMaintainSeparateSettings() {
        property("Different device IDs maintain separate settings") <- forAll { (settings1: DeviceSettings, settings2: DeviceSettings) in
            // Ensure different device IDs
            let deviceId1 = settings1.deviceId
            var modifiedSettings2 = settings2
            let deviceId2: String
            if settings2.deviceId == deviceId1 {
                // Generate a different device ID
                deviceId2 = "AA:BB:CC:DD:EE:FF"
                modifiedSettings2 = DeviceSettings(
                    deviceId: deviceId2,
                    noiseCancellation: settings2.noiseCancellation,
                    selfVoice: settings2.selfVoice,
                    autoOff: settings2.autoOff,
                    language: settings2.language,
                    voicePromptsEnabled: settings2.voicePromptsEnabled,
                    buttonAction: settings2.buttonAction,
                    ambientSoundLevel: settings2.ambientSoundLevel,
                    equalizerPreset: settings2.equalizerPreset,
                    customSettings: settings2.customSettings
                )
            } else {
                deviceId2 = settings2.deviceId
            }
            
            // Save both settings
            do {
                try self.settingsStore.save(settings: settings1, for: deviceId1)
                try self.settingsStore.save(settings: modifiedSettings2, for: deviceId2)
            } catch {
                return false
            }
            
            // Clear cache
            self.settingsStore.clearCache()
            
            // Load and verify each maintains its own settings
            guard let loaded1 = try? self.settingsStore.load(for: deviceId1),
                  let loaded2 = try? self.settingsStore.load(for: deviceId2) else {
                return false
            }
            
            return loaded1.noiseCancellation == settings1.noiseCancellation &&
                   loaded2.noiseCancellation == modifiedSettings2.noiseCancellation
        }
    }
    
    // MARK: - Property 17: Settings Round-Trip Serialization
    
    /// **Property 17: Settings Round-Trip Serialization**
    ///
    /// *For any* valid DeviceSettings object, serializing to JSON and deserializing
    /// back SHALL produce an equivalent DeviceSettings object (all fields match),
    /// supporting the addition of new setting types.
    ///
    /// **Validates: Requirements 8.3**
    ///
    /// **Feature: multi-device-support, Property 17: Settings Round-Trip Serialization**
    func testSettingsRoundTripSerialization() {
        property("JSON serialization round-trip preserves all settings") <- forAll { (settings: DeviceSettings) in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            // Serialize to JSON
            guard let jsonData = try? encoder.encode(settings) else {
                return false
            }
            
            // Deserialize back
            guard let decoded = try? decoder.decode(DeviceSettings.self, from: jsonData) else {
                return false
            }
            
            // Verify all fields match
            return decoded.deviceId == settings.deviceId &&
                   decoded.noiseCancellation == settings.noiseCancellation &&
                   decoded.selfVoice == settings.selfVoice &&
                   decoded.autoOff == settings.autoOff &&
                   decoded.language == settings.language &&
                   decoded.voicePromptsEnabled == settings.voicePromptsEnabled &&
                   decoded.buttonAction == settings.buttonAction &&
                   decoded.ambientSoundLevel == settings.ambientSoundLevel &&
                   decoded.equalizerPreset == settings.equalizerPreset &&
                   decoded.customSettings == settings.customSettings &&
                   decoded.schemaVersion == settings.schemaVersion
        }
    }
    
    /// Test that custom settings (for plugin-specific settings) are preserved
    ///
    /// **Feature: multi-device-support, Property 17: Settings Round-Trip Serialization**
    func testCustomSettingsRoundTrip() {
        property("Custom settings dictionary is preserved through serialization") <- forAll { (settings: DeviceSettings) in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            // Serialize and deserialize
            guard let jsonData = try? encoder.encode(settings),
                  let decoded = try? decoder.decode(DeviceSettings.self, from: jsonData) else {
                return false
            }
            
            // Custom settings should be exactly preserved
            return decoded.customSettings == settings.customSettings
        }
    }
    
    /// Test that settings can be updated and re-saved
    ///
    /// **Feature: multi-device-support, Property 16: Settings Persistence by Device ID**
    func testSettingsUpdatePersistence() {
        property("Updated settings are correctly persisted") <- forAll { (settings: DeviceSettings, newNC: NoiseCancellationLevel) in
            let deviceId = settings.deviceId
            
            // Save initial settings
            do {
                try self.settingsStore.save(settings: settings, for: deviceId)
            } catch {
                return false
            }
            
            // Update settings with new NC level
            let updatedSettings = DeviceSettings(
                deviceId: deviceId,
                noiseCancellation: newNC,
                selfVoice: settings.selfVoice,
                autoOff: settings.autoOff,
                language: settings.language,
                voicePromptsEnabled: settings.voicePromptsEnabled,
                buttonAction: settings.buttonAction,
                ambientSoundLevel: settings.ambientSoundLevel,
                equalizerPreset: settings.equalizerPreset,
                customSettings: settings.customSettings
            )
            
            // Save updated settings
            do {
                try self.settingsStore.save(settings: updatedSettings, for: deviceId)
            } catch {
                return false
            }
            
            // Clear cache and reload
            self.settingsStore.clearCache()
            
            guard let loaded = try? self.settingsStore.load(for: deviceId) else {
                return false
            }
            
            // Verify the update was persisted
            return loaded.noiseCancellation == newNC
        }
    }
    
    /// Test that deleting settings removes them
    func testSettingsDeletion() {
        property("Deleted settings are no longer retrievable") <- forAll { (settings: DeviceSettings) in
            let deviceId = settings.deviceId
            
            // Save settings
            do {
                try self.settingsStore.save(settings: settings, for: deviceId)
            } catch {
                return false
            }
            
            // Verify settings exist
            guard (try? self.settingsStore.load(for: deviceId)) != nil else {
                return false
            }
            
            // Delete settings
            do {
                try self.settingsStore.delete(for: deviceId)
            } catch {
                return false
            }
            
            // Clear cache
            self.settingsStore.clearCache()
            
            // Verify settings are gone
            let loaded = try? self.settingsStore.load(for: deviceId)
            return loaded == nil
        }
    }
}
