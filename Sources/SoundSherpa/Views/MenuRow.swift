import SwiftUI

/// A native-style interactive row matching the macOS Control Center / menu idiom:
/// full-width, leading label (with optional leading glyph), an optional trailing
/// accessory, and a subtle rounded highlight on hover. Used for "More", the footer
/// actions, and the paired-device rows so they all feel like real system rows.
struct MenuRow<Leading: View, Trailing: View>: View {
    let title: String
    var titleFont: Font = .body
    var horizontalInset: CGFloat = 7
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading()
                Text(title)
                Spacer(minLength: 0)
                trailing()
            }
            .font(titleFont)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// Convenience: SF Symbol leading glyph (or none), no trailing.
extension MenuRow where Leading == AnyView, Trailing == EmptyView {
    init(title: String, horizontalInset: CGFloat = 7, systemImage: String? = nil, action: @escaping () -> Void) {
        self.init(
            title: title,
            horizontalInset: horizontalInset,
            leading: {
                AnyView(Group {
                    if let systemImage {
                        Image(systemName: systemImage).frame(width: 20)
                    }
                })
            },
            trailing: { EmptyView() },
            action: action)
    }
}

// Convenience: SF Symbol leading glyph (or none), custom trailing.
extension MenuRow where Leading == AnyView {
    init(title: String,
         titleFont: Font = .body,
         horizontalInset: CGFloat = 7,
         systemImage: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         action: @escaping () -> Void) {
        self.init(
            title: title,
            titleFont: titleFont,
            horizontalInset: horizontalInset,
            leading: {
                AnyView(Group {
                    if let systemImage {
                        Image(systemName: systemImage).frame(width: 20)
                    }
                })
            },
            trailing: trailing,
            action: action)
    }
}
