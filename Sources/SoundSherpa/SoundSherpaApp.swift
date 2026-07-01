import SwiftUI
import SoundSherpaCore
import MenuBarExtraAccess

@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Drives the MenuBarExtra(.window) panel's presentation via MenuBarExtraAccess so
    // the "Settings…" action can dismiss the panel (no first-party API for this).
    @State private var isMenuPresented = false

    // Persisted menu bar content preference. Stored as the enum rawValue so the
    // Scene re-evaluates (and the label updates) whenever the General tab writes it.
    @AppStorage("menuBarContent") private var contentRaw = MenuBarContent.iconOnly.rawValue

    private var menuBarContent: MenuBarContent {
        MenuBarContent(rawValue: contentRaw) ?? .iconOnly
    }

    var body: some Scene {
        MenuBarExtra {
            ContentTile(dismissMenu: { isMenuPresented = false })
                .environment(controller)
        } label: {
            MenuBarLabel(content: menuBarContent,
                         isConnected: controller.isConnected,
                         batteryLevel: controller.batteryLevel)
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

/// The menu bar glyph plus optional battery percentage. Monochrome by default;
/// tints amber/red only at low charge. Falls back to icon-only when there is no
/// battery level (disconnected, or not yet read).
private struct MenuBarLabel: View {
    let content: MenuBarContent
    let isConnected: Bool
    let batteryLevel: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: content.connectionSymbolName(isConnected: isConnected))
            if content.showsBattery, let level = batteryLevel {
                Text("\(level)%").foregroundStyle(tint(forLevel: level))
            }
        }
    }

    /// Monochrome (`.primary`) unless the level is low/critical.
    private func tint(forLevel level: Int) -> Color {
        switch DeviceDisplay.menuBarBatteryTier(forLevel: level) {
        case .critical: return .red
        case .low:      return .orange
        case .normal:   return .primary
        }
    }
}
