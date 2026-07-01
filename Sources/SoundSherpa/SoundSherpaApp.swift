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

    // Persisted menu bar icon preference. Stored as the enum rawValue so the
    // Scene re-evaluates (and the glyph updates) whenever the General tab writes it.
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    private var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection
    }

    var body: some Scene {
        MenuBarExtra("SoundSherpa", systemImage: iconStyle.symbolName(isConnected: controller.isConnected)) {
            ContentTile(dismissMenu: { isMenuPresented = false })
                .environment(controller)
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}
