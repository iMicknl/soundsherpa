import SwiftUI

/// SwiftUI entry point. A `MenuBarExtra` in `.window` style presents the glass `ContentTile`,
/// and a standard `Settings` scene hosts `AdvancedSettingsView`. The lifecycle adaptor wires
/// Bluetooth/sleep-wake monitoring and the synchronous teardown into the shared controller.
@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The icon reflects connection state: the standard headphones glyph when a device is
        // connected, the slashed glyph when nothing is. Reading the observable property here
        // makes the Scene re-evaluate (and the menu bar icon update) on every change.
        MenuBarExtra("SoundSherpa", systemImage: controller.isConnected ? "headphones.over.ear" : "headphones.slash") {
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
