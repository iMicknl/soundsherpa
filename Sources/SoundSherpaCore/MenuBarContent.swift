import Foundation

/// What the menu bar shows. Pure (no AppKit) so it lives in the testable core;
/// `SoundSherpaApp` maps the result to the `MenuBarExtra` label.
public enum MenuBarContent: String, CaseIterable, Identifiable {
    /// Headphones glyph only, following connection state.
    case iconOnly
    /// Headphones glyph plus the battery percentage when a level is available.
    case iconAndBattery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly:       return "Icon only"
        case .iconAndBattery: return "Icon + battery"
        }
    }

    /// Whether this content includes the battery percentage.
    public var showsBattery: Bool {
        switch self {
        case .iconOnly:       return false
        case .iconAndBattery: return true
        }
    }

    /// The headphones glyph for the current connection state. Same for both
    /// cases — battery text (if any) is rendered alongside it by the app layer.
    public func connectionSymbolName(isConnected: Bool) -> String {
        isConnected ? "headphones.over.ear" : "headphones.slash"
    }
}
