import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(DeviceController.self) private var controller

    var body: some View {
        VStack(spacing: 1) {
            MenuRow(title: "Refresh") { controller.refresh() }
            MenuRow(title: "Advanced Settings…") {
                openSettings()
                // LSUIElement (.accessory) apps never become active on their own, so the
                // Settings window would open behind other apps. Activate to pull it forward.
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(title: "Quit SoundSherpa") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
