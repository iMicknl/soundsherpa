import Foundation
import SwiftCheck
@testable import SoundSherpa

// MARK: - Arbitrary Conformance for Custom Types

extension BluetoothDevice: Arbitrary {
    public static var arbitrary: Gen<BluetoothDevice> {
        return Gen<BluetoothDevice>.compose { c in
            BluetoothDevice(
                address: c.generate(using: macAddressGen),
                name: c.generate(using: deviceNameGen),
                vendorId: c.generate(using: vendorIdGen),
                productId: c.generate(using: productIdGen),
                serviceUUIDs: c.generate(using: serviceUUIDsGen),
                isConnected: c.generate(),
                rssi: c.generate(using: Gen<Int?>.frequency([(1, Gen.pure(nil)), (3, Gen<Int>.choose((-100, 0)).map { Optional($0) })])),
                deviceClass: nil,
                manufacturerData: nil,
                advertisementData: nil
            )
        }
    }
    
    /// Generate random MAC addresses
    private static let macAddressGen: Gen<String> = Gen<String>.compose { c in
        let bytes = (0..<6).map { _ in String(format: "%02X", c.generate(using: Gen<UInt8>.choose((0, 255)))) }
        return bytes.joined(separator: ":")
    }
    
    /// Generate random vendor IDs
    private static let vendorIdGen: Gen<String?> = Gen<String?>.frequency([
        (3, Gen.pure("0x009E")),  // Bose
        (3, Gen.pure("0x054C")),  // Sony
        (2, Gen.pure("0x0001")),  // Random
        (2, Gen.pure(nil))
    ])
    
    /// Generate random product IDs
    private static let productIdGen: Gen<String?> = Gen<String?>.frequency([
        (2, Gen.pure("0x4001")),  // QC35
        (2, Gen.pure("0x4002")),  // QC35 II
        (2, Gen.pure("0x0CD3")),  // Sony XM4
        (2, Gen.pure("0x0001")),  // Random
        (2, Gen.pure(nil))
    ])
    
    /// Generate random service UUIDs
    private static let serviceUUIDsGen: Gen<[String]> = Gen<[String]>.frequency([
        (3, Gen.pure(["0000110B-0000-1000-8000-00805F9B34FB"])),  // Audio Sink
        (2, Gen.pure(["0000110B-0000-1000-8000-00805F9B34FB", "0000180F-0000-1000-8000-00805F9B34FB"])),
        (2, Gen.pure([])),
        (1, Gen.pure(["96CC203E-5068-46AD-B32D-E316F5E069BA"]))  // Sony proprietary
    ])
    
    /// Generate random device names
    private static let deviceNameGen: Gen<String> = Gen<String>.frequency([
        (3, Gen.pure("Bose QC35 II")),
        (2, Gen.pure("Bose QC35")),
        (2, Gen.pure("WH-1000XM4")),
        (2, Gen.pure("WH-1000XM5")),
        (1, Gen.pure("Unknown Device"))
    ])
}

extension DeviceIdentifier: Arbitrary {
    public static var arbitrary: Gen<DeviceIdentifier> {
        return Gen<DeviceIdentifier>.compose { c in
            DeviceIdentifier(
                vendorId: c.generate(using: vendorIdGen),
                productId: c.generate(using: productIdGen),
                serviceUUIDs: c.generate(using: serviceUUIDsGen),
                namePattern: c.generate(using: namePatternGen),
                macAddressPrefix: c.generate(using: macPrefixGen),
                confidenceScore: c.generate(using: Gen<Int>.choose((50, 100))),
                customIdentifiers: [:]
            )
        }
    }
    
    /// Generate random vendor IDs
    private static let vendorIdGen: Gen<String?> = Gen<String?>.frequency([
        (3, Gen.pure("0x009E")),  // Bose
        (3, Gen.pure("0x054C")),  // Sony
        (2, Gen.pure("0x0001")),  // Random
        (2, Gen.pure(nil))
    ])
    
    /// Generate random product IDs
    private static let productIdGen: Gen<String?> = Gen<String?>.frequency([
        (2, Gen.pure("0x4001")),  // QC35
        (2, Gen.pure("0x4002")),  // QC35 II
        (2, Gen.pure("0x0CD3")),  // Sony XM4
        (2, Gen.pure("0x0001")),  // Random
        (2, Gen.pure(nil))
    ])
    
    /// Generate random service UUIDs
    private static let serviceUUIDsGen: Gen<[String]> = Gen<[String]>.frequency([
        (3, Gen.pure(["0000110B-0000-1000-8000-00805F9B34FB"])),  // Audio Sink
        (2, Gen.pure(["0000110B-0000-1000-8000-00805F9B34FB", "0000180F-0000-1000-8000-00805F9B34FB"])),
        (2, Gen.pure([])),
        (1, Gen.pure(["96CC203E-5068-46AD-B32D-E316F5E069BA"]))  // Sony proprietary
    ])
    
