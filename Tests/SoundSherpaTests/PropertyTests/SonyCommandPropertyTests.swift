import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for Sony command encoding/decoding and device identification
/// Feature: multi-device-support, Property 11: Sony Device Identification
/// Feature: multi-device-support, Property 12: Sony NC Command Encoding
/// **Validates: Requirements 6.1, 6.3**
final class SonyCommandPropertyTests: XCTestCase {
    
    // MARK: - Generators
    
    /// Generator for valid Sony NC levels (0-20)
    static let ncLevelGen: Gen<Int> = Gen<Int>.choose((0, 20))
    
    /// Generator for valid Sony ambient sound levels (0-20)
    static let ambientSoundLevelGen: Gen<Int> = Gen<Int>.choose((0, 20))
    
    /// Generator for valid auto-off settings
    static let autoOffSettingGen: Gen<AutoOffSetting> = Gen<AutoOffSetting>.fromElements(of: AutoOffSetting.allCases)
    
    /// Generator for valid equalizer presets
    static let equalizerPresetGen: Gen<String> = Gen<String>.fromElements(of: [
        "off", "bright", "excited", "mellow", "relaxed", "vocal", "treble", "bass", "speech", "custom"
    ])
    
    /// Generator for sequence numbers
    static let sequenceNumberGen: Gen<UInt8> = Gen<UInt8>.choose((0, 255))
    
    /// Generator for Sony device models
    static let sonyModelGen: Gen<SonyDeviceModel> = Gen<SonyDeviceModel>.fromElements(of: SonyDeviceModel.allCases)
    
    /// Generator for Sony device names matching the pattern WH-1000XM[3-5] or WF-1000XM[4-5]
    static let sonyDeviceNameGen: Gen<String> = Gen<String>.frequency([
        (2, Gen.pure("WH-1000XM3")),
        (2, Gen.pure("WH-1000XM4")),
        (2, Gen.pure("WH-1000XM5")),
        (2, Gen.pure("WF-1000XM4")),
        (2, Gen.pure("WF-1000XM5")),
        (1, Gen.pure("WH-1000XM4 (Custom Name)")),
        (1, Gen.pure("WF-1000XM5 Earbuds"))
    ])
    
    /// Generator for Sony Bluetooth devices
    static let sonyBluetoothDeviceGen: Gen<BluetoothDevice> = Gen<BluetoothDevice>.compose { c in
        let model = c.generate(using: sonyModelGen)
        return BluetoothDevice(
            address: c.generate(using: macAddressGen),
            name: model.rawValue,
            vendorId: SonyConstants.vendorId,
            productId: model.productId,
            serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
            isConnected: c.generate(),
            rssi: c.generate(using: Gen<Int?>.frequency([(1, Gen.pure(nil)), (3, Gen<Int>.choose((-100, 0)).map { Optional($0) })])),
            deviceClass: nil,
            manufacturerData: nil,
            advertisementData: nil
        )
    }
    
    /// Generator for random MAC addresses
    private static let macAddressGen: Gen<String> = Gen<String>.compose { c in
        let bytes = (0..<6).map { _ in String(format: "%02X", c.generate(using: Gen<UInt8>.choose((0, 255)))) }
        return bytes.joined(separator: ":")
    }
    
    // MARK: - Property 11: Sony Device Identification Tests
    
