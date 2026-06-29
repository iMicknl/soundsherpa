import SwiftUI
import SoundSherpaCore

struct DeviceHeaderView: View {
    let name: String
    let batteryLevel: Int?
    var isConnected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Blue badge with the standard headphones glyph when connected; a gray
            // badge with the slashed glyph when nothing is connected.
            DeviceBadge(systemImage: isConnected ? "headphones.over.ear" : "headphones.slash",
                        isConnected: isConnected)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.semibold))
                if let level = batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(level))
                            .foregroundStyle(batteryColor(level))
                        Text("\(level)%").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch DeviceDisplay.batteryTier(forLevel: level) {
        case .critical: return .red
        case .low: return .orange
        case .normal: return .secondary
        }
    }
}
