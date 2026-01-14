import Foundation

/// Scoring weights for multi-criteria device identification
public struct IdentificationScoreWeights {
    /// Weight for vendor ID + product ID match (highest confidence)
    public static let vendorProductMatch: Int = 80
    
    /// Weight for service UUID match
    public static let serviceUUIDMatch: Int = 15
    
    /// Weight for MAC address prefix match
    public static let macPrefixMatch: Int = 10
    
    /// Weight for manufacturer data signature match
    public static let manufacturerDataMatch: Int = 5
    
    /// Weight for name pattern match (lowest confidence, fallback only)
    public static let namePatternMatch: Int = 3
    
    /// Minimum score threshold for accepting a device match
    public static let minimumThreshold: Int = 51
}

/// Information used to identify a device with multiple identification strategies
public struct DeviceIdentifier: Equatable, Hashable {
    /// Bluetooth vendor ID (e.g., "0x009E" for Bose)
    public let vendorId: String?
    
    /// Bluetooth product ID
    public let productId: String?
    
    /// Bluetooth service UUIDs
    public let serviceUUIDs: [String]
    
    /// Regex pattern for device name (fallback only)
    public let namePattern: String?
    
    /// MAC address prefix for specific models
    public let macAddressPrefix: String?
    
    /// Higher = more specific match (0-100)
    public let confidenceScore: Int
    
    /// Additional device-specific identifiers (e.g., ["firmwareSignature": "BOSE_QC35"])
    public let customIdentifiers: [String: String]
    
    public init(
        vendorId: String? = nil,
        productId: String? = nil,
        serviceUUIDs: [String] = [],
        namePattern: String? = nil,
        macAddressPrefix: String? = nil,
        confidenceScore: Int = 50,
        customIdentifiers: [String: String] = [:]
    ) {
        self.vendorId = vendorId
        self.productId = productId
        self.serviceUUIDs = serviceUUIDs
        self.namePattern = namePattern
        self.macAddressPrefix = macAddressPrefix
        self.confidenceScore = confidenceScore
        self.customIdentifiers = customIdentifiers
    }
    
    /// Calculate a match score for a given BluetoothDevice using multi-criteria identification
    /// - Parameter device: The Bluetooth device to match against
    /// - Returns: A score (0-100) indicating match confidence, or nil if below threshold
    public func calculateMatchScore(for device: BluetoothDevice) -> Int? {
        var score = 0
        
        // Primary identification: Vendor + Product ID (highest confidence)
        if let deviceVendorId = device.vendorId,
           let deviceProductId = device.productId,
           let identifierVendorId = vendorId,
           let identifierProductId = productId,
           deviceVendorId.uppercased() == identifierVendorId.uppercased(),
           deviceProductId.uppercased() == identifierProductId.uppercased() {
            score += IdentificationScoreWeights.vendorProductMatch
        }
        
        // Secondary: Service UUIDs match
        let deviceUUIDs = Set(device.serviceUUIDs.map { $0.uppercased() })
        let identifierUUIDs = Set(serviceUUIDs.map { $0.uppercased() })
        let commonServices = deviceUUIDs.intersection(identifierUUIDs)
        if !commonServices.isEmpty {
            score += IdentificationScoreWeights.serviceUUIDMatch
        }
        
        // Tertiary: MAC address prefix
        if let macPrefix = macAddressPrefix,
           device.address.uppercased().hasPrefix(macPrefix.uppercased()) {
            score += IdentificationScoreWeights.macPrefixMatch
        }
        
        // Quaternary: Manufacturer data signature
        if let manufacturerData = device.manufacturerData,
           let signature = customIdentifiers["firmwareSignature"],
           let signatureData = signature.data(using: .utf8) {
            if manufacturerData.range(of: signatureData) != nil {
                score += IdentificationScoreWeights.manufacturerDataMatch
            }
        }
        
        // Fallback: Name pattern (lowest confidence)
        if let pattern = namePattern,
           device.name.range(of: pattern, options: .regularExpression) != nil {
            score += IdentificationScoreWeights.namePatternMatch
        }
        
        // Apply confidence cap - score cannot exceed the identifier's confidence score
        if score > 0 {
            score = min(score, confidenceScore)
        }
        
        // Return nil if below minimum threshold
        return score >= IdentificationScoreWeights.minimumThreshold ? score : nil
    }
    