    /// Generate random name patterns
    private static let namePatternGen: Gen<String?> = Gen<String?>.frequency([
        (2, Gen.pure("Bose QC35.*")),
        (2, Gen.pure("WH-1000XM[4-5].*")),
        (3, Gen.pure(nil))
    ])
    
    /// Generate random MAC prefixes
    private static let macPrefixGen: Gen<String?> = Gen<String?>.frequency([
        (2, Gen.pure("04:52:C7")),  // Bose
        (2, Gen.pure("AC:80:0A")),  // Sony
        (3, Gen.pure(nil))
    ])
}

// MARK: - DeviceError Arbitrary Conformance

extension DeviceError: Arbitrary {
    public static var arbitrary: Gen<DeviceError> {
        return Gen<DeviceError>.frequency([
            // Connection errors
            (2, Gen.pure(.notConnected)),
            (1, Gen<String>.fromElements(of: ["timeout", "refused", "reset"]).map { .connectionFailed($0) }),
            (2, Gen.pure(.commandTimeout)),
            (2, Gen.pure(.channelClosed)),
            (1, Gen<String>.fromElements(of: ["RFCOMM", "BLE", "USB"]).map { .unsupportedChannel($0) }),
            (1, Gen.pure(.bluetoothDisabled)),
            (1, Gen.pure(.bluetoothUnavailable)),
            
            // Response errors
            (2, Gen.pure(.invalidResponse)),
            (1, Gen<String>.fromElements(of: ["wrong header", "bad checksum"]).map { .unexpectedResponse($0) }),
            (1, Gen.pure(.checksumMismatch)),
            
            // Command errors
            (2, Gen.pure(.unsupportedCommand)),
            (1, Gen<String>.fromElements(of: ["invalid level", "out of range"]).map { .invalidParameter($0) }),
            (1, Gen<String>.fromElements(of: ["busy", "locked"]).map { .commandRejected($0) }),
            
            // Plugin errors
            (1, Gen<String>.fromElements(of: ["empty ID", "missing method"]).map { .pluginValidationFailed($0) }),
            (1, Gen.pure(.pluginNotFound)),
            (1, Gen<String>.fromElements(of: ["duplicate ID", "invalid config"]).map { .registrationFailed($0) }),
            (1, Gen<String>.fromElements(of: ["nil pointer", "stack overflow"]).map { .pluginCrashed($0) }),
            (1, Gen<String>.fromElements(of: ["hardware failure", "firmware error"]).map { .pluginUnrecoverableError($0) }),
            
            // Settings errors
            (1, Gen<String>.fromElements(of: ["invalid JSON", "missing field"]).map { .settingsCorrupted($0) }),
            (1, Gen<String>.fromElements(of: ["version mismatch", "schema error"]).map { .settingsMigrationFailed($0) }),
            
            // General errors
            (1, Gen<String>.fromElements(of: ["unknown", "unexpected"]).map { .unknown($0) })
        ])
    }
}

// MARK: - ErrorSeverity Arbitrary Conformance

extension ErrorSeverity: Arbitrary {
    public static var arbitrary: Gen<ErrorSeverity> {
        return Gen<ErrorSeverity>.fromElements(of: ErrorSeverity.allCases)
    }
}

// MARK: - RecoveryStrategy Arbitrary Conformance

extension RecoveryStrategy: Arbitrary {
    public static var arbitrary: Gen<RecoveryStrategy> {
        return Gen<RecoveryStrategy>.fromElements(of: RecoveryStrategy.allCases)
    }
}

// MARK: - DeviceCommandType Arbitrary Conformance

extension DeviceCommandType: Arbitrary {
    public static var arbitrary: Gen<DeviceCommandType> {
        return Gen<DeviceCommandType>.fromElements(of: DeviceCommandType.allCases)
    }
}

// MARK: - Data Arbitrary Conformance

extension Data: Arbitrary {
    public static var arbitrary: Gen<Data> {
        return Gen<Data>.compose { c in
            let length = c.generate(using: Gen<Int>.choose((0, 50)))
            var bytes = [UInt8]()
            for _ in 0..<length {
                bytes.append(c.generate(using: Gen<UInt8>.choose((0, 255))))
            }
            return Data(bytes)
        }
    }
}


// MARK: - NoiseCancellationLevel Arbitrary Conformance

extension NoiseCancellationLevel: Arbitrary {
    public static var arbitrary: Gen<NoiseCancellationLevel> {
        return Gen<NoiseCancellationLevel>.fromElements(of: NoiseCancellationLevel.allCases)
    }
}

// MARK: - SelfVoiceLevel Arbitrary Conformance

extension SelfVoiceLevel: Arbitrary {
    public static var arbitrary: Gen<SelfVoiceLevel> {
        return Gen<SelfVoiceLevel>.fromElements(of: SelfVoiceLevel.allCases)
    }
}

