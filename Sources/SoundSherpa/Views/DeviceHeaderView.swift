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
                    BatteryLabel(level: level)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
