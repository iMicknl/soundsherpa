import SwiftUI
import ServiceManagement
import SoundSherpaCore

/// The app's Settings window (⌘,). General hosts app-level preferences;
/// Device hosts the set-once headphone controls; About is read-only info.
struct SettingsView: View {
    private enum Tab: Hashable { case general, device, about }

    @Environment(DeviceController.self) private var controller
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    @State private var startOnLogin = false
    @State private var loginError: String?
    @State private var selection = Tab.general

    var body: some View {
        TabView(selection: $selection) {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            deviceTab.tabItem { Label("Device", systemImage: "headphones") }.tag(Tab.device)
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(width: 420, height: 320)
        .padding()
        // The Settings scene's view tree persists across window close/reopen, so the
        // TabView would otherwise reopen on whatever tab was last viewed. Reset to
        // General when the window closes so the next open always starts there.
        .background(WindowCloseObserver { selection = .general })
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Start on login", isOn: Binding(
                    get: { startOnLogin },
                    set: { setStartOnLogin($0) }))
                if let loginError {
                    Text(loginError).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Picker("Menu bar icon", selection: Binding(
                    get: { MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection },
                    set: { iconStyleRaw = $0.rawValue })) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginStatus() }
    }

    private var deviceTab: some View {
        Group {
            if controller.isConnected {
                VStack(spacing: 0) {
                    deviceHeader
                        .padding(.horizontal)
                        .padding(.top)
                    Form {
                        Section("Controls") {
                            Picker("Auto-Off", selection: Binding(
                                get: { controller.autoOff ?? .never },
                                set: { controller.setAutoOff($0) })) {
                                ForEach([AutoOff.never, .five, .twenty, .forty, .sixty, .oneEighty], id: \.rawValue) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            Text("Turn the headphones off after a period of inactivity to save battery.")
                                .font(.caption).foregroundStyle(.secondary)

                            Picker("Button Action", selection: Binding(
                                get: { controller.buttonAction ?? .noiseCancellation },
                                set: { controller.setButtonAction($0) })) {
                                Text("Alexa").tag(ButtonAction.alexa)
                                Text("Noise Cancellation").tag(ButtonAction.noiseCancellation)
                            }
                            Text("Choose what a press of the headphones' action button does.")
                                .font(.caption).foregroundStyle(.secondary)

                            Picker("Language", selection: Binding(
                                get: { controller.language ?? .english },
                                set: { controller.setLanguage($0) })) {
                                ForEach(languageChoices, id: \.rawValue) { Text($0.displayName).tag($0) }
                            }
                            Toggle("Voice Prompts", isOn: Binding(
                                get: { controller.voicePromptsEnabled ?? false },
                                set: { controller.setVoicePrompts($0) }))
                        }

                        Section("About this device") {
                            if let level = controller.batteryLevel {
                                LabeledContent("Battery") { BatteryLabel(level: level) }
                            }
                            if let v = controller.firmware { LabeledContent("Firmware", value: v) }
                            if let v = controller.serial { LabeledContent("Serial Number", value: v) }
                        }

                        if hasAdvancedInfo {
                            Section {
                                DisclosureGroup("Advanced details") {
                                    if let v = controller.deviceId { LabeledContent("Device ID", value: v) }
                                    if let v = controller.services, !v.isEmpty {
                                        LabeledContent("Services") {
                                            Text(v.joined(separator: ", "))
                                                .multilineTextAlignment(.trailing)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            } else {
                deviceDisconnected
            }
        }
    }

    private var deviceDisconnected: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No device connected")
                .font(.headline)
            Text("Connect your headphones to manage their settings here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Device name as the subject of the tab (not a settings row).
    private var deviceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.deviceName ?? "Device")
                    .font(.headline)
                Text("Connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Pure-debug identity fields shown under the collapsed "Advanced details".
    private var hasAdvancedInfo: Bool {
        controller.deviceId != nil || !(controller.services ?? []).isEmpty
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            appLogo
                .frame(width: 96, height: 96)
                .accessibilityLabel("SoundSherpa")

            VStack(spacing: 2) {
                Text(appName)
                    .font(.title2.weight(.semibold))
                Text("Version \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Smart controls for non-Apple headphones.")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("SoundSherpa brings the Control Center experience to all headphones, "
                + "not just Apple ones. Manage noise cancellation, battery, connections, "
                + "and device switching from your menu bar — no more guessing, no more "
                + "digging through menus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            HStack {
                Link("Visit Website", destination: URL(string: "https://soundsherpa.app")!)
                Text("© 2026 Mick Vleeshouwer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// The app's bundled icon when present, otherwise the headphones glyph the
    /// rest of the UI uses, so the About panel always shows a recognizable mark.
    /// `applicationIconImage` returns a generic placeholder when no icon is
    /// bundled, so gate on the Info.plist actually declaring one.
    @ViewBuilder private var appLogo: some View {
        if hasBundledIcon, let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "headphones")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .padding(8)
        }
    }

    private var hasBundledIcon: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SoundSherpa"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
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

/// Invokes `onClose` when the hosting window closes. Used to reset Settings to the
/// General tab between opens, since the Settings scene's view tree is long-lived.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer until the view is in the hierarchy and has a window to observe.
        DispatchQueue.main.async { context.coordinator.observe(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
    }

    final class Coordinator {
        var onClose: () -> Void

        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func observe(_ window: NSWindow?) {
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification, object: window)
        }

        @objc private func windowWillClose() { onClose() }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
