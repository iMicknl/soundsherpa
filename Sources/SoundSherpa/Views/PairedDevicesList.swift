import SwiftUI
import SoundSherpaCore

struct PairedDevicesList: View {
    let devices: [PairedDeviceInfo]
    let onToggle: (PairedDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired Devices")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 1) {
                ForEach(devices, id: \.address) { device in
                    MenuRow(
                        title: DeviceDisplay.pairedDeviceDisplayName(rawName: device.name, address: device.address),
                        leading: {
                            DeviceBadge(systemImage: iconName(for: device),
                                        isConnected: device.isConnected,
                                        diameter: 28)
                        },
                        trailing: { EmptyView() },
                        action: { onToggle(device) })
                }
            }
            // Bleed the hover pills outward toward the tile edges while keeping the
            // badge/label aligned with the rows above (inset bumped +6 to offset -6).
            .padding(.horizontal, -6)
        }
    }

    private func iconName(for device: PairedDeviceInfo) -> String {
        DeviceTypeResolver.resolve(name: device.name, address: device.address).iconName
    }
}