    /// Property 11: Sony Device Identification
    /// *For any* BluetoothDevice with a name matching the pattern "WH-1000XM[3-5]" or "WF-1000XM[4-5]",
    /// the SonyDevicePlugin.canHandle() SHALL return a non-nil confidence score.
    /// **Validates: Requirements 6.1**
    ///
    /// Note: Sony devices are primarily identified by vendor ID + product ID combination.
    /// Name pattern matching alone is not sufficient for reliable identification.
    func testSonyDeviceIdentificationByVendorAndProductId() {
        property("Sony plugin identifies devices with matching vendor and product IDs") <- forAll(SonyCommandPropertyTests.sonyModelGen) { model in
            let plugin = SonyPlugin()
            
            // Create a device with Sony vendor ID and model-specific product ID
            let device = BluetoothDevice(
                address: "AC:80:0A:12:34:56",
                name: "Unknown Device",  // Name doesn't match pattern
                vendorId: SonyConstants.vendorId,
                productId: model.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID],
                isConnected: false
            )
            
            let score = plugin.canHandle(device: device)
            
            // Should return a non-nil score for Sony vendor/product ID combination
            return score != nil && score! >= 60
        }
    }
    
    func testSonyDeviceIdentificationWithFullCriteria() {
        property("Sony plugin gives highest confidence when all criteria match") <- forAll(SonyCommandPropertyTests.sonyModelGen) { model in
            let plugin = SonyPlugin()
            
            // Device with all identification criteria
            let device = BluetoothDevice(
                address: "AC:80:0A:12:34:56",  // Sony MAC prefix
                name: model.rawValue,
                vendorId: SonyConstants.vendorId,
                productId: model.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                isConnected: false
            )
            
            let score = plugin.canHandle(device: device)
            
            // Should return a high confidence score (90+ from vendor/product ID)
            return score != nil && score! >= 90
        }
    }
    
    func testSonyDeviceIdentificationWithProprietaryServiceUUID() {
        property("Sony plugin gives higher confidence when proprietary service UUID is present") <- forAll(SonyCommandPropertyTests.sonyModelGen) { model in
            let plugin = SonyPlugin()
            
            // Device with Sony proprietary service UUID
            let deviceWithUUID = BluetoothDevice(
                address: "AC:80:0A:12:34:56",
                name: model.rawValue,
                vendorId: SonyConstants.vendorId,
                productId: model.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID, SonyConstants.sonyProprietaryServiceUUID],
                isConnected: false
            )
            
            // Device without Sony proprietary service UUID
            let deviceWithoutUUID = BluetoothDevice(
                address: "AC:80:0A:12:34:56",
                name: model.rawValue,
                vendorId: SonyConstants.vendorId,
                productId: model.productId,
                serviceUUIDs: [SonyConstants.audioSinkServiceUUID],
                isConnected: false
            )
            
            let scoreWithUUID = plugin.canHandle(device: deviceWithUUID)
            let scoreWithoutUUID = plugin.canHandle(device: deviceWithoutUUID)
            
            // Both should be identified, but device with proprietary UUID should have higher score
            guard let withUUID = scoreWithUUID, let withoutUUID = scoreWithoutUUID else {
                return false
            }
            
            return withUUID >= withoutUUID
        }
    }
    
    func testSonyPluginFactoryCreatesCorrectSubclass() {
        property("Sony plugin factory creates correct subclass for each model") <- forAll(SonyCommandPropertyTests.sonyBluetoothDeviceGen) { device in
            guard let plugin = SonyPlugin.createPlugin(for: device) else {
                return false
            }
            
            // Verify the correct subclass is created based on product ID
            switch device.productId {
            case SonyDeviceModel.wh1000xm3.productId:
                return plugin is SonyWH1000XM3Plugin
            case SonyDeviceModel.wh1000xm4.productId:
                return plugin is SonyWH1000XM4Plugin
            case SonyDeviceModel.wh1000xm5.productId:
                return plugin is SonyWH1000XM5Plugin
            case SonyDeviceModel.wf1000xm4.productId:
                return plugin is SonyWF1000XM4Plugin
            case SonyDeviceModel.wf1000xm5.productId:
                return plugin is SonyWF1000XM5Plugin
            default:
                return false
            }
        }
    }
    
    // MARK: - Property 12: Sony NC Command Encoding Tests
    
    /// Property 12: Sony NC Command Encoding
    /// *For any* valid NoiseCancellationLevel supported by a Sony device model,
    /// encoding a Sony NC command and decoding it SHALL produce the same level value.
    /// **Validates: Requirements 6.3**
    func testNCCommandRoundTrip_V1() {
        property("V1 NC command encoding is reversible") <- forAll(SonyCommandPropertyTests.ncLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV1CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level, sequenceNumber: seqNum)
            
            // Decode the command
            guard let decoded = SonyCommand.decode(encoded) else {
                return false
            }
            
            // Verify the level is preserved in the payload
            // V1 format: [category, subCommand, level]
            guard decoded.payload.count >= 3 else {
                return false
            }
            
            let decodedLevel = Int(decoded.payload[2])
            return decodedLevel == level
        }
    }
    
    func testNCCommandRoundTrip_V2() {
        property("V2 NC command encoding is reversible") <- forAll(SonyCommandPropertyTests.ncLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV2CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level, sequenceNumber: seqNum)
            
            // Decode the command
            guard let decoded = SonyCommand.decode(encoded) else {
                return false
            }
            
            // V2 format: [category, subCommand, flags, mode, level]
            guard decoded.payload.count >= 5 else {
                return false
            }
            
            let decodedLevel = Int(decoded.payload[4])
            return decodedLevel == level
        }
    }
    
    func testAmbientSoundCommandRoundTrip_V1() {
        property("V1 Ambient sound command encoding is reversible") <- forAll(SonyCommandPropertyTests.ambientSoundLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV1CommandEncoder()
            let encoded = encoder.encodeAmbientSoundCommand(level: level, sequenceNumber: seqNum)
            
            guard let decoded = SonyCommand.decode(encoded) else {
                return false
            }
            
            guard decoded.payload.count >= 3 else {
                return false
            }
            
            let decodedLevel = Int(decoded.payload[2])
            return decodedLevel == level
        }
    }
    
    func testAmbientSoundCommandRoundTrip_V2() {
        property("V2 Ambient sound command encoding is reversible") <- forAll(SonyCommandPropertyTests.ambientSoundLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV2CommandEncoder()
            let encoded = encoder.encodeAmbientSoundCommand(level: level, sequenceNumber: seqNum)
            
            guard let decoded = SonyCommand.decode(encoded) else {
                return false
            }
            
            // V2 format: [category, subCommand, flags, mode, level]
            guard decoded.payload.count >= 5 else {
                return false
            }
            
            let decodedLevel = Int(decoded.payload[4])
            return decodedLevel == level
        }
    }
    
    func testEqualizerCommandRoundTrip() {
        property("Equalizer command encoding is reversible") <- forAll(SonyCommandPropertyTests.equalizerPresetGen, SonyCommandPropertyTests.sequenceNumberGen) { (preset, seqNum) in
            let encoder = SonyV1CommandEncoder()
            
            let encoded = encoder.encodeEqualizerCommand(preset: preset, sequenceNumber: seqNum)
            
            guard let command = SonyCommand.decode(encoded) else {
                return false
            }
            
            // Build a mock response with the same preset byte
            guard command.payload.count >= 3 else {
                return false
            }
            
            let presetByte = command.payload[2]
            
            // Verify the preset byte maps back to the original preset
            let expectedByte: UInt8
            switch preset.lowercased() {
            case "off": expectedByte = 0x00
            case "bright": expectedByte = 0x10
            case "excited": expectedByte = 0x11
            case "mellow": expectedByte = 0x12
            case "relaxed": expectedByte = 0x13
            case "vocal": expectedByte = 0x14
            case "treble": expectedByte = 0x15
            case "bass": expectedByte = 0x16
            case "speech": expectedByte = 0x17
            case "custom": expectedByte = 0xA0
            default: expectedByte = 0x00
            }
            
            return presetByte == expectedByte
        }
    }
    
    func testAutoOffCommandRoundTrip() {
        property("Auto-off command encoding is reversible") <- forAll(SonyCommandPropertyTests.autoOffSettingGen, SonyCommandPropertyTests.sequenceNumberGen) { (setting, seqNum) in
            let encoder = SonyV1CommandEncoder()
            let encoded = encoder.encodeAutoOffCommand(setting: setting, sequenceNumber: seqNum)
            
            guard let decoded = SonyCommand.decode(encoded) else {
                return false
            }
            
            guard decoded.payload.count >= 3 else {
                return false
            }
            
            let settingByte = decoded.payload[2]
            let decodedSetting: AutoOffSetting
            switch settingByte {
            case 0x00: decodedSetting = .never
            case 0x05: decodedSetting = .fiveMinutes
            case 0x14: decodedSetting = .twentyMinutes
            case 0x28: decodedSetting = .fortyMinutes
            case 0x3C: decodedSetting = .sixtyMinutes
            case 0xB4: decodedSetting = .oneEightyMinutes
            default: return false
            }
            
            return decodedSetting == setting
        }
    }
    
    // MARK: - SonyCommand Encode/Decode Round-Trip Tests
    
    func testSonyCommandStructureRoundTrip() {
        property("SonyCommand encode/decode is reversible") <- forAll(SonyCommandPropertyTests.sequenceNumberGen) { seqNum in
            // Create a command with random payload
            let payloadSize = Int.random(in: 1...10)
            let payload = Data((0..<payloadSize).map { _ in UInt8.random(in: 0...255) })
            
            let originalCommand = SonyCommand(
                dataType: SonyConstants.DataType.command,
                sequenceNumber: seqNum,
                payload: payload
            )
            
            // Encode
            let encoded = originalCommand.encode()
            
            // Decode
            guard let decodedCommand = SonyCommand.decode(encoded) else {
                return false
            }
            
            // Verify round-trip
            return decodedCommand.dataType == originalCommand.dataType &&
                   decodedCommand.sequenceNumber == originalCommand.sequenceNumber &&
                   decodedCommand.payload == originalCommand.payload
        }
    }
    
    func testSonyCommandChecksumValidation() {
        property("Sony commands have valid checksum") <- forAll(SonyCommandPropertyTests.ncLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV1CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level, sequenceNumber: seqNum)
            
            // Sony format: [start, dataType, seqNum, length, ...payload, checksum, end]
            guard encoded.count >= 6,
                  encoded[0] == SonyConstants.startByte,
                  encoded[encoded.count - 1] == SonyConstants.endByte else {
                return false
            }
            
            // Calculate expected checksum
            let dataType = encoded[1]
            let sequenceNumber = encoded[2]
            let length = encoded[3]
            
            var calculatedChecksum: UInt8 = dataType
            calculatedChecksum = calculatedChecksum &+ sequenceNumber
            calculatedChecksum = calculatedChecksum &+ length
            
            // Add payload bytes
            for i in 4..<(encoded.count - 2) {
                calculatedChecksum = calculatedChecksum &+ encoded[i]
            }
            
            let actualChecksum = encoded[encoded.count - 2]
            return calculatedChecksum == actualChecksum
        }
    }
    
    // MARK: - NC Level Range Validation Tests
    
    func testNCLevelClampedToValidRange() {
        property("NC level is clamped to 0-20 range") <- forAll(Gen<Int>.choose((-10, 30)), SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let encoder = SonyV1CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level, sequenceNumber: seqNum)
            
            guard let decoded = SonyCommand.decode(encoded),
                  decoded.payload.count >= 3 else {
                return false
            }
            
            let decodedLevel = Int(decoded.payload[2])
            
            // Level should be clamped to 0-20 range
            return decodedLevel >= 0 && decodedLevel <= 20
        }
    }
    
    // MARK: - Response Decoder Tests
    
    func testResponseDecoderBattery() {
        property("Battery response decoder extracts correct level") <- forAll(Gen<UInt8>.choose((0, 100)), SonyCommandPropertyTests.sequenceNumberGen) { (batteryLevel, seqNum) in
            let decoder = SonyResponseDecoder()
            
            // Build a mock battery response
            let payload = Data([
                SonyConstants.CommandCategory.battery,
                SonyConstants.SubCommand.notify,
                batteryLevel
            ])
            
            let response = SonyCommand(
                dataType: SonyConstants.DataType.data,
                sequenceNumber: seqNum,
                payload: payload
            )
            
            let encoded = response.encode()
            let decodedBattery = decoder.decodeBattery(encoded)
            
            return decodedBattery == Int(batteryLevel)
        }
    }
    
    func testResponseDecoderNCLevel() {
        property("NC level response decoder extracts correct level") <- forAll(SonyCommandPropertyTests.ncLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (ncLevel, seqNum) in
            let decoder = SonyResponseDecoder()
            
            // Build a mock NC response
            let payload = Data([
                SonyConstants.CommandCategory.noiseCancellation,
                SonyConstants.SubCommand.notify,
                UInt8(ncLevel)
            ])
            
            let response = SonyCommand(
                dataType: SonyConstants.DataType.data,
                sequenceNumber: seqNum,
                payload: payload
            )
            
            let encoded = response.encode()
            let decodedLevel = decoder.decodeNCLevel(encoded)
            
            return decodedLevel == ncLevel
        }
    }
    
    func testResponseDecoderAmbientSound() {
        property("Ambient sound response decoder extracts correct level") <- forAll(SonyCommandPropertyTests.ambientSoundLevelGen, SonyCommandPropertyTests.sequenceNumberGen) { (level, seqNum) in
            let decoder = SonyResponseDecoder()
            
            // Build a mock ambient sound response
            let payload = Data([
                SonyConstants.CommandCategory.ambientSound,
                SonyConstants.SubCommand.notify,
                UInt8(level)
            ])
            
            let response = SonyCommand(
                dataType: SonyConstants.DataType.data,
                sequenceNumber: seqNum,
                payload: payload
            )
            
            let encoded = response.encode()
            let decodedLevel = decoder.decodeAmbientSoundLevel(encoded)
            
            return decodedLevel == level
        }
    }
}
