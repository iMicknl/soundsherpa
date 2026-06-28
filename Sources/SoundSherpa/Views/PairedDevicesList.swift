import SwiftUI
import SoundSherpaCore

struct PairedDevicesList: View {
    let devices: [PairedDeviceInfo]
    let onToggle: (PairedDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired Devices")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(devices, id: \.address) { device in
                Button {
                    onToggle(device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: device))
                            .frame(width: 20)
                        Text(DeviceDisplay.pairedDeviceDisplayName(rawName: device.name, address: device.address))
                        Spacer()
                        if device.isConnected {
                            Circle().fill(.tint).frame(width: 8, height: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func iconName(for device: PairedDeviceInfo) -> String {
        DeviceTypeResolver.resolve(name: device.name, address: device.address).iconName
    }
}
