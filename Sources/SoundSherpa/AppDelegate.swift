import Cocoa
import Foundation
import IOBluetooth
import SoundSherpaCore

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

struct PairedDeviceInfo {
    let address: String
    let name: String
    let isConnected: Bool
    let isCurrentDevice: Bool
}

// MARK: - Paired Device Icon Mapping

/// Maps a transport-agnostic PairedDeviceType (from SoundSherpaCore) to the SF Symbol
/// name used in the menu. Lives in the UI layer so SoundSherpaCore stays free of AppKit.
private extension PairedDeviceType {
    var iconName: String {
        switch self {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .macBook: return "laptopcomputer"
        case .mac: return "desktopcomputer"
        case .appleWatch: return "applewatch"
        case .appleTV: return "appletv"
        case .airPods: return "airpods"
        case .appleGeneric: return "apple.logo"
        case .windows: return "pc"
        case .android: return "smartphone"
        case .unknown: return "display"
        }
    }
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

enum AutoOff: UInt8 {
    case never = 0x00
    case five = 0x05
    case twenty = 0x14
    case forty = 0x28
    case sixty = 0x3C
    case oneEighty = 0xB4
    case unknown = 0xFF
    
    var displayName: String {
        switch self {
        case .never: return "Never"
        case .five: return "5 minutes"
        case .twenty: return "20 minutes"
        case .forty: return "40 minutes"
        case .sixty: return "60 minutes"
        case .oneEighty: return "180 minutes"
        case .unknown: return "Unknown"
        }
    }
}

enum ButtonAction: UInt8 {
    case alexa = 0x01
    case noiseCancellation = 0x02
    case unknown = 0xFF
    