    /// Check if this identifier has at least one identification criterion
    public var hasIdentificationCriteria: Bool {
        return vendorId != nil ||
               productId != nil ||
               !serviceUUIDs.isEmpty ||
               namePattern != nil ||
               macAddressPrefix != nil
    }
}

/// Enhanced Bluetooth device information
public struct BluetoothDevice: Equatable {
    /// MAC address
    public let address: String
    
    /// User-changeable name
    public let name: String
    
    /// Bluetooth vendor ID
    public let vendorId: String?
    
    /// Bluetooth product ID
    public let productId: String?
    
    /// Available Bluetooth services
    public let serviceUUIDs: [String]
    
    /// Connection status
    public let isConnected: Bool
    
    /// Signal strength
    public let rssi: Int?
    
    /// Bluetooth device class
    public let deviceClass: UInt32?
    
    /// Manufacturer-specific data
    public let manufacturerData: Data?
    
    /// BLE advertisement data
    public let advertisementData: [String: Any]?
    
    public init(
        address: String,
        name: String,
        vendorId: String? = nil,
        productId: String? = nil,
        serviceUUIDs: [String] = [],
        isConnected: Bool = false,
        rssi: Int? = nil,
        deviceClass: UInt32? = nil,
        manufacturerData: Data? = nil,
        advertisementData: [String: Any]? = nil
    ) {
        self.address = address
        self.name = name
        self.vendorId = vendorId
        self.productId = productId
        self.serviceUUIDs = serviceUUIDs
        self.isConnected = isConnected
        self.rssi = rssi
        self.deviceClass = deviceClass
        self.manufacturerData = manufacturerData
        self.advertisementData = advertisementData
    }
    
    // Custom Equatable implementation since [String: Any] is not Equatable
    public static func == (lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool {
        return lhs.address == rhs.address &&
               lhs.name == rhs.name &&
               lhs.vendorId == rhs.vendorId &&
               lhs.productId == rhs.productId &&
               lhs.serviceUUIDs == rhs.serviceUUIDs &&
               lhs.isConnected == rhs.isConnected &&
               lhs.rssi == rhs.rssi &&
               lhs.deviceClass == rhs.deviceClass &&
               lhs.manufacturerData == rhs.manufacturerData
        // Note: advertisementData is not compared due to [String: Any] type
    }
    
    /// Check if this device has a specific service UUID
    /// - Parameter uuid: The service UUID to check for (case-insensitive)
    /// - Returns: True if the device has the service UUID
    public func hasServiceUUID(_ uuid: String) -> Bool {
        let normalizedUUID = uuid.uppercased()
        return serviceUUIDs.contains { $0.uppercased() == normalizedUUID }
    }
    
    /// Check if this device's MAC address starts with a specific prefix
    /// - Parameter prefix: The MAC address prefix to check (case-insensitive)
    /// - Returns: True if the device's MAC address starts with the prefix
    public func hasMACPrefix(_ prefix: String) -> Bool {
        return address.uppercased().hasPrefix(prefix.uppercased())
    }
    
    /// Check if this device has both vendor ID and product ID
    public var hasVendorAndProductId: Bool {
        return vendorId != nil && productId != nil
    }
    
    /// Get a unique identifier for this device (typically the MAC address)
    public var uniqueIdentifier: String {
        return address
    }
    
    /// Extract manufacturer ID from manufacturer data (first 2 bytes, little-endian)
    public var manufacturerId: UInt16? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        return UInt16(data[0]) | (UInt16(data[1]) << 8)
    }
    
    /// Get manufacturer-specific payload (bytes after manufacturer ID)
    public var manufacturerPayload: Data? {
        guard let data = manufacturerData, data.count > 2 else { return nil }
        return data.subdata(in: 2..<data.count)
    }
}
