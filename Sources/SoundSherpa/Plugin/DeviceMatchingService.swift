import Foundation

/// Service that provides device-to-plugin matching functionality
/// Implements multi-criteria scoring system for device identification
public class DeviceMatchingService {
    
    /// Minimum confidence threshold for accepting a device match
    public static let minimumThreshold = IdentificationScoreWeights.minimumThreshold
    
    /// Calculate the best match score for a device against a set of identifiers
    /// - Parameters:
    ///   - device: The Bluetooth device to match
    ///   - identifiers: Array of device identifiers to match against
    /// - Returns: The highest confidence score, or nil if no match above threshold
    public static func calculateBestMatchScore(
        for device: BluetoothDevice,
        against identifiers: [DeviceIdentifier]
    ) -> Int? {
        var bestScore = 0
        
        for identifier in identifiers {
            if let score = calculateMatchScore(for: device, against: identifier) {
                bestScore = max(bestScore, score)
            }
        }
        
        return bestScore >= minimumThreshold ? bestScore : nil
    }
    
    /// Calculate match score for a device against a single identifier
    /// Uses multi-criteria identification as specified in the design
    /// - Parameters:
    ///   - device: The Bluetooth device to match
    ///   - identifier: The device identifier to match against
    /// - Returns: The confidence score, or nil if below threshold
    public static func calculateMatchScore(
        for device: BluetoothDevice,
        against identifier: DeviceIdentifier
    ) -> Int? {
        var score = 0
        
        // Primary identification: Vendor + Product ID (highest confidence)
        if let deviceVendorId = device.vendorId,
           let deviceProductId = device.productId,
           let identifierVendorId = identifier.vendorId,
           let identifierProductId = identifier.productId,
           deviceVendorId.uppercased() == identifierVendorId.uppercased(),
           deviceProductId.uppercased() == identifierProductId.uppercased() {
            score += IdentificationScoreWeights.vendorProductMatch
        }
        
        // Secondary: Service UUIDs match
        let deviceUUIDs = Set(device.serviceUUIDs.map { $0.uppercased() })
        let identifierUUIDs = Set(identifier.serviceUUIDs.map { $0.uppercased() })
        let commonServices = deviceUUIDs.intersection(identifierUUIDs)
        if !commonServices.isEmpty {
            score += IdentificationScoreWeights.serviceUUIDMatch
        }
        
        // Tertiary: MAC address prefix
        if let macPrefix = identifier.macAddressPrefix,
           device.address.uppercased().hasPrefix(macPrefix.uppercased()) {
            score += IdentificationScoreWeights.macPrefixMatch
        }
        
        // Quaternary: Manufacturer data signature
        if let manufacturerData = device.manufacturerData,
           let signature = identifier.customIdentifiers["firmwareSignature"],
           let signatureData = signature.data(using: .utf8) {
            if manufacturerData.range(of: signatureData) != nil {
                score += IdentificationScoreWeights.manufacturerDataMatch
            }
        }
        
        // Fallback: Name pattern (lowest confidence)
        if let pattern = identifier.namePattern,
           device.name.range(of: pattern, options: .regularExpression) != nil {
            score += IdentificationScoreWeights.namePatternMatch
        }
        
        // Apply confidence cap - score cannot exceed the identifier's confidence score
        if score > 0 {
            score = min(score, identifier.confidenceScore)
        }
        
        // Return nil if below minimum threshold
        return score >= minimumThreshold ? score : nil
    }
    
    /// Find the best matching identifier for a device
    /// - Parameters:
    ///   - device: The Bluetooth device to match
    ///   - identifiers: Array of device identifiers to match against
    /// - Returns: Tuple of (identifier, score) for best match, or nil if no match
    public static func findBestMatchingIdentifier(
        for device: BluetoothDevice,
        from identifiers: [DeviceIdentifier]
    ) -> (identifier: DeviceIdentifier, score: Int)? {
        var bestMatch: (identifier: DeviceIdentifier, score: Int)?
        
        for identifier in identifiers {
            if let score = calculateMatchScore(for: device, against: identifier) {
                if bestMatch == nil || score > bestMatch!.score {
                    bestMatch = (identifier: identifier, score: score)
                }
            }
        }
        
        return bestMatch
    }
    