    var displayName: String {
        switch self {
        case .alexa: return "Alexa"
        case .noiseCancellation: return "Noise Cancellation"
        case .unknown: return "Unknown"
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
    private var currentAutoOffLevel: UInt8 = 0xFF // Unknown
    private var currentButtonAction: UInt8 = 0xFF // Unknown
    private var pairedDevicesList: [PairedDeviceInfo] = [] // Store paired devices for menu actions
    
    // Cached device info for immediate display
    private var cachedBatteryLevel: Int?
    private var cachedFirmwareVersion: String?
    private var cachedSerialNumber: String?
    private var cachedAudioCodec: String?
    private var cachedServices: String?
    private var cachedLanguage: PromptLanguage?
    private var cachedVoicePromptsEnabled: Bool?
    private var lastDataFetchTime: Date?
    private let cacheValidityDuration: TimeInterval = 30.0 // Cache is valid for 30 seconds
    
    // Bluetooth connection monitoring
    private var currentBoseDevice: IOBluetoothDevice?
    private var connectionNotification: IOBluetoothUserNotification?
    private var disconnectionNotification: IOBluetoothUserNotification?
    private var lastConnectionAttempt: Date?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupBluetoothNotifications()
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
        
        // Clean up Bluetooth notifications
        connectionNotification?.unregister()
        disconnectionNotification?.unregister()
        
        if let channel = rfcommChannel, channel.isOpen() {
            _ = channel.close()
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "headphones.over.ear", accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "SoundSherpa"
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
        
        let svHighItem = createSelfVoiceMenuItem(title: "High", action: #selector(setSelfVoiceHigh), tag: MenuTag.svHigh.rawValue, iconName: "person.spatialaudio.stereo.fill")
        menu.addItem(svHighItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === PAIRED DEVICES HEADER ===
        let pairedDevicesHeader = createSectionHeader(title: "Paired Devices")
        pairedDevicesHeader.tag = MenuTag.pairedDevices.rawValue
        menu.addItem(pairedDevicesHeader)
        
        // Paired device items will be added dynamically after this header
        
        menu.addItem(NSMenuItem.separator())
        
        // === ADVANCED SETTINGS SUBMENU ===
        let settingsItem = NSMenuItem(title: "Advanced Settings", action: nil, keyEquivalent: "")
        settingsItem.tag = MenuTag.settingsSubmenu.rawValue
        let settingsSubmenu = createSettingsSubmenu()
        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)
        
        // === ABOUT SOUNDSHERPA ===
        let aboutItem = NSMenuItem(title: "About SoundSherpa", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // === QUIT ===
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        
        // Initialize menu with cached values if available
        initializeMenuWithCachedValues()
    }
    
    private func setupBluetoothNotifications() {
        // For now, let's use a simpler approach - just register for general connection notifications
        // The main benefit is detecting disconnections via rfcommChannelClosed
        connectionNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }
    
    private func setupDeviceSpecificNotifications(for device: IOBluetoothDevice) {
        // Register for disconnection notifications on the specific device
        // Only if we don't already have one registered
        if disconnectionNotification == nil {
            disconnectionNotification = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
    }
    
    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Simple approach - just note that a Bose device connected, but don't interfere with normal operation
        if isBoseDevice(device) {
            print("Bose device connected: \(device.name ?? "Unknown")")
            currentBoseDevice = device
            setupDeviceSpecificNotifications(for: device)
        }
    }
    
    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Only act on disconnection of our current device
        if isBoseDevice(device) && currentBoseDevice?.addressString == device.addressString {
            print("Bose device disconnected: \(device.name ?? "Unknown")")
            currentBoseDevice = nil
            disconnectionNotification = nil // Clear the notification
            
            // Update menu to show disconnected state
            DispatchQueue.main.async {
                self.updateMenuWithNoDevice()
            }
        }
    }
    
    private func isBoseDevice(_ device: IOBluetoothDevice) -> Bool {
        guard let name = device.name else { return false }
        return name.lowercased().contains("bose")
    }
    
    private func initializeMenuWithCachedValues() {
        // Only show cached values if device is currently connected
        guard let info = currentHeadphoneInfo, info.isConnected else {
            return // Don't show cached info when disconnected
        }
        
        // Show cached battery level if available
        if let battery = cachedBatteryLevel {
            updateDeviceHeader(name: info.name, battery: battery, isConnected: true)
            updateStatusBarIcon(batteryLevel: battery)
        }
        
        // Show cached NC level
        if currentNCLevel != 0xFF {
            updateNCSelection(level: currentNCLevel)
        }
        
        // Show cached self voice level
        if currentSelfVoiceLevel != 0xFF {
            updateSelfVoiceSelection(level: currentSelfVoiceLevel)
        }
        
        // Show cached auto-off level
        if currentAutoOffLevel != 0xFF {
            updateAutoOffSelection(level: currentAutoOffLevel)
        }
        
        // Show cached button action level
        if currentButtonAction != 0xFF {
            updateButtonActionSelection(level: currentButtonAction)
        }
        
        // Show cached language
        if let language = cachedLanguage {
            updateLanguageCheckmark(language)
        }
        
        // Show cached voice prompts setting
        if let voicePrompts = cachedVoicePromptsEnabled {
            updateVoicePromptsCheckmark(voicePrompts)
        }
        
        // Show cached info items (only if we have some cached data)
        if cachedFirmwareVersion != nil || cachedSerialNumber != nil || cachedAudioCodec != nil || cachedServices != nil {
            updateInfoSubmenu(
                firmware: cachedFirmwareVersion,
                codec: cachedAudioCodec,
                vendorId: nil,
                productId: nil,
                services: cachedServices,
                serial: cachedSerialNumber
            )
        }
        
        // Show cached paired devices
        if !pairedDevicesList.isEmpty {
            updatePairedDevicesMenu(pairedDevicesList, totalCount: pairedDevicesList.count, connectedCount: pairedDevicesList.filter { $0.isConnected }.count)
        }
    }
    
    private func shouldFetchFreshData() -> Bool {
        guard let lastFetch = lastDataFetchTime else {
            return true // No previous fetch, so fetch now
        }
        
        let timeSinceLastFetch = Date().timeIntervalSince(lastFetch)
        return timeSinceLastFetch > cacheValidityDuration
    }
    
    private func markDataAsFetched() {
        lastDataFetchTime = Date()
    }
    
    private func createDeviceHeaderItem(name: String, battery: Int?, isConnected: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = true
        
        // When disconnected, use a standard menu item (clickable) with styled appearance
        if !isConnected {
            item.title = "     " + name  // Indent for icon space
            item.action = #selector(connectToDevice)
            item.target = self
            
            // Create a composite image with grey circle and black headphone icon
            let imageSize = NSSize(width: 32, height: 32)
            let compositeImage = NSImage(size: imageSize, flipped: false) { rect in
                // Draw grey circle
                NSColor.systemGray.setFill()
                let circlePath = NSBezierPath(ovalIn: rect)
                circlePath.fill()
                
                // Draw headphone icon
                if let headphoneImage = NSImage(systemSymbolName: "headphones.over.ear", accessibilityDescription: "Headphones") {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let configuredImage = headphoneImage.withSymbolConfiguration(config) {
                        let iconSize = NSSize(width: 18, height: 18)
                        let iconRect = NSRect(
                            x: (rect.width - iconSize.width) / 2,
                            y: (rect.height - iconSize.height) / 2,
                            width: iconSize.width,
                            height: iconSize.height
                        )
                        configuredImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                }
                return true
            }
            compositeImage.isTemplate = false
            item.image = compositeImage
            return item
        }
        
        // Connected state uses custom view with full styling
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: battery != nil ? 48 : 32))
        
        // Blue circle background
        let circleSize: CGFloat = 32
        let circleX: CGFloat = 10
        let circleY: CGFloat = (containerView.frame.height - circleSize) / 2
        
        let circleView = NSView(frame: NSRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
        circleView.wantsLayer = true
        circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        circleView.layer?.cornerRadius = circleSize / 2
        containerView.addSubview(circleView)
        
        // Headphone icon (white when connected) - centered in circle
        let iconSize: CGFloat = 18
        let iconX = circleX + (circleSize - iconSize) / 2
        let iconY = circleY + (circleSize - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        iconView.imageAlignment = .alignCenter
        if let image = NSImage(systemSymbolName: "headphones.over.ear", accessibilityDescription: "Headphones") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = .white
        }
        containerView.addSubview(iconView)
        
        // Device name label - vertically aligned with circle center when no battery, or upper half when battery shown
        let textX: CGFloat = circleX + circleSize + 10
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        
        if battery != nil {
            // Two-line layout: name on top, battery below, both centered relative to circle
            let nameY = circleY + circleSize / 2  // Upper half of circle
            nameLabel.frame = NSRect(x: textX, y: nameY, width: 200, height: 18)
        } else {
            // Single line: vertically centered with circle
            let nameY = circleY + (circleSize - 18) / 2
            nameLabel.frame = NSRect(x: textX, y: nameY, width: 200, height: 18)
        }
        containerView.addSubview(nameLabel)
        
        // Battery label with icon (if available)
        if let battery = battery {
            let batteryText = "\(battery)%"
            let batteryLabel = NSTextField(labelWithString: batteryText)
            batteryLabel.font = NSFont.systemFont(ofSize: 11)
            batteryLabel.textColor = .secondaryLabelColor
            batteryLabel.sizeToFit()
            
            // Position battery text in lower half of circle area
            let batteryLabelHeight: CGFloat = 14
            let batteryY = circleY + (circleSize / 2 - batteryLabelHeight) / 2
            batteryLabel.frame = NSRect(x: textX, y: batteryY, width: batteryLabel.frame.width, height: batteryLabelHeight)
            containerView.addSubview(batteryLabel)
            
            // Battery icon - vertically centered with battery text
            let batteryIconSize: CGFloat = 14
            let batteryIconY = batteryY + (batteryLabelHeight - batteryIconSize) / 2
            let batteryIconView = NSImageView(frame: NSRect(x: textX + batteryLabel.frame.width + 2, y: batteryIconY, width: 20, height: batteryIconSize))
            batteryIconView.imageAlignment = .alignCenter
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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            item.image = image.withSymbolConfiguration(config)
        }
        return item
    }
    
    private func createSectionHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        
        // Use a custom view to match Apple's native style
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .black
        label.frame = NSRect(x: 14, y: 1, width: 250, height: 16)
        containerView.addSubview(label)
        
        item.view = containerView
        return item
    }
    
    private func createSettingsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        // === SETTINGS ITEMS (at the top) ===
        
        // Auto-Off submenu
        let autoOffItem = NSMenuItem(title: "Auto-Off", action: nil, keyEquivalent: "")
        let autoOffSubmenu = NSMenu()
        autoOffSubmenu.autoenablesItems = false
        
        let autoOffOptions: [(String, AutoOff)] = [
            ("Never", .never),
            ("5 minutes", .five),
            ("20 minutes", .twenty),
            ("40 minutes", .forty),
            ("60 minutes", .sixty),
            ("180 minutes", .oneEighty)
        ]
        
        for (name, autoOff) in autoOffOptions {
            let item = NSMenuItem(title: name, action: #selector(setAutoOff(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(autoOff.rawValue) + 600 // Offset to avoid conflicts
            autoOffSubmenu.addItem(item)
        }
        autoOffItem.submenu = autoOffSubmenu
        submenu.addItem(autoOffItem)
        
        // Language submenu
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu()
        languageSubmenu.autoenablesItems = false
        
        let languages: [(String, PromptLanguage)] = [
            ("Chinese", .chinese), ("Dutch", .dutch), ("English", .english),
            ("French", .french), ("German", .german), ("Italian", .italian),
            ("Japanese", .japanese), ("Korean", .korean), ("Polish", .polish),
            ("Portuguese", .portuguese), ("Russian", .russian), ("Spanish", .spanish),
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
        
        // Button Action submenu
        let buttonActionItem = NSMenuItem(title: "Button Action", action: nil, keyEquivalent: "")
        let baSubmenu = NSMenu()
        baSubmenu.autoenablesItems = false
        
        let baAlexaItem = NSMenuItem(title: "Alexa", action: #selector(setButtonActionAlexa), keyEquivalent: "")
        baAlexaItem.target = self
        baAlexaItem.tag = 801
        baSubmenu.addItem(baAlexaItem)
        
        let baNCItem = NSMenuItem(title: "Noise Cancellation", action: #selector(setButtonActionNC), keyEquivalent: "")
        baNCItem.target = self
        baNCItem.tag = 802
        baSubmenu.addItem(baNCItem)
        
        buttonActionItem.submenu = baSubmenu
        submenu.addItem(buttonActionItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // === INFO ITEMS ===
        let firmwareItem = NSMenuItem(title: "Firmware: Unknown", action: nil, keyEquivalent: "")
        firmwareItem.isEnabled = false
        firmwareItem.tag = 401
        submenu.addItem(firmwareItem)
        
        let serialItem = NSMenuItem(title: "Serial Number: Unknown", action: nil, keyEquivalent: "")
        serialItem.isEnabled = false
        serialItem.tag = 405
        submenu.addItem(serialItem)
        
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
        
        submenu.addItem(NSMenuItem.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshBattery), keyEquivalent: "r")
        refreshItem.target = self
        submenu.addItem(refreshItem)
        
        return submenu
    }

    
    // MARK: - Menu Update Methods
    
    private func updateDeviceHeader(name: String, battery: Int?, isConnected: Bool = false) {
        guard let menu = statusItem?.menu,
              let deviceItem = menu.item(withTag: MenuTag.deviceHeader.rawValue) else { return }
        
        // When disconnected, use standard menu item for proper hover behavior
        if !isConnected {
            deviceItem.view = nil  // Remove custom view to enable hover
            deviceItem.action = #selector(connectToDevice)
            deviceItem.target = self
            deviceItem.isEnabled = true
            
            // Use attributed string for regular weight text
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
            deviceItem.attributedTitle = NSAttributedString(string: name, attributes: attributes)
            
            // Create a composite image with light grey circle and dark headphone icon
            let imageSize = NSSize(width: 32, height: 32)
            let compositeImage = NSImage(size: imageSize, flipped: false) { rect in
                // Draw light grey circle (like Apple native dialogs)
                NSColor(white: 0.85, alpha: 1.0).setFill()
                let circlePath = NSBezierPath(ovalIn: rect)
                circlePath.fill()
                
                // Draw headphone icon
                if let headphoneImage = NSImage(systemSymbolName: "headphones.over.ear", accessibilityDescription: "Headphones") {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let configuredImage = headphoneImage.withSymbolConfiguration(config) {
                        // Tint the icon dark
                        let _ = NSImage(size: configuredImage.size, flipped: false) { tintRect in
                            NSColor(white: 0.35, alpha: 1.0).set()
                            configuredImage.draw(in: tintRect, from: .zero, operation: .destinationIn, fraction: 1.0)
                            return true
                        }
                        let iconSize = NSSize(width: 18, height: 18)
                        let iconRect = NSRect(
                            x: (rect.width - iconSize.width) / 2,
                            y: (rect.height - iconSize.height) / 2,
                            width: iconSize.width,
                            height: iconSize.height
                        )
                        configuredImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                }
                return true
            }
            compositeImage.isTemplate = false
            deviceItem.image = compositeImage
            return
        }
        
        // Connected state - use custom view
        deviceItem.action = nil
        deviceItem.target = nil
        deviceItem.image = nil
        deviceItem.title = ""
        
        // Create custom view for connected state
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: battery != nil ? 48 : 32))
        
        // Blue circle background
        let circleSize: CGFloat = 32
        let circleX: CGFloat = 10
        let circleY: CGFloat = (containerView.frame.height - circleSize) / 2
        
        let circleView = NSView(frame: NSRect(x: circleX, y: circleY, width: circleSize, height: circleSize))
        circleView.wantsLayer = true
        circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        circleView.layer?.cornerRadius = circleSize / 2
        containerView.addSubview(circleView)
        
        // Headphone icon (white) - centered in circle
        let iconSize: CGFloat = 18
        let iconX = circleX + (circleSize - iconSize) / 2
        let iconY = circleY + (circleSize - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        iconView.imageAlignment = .alignCenter
        if let image = NSImage(systemSymbolName: "headphones.over.ear", accessibilityDescription: "Headphones") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = .white
        }
        containerView.addSubview(iconView)
        
        // Device name label - vertically aligned with circle center
        let textX: CGFloat = circleX + circleSize + 10
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        
        if battery != nil {
            // Two-line layout: name on top, battery below, both centered relative to circle
            let nameY = circleY + circleSize / 2
            nameLabel.frame = NSRect(x: textX, y: nameY, width: 200, height: 18)
        } else {
            // Single line: vertically centered with circle
            let nameY = circleY + (circleSize - 18) / 2
            nameLabel.frame = NSRect(x: textX, y: nameY, width: 200, height: 18)
        }
        containerView.addSubview(nameLabel)
        
        // Battery label with icon (if available)
        if let battery = battery {
            let batteryText = "\(battery)%"
            let batteryLabel = NSTextField(labelWithString: batteryText)
            batteryLabel.font = NSFont.systemFont(ofSize: 11)
            batteryLabel.textColor = .secondaryLabelColor
            batteryLabel.sizeToFit()
            
            // Position battery text in lower half of circle area
            let batteryLabelHeight: CGFloat = 14
            let batteryY = circleY + (circleSize / 2 - batteryLabelHeight) / 2
            batteryLabel.frame = NSRect(x: textX, y: batteryY, width: batteryLabel.frame.width, height: batteryLabelHeight)
            containerView.addSubview(batteryLabel)
            
            // Battery icon - vertically centered with battery text
            let batteryIconSize: CGFloat = 14
            let batteryIconY = batteryY + (batteryLabelHeight - batteryIconSize) / 2
            let batteryIconView = NSImageView(frame: NSRect(x: textX + batteryLabel.frame.width + 2, y: batteryIconY, width: 20, height: batteryIconSize))
            batteryIconView.imageAlignment = .alignCenter
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
        // Match macOS battery icon behavior - icon reflects actual level
        switch level {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
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
    
    private func updateMenuItemsVisibility(isConnected: Bool) {
        guard let menu = statusItem?.menu else { return }
        
        // Don't aggressively close RFCOMM channel here - let it be managed elsewhere
        // The channel should only be closed when we actually detect a real disconnection
        
        // Update menu bar icon based on connection state
        if let button = statusItem?.button {
            let iconName = isConnected ? "headphones.over.ear" : "headphones.slash"
            let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
        }
        
        // Hide/show NC section
        menu.item(withTag: MenuTag.noiseCancellationHeader.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.ncOff.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.ncLow.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.ncHigh.rawValue)?.isHidden = !isConnected
        
        // Hide/show Self Voice section
        menu.item(withTag: MenuTag.selfVoiceHeader.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.svOff.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.svLow.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.svMedium.rawValue)?.isHidden = !isConnected
        menu.item(withTag: MenuTag.svHigh.rawValue)?.isHidden = !isConnected
        
        // Hide/show Advanced Settings submenu
        menu.item(withTag: MenuTag.settingsSubmenu.rawValue)?.isHidden = !isConnected
        
        // Hide/show Paired Devices header and items
        menu.item(withTag: MenuTag.pairedDevices.rawValue)?.isHidden = !isConnected
        for item in menu.items where item.tag >= 700 && item.tag < 800 {
            item.isHidden = !isConnected
        }
        
        // Hide separators when disconnected (find by index since separators don't have tags)
        // We need to hide the separators between sections
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                // Keep only the separator before Quit visible when disconnected
                let isLastSeparator = index == menu.items.count - 2
                item.isHidden = !isConnected && !isLastSeparator
            }
        }
    }
    
    private func updateInfoSubmenu(firmware: String?, codec: String?, vendorId: String?, productId: String?, services: String?, serial: String?) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let submenu = settingsItem.submenu else { return }
        
        submenu.item(withTag: 401)?.title = "Firmware: \(firmware ?? "Unknown")"
        submenu.item(withTag: 402)?.title = "Audio Codec: \(codec ?? "Unknown")"
        
        let deviceIdText = "\(vendorId ?? "Unknown") / \(productId ?? "Unknown")"
        submenu.item(withTag: 403)?.title = "Device ID: \(deviceIdText)"
        submenu.item(withTag: 404)?.title = "Services: \(services ?? "Unknown")"
        submenu.item(withTag: 405)?.title = "Serial Number: \(serial ?? "Unknown")"
    }
    
    private func updatePairedDevicesMenu(_ devices: [PairedDeviceInfo], totalCount: Int, connectedCount: Int) {
        guard let menu = statusItem?.menu,
              let pairedHeaderItem = menu.item(withTag: MenuTag.pairedDevices.rawValue) else { return }
        
        // Store devices for menu action handlers
        pairedDevicesList = devices
        
        // Find the index of the paired devices header
        guard let headerIndex = menu.items.firstIndex(of: pairedHeaderItem) else { return }
        
        // Remove existing paired device items (tags 700+)
        let itemsToRemove = menu.items.filter { $0.tag >= 700 && $0.tag < 800 }
        for item in itemsToRemove {
            menu.removeItem(item)
        }
        
        // Insert new device items after the header
        var insertIndex = headerIndex + 1
        
        for (index, device) in devices.enumerated() {
            let deviceItem = NSMenuItem(title: device.name, action: #selector(pairedDeviceClicked(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.tag = 700 + index
            deviceItem.isEnabled = true
            deviceItem.indentationLevel = 1
            
            // Show checkmark for connected devices
            if device.isConnected {
                deviceItem.state = .on
            }
            
            // Add icon based on device type (detected from MAC address OUI and name)
            let deviceType = DeviceTypeResolver.resolve(name: device.name, address: device.address)
            if let image = NSImage(systemSymbolName: deviceType.iconName, accessibilityDescription: device.name) {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                deviceItem.image = image.withSymbolConfiguration(config)
            }
            
            menu.insertItem(deviceItem, at: insertIndex)
            insertIndex += 1
        }
    }
    
    @objc private func pairedDeviceClicked(_ sender: NSMenuItem) {
        let index = sender.tag - 700
        guard index >= 0 && index < pairedDevicesList.count else { return }
        
        let device = pairedDevicesList[index]
        
        if device.isConnected {
            // Disconnect the device
            disconnectPairedDevice(address: device.address)
        } else {
            // Connect the device
            connectPairedDevice(address: device.address)
        }
    }
    
    private func connectPairedDevice(address: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Convert address string to bytes
            guard let addressBytes = self.addressStringToBytes(address) else {
                print("Invalid address format: \(address)")
                return
            }
            
            // Build CONNECT_DEVICE command: [0x04, 0x01, 0x05, 0x07, 0x00, <6 bytes address>]
            var command: [UInt8] = [0x04, 0x01, 0x05, 0x07, 0x00]
            command.append(contentsOf: addressBytes)
            
            print("Sending connect command to Bose for device: \(address)")
            let response = self.sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x01], timeout: 2.0)
            
            if response.count >= 4 && response[0] == 0x04 && response[1] == 0x01 && response[2] == 0x07 {
                print("Connect command acknowledged for device: \(address)")
            } else {
                print("Connect command response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            
            // Always refresh after a delay to let the headphones update their state
            Thread.sleep(forTimeInterval: 1.5)
            self.fetchPairedDevices()
        }
    }
    
    private func disconnectPairedDevice(address: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Convert address string to bytes
            guard let addressBytes = self.addressStringToBytes(address) else {
                print("Invalid address format: \(address)")
                return
            }
            
            // Build DISCONNECT_DEVICE command: [0x04, 0x02, 0x05, 0x06, <6 bytes address>]
            var command: [UInt8] = [0x04, 0x02, 0x05, 0x06]
            command.append(contentsOf: addressBytes)
            
            print("Sending disconnect command to Bose for device: \(address)")
            let response = self.sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x02], timeout: 2.0)
            
            if response.count >= 4 && response[0] == 0x04 && response[1] == 0x02 && response[2] == 0x07 {
                print("Disconnect command acknowledged for device: \(address)")
            } else {
                print("Disconnect command response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            
            // Always refresh after a delay to let the headphones update their state
            Thread.sleep(forTimeInterval: 1.0)
            self.fetchPairedDevices()
        }
    }
    
    private func addressStringToBytes(_ address: String) -> [UInt8]? {
        // Remove separators and convert to uppercase
        let cleanAddress = address.replacingOccurrences(of: ":", with: "")
                                  .replacingOccurrences(of: "-", with: "")
                                  .uppercased()
        
        guard cleanAddress.count == 12 else { return nil }
        
        var bytes: [UInt8] = []
        var index = cleanAddress.startIndex
        
        for _ in 0..<6 {
            let nextIndex = cleanAddress.index(index, offsetBy: 2)
            let byteString = String(cleanAddress[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        
        return bytes
    }
    
    // MARK: - Device Discovery
    
    private func checkForBoseDevices() {
        print("Checking for Bose devices...")
        
        // Fast path: Check IOBluetooth paired devices first (much faster than system_profiler)
        if let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in pairedDevices {
                if let name = device.name, name.lowercased().contains("bose"), device.isConnected() {
                    print("Fast path: Found connected Bose device: \(name)")
                    
                    // Update menu immediately with basic info
                    let info = HeadphoneInfo(
                        name: name,
                        batteryLevel: nil,
                        isConnected: true,
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
                    
                    self.deviceAddress = device.addressString
                    
                    DispatchQueue.main.async {
                        self.updateMenuWithHeadphoneInfo(info)
                    }
                    
                    // Start fetching detailed data via RFCOMM
                    self.detectNoiseCancellationStatusAsync()
                    return
                }
            }
        }
        
        // Slow path fallback: Use system_profiler for more detailed info
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
                
                // Show full menu immediately since we're connected
                DispatchQueue.main.async {
                    self.updateMenuItemsVisibility(isConnected: true)
                }
                
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
        
        // Store the current Bose device for notifications
        currentBoseDevice = device
        
        // Set up device-specific disconnect notifications
        setupDeviceSpecificNotifications(for: device)
        
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
        let _ = responseSemaphore  // Keep reference until after wait
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
        let _ = responseSemaphore  // Keep reference until after wait
        responseSemaphore = nil
        
        responseLock.lock()
        let result_buffer = responseBuffer
        expectedResponsePrefix = []
        responseLock.unlock()
        
        return result_buffer
    }
    
    // MARK: - Fetch All Device Info
    
    private func fetchAllDeviceInfo() {
        // Only fetch fresh data if cache is stale or we don't have cached data
        if shouldFetchFreshData() {
            fetchBatteryLevel()
            fetchSerialNumber()
            fetchDeviceStatus()
            fetchAutoOffStatus()
            fetchButtonActionStatus()
            markDataAsFetched()
            
            // Fetch paired devices last (it's slower due to per-device status queries)
            fetchPairedDevices()
        } else {
            // Use cached data - just update the menu with what we have
            DispatchQueue.main.async {
                self.initializeMenuWithCachedValues()
            }
        }
    }
    
    private func fetchBatteryLevel() {
        let command: [UInt8] = [0x02, 0x02, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x02, 0x02])
        
        if response.count >= 5 && response[0] == 0x02 && response[1] == 0x02 && response[2] == 0x03 {
            let level = Int(response[4])
            cachedBatteryLevel = level // Cache the battery level
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
                    cachedSerialNumber = serial // Cache the serial number
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
        let _ = responseSemaphore  // Keep reference until after wait
        responseSemaphore = nil
        
        responseLock.lock()
        expectedResponsePrefix = []
        responseLock.unlock()
        
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
                    // Cache the language and voice prompts settings
                    cachedLanguage = lang
                    cachedVoicePromptsEnabled = voicePromptsOn
                    
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
    
    // Device connection status from GET_DEVICE_INFO
    private enum DeviceStatus: UInt8 {
        case disconnected = 0x00
        case connected = 0x01
        case thisDevice = 0x03
    }
    
    // Query individual device status using GET_DEVICE_INFO command
    private func getDeviceStatus(address: String) -> DeviceStatus {
        guard let addressBytes = addressStringToBytes(address) else {
            return .disconnected
        }
        
        // GET_DEVICE_INFO: [0x04, 0x05, 0x01, 0x06, <6 bytes address>]
        var command: [UInt8] = [0x04, 0x05, 0x01, 0x06]
        command.append(contentsOf: addressBytes)
        
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x05, 0x03], timeout: 1.0)
        
        // Response: [0x04, 0x05, 0x03, length, <6 bytes address>, status_byte, ...]
        if response.count >= 11 && response[0] == 0x04 && response[1] == 0x05 && response[2] == 0x03 {
            let statusByte = response[10]  // After header(4) + address(6)
            print("Device \(address) status byte: 0x\(String(format: "%02X", statusByte))")
            return DeviceStatus(rawValue: statusByte) ?? .disconnected
        }
        
        return .disconnected
    }
    
    // Number of connected devices
    private enum DevicesConnected: UInt8 {
        case one = 0x01
        case two = 0x03
    }
    
    private func fetchPairedDevices() {
        let command: [UInt8] = [0x04, 0x04, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x04])
        
        print("Paired devices response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        if response.count >= 5 && response[0] == 0x04 && response[1] == 0x04 && response[2] == 0x03 {
            let numDevicesBytes = Int(response[3])
            let numDevicesTotal = numDevicesBytes / 6
            
            print("Total paired devices: \(numDevicesTotal)")
            
            var addresses: [(address: String, bytes: [UInt8])] = []
            var offset = 5  // Skip header bytes
            
            // First pass: collect all addresses quickly
            for _ in 0..<numDevicesTotal {
                if offset + 6 <= response.count {
                    let addressBytes = Array(response[offset..<(offset + 6)])
                    let address = addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                    addresses.append((address: address, bytes: addressBytes))
                    offset += 6
                }
            }
            
            // Query each device's status (this is the slow part)
            var devices: [PairedDeviceInfo] = []
            for (address, _) in addresses {
                let status = getDeviceStatus(address: address)
                let isConnected = (status == .connected || status == .thisDevice)
                let isCurrentDevice = (status == .thisDevice)
                
                var deviceName: String
                if isCurrentDevice {
                    deviceName = Host.current().localizedName ?? getDeviceNameForAddress(address) ?? address
                } else {
                    deviceName = getDeviceNameForAddress(address) ?? address
                }
                
                print("Device: \(address) - \(deviceName) - status: \(status)")
                
                let deviceInfo = PairedDeviceInfo(
                    address: address,
                    name: deviceName,
                    isConnected: isConnected,
                    isCurrentDevice: isCurrentDevice
                )
                devices.append(deviceInfo)
            }
            
            DispatchQueue.main.async {
                let connectedCount = devices.filter { $0.isConnected }.count
                self.updatePairedDevicesMenu(devices, totalCount: numDevicesTotal, connectedCount: connectedCount)
            }
        }
    }
    
    private func fetchAutoOffStatus() {
        let command: [UInt8] = [0x01, 0x04, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x01, 0x04])
        
        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x04 && response[2] == 0x03 {
            let autoOffValue = response[4]
            DispatchQueue.main.async {
                self.updateAutoOffSelection(level: autoOffValue)
            }
        }
    }
    
    private func fetchButtonActionStatus() {
        let command: [UInt8] = [0x01, 0x09, 0x03, 0x04, 0x10, 0x04, 0x00, 0x07]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x01, 0x09])
        
        print("Button Action Response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: ", "))")
        
        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x09 && response[2] == 0x03 {
            let buttonActionValue = response[4]
            print("Button Action Value: 0x\(String(format: "%02X", buttonActionValue))")
            DispatchQueue.main.async {
                self.updateButtonActionSelection(level: buttonActionValue)
            }
        } else {
            print("Button Action Response validation failed - count: \(response.count)")
        }
    }
    
    private func getAutoOff() -> AutoOff {
        let command: [UInt8] = [0x01, 0x04, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x01, 0x04])
        
        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x04 && response[2] == 0x03 {
            return AutoOff(rawValue: response[4]) ?? .unknown
        }
        return .unknown
    }
    
