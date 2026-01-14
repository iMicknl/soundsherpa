import XCTest
import SwiftCheck
@testable import SoundSherpa

/// Property tests for Bose command encoding/decoding
/// Feature: multi-device-support, Property 9: Bose Command Round-Trip
/// Feature: multi-device-support, Property 10: Bose Paired Device Parsing
/// **Validates: Requirements 5.2, 5.3, 5.4, 5.5, 5.6, 5.7**
final class BoseCommandPropertyTests: XCTestCase {
    
    // MARK: - Generators
    
    /// Generator for valid noise cancellation levels
    static let ncLevelGen: Gen<NoiseCancellationLevel> = Gen<NoiseCancellationLevel>.fromElements(of: NoiseCancellationLevel.allCases)
    
    /// Generator for valid self-voice levels
    static let selfVoiceLevelGen: Gen<SelfVoiceLevel> = Gen<SelfVoiceLevel>.fromElements(of: SelfVoiceLevel.allCases)
    
    /// Generator for valid auto-off settings
    static let autoOffSettingGen: Gen<AutoOffSetting> = Gen<AutoOffSetting>.fromElements(of: AutoOffSetting.allCases)
    
    /// Generator for valid device languages
    static let languageGen: Gen<DeviceLanguage> = Gen<DeviceLanguage>.fromElements(of: DeviceLanguage.allCases)
    
    /// Generator for valid button action settings
    static let buttonActionGen: Gen<ButtonActionSetting> = Gen<ButtonActionSetting>.fromElements(of: ButtonActionSetting.allCases)
    
    /// Generator for valid MAC addresses
    static let macAddressGen: Gen<String> = Gen<String>.compose { c in
        let bytes = (0..<6).map { _ in String(format: "%02X", c.generate(using: Gen<UInt8>.choose((0, 255)))) }
        return bytes.joined(separator: ":")
    }
    
    /// Generator for device names
    static let deviceNameGen: Gen<String> = Gen<String>.frequency([
        (3, Gen.pure("iPhone")),
        (2, Gen.pure("MacBook Pro")),
        (2, Gen.pure("iPad")),
        (1, Gen.pure("Windows PC")),
        (1, Gen.pure("Android Phone")),
        (1, Gen.pure("Unknown Device"))
    ])
    
    // MARK: - Property 9: Bose Command Round-Trip Tests
    
