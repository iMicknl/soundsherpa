import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 1) {
            MenuRow(title: "Settings…") {
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