    private func setAutoOffValue(_ minutes: AutoOff) -> Bool {
        let command: [UInt8] = [0x01, 0x04, 0x02, 0x01, minutes.rawValue]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x01, 0x04])
        
        if response.count >= 4 && response[0] == 0x01 && response[1] == 0x04 {
            // Verify the setting by reading it back
            let gotMinutes = getAutoOff()
            return gotMinutes == minutes
        }
        return false
    }
    
    private func updateAutoOffSelection(level: UInt8) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu,
              let autoOffItem = settingsSubmenu.items.first,
              let autoOffSubmenu = autoOffItem.submenu else { return }
        
        currentAutoOffLevel = level
        
        // Clear all checkmarks
        for item in autoOffSubmenu.items {
            item.state = .off
        }
        
        // Set the appropriate checkmark
        let targetTag = Int(level) + 600
        autoOffSubmenu.item(withTag: targetTag)?.state = .on
    }
    
    private func updateButtonActionSelection(level: UInt8) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu else { return }
        
        currentButtonAction = level
        
        // Find the Button Action menu item by title
        guard let buttonActionItem = settingsSubmenu.items.first(where: { $0.title == "Button Action" }),
              let buttonActionSubmenu = buttonActionItem.submenu else { return }
        
        // Clear all checkmarks
        for item in buttonActionSubmenu.items {
            item.state = .off
        }
        
        // Set the appropriate checkmark
        switch level {
        case 0x01:
            buttonActionSubmenu.item(withTag: 801)?.state = .on // Alexa
        case 0x02:
            buttonActionSubmenu.item(withTag: 802)?.state = .on // Noise Cancellation
        default:
            break
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
            let semaphore = responseSemaphore
            responseLock.unlock()
            semaphore?.signal()
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
        print("RFCOMM channel closed")
        self.rfcommChannel = nil
        
        // Only update menu if we currently show as connected
        // This prevents unnecessary updates during normal operation
        if currentHeadphoneInfo?.isConnected == true {
            DispatchQueue.main.async {
                self.updateMenuWithNoDevice()
            }
        }
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
        var inConnectedSection = false
        
        for (_, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Track whether we're in Connected or Not Connected section
            if trimmedLine == "Connected:" {
                inConnectedSection = true
                continue
            }
            if trimmedLine == "Not Connected:" {
                inConnectedSection = false
                continue
            }
            
            if trimmedLine.contains("Bose") && trimmedLine.hasSuffix(":") {
                currentDevice = String(trimmedLine.dropLast())
                isConnected = inConnectedSection
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
        
        // Cache the device info only when connected
        if info.isConnected {
            if let battery = info.batteryLevel {
                cachedBatteryLevel = battery
            }
            cachedFirmwareVersion = info.firmwareVersion
            cachedSerialNumber = info.serialNumber
            cachedAudioCodec = info.audioCodec
            cachedServices = info.services
        } else {
            // Clear cached values when disconnected to save memory and avoid stale data
            cachedBatteryLevel = nil
            cachedFirmwareVersion = nil
            cachedSerialNumber = nil
            cachedAudioCodec = nil
            cachedServices = nil
            cachedLanguage = nil
            cachedVoicePromptsEnabled = nil
            currentNCLevel = 0xFF
            currentSelfVoiceLevel = 0xFF
            currentAutoOffLevel = 0xFF
            currentButtonAction = 0xFF
            pairedDevicesList = []
            lastDataFetchTime = nil // Clear cache timestamp
        }
        
        // Update device header with name, battery, and connection status
        updateDeviceHeader(name: info.name, battery: info.batteryLevel, isConnected: info.isConnected)
        
        // Always show full menu immediately when connected - data will populate progressively
        updateMenuItemsVisibility(isConnected: info.isConnected)
        
        // Update status bar icon
        if let battery = info.batteryLevel {
            updateStatusBarIcon(batteryLevel: battery)
        } else {
            // Reset status bar icon color when no battery info
            statusItem?.button?.contentTintColor = nil
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
            if info.isConnected {
                let batteryInfo = info.batteryLevel.map { "\($0)%" } ?? "Unknown"
                button.toolTip = "\(info.name)\nBattery: \(batteryInfo)"
            } else {
                button.toolTip = "No Bose Device Connected"
            }
        }
    }
    
    private func updateMenuWithNoDevice() {
        let info = HeadphoneInfo(
            name: "No Bose device connected",
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
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let submenu = settingsItem.submenu else { return }
        submenu.item(withTag: 405)?.title = "Serial Number: \(serial)"
    }
    
    private func updateLanguageCheckmark(_ language: PromptLanguage) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu else { return }
        
        // Find the Language menu item by title
        guard let languageItem = settingsSubmenu.items.first(where: { $0.title == "Language" }),
              let languageSubmenu = languageItem.submenu else { return }
        
        for item in languageSubmenu.items {
            item.state = (item.tag == Int(language.rawValue)) ? .on : .off
        }
    }
    
    private func updateVoicePromptsCheckmark(_ on: Bool) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let settingsSubmenu = settingsItem.submenu else { return }
        
        // Find the Voice Prompts menu item by title
        guard let vpItem = settingsSubmenu.items.first(where: { $0.title == "Voice Prompts" }),
              let vpSubmenu = vpItem.submenu else { return }
        
        vpSubmenu.item(withTag: 501)?.state = on ? .on : .off
        vpSubmenu.item(withTag: 502)?.state = on ? .off : .on
    }

    
    // MARK: - Actions
    
    @objc private func refreshBattery() {
        checkForBoseDevices()
    }
    
    @objc private func connectToDevice() {
        guard let deviceAddr = deviceAddress else { return }
        attemptBluetoothConnection(address: deviceAddr)
    }
    
    private func attemptBluetoothConnection(address: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
                return
            }
            
            // Find the Bose device
            guard let device = pairedDevices.first(where: { device in
                if let deviceAddress = device.addressString {
                    let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                    let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                    return cleanDeviceAddr == cleanTargetAddr
                }
                if let name = device.name, name.contains("Bose") {
                    return true
                }
                return false
            }) else {
                return
            }
            
            // Attempt to connect
            if !device.isConnected() {
                let result = device.openConnection()
                if result == kIOReturnSuccess {
                    // Wait a moment for connection to establish
                    Thread.sleep(forTimeInterval: 1.0)
                    // Refresh device status
                    DispatchQueue.main.async {
                        self?.checkForBoseDevices()
                    }
                }
            }
        }
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
    
    @objc private func setAutoOff(_ sender: NSMenuItem) {
        let autoOffValue = UInt8(sender.tag - 600) // Remove the offset
        guard let autoOff = AutoOff(rawValue: autoOffValue) else { return }
        
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let success = self.setAutoOffValue(autoOff)
            DispatchQueue.main.async {
                if success {
                    self.updateAutoOffSelection(level: autoOffValue)
                } else {
                    // Revert to current setting if failed
                    self.updateAutoOffSelection(level: self.currentAutoOffLevel)
                }
            }
        }
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
    
    @objc private func setButtonActionAlexa() {
        setButtonAction(.alexa)
    }
    
    @objc private func setButtonActionNC() {
        setButtonAction(.noiseCancellation)
    }
    
    private func setButtonAction(_ action: ButtonAction) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x09, 0x02, 0x03, 0x10, 0x04, action.rawValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.updateButtonActionSelection(level: action.rawValue)
                }
            }
        }
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
    
    @objc private func showAbout() {
        print("showAbout method called")
        
        let alert = NSAlert()
        alert.messageText = "SoundSherpa"
        alert.informativeText = "Smart controls for non-Apple headphones\n\nSoundSherpa brings the Control Center experience to all headphones, not just Apple ones. Manage noise cancellation, battery, connections, and device switching from your menu bar. No more guessing. No more digging through menus.\n\nVersion 1.0"
        alert.alertStyle = .informational
        
        // Add buttons - first button added is the default (rightmost, blue)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Visit Website")
        
        // Bring app to front and show alert in a window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Run modal - the first button added is automatically the default (blue) button
        let response = alert.runModal()
        
        // Return to accessory app mode
        NSApp.setActivationPolicy(.accessory)
        
        // Handle button responses
        if response == .alertSecondButtonReturn { // Visit Website button
            if let url = URL(string: "https://soundsherpa.app") {
                NSWorkspace.shared.open(url)
            }
        }
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
            let _ = self.responseSemaphore  // Keep reference until after wait
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
