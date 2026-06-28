import SwiftUI
import SoundSherpaCore

struct DeviceHeaderView: View {
    let name: String
    let batteryLevel: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.tint).frame(width: 36, height: 36)
                Image(systemName: "headphones.over.ear")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                if let level = batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(level))
                            .foregroundStyle(batteryColor(level))
                        Text("\(level)%").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Spacer()
        }
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
