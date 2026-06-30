import SwiftUI
import ServiceManagement
import SoundSherpaCore

/// The app's Settings window (⌘,). General hosts app-level preferences;
/// Device hosts the set-once headphone controls; About is read-only info.
struct SettingsView: View {
    @Environment(DeviceController.self) private var controller
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    @State private var startOnLogin = false
    @State private var loginError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            deviceTab.tabItem { Label("Device", systemImage: "headphones") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Start on login", isOn: Binding(
                get: { startOnLogin },
                set: { setStartOnLogin($0) }))
            if let loginError {
                Text(loginError).font(.footnote).foregroundStyle(.red)
            }
            Picker("Menu bar icon", selection: Binding(
                get: { MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection },
                set: { iconStyleRaw = $0.rawValue })) {
                ForEach(MenuBarIconStyle.allCases) { Text($0.displayName).tag($0) }
            }
        }
        .onAppear { refreshLoginStatus() }
    }

    private var deviceTab: some View {
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

    // MARK: - Start on login (source of truth: SMAppService, not @AppStorage)

    private func refreshLoginStatus() {
        startOnLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setStartOnLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
        }
        // Re-read the real status so the toggle reflects truth even on failure.
        refreshLoginStatus()
    }
}
