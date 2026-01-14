import XCTest
@testable import SoundSherpa

/// Unit tests for device identification
/// **Validates: Requirements 2.2**
final class DeviceIdentificationTests: XCTestCase {
    
    // MARK: - Vendor/Product ID Tests
    
    /// Test that vendor ID + product ID match gives highest score
    func testVendorProductIdMatchGivesHighestScore() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        XCTAssertEqual(score, 80) // Vendor + Product ID match = 80 points
    }
    
    /// Test that vendor ID alone doesn't match (needs product ID too for full score)
    func testVendorIdAloneDoesNotGiveFullScore() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x9999" // Different product ID
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        // Should be nil because no criteria matched above threshold
        XCTAssertNil(score)
    }
    
    /// Test case-insensitive vendor/product ID matching
    func testVendorProductIdMatchingIsCaseInsensitive() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009e", // lowercase
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        XCTAssertEqual(score, 80)
    }
    
    // MARK: - Service UUID Tests
    
    /// Test service UUID matching adds to score
    func testServiceUUIDMatchAddsToScore() {
        let identifier = DeviceIdentifier(
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        // Service UUID alone (15 points) is below threshold (51), so nil
        XCTAssertNil(score)
    }
    
    /// Test multiple service UUIDs - only needs one match
    func testMultipleServiceUUIDsOnlyNeedOneMatch() {
        let identifier = DeviceIdentifier(
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB", "0000180F-0000-1000-8000-00805F9B34FB"],
            namePattern: ".*", // Add name pattern to get above threshold
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"] // Only one matches
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        // Service UUID (15) + name pattern (3) = 18, below threshold
        XCTAssertNil(score)
    }
    
    /// Test service UUID matching is case-insensitive
    func testServiceUUIDMatchingIsCaseInsensitive() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110b-0000-1000-8000-00805f9b34fb"] // lowercase
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Vendor+Product (80) + Service UUID (15) = 95, capped at confidenceScore
        XCTAssertEqual(score, 95)
    }
    
    // MARK: - MAC Address Prefix Tests
    
    /// Test MAC address prefix matching
    func testMACAddressPrefixMatching() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            macAddressPrefix: "04:52:C7",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Vendor+Product (80) + MAC prefix (10) = 90
        XCTAssertEqual(score, 90)
    }
    
    /// Test MAC address prefix matching is case-insensitive
    func testMACAddressPrefixMatchingIsCaseInsensitive() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            macAddressPrefix: "04:52:c7", // lowercase
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC", // uppercase
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        XCTAssertEqual(score, 90)
    }
    
    /// Test MAC address prefix mismatch
    func testMACAddressPrefixMismatch() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            macAddressPrefix: "AC:80:0A", // Sony prefix
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC", // Bose prefix
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Only Vendor+Product (80), no MAC prefix bonus
        XCTAssertEqual(score, 80)
    }
    
    // MARK: - Confidence Score Tests
    
    /// Test that score is capped at confidence score
    func testScoreIsCappedAtConfidenceScore() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"],
            macAddressPrefix: "04:52:C7",
            confidenceScore: 70 // Lower cap
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Raw score would be 80+15+10=105, but capped at 70
        XCTAssertEqual(score, 70)
    }
    
    /// Test minimum threshold rejection
    func testMinimumThresholdRejection() {
        let identifier = DeviceIdentifier(
            namePattern: ".*", // Only name pattern match (3 points)
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Any Device"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        // 3 points is below 51 threshold
        XCTAssertNil(score)
    }
    
    // MARK: - Name Pattern Tests
    
    /// Test name pattern matching with regex
    func testNamePatternMatchingWithRegex() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            namePattern: "Bose QC35.*",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Vendor+Product (80) + name pattern (3) = 83
        XCTAssertEqual(score, 83)
    }
    
    /// Test name pattern mismatch
    func testNamePatternMismatch() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            namePattern: "Sony.*", // Won't match Bose device
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNotNil(score)
        // Only Vendor+Product (80), no name pattern bonus
        XCTAssertEqual(score, 80)
    }
    
    // MARK: - Edge Cases
    
    /// Test device with no identification data
    func testDeviceWithNoIdentificationData() {
        let identifier = DeviceIdentifier(
            vendorId: "0x009E",
            productId: "0x4002",
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "AA:BB:CC:DD:EE:FF",
            name: "Unknown Device"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNil(score)
    }
    
    /// Test identifier with no criteria
    func testIdentifierWithNoCriteria() {
        let identifier = DeviceIdentifier(
            confidenceScore: 95
        )
        
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Bose QC35 II",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        
        let score = identifier.calculateMatchScore(for: device)
        
        XCTAssertNil(score)
    }
    
    /// Test hasIdentificationCriteria property
    func testHasIdentificationCriteria() {
        let emptyIdentifier = DeviceIdentifier(confidenceScore: 50)
        XCTAssertFalse(emptyIdentifier.hasIdentificationCriteria)
        
        let vendorIdentifier = DeviceIdentifier(vendorId: "0x009E", confidenceScore: 50)
        XCTAssertTrue(vendorIdentifier.hasIdentificationCriteria)
        
        let serviceIdentifier = DeviceIdentifier(serviceUUIDs: ["test-uuid"], confidenceScore: 50)
        XCTAssertTrue(serviceIdentifier.hasIdentificationCriteria)
        
        let nameIdentifier = DeviceIdentifier(namePattern: ".*", confidenceScore: 50)
        XCTAssertTrue(nameIdentifier.hasIdentificationCriteria)
        
        let macIdentifier = DeviceIdentifier(macAddressPrefix: "04:52:C7", confidenceScore: 50)
        XCTAssertTrue(macIdentifier.hasIdentificationCriteria)
    }
    
    // MARK: - BluetoothDevice Helper Tests
    
    /// Test hasServiceUUID helper
    func testHasServiceUUID() {
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            serviceUUIDs: ["0000110B-0000-1000-8000-00805F9B34FB"]
        )
        
        XCTAssertTrue(device.hasServiceUUID("0000110B-0000-1000-8000-00805F9B34FB"))
        XCTAssertTrue(device.hasServiceUUID("0000110b-0000-1000-8000-00805f9b34fb")) // case-insensitive
        XCTAssertFalse(device.hasServiceUUID("0000180F-0000-1000-8000-00805F9B34FB"))
    }
    
    /// Test hasMACPrefix helper
    func testHasMACPrefix() {
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device"
        )
        
        XCTAssertTrue(device.hasMACPrefix("04:52:C7"))
        XCTAssertTrue(device.hasMACPrefix("04:52:c7")) // case-insensitive
        XCTAssertFalse(device.hasMACPrefix("AC:80:0A"))
    }
    
    /// Test hasVendorAndProductId helper
    func testHasVendorAndProductId() {
        let deviceWithBoth = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            vendorId: "0x009E",
            productId: "0x4002"
        )
        XCTAssertTrue(deviceWithBoth.hasVendorAndProductId)
        
        let deviceWithVendorOnly = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            vendorId: "0x009E"
        )
        XCTAssertFalse(deviceWithVendorOnly.hasVendorAndProductId)
        
        let deviceWithNeither = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device"
        )
        XCTAssertFalse(deviceWithNeither.hasVendorAndProductId)
    }
    
    /// Test manufacturerId extraction
    func testManufacturerId() {
        // Manufacturer data with ID 0x009E (Bose) in little-endian
        let manufacturerData = Data([0x9E, 0x00, 0x01, 0x02, 0x03])
        let device = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            manufacturerData: manufacturerData
        )
        
        XCTAssertEqual(device.manufacturerId, 0x009E)
        XCTAssertEqual(device.manufacturerPayload, Data([0x01, 0x02, 0x03]))
    }
    
    /// Test manufacturerId with insufficient data
    func testManufacturerIdWithInsufficientData() {
        let device1 = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            manufacturerData: Data([0x9E]) // Only 1 byte
        )
        XCTAssertNil(device1.manufacturerId)
        
        let device2 = BluetoothDevice(
            address: "04:52:C7:AA:BB:CC",
            name: "Test Device",
            manufacturerData: nil
        )
        XCTAssertNil(device2.manufacturerId)
    }
}
