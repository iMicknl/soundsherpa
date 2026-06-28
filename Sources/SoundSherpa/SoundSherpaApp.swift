import SwiftUI

/// SwiftUI entry point. A `MenuBarExtra` in `.window` style presents the glass `ContentTile`,
/// and a standard `Settings` scene hosts `AdvancedSettingsView`. The lifecycle adaptor wires
/// Bluetooth/sleep-wake monitoring and the synchronous teardown into the shared controller.
@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SoundSherpa", systemImage: "headphones.over.ear") {
            ContentTile()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AdvancedSettingsView()
                .environment(controller)
        }
    }
}
