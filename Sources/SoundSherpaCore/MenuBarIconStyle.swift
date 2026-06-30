import Foundation

/// How the menu bar icon glyph is chosen. Pure (no AppKit) so it lives in the
/// testable core; `SoundSherpaApp` maps the result to the `MenuBarExtra` symbol.
public enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    /// Headphones glyph when connected, slashed glyph when not.
    case followConnection
    /// Always the connected headphones glyph, regardless of state.
    case alwaysShow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .followConnection: return "Follow connection"
        case .alwaysShow:        return "Always show"
        }
    }

    /// Resolve to an SF Symbol name given the live connection state.
    public func symbolName(isConnected: Bool) -> String {
        switch self {
        case .followConnection: return isConnected ? "headphones.over.ear" : "headphones.slash"
        case .alwaysShow:        return "headphones.over.ear"
        }
    }
}
