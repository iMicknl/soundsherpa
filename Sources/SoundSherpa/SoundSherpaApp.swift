import SwiftUI
import SoundSherpaCore

@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Persisted menu bar icon preference. Stored as the enum rawValue so the
    // Scene re-evaluates (and the glyph updates) whenever the General tab writes it.
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    private var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection
    }

    var body: some Scene {
        MenuBarExtra("SoundSherpa", systemImage: iconStyle.symbolName(isConnected: controller.isConnected)) {
            ContentTile()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}