    /// Get all matching identifiers for a device, sorted by score (highest first)
    /// - Parameters:
    ///   - device: The Bluetooth device to match
    ///   - identifiers: Array of device identifiers to match against
    /// - Returns: Array of (identifier, score) tuples, sorted by score descending
    public static func findAllMatchingIdentifiers(
        for device: BluetoothDevice,
        from identifiers: [DeviceIdentifier]
    ) -> [(identifier: DeviceIdentifier, score: Int)] {
        var matches: [(identifier: DeviceIdentifier, score: Int)] = []
        
        for identifier in identifiers {
            if let score = calculateMatchScore(for: device, against: identifier) {
                matches.append((identifier: identifier, score: score))
            }
        }
        
        return matches.sorted { $0.score > $1.score }
    }
    
    /// Check if a device matches any of the given identifiers
    /// - Parameters:
    ///   - device: The Bluetooth device to check
    ///   - identifiers: Array of device identifiers to check against
    /// - Returns: True if device matches at least one identifier above threshold
    public static func deviceMatches(
        _ device: BluetoothDevice,
        anyOf identifiers: [DeviceIdentifier]
    ) -> Bool {
        return calculateBestMatchScore(for: device, against: identifiers) != nil
    }
    
    /// Get a detailed breakdown of how a device matches an identifier
    /// Useful for debugging and logging
    /// - Parameters:
    ///   - device: The Bluetooth device to analyze
    ///   - identifier: The device identifier to match against
    /// - Returns: Dictionary with match details
    public static func getMatchDetails(
        for device: BluetoothDevice,
        against identifier: DeviceIdentifier
    ) -> [String: Any] {
        var details: [String: Any] = [:]
        var totalScore = 0
        
        // Vendor + Product ID match
        let vendorProductMatch = device.vendorId?.uppercased() == identifier.vendorId?.uppercased() &&
                                 device.productId?.uppercased() == identifier.productId?.uppercased() &&
                                 device.vendorId != nil && device.productId != nil &&
                                 identifier.vendorId != nil && identifier.productId != nil
        details["vendorProductMatch"] = vendorProductMatch
        if vendorProductMatch {
            totalScore += IdentificationScoreWeights.vendorProductMatch
            details["vendorProductScore"] = IdentificationScoreWeights.vendorProductMatch
        }
        
        // Service UUIDs match
        let deviceUUIDs = Set(device.serviceUUIDs.map { $0.uppercased() })
        let identifierUUIDs = Set(identifier.serviceUUIDs.map { $0.uppercased() })
        let commonServices = deviceUUIDs.intersection(identifierUUIDs)
        let serviceMatch = !commonServices.isEmpty
        details["serviceUUIDMatch"] = serviceMatch
        details["matchingServices"] = Array(commonServices)
        if serviceMatch {
            totalScore += IdentificationScoreWeights.serviceUUIDMatch
            details["serviceUUIDScore"] = IdentificationScoreWeights.serviceUUIDMatch
        }
        
        // MAC prefix match
        let macMatch = identifier.macAddressPrefix != nil &&
                       device.address.uppercased().hasPrefix(identifier.macAddressPrefix!.uppercased())
        details["macPrefixMatch"] = macMatch
        if macMatch {
            totalScore += IdentificationScoreWeights.macPrefixMatch
            details["macPrefixScore"] = IdentificationScoreWeights.macPrefixMatch
        }
        
        // Manufacturer data match
        var manufacturerMatch = false
        if let manufacturerData = device.manufacturerData,
           let signature = identifier.customIdentifiers["firmwareSignature"],
           let signatureData = signature.data(using: .utf8) {
            manufacturerMatch = manufacturerData.range(of: signatureData) != nil
        }
        details["manufacturerDataMatch"] = manufacturerMatch
        if manufacturerMatch {
            totalScore += IdentificationScoreWeights.manufacturerDataMatch
            details["manufacturerDataScore"] = IdentificationScoreWeights.manufacturerDataMatch
        }
        
        // Name pattern match
        var nameMatch = false
        if let pattern = identifier.namePattern {
            nameMatch = device.name.range(of: pattern, options: .regularExpression) != nil
        }
        details["namePatternMatch"] = nameMatch
        if nameMatch {
            totalScore += IdentificationScoreWeights.namePatternMatch
            details["namePatternScore"] = IdentificationScoreWeights.namePatternMatch
        }
        
        // Final score calculation
        let cappedScore = min(totalScore, identifier.confidenceScore)
        details["rawScore"] = totalScore
        details["confidenceCap"] = identifier.confidenceScore
        details["finalScore"] = cappedScore
        details["meetsThreshold"] = cappedScore >= minimumThreshold
        
        return details
    }
}
