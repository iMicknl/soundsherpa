import Foundation

/// How the battery is depicted next to the headphones glyph, when shown.
public enum MenuBarBatteryStyle: Sendable {
    /// Horizontal battery glyph with the percentage number stacked above it.
    case horizontalWithNumber
    /// Vertical battery glyph that fills by charge, no number.
    case verticalGlyph
}

/// What the menu bar shows. Pure (no AppKit) so it lives in the testable core;
/// `SoundSherpaApp` maps the result to the `MenuBarExtra` label.
public enum MenuBarContent: String, CaseIterable, Identifiable {
    /// Headphones glyph only, following connection state.
    case iconOnly
    /// Headphones glyph plus the battery percentage (horizontal glyph + number).
    case iconAndBattery
    /// Headphones glyph plus a vertical battery glyph (fill only, no number).
    case iconAndVerticalBattery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly:             return "Icon only"
        case .iconAndBattery:       return "Icon + battery %"
        case .iconAndVerticalBattery: return "Icon + battery gauge"
        }
    }

    /// The battery depiction for this content, or nil when no battery is shown.
    public var batteryStyle: MenuBarBatteryStyle? {
        switch self {
        case .iconOnly:               return nil
        case .iconAndBattery:         return .horizontalWithNumber
        case .iconAndVerticalBattery: return .verticalGlyph
        }
    }

    /// Whether this content includes the battery.
    public var showsBattery: Bool { batteryStyle != nil }

    /// The headphones glyph for the current connection state. Same for both
    /// cases — battery text (if any) is rendered alongside it by the app layer.
    public func connectionSymbolName(isConnected: Bool) -> String {
        isConnected ? "headphones.over.ear" : "headphones.slash"
    }
}
