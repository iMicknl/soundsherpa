import Cocoa
import Foundation
import IOBluetooth

struct HeadphoneInfo {
    let name: String
    let batteryLevel: Int?
    let isConnected: Bool
    let firmwareVersion: String?
    let noiseCancellationEnabled: Bool?
    let audioCodec: String?
    let vendorId: String?
    let productId: String?
    let services: String?
    let serialNumber: String?
    let language: String?
    let voicePromptsEnabled: Bool?
    let selfVoiceLevel: String?
    let pairedDevices: [String]?
    let pairedDevicesCount: Int?
    let connectedDevicesCount: Int?
}

enum PromptLanguage: UInt8 {
    case english = 0x21
    case french = 0x22
    case italian = 0x23
    case german = 0x24
    case spanish = 0x26
    case portuguese = 0x27
    case chinese = 0x28
    case korean = 0x29
    case polish = 0x2B
    case russian = 0x2A
    case dutch = 0x2e
    case japanese = 0x2f
    case swedish = 0x32
    case unknown = 0x00
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .italian: return "Italian"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese"
        case .korean: return "Korean"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .dutch: return "Dutch"
        case .japanese: return "Japanese"
        case .swedish: return "Swedish"
        case .unknown: return "Unknown"
        }
    }
}

enum SelfVoice: UInt8 {
    case off = 0x00
    case high = 0x01
    case medium = 0x02
    case low = 0x03
    
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

// MARK: - Menu Item Tags for easy lookup
private enum MenuTag: Int {
    case deviceHeader = 100
    case batteryInfo = 101
    case noiseCancellationHeader = 200
    case ncOff = 201
    case ncLow = 202
    case ncHigh = 203
    case selfVoiceHeader = 300
    case svOff = 301
    case svLow = 302
    case svMedium = 303
    case svHigh = 304
    case infoSubmenu = 400
    case settingsSubmenu = 500
    case pairedDevices = 600
}

class AppDelegate: NSObject, NSApplicationDelegate, IOBluetoothRFCOMMChannelDelegate {
    private var statusItem: NSStatusItem?
    private var currentHeadphoneInfo: HeadphoneInfo?
    private var updateTimer: Timer?
    private var ncUpdateTimer: Timer?
    private var deviceAddress: String?
    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var channelOpenSemaphore: DispatchSemaphore?
    private var isChannelReady = false
    private var responseBuffer: [UInt8] = []
    private var responseSemaphore: DispatchSemaphore?
    private var expectedResponsePrefix: [UInt8] = []
    private let responseLock = NSLock()
    private var currentNCLevel: UInt8 = 0xFF // Unknown
    private var currentSelfVoiceLevel: UInt8 = 0xFF // Unknown
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        checkForBoseDevices()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            self.checkForBoseDevices()
        }
        
        ncUpdateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            if self.currentHeadphoneInfo?.isConnected == true {
                self.detectNoiseCancellationStatusAsync()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        ncUpdateTimer?.invalidate()
        
        if let channel = rfcommChannel, channel.isOpen() {
            _ = channel.close()
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Headphone Battery Monitor"
        }
        
        setupMenu()
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // === DEVICE HEADER with icon ===
        let deviceItem = createDeviceHeaderItem(name: "Searching for Bose Device...", battery: nil)
        deviceItem.tag = MenuTag.deviceHeader.rawValue
        menu.addItem(deviceItem)
        
        // Battery info below device name
        let batteryItem = NSMenuItem(title: "    ", action: nil, keyEquivalent: "")
        batteryItem.tag = MenuTag.batteryInfo.rawValue
        batteryItem.isEnabled = false
        batteryItem.isHidden = true
        menu.addItem(batteryItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === NOISE CANCELLATION (Listening Mode style) ===
        let ncHeaderItem = createSectionHeader(title: "Noise Cancellation")
        ncHeaderItem.tag = MenuTag.noiseCancellationHeader.rawValue
        menu.addItem(ncHeaderItem)
        
        let ncOffItem = createNCMenuItem(title: "Off", action: #selector(setNoiseCancellationOff), tag: MenuTag.ncOff.rawValue, iconName: "speaker.wave.1")
        menu.addItem(ncOffItem)
        
        let ncLowItem = createNCMenuItem(title: "Low", action: #selector(setNoiseCancellationLow), tag: MenuTag.ncLow.rawValue, iconName: "speaker.wave.2")
        menu.addItem(ncLowItem)
        
        let ncHighItem = createNCMenuItem(title: "High", action: #selector(setNoiseCancellationHigh), tag: MenuTag.ncHigh.rawValue, iconName: "speaker.wave.3")
        menu.addItem(ncHighItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === SELF VOICE (Listening Mode style) ===
        let svHeaderItem = createSectionHeader(title: "Self Voice")
        svHeaderItem.tag = MenuTag.selfVoiceHeader.rawValue
        menu.addItem(svHeaderItem)
        
        let svOffItem = createSelfVoiceMenuItem(title: "Off", action: #selector(setSelfVoiceOff), tag: MenuTag.svOff.rawValue, iconName: "person")
        menu.addItem(svOffItem)
        
        let svLowItem = createSelfVoiceMenuItem(title: "Low", action: #selector(setSelfVoiceLow), tag: MenuTag.svLow.rawValue, iconName: "person.wave.2")
        menu.addItem(svLowItem)
        
        let svMediumItem = createSelfVoiceMenuItem(title: "Medium", action: #selector(setSelfVoiceMedium), tag: MenuTag.svMedium.rawValue, iconName: "person.wave.2.fill")
        menu.addItem(svMediumItem)
        
        let svHighItem = createSelfVoiceMenuItem(title: "High", action: #selector(setSelfVoiceHigh), tag: MenuTag.svHigh.rawValue, iconName: "person.2.wave.2.fill")
        menu.addItem(svHighItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === INFO SUBMENU ===
        let infoItem = NSMenuItem(title: "Info", action: nil, keyEquivalent: "")
        infoItem.tag = MenuTag.infoSubmenu.rawValue
        let infoSubmenu = createInfoSubmenu()
        infoItem.submenu = infoSubmenu
        menu.addItem(infoItem)
        
        // === SETTINGS SUBMENU ===
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.tag = MenuTag.settingsSubmenu.rawValue
        let settingsSubmenu = createSettingsSubmenu()
        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === PAIRED DEVICES ===
        let pairedDevicesItem = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
        pairedDevicesItem.tag = MenuTag.pairedDevices.rawValue
        pairedDevicesItem.isEnabled = false
        menu.addItem(pairedDevicesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === QUIT ===
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    private func createDeviceHeaderItem(name: String, battery: Int?, isConnected: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        
        // Create a custom view for the device header
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: battery != nil ? 48 : 32))
        
        // Blue circle background for connected state
        let circleSize: CGFloat = 32
        let circleX: CGFloat = 10
        let circleY: CGFloat = (containerView.frame.height - circleSize) / 2
        
        if isConnected {
            let circleView = NSView(frame: NSRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
            circleView.wantsLayer = true
            circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
            circleView.layer?.cornerRadius = circleSize / 2
            containerView.addSubview(circleView)
        }
        
        // Headphone icon
        let iconSize: CGFloat = 20
        let iconX = circleX + (circleSize - iconSize) / 2
        let iconY = circleY + (circleSize - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        if let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = isConnected ? .white : .secondaryLabelColor
        }
        containerView.addSubview(iconView)
        
        // Device name label
        let textX: CGFloat = circleX + circleSize + 10
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: textX, y: battery != nil ? 26 : 7, width: 200, height: 18)
        containerView.addSubview(nameLabel)
        
        // Battery label with icon (if available)
        if let battery = battery {
            let batteryText = "\(battery)%"
            let batteryLabel = NSTextField(labelWithString: batteryText)
            batteryLabel.font = NSFont.systemFont(ofSize: 11)
            batteryLabel.textColor = .secondaryLabelColor
            batteryLabel.sizeToFit()
            let batteryY: CGFloat = 8
            batteryLabel.frame = NSRect(x: textX, y: batteryY, width: batteryLabel.frame.width, height: 16)
            containerView.addSubview(batteryLabel)
            
            // Battery icon - vertically centered with text, closer spacing
            let iconHeight: CGFloat = 11
            let iconY = batteryY + (16 - iconHeight) / 2
            let batteryIconView = NSImageView(frame: NSRect(x: textX + batteryLabel.frame.width + 2, y: iconY, width: 20, height: iconHeight))
            let batteryIconName = batteryIconNameForLevel(battery)
            if let batteryImage = NSImage(systemSymbolName: batteryIconName, accessibilityDescription: "Battery") {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                batteryIconView.image = batteryImage.withSymbolConfiguration(config)
                batteryIconView.contentTintColor = batteryColorForLevel(battery)
            }
            containerView.addSubview(batteryIconView)
        }
        
        item.view = containerView
        return item
    }
    
    private func createNCMenuItem(title: String, action: Selector, tag: Int, iconName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.indentationLevel = 1
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            item.image = image.withSymbolConfiguration(config)
        }
        return item
    }
    
    private func createSelfVoiceMenuItem(title: String, action: Selector, tag: Int, iconName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.indentationLevel = 1
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            item.image = image.withSymbolConfiguration(config)
        }
        return item
    }
    
    private func createSectionHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        
        // Use a custom view to ensure black text and left alignment
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        label.textColor = .black
        label.frame = NSRect(x: 20, y: 2, width: 250, height: 18)
        containerView.addSubview(label)
        
        item.view = containerView
        return item
    }
    
    private func createInfoSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        let firmwareItem = NSMenuItem(title: "Firmware: Unknown", action: nil, keyEquivalent: "")
        firmwareItem.isEnabled = false
        firmwareItem.tag = 401
        submenu.addItem(firmwareItem)
        
        let codecItem = NSMenuItem(title: "Audio Codec: Unknown", action: nil, keyEquivalent: "")
        codecItem.isEnabled = false
        codecItem.tag = 402
        submenu.addItem(codecItem)
        
        let deviceIdItem = NSMenuItem(title: "Device ID: Unknown", action: nil, keyEquivalent: "")
        deviceIdItem.isEnabled = false
        deviceIdItem.tag = 403
        submenu.addItem(deviceIdItem)
        
        let servicesItem = NSMenuItem(title: "Services: Unknown", action: nil, keyEquivalent: "")
        servicesItem.isEnabled = false
        servicesItem.tag = 404
        submenu.addItem(servicesItem)
        
        let serialItem = NSMenuItem(title: "Serial Number: Unknown", action: nil, keyEquivalent: "")
        serialItem.isEnabled = false
        serialItem.tag = 405
        submenu.addItem(serialItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshBattery), keyEquivalent: "r")
        refreshItem.target = self
        submenu.addItem(refreshItem)
        
        return submenu
    }
    
    private func createSettingsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        // Language submenu
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu()
        languageSubmenu.autoenablesItems = false
        
        let languages: [(String, PromptLanguage)] = [
            ("English", .english), ("French", .french), ("Italian", .italian),
            ("German", .german), ("Spanish", .spanish), ("Portuguese", .portuguese),
            ("Chinese", .chinese), ("Korean", .korean), ("Polish", .polish),
            ("Russian", .russian), ("Dutch", .dutch), ("Japanese", .japanese),
            ("Swedish", .swedish)
        ]
        
        for (name, lang) in languages {
            let item = NSMenuItem(title: name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(lang.rawValue)
            languageSubmenu.addItem(item)
        }
        languageItem.submenu = languageSubmenu
        submenu.addItem(languageItem)
        
        // Voice Prompts submenu
        let voicePromptsItem = NSMenuItem(title: "Voice Prompts", action: nil, keyEquivalent: "")
        let vpSubmenu = NSMenu()
        vpSubmenu.autoenablesItems = false
        
        let vpOnItem = NSMenuItem(title: "On", action: #selector(setVoicePromptsOn), keyEquivalent: "")
        vpOnItem.target = self
        vpOnItem.tag = 501
        vpSubmenu.addItem(vpOnItem)
        
        let vpOffItem = NSMenuItem(title: "Off", action: #selector(setVoicePromptsOff), keyEquivalent: "")
        vpOffItem.target = self
        vpOffItem.tag = 502
        vpSubmenu.addItem(vpOffItem)
        
        voicePromptsItem.submenu = vpSubmenu
        submenu.addItem(voicePromptsItem)
        
        return submenu
    }

    
    // MARK: - Menu Update Methods
    
    private func updateDeviceHeader(name: String, battery: Int?, isConnected: Bool = false) {
        guard let menu = statusItem?.menu,
              let deviceItem = menu.item(withTag: MenuTag.deviceHeader.rawValue) else { return }
        
        // Recreate the custom view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: battery != nil ? 48 : 32))
        
        // Blue circle background for connected state
        let circleSize: CGFloat = 32
        let circleX: CGFloat = 10
        let circleY: CGFloat = (containerView.frame.height - circleSize) / 2
        
        if isConnected {
            let circleView = NSView(frame: NSRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
            circleView.wantsLayer = true
            circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
            circleView.layer?.cornerRadius = circleSize / 2
            containerView.addSubview(circleView)
        }
        
        // Headphone icon
        let iconSize: CGFloat = 20
        let iconX = circleX + (circleSize - iconSize) / 2
        let iconY = circleY + (circleSize - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        if let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = isConnected ? .white : .secondaryLabelColor
        }
        containerView.addSubview(iconView)
        
        // Device name label
        let textX: CGFloat = circleX + circleSize + 10
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: textX, y: battery != nil ? 26 : 7, width: 200, height: 18)
        containerView.addSubview(nameLabel)
        
        // Battery label with icon (if available)
        if let battery = battery {
            let batteryText = "\(battery)%"
            let batteryLabel = NSTextField(labelWithString: batteryText)
            batteryLabel.font = NSFont.systemFont(ofSize: 11)
            batteryLabel.textColor = .secondaryLabelColor
            batteryLabel.sizeToFit()
            let batteryY: CGFloat = 8
            batteryLabel.frame = NSRect(x: textX, y: batteryY, width: batteryLabel.frame.width, height: 16)
            containerView.addSubview(batteryLabel)
            
            // Battery icon - vertically centered with text, closer spacing
            let iconHeight: CGFloat = 11
            let iconY = batteryY + (16 - iconHeight) / 2
            let batteryIconView = NSImageView(frame: NSRect(x: textX + batteryLabel.frame.width + 2, y: iconY, width: 20, height: iconHeight))
            let batteryIconName = batteryIconNameForLevel(battery)
            if let batteryImage = NSImage(systemSymbolName: batteryIconName, accessibilityDescription: "Battery") {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                batteryIconView.image = batteryImage.withSymbolConfiguration(config)
                batteryIconView.contentTintColor = batteryColorForLevel(battery)
            }
            containerView.addSubview(batteryIconView)
        }
        
        deviceItem.view = containerView
    }
    
    private func batteryIconNameForLevel(_ level: Int) -> String {
        switch level {
        case 0...10: return "battery.0percent"
        case 11...25: return "battery.25percent"
        case 26...50: return "battery.50percent"
        case 51...75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    
    private func batteryColorForLevel(_ level: Int) -> NSColor {
        if level <= 20 {
            return .systemRed
        } else if level <= 50 {
            return .systemOrange
        } else {
            return .secondaryLabelColor
        }
    }
    
    private func updateNCSelection(level: UInt8) {
        guard let menu = statusItem?.menu else { return }
        currentNCLevel = level
        
        // Clear all checkmarks
        menu.item(withTag: MenuTag.ncOff.rawValue)?.state = .off
        menu.item(withTag: MenuTag.ncLow.rawValue)?.state = .off
        menu.item(withTag: MenuTag.ncHigh.rawValue)?.state = .off
        
        // Set the appropriate checkmark
        switch level {
        case 0x00:
            menu.item(withTag: MenuTag.ncOff.rawValue)?.state = .on
        case 0x03:
            menu.item(withTag: MenuTag.ncLow.rawValue)?.state = .on
        case 0x01:
            menu.item(withTag: MenuTag.ncHigh.rawValue)?.state = .on
        default:
            break
        }
    }
    
    private func updateSelfVoiceSelection(level: UInt8) {
        guard let menu = statusItem?.menu else { return }
        currentSelfVoiceLevel = level
        
        // Clear all checkmarks
        menu.item(withTag: MenuTag.svOff.rawValue)?.state = .off
        menu.item(withTag: MenuTag.svLow.rawValue)?.state = .off
        menu.item(withTag: MenuTag.svMedium.rawValue)?.state = .off
        menu.item(withTag: MenuTag.svHigh.rawValue)?.state = .off
        
        // Set the appropriate checkmark
        switch level {
        case 0x00:
            menu.item(withTag: MenuTag.svOff.rawValue)?.state = .on
        case 0x03:
            menu.item(withTag: MenuTag.svLow.rawValue)?.state = .on
        case 0x02:
            menu.item(withTag: MenuTag.svMedium.rawValue)?.state = .on
        case 0x01:
            menu.item(withTag: MenuTag.svHigh.rawValue)?.state = .on
        default:
            break
        }
    }
    
    private func updateInfoSubmenu(firmware: String?, codec: String?, vendorId: String?, productId: String?, services: String?, serial: String?) {
        guard let menu = statusItem?.menu,
              let infoItem = menu.item(withTag: MenuTag.infoSubmenu.rawValue),
              let submenu = infoItem.submenu else { return }
        
        submenu.item(withTag: 401)?.title = "Firmware: \(firmware ?? "Unknown")"
        submenu.item(withTag: 402)?.title = "Audio Codec: \(codec ?? "Unknown")"
        
        let deviceIdText = "\(vendorId ?? "Unknown") / \(productId ?? "Unknown")"
        submenu.item(withTag: 403)?.title = "Device ID: \(deviceIdText)"
        submenu.item(withTag: 404)?.title = "Services: \(services ?? "Unknown")"
        submenu.item(withTag: 405)?.title = "Serial Number: \(serial ?? "Unknown")"
    }
    
    private func updatePairedDevicesMenu(_ devices: [String], totalCount: Int, connectedCount: Int) {
        guard let menu = statusItem?.menu,
              let pairedItem = menu.item(withTag: MenuTag.pairedDevices.rawValue) else { return }
        
        pairedItem.title = "Paired Devices: \(totalCount) (\(connectedCount) connected)"
        
        if !devices.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            
            let headerItem = NSMenuItem(title: "! = Current device, * = Connected", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            submenu.addItem(headerItem)
            submenu.addItem(NSMenuItem.separator())
            
            for device in devices {
                let deviceItem = NSMenuItem(title: device, action: nil, keyEquivalent: "")
                deviceItem.isEnabled = false
                submenu.addItem(deviceItem)
            }
            
            pairedItem.submenu = submenu
            pairedItem.isEnabled = true
        }
    }
    
    // MARK: - Device Discovery
    
    private func checkForBoseDevices() {
        print("Checking for Bose devices...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.launchPath = "/usr/sbin/system_profiler"
            task.arguments = ["SPBluetoothDataType"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.parseBoseInfoFromSystemProfiler(output)
                        self?.detectNoiseCancellationStatusAsync()
                    }
                } else {
                    print("Failed to get system profiler output")
                    DispatchQueue.main.async {
                        self?.updateMenuWithNoDevice()
                    }
                }
            } catch {
                print("Error running system_profiler: \(error)")
                DispatchQueue.main.async {
                    self?.updateMenuWithNoDevice()
                }
            }
        }
    }
    
    private func detectNoiseCancellationStatusAsync() {
        guard let deviceAddr = deviceAddress else {
            print("No device address available for NC detection")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print(">>> Starting connection to device: \(deviceAddr)")
            
            if self.connectToBoseDeviceSync(address: deviceAddr) {
                print(">>> Connection successful, initializing Bose protocol...")
                
                if self.initBoseConnection() {
                    print(">>> Init successful, fetching device info...")
                    self.fetchAllDeviceInfo()
                } else {
                    print(">>> Init failed, trying to fetch without init...")
                    self.fetchAllDeviceInfo()
                }
            } else {
                print(">>> Connection failed")
            }
        }
    }
    
    private func connectToBoseDeviceSync(address: String) -> Bool {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            print("No paired devices found")
            return false
        }
        
        print("Looking for device with address: \(address)")
        
        guard let device = pairedDevices.first(where: { device in
            if let deviceAddress = device.addressString {
                if deviceAddress.uppercased() == address.uppercased() {
                    return true
                }
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                if cleanDeviceAddr.uppercased() == cleanTargetAddr.uppercased() {
                    return true
                }
            }
            if let name = device.name, name.contains("Bose") {
                return true
            }
            return false
        }) else {
            print("Could not find Bose device in paired devices")
            return false
        }
        
        print("Found Bose device: \(device.name ?? "Unknown") at \(device.addressString ?? "Unknown")")
        
        if !device.isConnected() {
            print("Device not connected, attempting to connect...")
            let connectResult = device.openConnection()
            if connectResult != kIOReturnSuccess {
                print("Failed to open connection: \(krToString(connectResult))")
            } else {
                print("Connection opened successfully")
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        
        let ret = device.performSDPQuery(self, uuids: [])
        if ret != kIOReturnSuccess {
            print("SDP Query unsuccessful: \(krToString(ret))")
        }
        
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            print("No services found on device")
            return false
        }
        
        guard let sppService = services.first(where: { $0.getServiceName() == "SPP Dev" }) else {
            print("Could not find SPP Dev service")
            if let anySerialService = services.first(where: {
                let name = $0.getServiceName() ?? ""
                return name.lowercased().contains("spp") || name.lowercased().contains("serial")
            }) {
                return connectToService(device: device, service: anySerialService)
            }
            return false
        }
        
        return connectToService(device: device, service: sppService)
    }
    
    private func connectToService(device: IOBluetoothDevice, service: IOBluetoothSDPServiceRecord) -> Bool {
        var channelId: BluetoothRFCOMMChannelID = BluetoothRFCOMMChannelID()
        let channelResult = service.getRFCOMMChannelID(&channelId)
        if channelResult != kIOReturnSuccess {
            print("Failed to get RFCOMM channel ID: \(channelResult)")
            return false
        }
        
        if let existingChannel = rfcommChannel, existingChannel.isOpen() {
            return true
        }
        
        rfcommChannel = nil
        isChannelReady = false
        
        var channel: IOBluetoothRFCOMMChannel?
        var openResult = device.openRFCOMMChannelSync(&channel, withChannelID: channelId, delegate: self)
        
        if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
            self.rfcommChannel = ch
            self.isChannelReady = true
            return true
        }
        
        channelOpenSemaphore = DispatchSemaphore(value: 0)
        let asyncResult = device.openRFCOMMChannelAsync(&channel, withChannelID: channelId, delegate: self)
        if asyncResult == kIOReturnSuccess {
            self.rfcommChannel = channel
            let waitResult = channelOpenSemaphore?.wait(timeout: .now() + 10.0)
            channelOpenSemaphore = nil
            if waitResult != .timedOut && isChannelReady && (rfcommChannel?.isOpen() ?? false) {
                return true
            }
        } else {
            channelOpenSemaphore = nil
        }
        
        let channelIdsToTry: [BluetoothRFCOMMChannelID] = [8, 9, 1, 2, 3]
        for tryChannelId in channelIdsToTry {
            if tryChannelId == channelId { continue }
            channel = nil
            openResult = device.openRFCOMMChannelSync(&channel, withChannelID: tryChannelId, delegate: self)
            if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
                self.rfcommChannel = ch
                self.isChannelReady = true
                return true
            }
        }
        
        return false
    }
    
    private func initBoseConnection() -> Bool {
        guard let channel = rfcommChannel, channel.isOpen() else {
            return false
        }
        
        let initCommand: [UInt8] = [0x00, 0x01, 0x01, 0x00]
        responseBuffer = []
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = initCommand
        var result: [UInt8] = []
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            responseSemaphore = nil
            return false
        }
        
        let waitResult = responseSemaphore?.wait(timeout: .now() + 5.0)
        responseSemaphore = nil
        
        if waitResult == .timedOut {
            return true
        }
        
        if responseBuffer.count >= 4 && responseBuffer[0] == 0x00 && responseBuffer[1] == 0x01 {
            return true
        }
        
        return true
    }

    
    // MARK: - Command Helpers
    
    private func sendCommandAndWait(command: [UInt8], expectedPrefix: [UInt8], timeout: TimeInterval = 0.5) -> [UInt8] {
        guard let channel = rfcommChannel, channel.isOpen() else { return [] }
        
        responseLock.lock()
        responseBuffer = []
        expectedResponsePrefix = expectedPrefix
        responseLock.unlock()
        
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = command
        var result: [UInt8] = []
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            responseSemaphore = nil
            responseLock.lock()
            expectedResponsePrefix = []
            responseLock.unlock()
            return []
        }
        
        _ = responseSemaphore?.wait(timeout: .now() + timeout)
        responseSemaphore = nil
        
        responseLock.lock()
        let result_buffer = responseBuffer
        expectedResponsePrefix = []
        responseLock.unlock()
        
        return result_buffer
    }
    
    // MARK: - Fetch All Device Info
    
    private func fetchAllDeviceInfo() {
        fetchBatteryLevel()
        fetchSerialNumber()
        fetchDeviceStatus()
        fetchPairedDevices()
    }
    
    private func fetchBatteryLevel() {
        let command: [UInt8] = [0x02, 0x02, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x02, 0x02])
        
        if response.count >= 5 && response[0] == 0x02 && response[1] == 0x02 && response[2] == 0x03 {
            let level = Int(response[4])
            DispatchQueue.main.async {
                self.updateBatteryInMenu(level)
            }
        }
    }
    
    private func fetchSerialNumber() {
        let command: [UInt8] = [0x00, 0x07, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x00, 0x07])
        
        if response.count >= 4 && response[0] == 0x00 && response[1] == 0x07 && response[2] == 0x03 {
            let length = Int(response[3])
            if response.count >= 4 + length {
                let serialBytes = Array(response[4..<(4 + length)])
                if let serial = String(bytes: serialBytes, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.updateSerialInMenu(serial)
                    }
                }
            }
        }
    }
    
