import SwiftUI
import SettingsAccess

struct TileFooter: View {
    /// Closes the MenuBarExtra panel (via MenuBarExtraAccess at the scene level).
    var dismissMenu: () -> Void = {}

    var body: some View {
        VStack(spacing: 1) {
            // SettingsLink (from SettingsAccess) is the only reliable way to open the
            // Settings scene from a MenuBarExtra on macOS 14+. preAction runs before the
            // window opens; postAction after. We activate the app first (so its window is
            // allowed to take focus), then dismiss the panel and pull Settings to the front.
            SettingsLink {
                SettingsRowLabel()
            } preAction: {
                NSApp.activate(ignoringOtherApps: true)
            } postAction: {
                dismissMenu()
                bringSettingsToFront()
            }
            .buttonStyle(.plain)

            MenuRow(title: "Quit SoundSherpa") {
                NSApplication.shared.terminate(nil)
            }
        }
        // Bleed the hover pills outward toward the tile edges while keeping the labels
        // aligned with the rows above (inset bumped +6 to counteract the -6 padding).
        .padding(.horizontal, -6)
    }

    /// SettingsLink already opens/fronts the scene, but in an .accessory app the window
    /// can still come up behind. Nudge it front once it exists (next runloop tick).
    private func bringSettingsToFront() {
        DispatchQueue.main.async {
            NSApp.windows
                .first { $0.identifier?.rawValue.contains("Settings") == true }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

/// The "Settings…" label, styled to match `MenuRow`'s full-width hover pill so it sits
/// flush with the Quit row below it. `SettingsLink` supplies the button behavior.
private struct SettingsRowLabel: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Settings…")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
        )
        .onHover { hovering = $0 }
    }
}
