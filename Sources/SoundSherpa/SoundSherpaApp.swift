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
            Image(nsImage: MenuBarIconRenderer.image(
                content: menuBarContent,
                isConnected: controller.isConnected,
                batteryLevel: controller.batteryLevel))
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}
