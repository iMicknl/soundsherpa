import SwiftUI
import SoundSherpaCore

struct PairedDevicesList: View {
    let devices: [PairedDeviceInfo]
    let onToggle: (PairedDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired Devices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
        }
    }

    private func iconName(for device: PairedDeviceInfo) -> String {
        DeviceTypeResolver.resolve(name: device.name, address: device.address).iconName
    }
}