    private func fetchDeviceStatus() {
        let deviceIdCommand: [UInt8] = [0x00, 0x03, 0x01, 0x00]
        _ = sendCommandAndWait(command: deviceIdCommand, expectedPrefix: [0x00, 0x03])
        
        let statusCommand: [UInt8] = [0x01, 0x01, 0x05, 0x00]
        
        responseLock.lock()
        responseBuffer = []
        expectedResponsePrefix = [0x01]
        responseLock.unlock()
        
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = statusCommand
        var result: [UInt8] = []
        let writeResult = rfcommChannel?.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            responseSemaphore = nil
            responseLock.lock()
            expectedResponsePrefix = []
            responseLock.unlock()
            return
        }
        
        _ = responseSemaphore?.wait(timeout: .now() + 0.5)
        
        for _ in 0..<5 {
            responseSemaphore = DispatchSemaphore(value: 0)
            let waitResult = responseSemaphore?.wait(timeout: .now() + 0.15)
            if waitResult == .timedOut {
                break
            }
        }
        responseSemaphore = nil
        
        responseLock.lock()
        let statusResponse = responseBuffer
        expectedResponsePrefix = []
        responseLock.unlock()
        
        parseDeviceStatusResponse(statusResponse)
    }
    
    private func parseDeviceStatusResponse(_ response: [UInt8]) {
        // Parse language
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x03 && response[i+2] == 0x03 {
                let langByte = response[i+4]
                let voicePromptsOn = (langByte & 0x80) != 0
                let langValue = langByte & 0x7F
                
                currentLanguageValue = langByte
                
                if let lang = PromptLanguage(rawValue: langValue) {
                    DispatchQueue.main.async {
                        self.updateLanguageCheckmark(lang)
                        self.updateVoicePromptsCheckmark(voicePromptsOn)
                    }
                }
                break
            }
        }
        
        // Parse NC level
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x06 && response[i+2] == 0x03 {
                let ncLevel = response[i+4]
                DispatchQueue.main.async {
                    self.updateNCSelection(level: ncLevel)
                }
                break
            }
        }
        
        // Parse Self Voice level
        for i in 0..<response.count {
            if i + 5 < response.count && response[i] == 0x01 && response[i+1] == 0x0b && response[i+2] == 0x03 {
                let selfVoiceLevel = response[i+5]
                DispatchQueue.main.async {
                    self.updateSelfVoiceSelection(level: selfVoiceLevel)
                }
                break
            }
        }
    }
    
    private func fetchPairedDevices() {
        let command: [UInt8] = [0x04, 0x04, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x04])
        
        if response.count >= 5 && response[0] == 0x04 && response[1] == 0x04 && response[2] == 0x03 {
            let numDevicesBytes = Int(response[3])
            let numDevices = numDevicesBytes / 6
            let numConnected = Int(response[4])
            
            var devices: [String] = []
            var offset = 5
            
            for i in 0..<numDevices {
                if offset + 6 <= response.count {
                    let addressBytes = Array(response[offset..<(offset + 6)])
                    let address = addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                    
                    var deviceName: String?
                    if i == 0 {
                        deviceName = Host.current().localizedName ?? getDeviceNameForAddress(address)
                    } else {
                        deviceName = getDeviceNameForAddress(address)
                    }
                    
                    let indicator: String
                    if i == 0 {
                        indicator = "! "
                    } else if i < numConnected {
                        indicator = "* "
                    } else {
                        indicator = "  "
                    }
                    
                    if let name = deviceName {
                        devices.append("\(indicator)\(name) (\(address))")
                    } else {
                        devices.append("\(indicator)\(address)")
                    }
                    
                    offset += 6
                }
            }
            
            DispatchQueue.main.async {
                self.updatePairedDevicesMenu(devices, totalCount: numDevices, connectedCount: numConnected)
            }
        }
    }
    
    private func getDeviceNameForAddress(_ address: String) -> String? {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }
        
        for device in pairedDevices {
            if let deviceAddress = device.addressString {
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                if cleanDeviceAddr == cleanTargetAddr {
                    return device.name
                }
            }
        }
        return nil
    }
    
    // MARK: - RFCOMM Delegate
    
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = dataPointer.assumingMemoryBound(to: UInt8.self)
        var responseData: [UInt8] = []
        for i in 0..<dataLength {
            responseData.append(bytes[i])
        }
        
        responseLock.lock()
        let expectedPrefix = expectedResponsePrefix
        var isExpectedResponse = expectedPrefix.isEmpty
        
        if !isExpectedResponse && !responseData.isEmpty {
            if expectedPrefix.count == 1 {
                isExpectedResponse = responseData[0] == expectedPrefix[0]
            } else if expectedPrefix.count >= 2 && responseData.count >= 2 {
                isExpectedResponse = responseData[0] == expectedPrefix[0] && responseData[1] == expectedPrefix[1]
            }
        }
        
        if isExpectedResponse {
            responseBuffer.append(contentsOf: responseData)
            responseLock.unlock()
            responseSemaphore?.signal()
        } else {
            responseLock.unlock()
        }
        
        // Parse NC status updates
        if responseData.count >= 5 && responseData[0] == 0x01 && responseData[1] == 0x06 {
            var ncLevel: UInt8
            if responseData[2] == 0x04 && responseData.count == 5 {
                ncLevel = responseData[4]
            } else if responseData[2] == 0x03 && responseData.count >= 5 {
                ncLevel = responseData[4]
            } else {
                ncLevel = responseData[4]
            }
            DispatchQueue.main.async {
                self.updateNCSelection(level: ncLevel)
            }
        }
    }
    
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            isChannelReady = true
        } else {
            isChannelReady = false
        }
        channelOpenSemaphore?.signal()
    }
    
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        self.rfcommChannel = nil
    }

    
    // MARK: - System Profiler Parsing
    
    private func parseBoseInfoFromSystemProfiler(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        var currentDevice: String?
        var batteryLevel: Int?
        var firmwareVersion: String?
        var vendorId: String?
        var productId: String?
        var services: String?
        var deviceAddress: String?
        var isConnected = false
        var foundBoseDevice = false
        var isProcessingBoseDevice = false
        
        for (_, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.contains("Bose") && trimmedLine.hasSuffix(":") {
                currentDevice = String(trimmedLine.dropLast())
                isConnected = true
                foundBoseDevice = true
                isProcessingBoseDevice = true
                batteryLevel = nil
                firmwareVersion = nil
                vendorId = nil
                productId = nil
                services = nil
                deviceAddress = nil
                continue
            }
            
            if trimmedLine.hasSuffix(":") && !trimmedLine.contains("Bose") && !trimmedLine.isEmpty {
                isProcessingBoseDevice = false
            }
            
            guard isProcessingBoseDevice else { continue }
            
            if trimmedLine.contains("Address:") {
                if let range = trimmedLine.range(of: "Address:") {
                    let addressPart = String(trimmedLine[range.upperBound...])
                    deviceAddress = addressPart.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            
            if trimmedLine.contains("Battery Level:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    let batteryString = components[1].trimmingCharacters(in: .whitespaces)
                    if let percentage = Int(batteryString.replacingOccurrences(of: "%", with: "")) {
                        batteryLevel = percentage
                    }
                }
                continue
            }
            
            if trimmedLine.contains("Firmware Version:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    firmwareVersion = components[1].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            
            if trimmedLine.contains("Vendor ID:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    vendorId = components[1].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            
            if trimmedLine.contains("Product ID:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    productId = components[1].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            
            if trimmedLine.contains("Services:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    services = components[1].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            
            if !line.hasPrefix("      ") && !trimmedLine.isEmpty && trimmedLine != "Connected:" && trimmedLine != "Not Connected:" {
                if let device = currentDevice, device.contains("Bose") {
                    self.deviceAddress = deviceAddress
                    
                    let info = HeadphoneInfo(
                        name: device,
                        batteryLevel: batteryLevel,
                        isConnected: isConnected,
                        firmwareVersion: firmwareVersion,
                        noiseCancellationEnabled: nil,
                        audioCodec: determineAudioCodec(from: services),
                        vendorId: vendorId,
                        productId: productId,
                        services: services,
                        serialNumber: nil,
                        language: nil,
                        voicePromptsEnabled: nil,
                        selfVoiceLevel: nil,
                        pairedDevices: nil,
                        pairedDevicesCount: nil,
                        connectedDevicesCount: nil
                    )
                    
                    DispatchQueue.main.async {
                        self.updateMenuWithHeadphoneInfo(info)
                    }
                    return
                }
                
                currentDevice = nil
                batteryLevel = nil
                firmwareVersion = nil
                vendorId = nil
                productId = nil
                services = nil
                deviceAddress = nil
                isConnected = false
                isProcessingBoseDevice = false
            }
        }
        
        if let device = currentDevice, device.contains("Bose") {
            self.deviceAddress = deviceAddress
            
            let info = HeadphoneInfo(
                name: device,
                batteryLevel: batteryLevel,
                isConnected: isConnected,
                firmwareVersion: firmwareVersion,
                noiseCancellationEnabled: nil,
                audioCodec: determineAudioCodec(from: services),
                vendorId: vendorId,
                productId: productId,
                services: services,
                serialNumber: nil,
                language: nil,
                voicePromptsEnabled: nil,
                selfVoiceLevel: nil,
                pairedDevices: nil,
                pairedDevicesCount: nil,
                connectedDevicesCount: nil
            )
            
            DispatchQueue.main.async {
                self.updateMenuWithHeadphoneInfo(info)
            }
            return
        }
        
        if !foundBoseDevice {
            updateMenuWithNoDevice()
        }
    }
    
    private func determineAudioCodec(from services: String?) -> String {
        guard let services = services else { return "Unknown" }
        if services.contains("A2DP") {
            return "A2DP (High Quality)"
        } else if services.contains("HFP") {
            return "HFP (Voice)"
        } else {
            return "Standard"
        }
    }
    
    private func updateMenuWithHeadphoneInfo(_ info: HeadphoneInfo) {
        currentHeadphoneInfo = info
        
        // Update device header with name, battery, and connection status
        updateDeviceHeader(name: info.name, battery: info.batteryLevel, isConnected: info.isConnected)
        
        // Update status bar icon
        if let battery = info.batteryLevel {
            updateStatusBarIcon(batteryLevel: battery)
        }
        
        // Update Info submenu
        updateInfoSubmenu(
            firmware: info.firmwareVersion,
            codec: info.audioCodec,
            vendorId: info.vendorId,
            productId: info.productId,
            services: info.services,
            serial: info.serialNumber
        )
        
        // Update tooltip
        if let button = statusItem?.button {
            let batteryInfo = info.batteryLevel.map { "\($0)%" } ?? "Unknown"
            button.toolTip = "\(info.name)\nBattery: \(batteryInfo)"
        }
    }
    
    private func updateMenuWithNoDevice() {
        let info = HeadphoneInfo(
            name: "No Bose Device Found",
            batteryLevel: nil,
            isConnected: false,
            firmwareVersion: nil,
            noiseCancellationEnabled: nil,
            audioCodec: nil,
            vendorId: nil,
            productId: nil,
            services: nil,
            serialNumber: nil,
            language: nil,
            voicePromptsEnabled: nil,
            selfVoiceLevel: nil,
            pairedDevices: nil,
            pairedDevicesCount: nil,
            connectedDevicesCount: nil
        )
        updateMenuWithHeadphoneInfo(info)
    }
    
    private func updateStatusBarIcon(batteryLevel: Int) {
        guard let button = statusItem?.button else { return }
        if batteryLevel < 20 {
            button.contentTintColor = .systemRed
        } else if batteryLevel < 50 {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil
        }
    }
    
    private func updateBatteryInMenu(_ level: Int) {
        if let info = currentHeadphoneInfo {
            updateDeviceHeader(name: info.name, battery: level, isConnected: info.isConnected)
            updateStatusBarIcon(batteryLevel: level)
        }
    }
    
    private func updateSerialInMenu(_ serial: String) {
        guard let menu = statusItem?.menu,
              let infoItem = menu.item(withTag: MenuTag.infoSubmenu.rawValue),
              let submenu = infoItem.submenu else { return }
        submenu.item(withTag: 405)?.title = "Serial Number: \(serial)"
    }
    
    private func updateLanguageCheckmark(_ language: PromptLanguage) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu,
              let languageItem = settingsSubmenu.item(at: 0),
              let languageSubmenu = languageItem.submenu else { return }
        
        for item in languageSubmenu.items {
            item.state = (item.tag == Int(language.rawValue)) ? .on : .off
        }
    }
    
    private func updateVoicePromptsCheckmark(_ on: Bool) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu,
              let vpItem = settingsSubmenu.item(at: 1),
              let vpSubmenu = vpItem.submenu else { return }
        
        vpSubmenu.item(withTag: 501)?.state = on ? .on : .off
        vpSubmenu.item(withTag: 502)?.state = on ? .off : .on
    }

    
    // MARK: - Actions
    
    @objc private func refreshBattery() {
        checkForBoseDevices()
    }
    
    @objc private func setNoiseCancellationOff() {
        sendNoiseCancellationCommand(level: 0x00)
    }
    
    @objc private func setNoiseCancellationLow() {
        sendNoiseCancellationCommand(level: 0x03)
    }
    
    @objc private func setNoiseCancellationHigh() {
        sendNoiseCancellationCommand(level: 0x01)
    }
    
    private func sendNoiseCancellationCommand(level: UInt8) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x06, 0x02, 0x01, level]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.updateNCSelection(level: level)
                }
            }
        }
    }
    
    @objc private func setSelfVoiceOff() {
        setSelfVoiceAsync(.off)
    }
    
    @objc private func setSelfVoiceLow() {
        setSelfVoiceAsync(.low)
    }
    
    @objc private func setSelfVoiceMedium() {
        setSelfVoiceAsync(.medium)
    }
    
    @objc private func setSelfVoiceHigh() {
        setSelfVoiceAsync(.high)
    }
    
    private func setSelfVoiceAsync(_ level: SelfVoice) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.updateSelfVoiceSelection(level: level.rawValue)
                }
            }
        }
    }
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let languageValue = UInt8(sender.tag)
        
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, languageValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    if let lang = PromptLanguage(rawValue: languageValue) {
                        self.updateLanguageCheckmark(lang)
                    }
                }
            }
        }
    }
    
    private var currentLanguageValue: UInt8 = 0x21
    
    @objc private func setVoicePromptsOn() {
        setVoicePrompts(on: true)
    }
    
    @objc private func setVoicePromptsOff() {
        setVoicePrompts(on: false)
    }
    
    private func setVoicePrompts(on: Bool) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            var languageValue = self.currentLanguageValue & 0x7F
            if on {
                languageValue |= 0x80
            }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, languageValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.updateVoicePromptsCheckmark(on)
                }
            }
        }
    }
    
    @objc private func disconnectDevice() {
        // Placeholder - will be moved to device list later
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Async Helpers
    
    private func sendCommandAsync(_ command: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let channel = self.rfcommChannel, channel.isOpen() else {
                completion(nil)
                return
            }
            
            self.responseBuffer = []
            self.responseSemaphore = DispatchSemaphore(value: 0)
            
            var data = command
            var result: [UInt8] = []
            let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
            if writeResult != kIOReturnSuccess {
                self.responseSemaphore = nil
                completion(nil)
                return
            }
            
            let waitResult = self.responseSemaphore?.wait(timeout: .now() + 2.0)
            self.responseSemaphore = nil
            
            if waitResult == .timedOut {
                completion(nil)
                return
            }
            
            completion(self.responseBuffer.isEmpty ? nil : self.responseBuffer)
        }
    }
    
    private func ensureConnectionAsync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            if self.rfcommChannel == nil || !(self.rfcommChannel?.isOpen() ?? false) {
                if let deviceAddr = self.deviceAddress {
                    let result = self.connectToBoseDeviceSync(address: deviceAddr)
                    completion(result)
                } else {
                    completion(false)
                }
            } else {
                completion(true)
            }
        }
    }
    
    private func krToString(_ kr: kern_return_t) -> String {
        if let cStr = mach_error_string(kr) {
            return String(cString: cStr)
        } else {
            return "Unknown kernel error \(kr)"
        }
    }
    
    @objc func newRFCOMMChannelOpened(userNotification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        channel.setDelegate(self)
    }
}
