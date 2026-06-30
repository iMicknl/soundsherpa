import SwiftUI
import SoundSherpaCore

struct ContentTile: View {
    @Environment(DeviceController.self) private var controller
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceHeaderView(name: controller.deviceName ?? "No device connected",
                             batteryLevel: controller.batteryLevel,
                             isConnected: controller.isConnected)

            if controller.isConnected {
                Divider()

                SegmentedSection(
                    title: "Noise Cancellation",
                    options: [(.off, "Off", "speaker.wave.1"),
                              (.low, "Low", "speaker.wave.2"),
                              (.high, "High", "speaker.wave.3")],
                    selection: controller.ncLevel,
                    onSelect: { controller.setNoiseCancellation($0) })

                SegmentedSection(
                    title: "Self Voice",
                    options: [(.off, "Off", "person"),
                              (.low, "Low", "person.wave.2"),
                              (.medium, "Medium", "person.wave.2.fill"),
                              (.high, "High", "person.spatialaudio.stereo.fill")],
                    selection: controller.selfVoiceLevel,
                    onSelect: { controller.setSelfVoice($0) })

                // Native-style disclosure: a full-width row with a trailing chevron that
                // rotates when expanded, revealing the advanced controls inline.
                MenuRow(title: "More", titleFont: .system(size: 12, weight: .semibold), horizontalInset: 2, trailing: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }, action: { withAnimation(.easeInOut(duration: 0.18)) { showMore.toggle() } })

                if showMore {
                    PairedDevicesList(devices: controller.pairedDevices) { device in
                        if device.isConnected {
                            controller.disconnectPairedDevice(device)
                        } else {
                            controller.connectPairedDevice(device)
                        }
                    }
                }
            }

            Divider()
            TileFooter()
        }
        .padding(12)
        .frame(width: 280)
        .tint(.accentColor)
    }
}
