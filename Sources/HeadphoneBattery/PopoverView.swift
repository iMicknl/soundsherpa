import SwiftUI

struct PopoverView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @Environment(\.colorScheme) var colorScheme
    var onQuit: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Device Header
            DeviceHeaderView(device: bluetoothManager.currentDevice) {
                if bluetoothManager.currentDevice?.isConnected == false {
                    bluetoothManager.connectCurrentDevice()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            if bluetoothManager.currentDevice?.isConnected == true {
                Divider()
                    .padding(.horizontal, 16)
                
                // Noise Cancellation
                VStack(alignment: .leading, spacing: 8) {
                    Text("Noise Cancellation")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    
                    HStack(spacing: 8) {
                        ForEach(NoiseCancellationLevel.allCases) { level in
                            ControlButton(
                                title: level.displayName,
                                iconName: level.iconName,
                                isSelected: bluetoothManager.noiseCancellation == level
                            ) {
                                bluetoothManager.setNoiseCancellation(level)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                
                // Self Voice
                VStack(alignment: .leading, spacing: 8) {
                    Text("Self Voice")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    
                    HStack(spacing: 8) {
                        ForEach(SelfVoiceLevel.displayOrder) { level in
                            ControlButton(
                                title: level.displayName,
                                iconName: level.iconName,
                                isSelected: bluetoothManager.selfVoice == level
                            ) {
                                bluetoothManager.setSelfVoice(level)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                
                // Paired Devices Section
                if !bluetoothManager.pairedDevices.isEmpty {
                    PairedDevicesSection(
                        devices: bluetoothManager.pairedDevices,
                        onConnect: { device in
                            bluetoothManager.connectDevice(device)
                        },
                        onDisconnect: { device in
                            bluetoothManager.disconnectDevice(device)
                        }
                    )
                }
                
                Divider()
                    .padding(.horizontal, 16)
                
                // Settings Row
                SettingsRow(bluetoothManager: bluetoothManager)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            
            Divider()
                .padding(.horizontal, 16)
            
            // Footer
            HStack {
                Button("Refresh") {
                    bluetoothManager.refresh()
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                
                Spacer()
                
                Button("Quit") {
                    onQuit()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut("q", modifiers: .command)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(VisualEffectView())
    }
}

// MARK: - Device Header

struct DeviceHeaderView: View {
    let device: BoseDevice?
    var onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device Icon Circle
            ZStack {
                Circle()
                    .fill(device?.isConnected == true ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "headphones")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(device?.isConnected == true ? .white : .primary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device?.name ?? "No Bose Device Found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                if let battery = device?.batteryLevel, device?.isConnected == true {
                    HStack(spacing: 4) {
                        Text("\(battery)%")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        Image(systemName: batteryIconName(for: battery))
                            .font(.system(size: 11))
                            .foregroundColor(batteryColor(for: battery))
                    }
                } else if device?.isConnected == false && device != nil {
                    Text("Not Connected – Click to Connect")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
    
    private func batteryIconName(for level: Int) -> String {
        switch level {
        case 0...10: return "battery.0percent"
        case 11...25: return "battery.25percent"
        case 26...50: return "battery.50percent"
        case 51...75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    
    private func batteryColor(for level: Int) -> Color {
        if level <= 20 {
            return .red
        } else if level <= 50 {
            return .orange
        } else {
            return .secondary
        }
    }
}


// MARK: - Control Button

struct ControlButton: View {
    let title: String
    let iconName: String
    let isSelected: Bool
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.15))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Paired Devices Section

struct PairedDevicesSection: View {
    let devices: [PairedDevice]
    var onConnect: (PairedDevice) -> Void
    var onDisconnect: (PairedDevice) -> Void
    
    var connectedCount: Int {
        devices.filter { $0.isConnected }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired Devices (\(devices.count), \(connectedCount) connected)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            
            VStack(spacing: 2) {
                ForEach(devices) { device in
                    PairedDeviceRow(device: device) {
                        if device.isConnected {
                            onDisconnect(device)
                        } else {
                            onConnect(device)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

struct PairedDeviceRow: View {
    let device: PairedDevice
    var onTap: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(device.isConnected ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if device.isCurrentDevice {
                        Text("!")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    Text(device.name)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                
                Text(device.id)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Action hint on hover
            if isHovering {
                Text(device.isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovering ? Color.gray.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Settings Row

struct SettingsRow: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @State private var showingSettings = false
    @State private var showingInfo = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { 
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings.toggle()
                        if showingSettings { showingInfo = false }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Text("Settings")
                            .font(.system(size: 12))
                        Image(systemName: showingSettings ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if bluetoothManager.currentDevice != nil {
                    Button(action: { 
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingInfo.toggle()
                            if showingInfo { showingSettings = false }
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                            Text("Info")
                                .font(.system(size: 12))
                            Image(systemName: showingInfo ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if showingSettings {
                VStack(spacing: 8) {
                    // Language Picker
                    HStack {
                        Text("Language")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { bluetoothManager.currentLanguage },
                            set: { bluetoothManager.setLanguage($0) }
                        )) {
                            ForEach(PromptLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    
                    // Voice Prompts Toggle
                    HStack {
                        Text("Voice Prompts")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { bluetoothManager.voicePromptsEnabled },
                            set: { bluetoothManager.setVoicePrompts($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            if showingInfo, let device = bluetoothManager.currentDevice {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Firmware", value: device.firmwareVersion ?? "Unknown")
                    InfoRow(label: "Audio Codec", value: device.audioCodec ?? "Unknown")
                    InfoRow(label: "Vendor ID", value: device.vendorId ?? "Unknown")
                    InfoRow(label: "Product ID", value: device.productId ?? "Unknown")
                    InfoRow(label: "Serial Number", value: device.serialNumber ?? "Unknown")
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Device Info View (unused, kept for reference)

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
}

// MARK: - Visual Effect View (for native blur)

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .popover
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
