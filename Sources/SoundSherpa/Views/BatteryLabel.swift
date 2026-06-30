import SwiftUI
import SoundSherpaCore

/// Battery icon + percentage, tinted by charge tier. Shared by the menu-bar
/// device header and the Settings → Device "About this device" group so the
/// glyph/color logic lives in exactly one place.
struct BatteryLabel: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: DeviceDisplay.batterySymbolName(forLevel: level))
                .foregroundStyle(tierColor)
            Text("\(level)%").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var tierColor: Color {
        switch DeviceDisplay.batteryTier(forLevel: level) {
        case .critical: return .red
        case .low: return .orange
        case .normal: return .secondary
        }
    }
}