    /// Property 9: Bose Command Round-Trip
    /// *For any* valid Bose command type (noise cancellation, self-voice, auto-off, language, button action)
    /// and valid parameter values, encoding the command to bytes and then decoding those bytes
    /// SHALL produce an equivalent command structure.
    /// **Validates: Requirements 5.2, 5.3, 5.4, 5.5, 5.7**
    func testNCCommandRoundTrip_V1() {
        property("V1 NC command encoding is reversible") <- forAll(BoseCommandPropertyTests.ncLevelGen) { level in
            // Skip adaptive for V1 (not supported)
            guard level != .adaptive else { return true }
            
            let encoder = BoseV1CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level)
            
            // Verify command structure
            guard encoded.count >= 5 else { return false }
            
            // Decode the level byte
            let levelByte = encoded[4]
            let decodedLevel: NoiseCancellationLevel
            switch levelByte {
            case 0x00: decodedLevel = .off
            case 0x01: decodedLevel = .high
            case 0x02: decodedLevel = .medium
            case 0x03: decodedLevel = .low
            default: return false
            }
            
            return decodedLevel == level
        }
    }
    
    func testNCCommandRoundTrip_V2() {
        property("V2 NC command encoding is reversible") <- forAll(BoseCommandPropertyTests.ncLevelGen) { level in
            let encoder = BoseV2CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level)
            
            // V2 format: [length, functionBlock, function, operator, payloadLength, levelByte, checksum]
            guard encoded.count >= 7 else { return false }
            
            // Decode the level byte (at position 5 in V2 format)
            let levelByte = encoded[5]
            let decodedLevel: NoiseCancellationLevel
            switch levelByte {
            case 0x00: decodedLevel = .off
            case 0x01: decodedLevel = .high
            case 0x02: decodedLevel = .medium
            case 0x03: decodedLevel = .low
            case 0x04: decodedLevel = .adaptive
            default: return false
            }
            
            return decodedLevel == level
        }
    }
    
    func testSelfVoiceCommandRoundTrip_V1() {
        property("V1 Self-voice command encoding is reversible") <- forAll(BoseCommandPropertyTests.selfVoiceLevelGen) { level in
            let encoder = BoseV1CommandEncoder()
            let encoded = encoder.encodeSelfVoiceCommand(level: level)
            
            guard encoded.count >= 5 else { return false }
            
            let levelByte = encoded[4]
            let decodedLevel: SelfVoiceLevel
            switch levelByte {
            case 0x00: decodedLevel = .off
            case 0x01: decodedLevel = .low
            case 0x02: decodedLevel = .medium
            case 0x03: decodedLevel = .high
            default: return false
            }
            
            return decodedLevel == level
        }
    }
    
    func testAutoOffCommandRoundTrip_V1() {
        property("V1 Auto-off command encoding is reversible") <- forAll(BoseCommandPropertyTests.autoOffSettingGen) { setting in
            let encoder = BoseV1CommandEncoder()
            let encoded = encoder.encodeAutoOffCommand(setting: setting)
            
            guard encoded.count >= 5 else { return false }
            
            let settingByte = encoded[4]
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
    
    func testLanguageCommandRoundTrip_V1() {
        property("V1 Language command encoding is reversible") <- forAll(BoseCommandPropertyTests.languageGen, Bool.arbitrary) { (language, voicePromptsEnabled) in
            let encoder = BoseV1CommandEncoder()
            let encoded = encoder.encodeLanguageCommand(language: language, voicePromptsEnabled: voicePromptsEnabled)
            
            guard encoded.count >= 6 else { return false }
            
            let languageByte = encoded[4]
            let voicePromptsByte = encoded[5]
            
            let decodedLanguage: DeviceLanguage
            switch languageByte {
            case 0x00: decodedLanguage = .english
            case 0x01: decodedLanguage = .french
            case 0x02: decodedLanguage = .italian
            case 0x03: decodedLanguage = .german
            case 0x04: decodedLanguage = .spanish
            case 0x05: decodedLanguage = .portuguese
            case 0x06: decodedLanguage = .chinese
            case 0x07: decodedLanguage = .korean
            case 0x08: decodedLanguage = .polish
            case 0x09: decodedLanguage = .russian
            case 0x0A: decodedLanguage = .dutch
            case 0x0B: decodedLanguage = .japanese
            case 0x0C: decodedLanguage = .swedish
            default: return false
            }
            
            let decodedVoicePrompts = voicePromptsByte == 0x01
            
            return decodedLanguage == language && decodedVoicePrompts == voicePromptsEnabled
        }
    }
    
    func testButtonActionCommandRoundTrip_V1() {
        property("V1 Button action command encoding is reversible") <- forAll(BoseCommandPropertyTests.buttonActionGen) { action in
            let encoder = BoseV1CommandEncoder()
            let encoded = encoder.encodeButtonActionCommand(action: action)
            
            guard encoded.count >= 5 else { return false }
            
            let actionByte = encoded[4]
            let decodedAction: ButtonActionSetting
            switch actionByte {
            case 0x00: decodedAction = .voiceAssistant
            case 0x01: decodedAction = .noiseCancellation
            case 0x02: decodedAction = .playPause
            case 0x03: decodedAction = .custom
            default: return false
            }
            
            return decodedAction == action
        }
    }

    
    // MARK: - BoseCommand Encode/Decode Round-Trip
    
    func testBoseCommandStructureRoundTrip() {
        property("BoseCommand encode/decode is reversible") <- forAll { (functionBlock: UInt8, function: UInt8, operatorByte: UInt8) in
            // Create a command with random payload
            let payloadSize = Int.random(in: 0...10)
            let payload = Data((0..<payloadSize).map { _ in UInt8.random(in: 0...255) })
            
            let originalCommand = BoseCommand(
                functionBlock: functionBlock,
                function: function,
                operatorByte: operatorByte,
                payload: payload
            )
            
            // Encode
            let encoded = originalCommand.encode()
            
            // Decode
            guard let decodedCommand = BoseCommand.decode(encoded) else {
                return false
            }
            
            // Verify round-trip
            return decodedCommand.functionBlock == originalCommand.functionBlock &&
                   decodedCommand.function == originalCommand.function &&
                   decodedCommand.operatorByte == originalCommand.operatorByte &&
                   decodedCommand.payload == originalCommand.payload
        }
    }
    
    // MARK: - Property 10: Bose Paired Device Parsing Tests
    
    /// Property 10: Bose Paired Device Parsing
    /// *For any* valid Bose paired devices response containing N device entries,
    /// parsing the response SHALL produce exactly N PairedDevice objects with valid MAC addresses.
    /// **Validates: Requirements 5.6**
    func testPairedDeviceParsingProducesCorrectCount() {
        property("Paired device parsing produces correct number of devices") <- forAll(Gen<Int>.choose((0, 5))) { deviceCount in
            let decoder = BoseResponseDecoder()
            
            // Build a mock paired devices response
            var responseData = Data([
                BoseConstants.FunctionBlock.deviceManagement,
                BoseConstants.Function.pairedDevices,
                BoseConstants.Operator.result,
                UInt8(deviceCount)  // Device count
            ])
            
            // Add device entries
            for i in 0..<deviceCount {
                // MAC address (6 bytes)
                let macBytes: [UInt8] = [0x04, 0x52, 0xC7, UInt8(i), 0x00, 0x01]
                responseData.append(contentsOf: macBytes)
                
                // Status byte (connected = 0x01, current = 0x02)
                let statusByte: UInt8 = i == 0 ? 0x03 : 0x00  // First device is connected and current
                responseData.append(statusByte)
                
                // Name length and name
                let name = "Device \(i)"
                responseData.append(UInt8(name.count))
                responseData.append(contentsOf: name.data(using: .utf8)!)
            }
            
            // Parse
            let devices = decoder.decodePairedDevices(responseData)
            
            // Verify count
            return devices.count == deviceCount
        }
    }
    
    func testPairedDeviceParsingProducesValidMACAddresses() {
        property("Parsed paired devices have valid MAC addresses") <- forAll(Gen<Int>.choose((1, 5))) { deviceCount in
            let decoder = BoseResponseDecoder()
            
            // Build a mock paired devices response
            var responseData = Data([
                BoseConstants.FunctionBlock.deviceManagement,
                BoseConstants.Function.pairedDevices,
                BoseConstants.Operator.result,
                UInt8(deviceCount)
            ])
            
            // Store expected MAC addresses
            var expectedMACs: [String] = []
            
            for i in 0..<deviceCount {
                // Generate random MAC bytes
                let macBytes: [UInt8] = (0..<6).map { _ in UInt8.random(in: 0...255) }
                let expectedMAC = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                expectedMACs.append(expectedMAC)
                
                responseData.append(contentsOf: macBytes)
                responseData.append(0x00)  // Status byte
                
                let name = "Device \(i)"
                responseData.append(UInt8(name.count))
                responseData.append(contentsOf: name.data(using: .utf8)!)
            }
            
            // Parse
            let devices = decoder.decodePairedDevices(responseData)
            
            // Verify all MAC addresses are valid format (XX:XX:XX:XX:XX:XX)
            let macPattern = "^([0-9A-F]{2}:){5}[0-9A-F]{2}$"
            for device in devices {
                if device.id.range(of: macPattern, options: .regularExpression) == nil {
                    return false
                }
            }
            
            // Verify MAC addresses match expected
            for (index, device) in devices.enumerated() {
                if device.id != expectedMACs[index] {
                    return false
                }
            }
            
            return true
        }
    }
    
    func testPairedDeviceParsingPreservesConnectionStatus() {
        property("Parsed paired devices preserve connection status") <- forAll(Gen<Int>.choose((1, 5))) { deviceCount in
            let decoder = BoseResponseDecoder()
            
            var responseData = Data([
                BoseConstants.FunctionBlock.deviceManagement,
                BoseConstants.Function.pairedDevices,
                BoseConstants.Operator.result,
                UInt8(deviceCount)
            ])
            
            var expectedStatuses: [(isConnected: Bool, isCurrentDevice: Bool)] = []
            
            for i in 0..<deviceCount {
                let macBytes: [UInt8] = [0x04, 0x52, 0xC7, UInt8(i), 0x00, 0x01]
                responseData.append(contentsOf: macBytes)
                
                // Random status
                let isConnected = Bool.random()
                let isCurrentDevice = Bool.random()
                var statusByte: UInt8 = 0
                if isConnected { statusByte |= 0x01 }
                if isCurrentDevice { statusByte |= 0x02 }
                responseData.append(statusByte)
                expectedStatuses.append((isConnected, isCurrentDevice))
                
                let name = "Device \(i)"
                responseData.append(UInt8(name.count))
                responseData.append(contentsOf: name.data(using: .utf8)!)
            }
            
            let devices = decoder.decodePairedDevices(responseData)
            
            // Verify statuses match
            for (index, device) in devices.enumerated() {
                if device.isConnected != expectedStatuses[index].isConnected ||
                   device.isCurrentDevice != expectedStatuses[index].isCurrentDevice {
                    return false
                }
            }
            
            return true
        }
    }
    
    // MARK: - V2 Protocol Checksum Tests
    
    func testV2CommandsHaveValidChecksum() {
        property("V2 commands have valid checksum") <- forAll(BoseCommandPropertyTests.ncLevelGen) { level in
            let encoder = BoseV2CommandEncoder()
            let encoded = encoder.encodeNCCommand(level: level)
            
            // V2 format: [length, payload..., checksum]
            guard encoded.count >= 2 else { return false }
            
            let length = Int(encoded[0])
            guard encoded.count == length + 2 else { return false }  // length byte + payload + checksum
            
            // Verify checksum
            let payload = encoded.subdata(in: 1..<(encoded.count - 1))
            var calculatedChecksum: UInt8 = 0
            for byte in payload {
                calculatedChecksum = calculatedChecksum &+ byte
            }
            calculatedChecksum = ~calculatedChecksum &+ 1
            
            let actualChecksum = encoded[encoded.count - 1]
            return calculatedChecksum == actualChecksum
        }
    }
}
