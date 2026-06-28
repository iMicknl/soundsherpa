import SwiftUI
import SoundSherpaCore

struct AdvancedSettingsView: View {
    @Environment(DeviceController.self) private var controller

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            voiceTab.tabItem { Label("Voice", systemImage: "waveform") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Picker("Auto-Off", selection: Binding(
                get: { controller.autoOff ?? .never },
                set: { controller.setAutoOff($0) })) {
                ForEach([AutoOff.never, .five, .twenty, .forty, .sixty, .oneEighty], id: \.rawValue) {
                    Text($0.displayName).tag($0)
                }
            }
            Picker("Button Action", selection: Binding(
                get: { controller.buttonAction ?? .noiseCancellation },
                set: { controller.setButtonAction($0) })) {
                Text("Alexa").tag(ButtonAction.alexa)
                Text("Noise Cancellation").tag(ButtonAction.noiseCancellation)
            }
        }
    }

    private var voiceTab: some View {
        Form {
            Picker("Language", selection: Binding(
                get: { controller.language ?? .english },
                set: { controller.setLanguage($0) })) {
                ForEach(languageChoices, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            Toggle("Voice Prompts", isOn: Binding(
                get: { controller.voicePromptsEnabled ?? false },
                set: { controller.setVoicePrompts($0) }))
        }
    }

    private var aboutTab: some View {
        Form {
            if let v = controller.firmware { LabeledContent("Firmware", value: v) }
            if let v = controller.serial { LabeledContent("Serial Number", value: v) }
            if let v = controller.deviceId { LabeledContent("Device ID", value: v) }
            if let v = controller.services, !v.isEmpty {
                LabeledContent("Services", value: v.joined(separator: ", "))
            }
            Text("Smart controls for non-Apple headphones. Version 1.0")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var languageChoices: [PromptLanguage] {
        [.chinese, .dutch, .english, .french, .german, .italian, .japanese,
         .korean, .polish, .portuguese, .russian, .spanish, .swedish]
    }
}
