import Foundation

/// Battery color tier shared by the menu-bar icon and the header pill.
public enum BatteryTier: Sendable { case normal, low, critical }

/// Pure presentation mappings used by the UI layer. Kept in the core so they're
/// unit-testable without AppKit/SwiftUI.
public enum DeviceDisplay {
    /// ≤20 critical (red), ≤50 low (amber), else normal. Matches the legacy thresholds.
    public static func batteryTier(forLevel level: Int) -> BatteryTier {
        if level <= 20 { return .critical }
        if level <= 50 { return .low }
        return .normal
    }

    /// A paired device's human label, or "Unknown Device" when all we have is its address.
    public static func pairedDeviceDisplayName(rawName: String, address: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Unknown Device" }
        if trimmed.caseInsensitiveCompare(address) == .orderedSame { return "Unknown Device" }
        return trimmed
    }
}
