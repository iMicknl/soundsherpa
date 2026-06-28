import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 4) {
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
