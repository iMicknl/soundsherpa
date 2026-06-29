import SwiftUI

/// Circular device icon badge matching the native Sound Output list:
/// accent-blue fill with a white glyph when connected, gray fill with a
/// primary glyph otherwise. Shared by the device header and paired-device rows.
struct DeviceBadge: View {
    let systemImage: String
    var isConnected: Bool = false
    var diameter: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: diameter, height: diameter)
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.47, weight: .medium))
                .foregroundStyle(isConnected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
    }
}
