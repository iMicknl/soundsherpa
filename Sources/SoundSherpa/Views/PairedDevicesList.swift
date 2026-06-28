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
                        systemImage: iconName(for: device),
                        trailing: {
                            if device.isConnected {
                                Circle().fill(.tint).frame(width: 7, height: 7)
                            }
                        },
                        action: { onToggle(device) })
                }
            }
        }
    }

    private func iconName(for device: PairedDeviceInfo) -> String {
        DeviceTypeResolver.resolve(name: device.name, address: device.address).iconName
    }
}
