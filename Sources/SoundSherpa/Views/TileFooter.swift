import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(DeviceController.self) private var controller

    var body: some View {
        VStack(spacing: 1) {
            MenuRow(title: "Refresh", systemImage: "arrow.clockwise") { controller.refresh() }
            MenuRow(title: "Advanced Settings…", systemImage: "gearshape") {
                openSettings()
                // LSUIElement (.accessory) apps never become active on their own, so the
                // Settings window would open behind other apps. Activate to pull it forward.
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(title: "Quit SoundSherpa", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
