import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(DeviceController.self) private var controller

    var body: some View {
        VStack(spacing: 4) {
            Button("Refresh") { controller.refresh() }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Advanced Settings…") { openSettings() }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Quit SoundSherpa") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}