// MARK: - AutoOffSetting Arbitrary Conformance

extension AutoOffSetting: Arbitrary {
    public static var arbitrary: Gen<AutoOffSetting> {
        return Gen<AutoOffSetting>.fromElements(of: AutoOffSetting.allCases)
    }
}

// MARK: - DeviceLanguage Arbitrary Conformance

extension DeviceLanguage: Arbitrary {
    public static var arbitrary: Gen<DeviceLanguage> {
        return Gen<DeviceLanguage>.fromElements(of: DeviceLanguage.allCases)
    }
}

// MARK: - ButtonActionSetting Arbitrary Conformance

extension ButtonActionSetting: Arbitrary {
    public static var arbitrary: Gen<ButtonActionSetting> {
        return Gen<ButtonActionSetting>.fromElements(of: ButtonActionSetting.allCases)
    }
}

// MARK: - BoseDeviceModel Arbitrary Conformance

extension BoseDeviceModel: Arbitrary {
    public static var arbitrary: Gen<BoseDeviceModel> {
        return Gen<BoseDeviceModel>.fromElements(of: BoseDeviceModel.allCases)
    }
}


// MARK: - SonyDeviceModel Arbitrary Conformance

extension SonyDeviceModel: Arbitrary {
    public static var arbitrary: Gen<SonyDeviceModel> {
        return Gen<SonyDeviceModel>.fromElements(of: SonyDeviceModel.allCases)
    }
}


// MARK: - DeviceSettings Arbitrary Conformance

extension DeviceSettings: Arbitrary {
    public static var arbitrary: Gen<DeviceSettings> {
        return Gen<DeviceSettings>.compose { c in
            DeviceSettings(
                deviceId: c.generate(using: deviceIdGen),
                lastModified: Date(),
                noiseCancellation: c.generate(using: optionalNCGen),
                selfVoice: c.generate(using: optionalSVGen),
                autoOff: c.generate(using: optionalAOGen),
                language: c.generate(using: optionalLangGen),
                voicePromptsEnabled: c.generate(using: optionalBoolGen),
                buttonAction: c.generate(using: optionalBAGen),
                ambientSoundLevel: c.generate(using: optionalAmbientGen),
                equalizerPreset: c.generate(using: optionalEQGen),
                customSettings: c.generate(using: customSettingsGen),
                schemaVersion: DeviceSettings.currentSchemaVersion
            )
        }
    }
    
    /// Generate valid device IDs (MAC address format)
    private static let deviceIdGen: Gen<String> = Gen<String>.compose { c in
        let bytes = (0..<6).map { _ in String(format: "%02X", c.generate(using: Gen<UInt8>.choose((0, 255)))) }
        return bytes.joined(separator: ":")
    }
    
    /// Generate optional noise cancellation level
    private static let optionalNCGen: Gen<NoiseCancellationLevel?> = Gen<NoiseCancellationLevel?>.frequency([
        (3, NoiseCancellationLevel.arbitrary.map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional self-voice level
    private static let optionalSVGen: Gen<SelfVoiceLevel?> = Gen<SelfVoiceLevel?>.frequency([
        (3, SelfVoiceLevel.arbitrary.map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional auto-off setting
    private static let optionalAOGen: Gen<AutoOffSetting?> = Gen<AutoOffSetting?>.frequency([
        (3, AutoOffSetting.arbitrary.map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional language
    private static let optionalLangGen: Gen<DeviceLanguage?> = Gen<DeviceLanguage?>.frequency([
        (3, DeviceLanguage.arbitrary.map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional boolean
    private static let optionalBoolGen: Gen<Bool?> = Gen<Bool?>.frequency([
        (2, Gen.pure(true)),
        (2, Gen.pure(false)),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional button action
    private static let optionalBAGen: Gen<ButtonActionSetting?> = Gen<ButtonActionSetting?>.frequency([
        (3, ButtonActionSetting.arbitrary.map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional ambient sound level
    private static let optionalAmbientGen: Gen<Int?> = Gen<Int?>.frequency([
        (3, Gen<Int>.choose((0, 20)).map { Optional($0) }),
        (1, Gen.pure(nil))
    ])
    
    /// Generate optional equalizer preset
    private static let optionalEQGen: Gen<String?> = Gen<String?>.frequency([
        (1, Gen.pure("flat")),
        (1, Gen.pure("bass")),
        (1, Gen.pure("treble")),
        (1, Gen.pure("vocal")),
        (1, Gen.pure(nil))
    ])
    
    /// Generate custom settings dictionary
    private static let customSettingsGen: Gen<[String: String]> = Gen<[String: String]>.frequency([
        (3, Gen.pure([:])),
        (1, Gen.pure(["customKey1": "value1"])),
        (1, Gen.pure(["customKey1": "value1", "customKey2": "value2"]))
    ])
}
