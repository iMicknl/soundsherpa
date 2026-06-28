import SwiftUI
import SoundSherpaCore

struct ContentTile: View {
    @Environment(DeviceController.self) private var controller
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceHeaderView(name: controller.deviceName ?? "No device connected",
                             batteryLevel: controller.batteryLevel)

            if controller.isConnected {
                Divider()

                SegmentedSection(
                    title: "Noise Cancellation",
                    options: [(.off, "Off", "speaker.wave.1"),
                              (.low, "Low", "speaker.wave.2"),
                              (.high, "High", "speaker.wave.3")],
                    selection: controller.ncLevel,
                    onSelect: { controller.setNoiseCancellation($0) })

                DisclosureGroup("More", isExpanded: $showMore) {
                    VStack(alignment: .leading, spacing: 14) {
                        SegmentedSection(
                            title: "Self Voice",
                            options: [(.off, "Off", "person"),
                                      (.low, "Low", "person.wave.2"),
                                      (.medium, "Medium", "person.wave.2.fill"),
                                      (.high, "High", "person.spatialaudio.stereo.fill")],
                            selection: controller.selfVoiceLevel,
                            onSelect: { controller.setSelfVoice($0) })

                        PairedDevicesList(devices: controller.pairedDevices) { device in
                            if device.isConnected {
                                controller.disconnectPairedDevice(device)
                            } else {
                                controller.connectPairedDevice(device)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }

            Divider()
            TileFooter()
        }
        .padding(18)
        .frame(width: 320)
        .tint(.accentColor)
    }
}
