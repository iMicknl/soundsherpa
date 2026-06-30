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

    /// Maps a battery percentage (0–100) to the SF Symbol name used to depict it.
    /// Lives here (Foundation-only) so both the menu tile and Settings share one
    /// mapping; the tint color stays in the SwiftUI layer.
    public static func batterySymbolName(forLevel level: Int) -> String {
        switch level {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// A paired device's human label, falling back to its address when we have
    /// no real name (rather than a vague "Unknown Device").
    public static func pairedDeviceDisplayName(rawName: String, address: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return address }
        if trimmed.caseInsensitiveCompare(address) == .orderedSame { return address }
        return trimmed
    }
}
