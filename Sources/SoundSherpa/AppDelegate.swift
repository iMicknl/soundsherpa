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

    // The DeviceChannel actor serializes all command I/O over the open RFCOMM channel so a
    // reply can never land in the wrong command's buffer (R7.1). Recreated on each open,
    // torn down on close. Incoming delegate bytes are forwarded to `deviceChannel.ingest`.
    private var deviceChannel: DeviceChannel?

    // The brand registry resolves which DevicePlugin speaks a connected device's protocol,
    // from its advertised name alone. Battery and static-metadata reads route through the
    // resolved plugin, so supporting a new brand (Sony, …) is registering one more plugin in
    // DeviceRegistry.standard — no change here. `activePlugin` is the plugin for the device
    // we're currently talking to, resolved on connect.
    private let deviceRegistry = DeviceRegistry.standard
    private var activePlugin: DevicePlugin?

    // All RFCOMM connect/teardown runs on this single serial queue so only one connection
    // attempt touches the channel state (rfcommChannel/deviceChannel/isChannelReady/
    // activePlugin) at a time. Previously each path hopped onto a fresh DispatchQueue.global
    // thread, so the 30s scan timer, the 10s NC timer, and menu setters could drive two
    // concurrent connects that raced over the device's single control channel — a latent
    // contributor to the "detected but shows nothing" instability. It stays a GCD worker
    // (not @MainActor): the blocking open/SDP query must run off the main thread, and the
    // execution context is otherwise identical so IOBluetooth delegate delivery is unchanged.
    private let connectionQueue = DispatchQueue(label: "nl.imick.soundsherpa.connection")

    // Incoming RFCOMM bytes are pushed here from the delegate callback (synchronously, so
    // arrival order is preserved) and drained by a single consumer task into the actor's
    // `ingest`. This keeps ordered delivery without spawning an unordered Task per chunk.
    private var ingestContinuation: AsyncStream<[UInt8]>.Continuation?
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

    // Persisted, address-keyed static metadata (firmware/serial/model/VID/PID/services).
    // Survives relaunch so the Info submenu shows last-known-good values instantly on
    // connect, even before a healthy RFCOMM channel is established.
    private let metadataStore = DeviceMetadataStore(persistence: FileMetadataPersistence())
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
        setupSleepWakeNotifications()
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        // Synchronous teardown: the process exits right after this returns, so an async
        // closeChannel() hop onto connectionQueue might never run, orphaning the device's
        // single control channel (the very failure we guard against). Run it inline on the
        // queue and wait, so the channel is actually released before we terminate.
        connectionQueue.sync { closeChannelLocked() }
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

    /// Observe system sleep/wake. On sleep we close our RFCOMM channel so we don't leave the
    /// Bose device's single control channel orphaned half-open (which would block reconnection
    /// after wake). On wake we re-scan and reconnect.
    private func setupSleepWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        print("System will sleep — closing RFCOMM channel to avoid orphaning it")
        closeChannel()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        print("System did wake — re-scanning for Bose device")
        // Cached connection state may be stale after sleep; force a fresh fetch.
        lastDataFetchTime = nil
        checkForBoseDevices()
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

            // Release our RFCOMM channel so we don't hold the device's single control
            // channel half-open — otherwise the next connect is refused.
            closeChannel()

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
        
        // Show persisted static metadata (firmware/serial/model/VID/PID/services).
        if let address = deviceAddress {
            applyCachedMetadata(for: address)
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
        
        // Audio codec is negotiated at the A2DP layer, not exposed by the Bose control
        // protocol, and has no reliable macOS API. Hidden until/unless we have a real
        // source for it (R5.8: no fabricated "Unknown" rows).
        let codecItem = NSMenuItem(title: "Audio Codec: Unknown", action: nil, keyEquivalent: "")
        codecItem.isEnabled = false
        codecItem.tag = 402
        codecItem.isHidden = true
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
        // Render each row from real data, hiding it entirely when we have nothing rather
        // than printing a fabricated "Unknown" (per the reliability spec, R5.8).
        updateInfoRow(tag: 401, label: "Firmware", value: firmware)
        updateInfoRow(tag: 402, label: "Audio Codec", value: codec)
        let deviceIdText: String?
        if vendorId != nil || productId != nil {
            deviceIdText = "\(vendorId ?? "?") / \(productId ?? "?")"
        } else {
            deviceIdText = nil
        }
        updateInfoRow(tag: 403, label: "Device ID", value: deviceIdText)
        updateInfoRow(tag: 404, label: "Services", value: services)
        updateInfoRow(tag: 405, label: "Serial Number", value: serial)
    }

    /// Sets an Info-submenu row's title, or hides it when `value` is nil/empty so the menu
    /// never shows an "Unknown" placeholder for data we don't have.
    private func updateInfoRow(tag: Int, label: String, value: String?) {
        guard let menu = statusItem?.menu,
              let settingsItem = menu.item(withTag: MenuTag.settingsSubmenu.rawValue),
              let submenu = settingsItem.submenu,
              let item = submenu.item(withTag: tag) else { return }

        if let value = value, !value.isEmpty {
            item.title = "\(label): \(value)"
            item.isHidden = false
        } else {
            item.isHidden = true
        }
    }

    /// Merge freshly-read static metadata into the persisted, address-keyed store so it
    /// survives relaunch and shows instantly on the next connect.
    private func storeMetadata(_ metadata: DeviceMetadata) {
        guard let address = deviceAddress else { return }
        metadataStore.put(metadata, for: address)
    }

    /// Populate the Info submenu from persisted metadata for the given address. Called on
    /// connect before any RFCOMM I/O, so last-known-good values appear immediately.
    private func applyCachedMetadata(for address: String) {
        guard let meta = metadataStore.metadata(for: address) else { return }
        if let firmware = meta.firmware { cachedFirmwareVersion = firmware }
        if let serial = meta.serial { cachedSerialNumber = serial }

        let deviceId: String?
        if meta.vendorId != nil || meta.productId != nil {
            deviceId = "\(meta.vendorId ?? "?") / \(meta.productId ?? "?")"
        } else if let modelId = meta.modelId {
            deviceId = String(format: "Bose 0x%04X", modelId)
        } else {
            deviceId = nil
        }

        updateInfoRow(tag: 401, label: "Firmware", value: meta.firmware)
        updateInfoRow(tag: 403, label: "Device ID", value: deviceId)
        updateInfoRow(tag: 404, label: "Services", value: meta.services?.joined(separator: ", "))
        updateInfoRow(tag: 405, label: "Serial Number", value: meta.serial)
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
        Task { [weak self] in
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
            let response = await self.send(command, expecting: [0x04, 0x01], timeout: 2.0)

            if response.count >= 4 && response[0] == 0x04 && response[1] == 0x01 && response[2] == 0x07 {
                print("Connect command acknowledged for device: \(address)")
            } else {
                print("Connect command response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }

            // Always refresh after a delay to let the headphones update their state
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.fetchPairedDevices()
        }
    }

    private func disconnectPairedDevice(address: String) {
        Task { [weak self] in
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
            let response = await self.send(command, expecting: [0x04, 0x02], timeout: 2.0)

            if response.count >= 4 && response[0] == 0x04 && response[1] == 0x02 && response[2] == 0x07 {
                print("Disconnect command acknowledged for device: \(address)")
            } else {
                print("Disconnect command response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }

            // Always refresh after a delay to let the headphones update their state
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self.fetchPairedDevices()
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

                    // Resolve which brand plugin speaks this device's protocol, by name. All
                    // command I/O below routes through it, so a new brand is a new plugin.
                    self.activePlugin = self.deviceRegistry.plugin(forDeviceNamed: name)

                    // Read host-side Bluetooth facts (VID/PID, services) that the Bose
                    // control protocol can't provide, straight from the SDP records.
                    let sdpMeta = self.sdpMetadata(for: device)
                    if !sdpMeta.isEmpty, let address = device.addressString {
                        self.metadataStore.put(sdpMeta, for: address)
                    }

                    DispatchQueue.main.async {
                        self.updateMenuWithHeadphoneInfo(info)
                        // Show last-known-good static metadata instantly, before RFCOMM I/O.
                        if let address = device.addressString {
                            self.applyCachedMetadata(for: address)
                        }
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
        
        // The blocking IOBluetooth open + SDP query must run off the main thread so the
        // delegate callbacks are delivered (the documented root cause of the "shows nothing"
        // bug). Run it on the serial connectionQueue so concurrent scans/timers can't drive
        // two connects at once. The command I/O afterward is serialized by the DeviceChannel
        // actor and can run in a Task.
        connectionQueue.async { [weak self] in
            guard let self = self else { return }

            print(">>> Starting connection to device: \(deviceAddr)")

            guard self.connectToBoseDeviceSync(address: deviceAddr) else {
                print(">>> Connection failed")
                return
            }
            print(">>> Connection successful, initializing Bose protocol...")

            // Show full menu immediately since we're connected
            DispatchQueue.main.async {
                self.updateMenuItemsVisibility(isConnected: true)
            }

            Task { [weak self] in
                guard let self = self else { return }
                _ = await self.initBoseConnection()
                print(">>> Fetching device info...")
                await self.fetchAllDeviceInfo()
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

        // Resolve the brand plugin from the device name if the fast path didn't already
        // (e.g. when we arrived here via the system_profiler slow path). All command I/O
        // routes through it.
        if activePlugin == nil, let name = device.name {
            activePlugin = deviceRegistry.plugin(forDeviceNamed: name)
        }

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
    
    /// Extracts the host-side Bluetooth facts the Bose control protocol can't provide —
    /// the advertised services list and the true Vendor/Product ID — from the device's
    /// SDP records. Returns an empty `DeviceMetadata` when the records aren't available
    /// (e.g. before an SDP query has completed); callers merge non-empty results only.
    private func sdpMetadata(for device: IOBluetoothDevice) -> DeviceMetadata {
        guard let records = device.services as? [IOBluetoothSDPServiceRecord] else {
            return DeviceMetadata()
        }

        // Service names, de-duplicated, in a stable order.
        var seen = Set<String>()
        let serviceNames: [String] = records.compactMap { record in
            guard let name = record.getServiceName(), !name.isEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }

        // Device ID Profile: service class UUID 0x1200, VendorID = attr 0x0201,
        // ProductID = attr 0x0202 (both 16-bit unsigned integers).
        var vendorId: String?
        var productId: String?
        if let dipRecord = records.first(where: { $0.matchesUUID16(0x1200) }) {
            vendorId = sdpUInt16Hex(dipRecord, attributeID: 0x0201)
            productId = sdpUInt16Hex(dipRecord, attributeID: 0x0202)
        }

        return DeviceMetadata(
            vendorId: vendorId,
            productId: productId,
            services: serviceNames.isEmpty ? nil : serviceNames
        )
    }

    /// Reads a 16-bit unsigned SDP attribute and formats it as `0xXXXX`, or nil if absent.
    private func sdpUInt16Hex(_ record: IOBluetoothSDPServiceRecord, attributeID: BluetoothSDPServiceAttributeID) -> String? {
        guard let element = record.getAttributeDataElement(attributeID),
              element.getTypeDescriptor() == kBluetoothSDPDataElementTypeUnsignedInt,
              let number = element.getNumberValue() else { return nil }
        return String(format: "0x%04X", number.uint16Value)
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

        // Close-before-open: the Bose control service permits exactly one RFCOMM connection.
        // If we hold a stale (non-open or leftover) channel, close it before opening a new one,
        // otherwise the device refuses the connection and the menu shows no data. We're on
        // connectionQueue here, so close inline (not via the async closeChannel hop).
        closeChannelLocked()
        isChannelReady = false

        // First attempt. If it fails, the device may still consider a prior channel open
        // (e.g. orphaned by a crash/sleep); wait briefly and retry once.
        if openChannel(device: device, channelId: channelId) {
            return true
        }

        print("Channel open failed; waiting and retrying once in case of a stale device-side channel")
        Thread.sleep(forTimeInterval: 1.0)
        if openChannel(device: device, channelId: channelId) {
            return true
        }

        return false
    }

    /// Open the RFCOMM channel using sync, then async, then a brute-force of known Bose channel
    /// IDs. Returns true and stores `rfcommChannel` on success.
    private func openChannel(device: IOBluetoothDevice, channelId: BluetoothRFCOMMChannelID) -> Bool {
        var channel: IOBluetoothRFCOMMChannel?
        var openResult = device.openRFCOMMChannelSync(&channel, withChannelID: channelId, delegate: self)

        if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
            attachChannel(ch)
            return true
        }

        channelOpenSemaphore = DispatchSemaphore(value: 0)
        let asyncResult = device.openRFCOMMChannelAsync(&channel, withChannelID: channelId, delegate: self)
        if asyncResult == kIOReturnSuccess {
            self.rfcommChannel = channel
            let waitResult = channelOpenSemaphore?.wait(timeout: .now() + 10.0)
            channelOpenSemaphore = nil
            if waitResult != .timedOut && isChannelReady && (rfcommChannel?.isOpen() ?? false),
               let ch = channel {
                attachChannel(ch)
                return true
            }
            // Async open did not complete cleanly — drop the half-open channel. Inline:
            // we're already on connectionQueue.
            closeChannelLocked()
        } else {
            channelOpenSemaphore = nil
        }

        let channelIdsToTry: [BluetoothRFCOMMChannelID] = [8, 9, 1, 2, 3]
        for tryChannelId in channelIdsToTry {
            if tryChannelId == channelId { continue }
            channel = nil
            openResult = device.openRFCOMMChannelSync(&channel, withChannelID: tryChannelId, delegate: self)
            if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
                attachChannel(ch)
                return true
            }
        }

        return false
    }

    /// Record a freshly-opened channel and wrap it in a DeviceChannel actor so all command
    /// I/O is serialized. The actor is the single owner of the response buffer.
    private func attachChannel(_ channel: IOBluetoothRFCOMMChannel) {
        self.rfcommChannel = channel
        self.isChannelReady = true
        let actor = DeviceChannel(transport: IOBluetoothRFCOMMTransport(channel: channel))
        self.deviceChannel = actor

        // Drain delegate bytes into the actor, in order, from a single consumer task.
        let stream = AsyncStream<[UInt8]> { continuation in
            self.ingestContinuation = continuation
        }
        Task {
            for await chunk in stream {
                await actor.ingest(chunk)
            }
        }
    }

    /// External teardown entry point (quit, sleep, disconnect). Hops onto the serial
    /// connectionQueue so a close can't race an in-flight connect over the channel state —
    /// it always runs strictly before or after a connect, never interleaved.
    private func closeChannel() {
        connectionQueue.async { [weak self] in
            self?.closeChannelLocked()
        }
    }

    /// Close and release the RFCOMM channel if we hold one. Safe to call when there is none.
    /// Centralizes teardown so every exit path (quit, sleep, disconnect, failed open) frees
    /// the single Bose control channel instead of orphaning it.
    ///
    /// MUST run on `connectionQueue`: callers are either external paths via `closeChannel()`
    /// or the connect flow itself (close-before-open / failed-open cleanup), which already
    /// runs on that queue.
    private func closeChannelLocked() {
        if let channel = deviceChannel {
            Task { await channel.close() }   // fails any in-flight command with .channelClosed
        }
        deviceChannel = nil
        activePlugin = nil
        ingestContinuation?.finish()
        ingestContinuation = nil
        if let channel = rfcommChannel {
            if channel.isOpen() {
                _ = channel.close()
            }
            rfcommChannel = nil
        }
        isChannelReady = false
    }
    
    // MARK: - Actor-backed command I/O

    /// Send a command and await the single reply identified by `prefix`. Returns the reply
    /// bytes, or an empty array on timeout / closed channel (preserving the legacy
    /// "empty == failed" contract the callers already check). All access is serialized by
    /// the DeviceChannel actor.
    private func send(_ command: [UInt8], expecting prefix: [UInt8], timeout: TimeInterval = 0.5) async -> [UInt8] {
        guard let channel = deviceChannel else { return [] }
        do {
            return try await channel.send(command, matcher: .prefix(prefix), timeout: timeout)
        } catch {
            return []
        }
    }

    /// Send a command and collect every reply sharing `prefix` until `window` elapses. Used
    /// for the status query, which provokes several distinct broadcast messages.
    private func collect(_ command: [UInt8], prefix: [UInt8], window: TimeInterval) async -> [UInt8] {
        guard let channel = deviceChannel else { return [] }
        do {
            return try await channel.send(command, matcher: .collecting(prefix: prefix), timeout: window)
        } catch {
            return []
        }
    }

    private func initBoseConnection() async -> Bool {
        guard let channel = rfcommChannel, channel.isOpen() else {
            return false
        }

        // The init handshake reply carries the firmware version (function 0x01). We used to
        // discard it; capture it via the pure codec so the Info submenu can show it.
        let response = await send([0x00, 0x01, 0x01, 0x00], expecting: [0x00, 0x01], timeout: 5.0)
        if let firmware = BoseCodec.decodeFirmware(response) {
            cachedFirmwareVersion = firmware
            storeMetadata(DeviceMetadata(firmware: firmware))
            DispatchQueue.main.async {
                self.updateInfoRow(tag: 401, label: "Firmware", value: firmware)
            }
        }
        return true
    }


    // MARK: - Command Helpers (legacy synchronous path — being retired)

    // MARK: - Fetch All Device Info

    private func fetchAllDeviceInfo() async {
        // Only fetch fresh data if cache is stale or we don't have cached data
        if shouldFetchFreshData() {
            await fetchBatteryLevel()
            await fetchSerialNumber()
            await fetchDeviceStatus()
            await fetchAutoOffStatus()
            await fetchButtonActionStatus()
            markDataAsFetched()

            // Fetch paired devices last (it's slower due to per-device status queries)
            await fetchPairedDevices()
        } else {
            // Use cached data - just update the menu with what we have
            DispatchQueue.main.async {
                self.initializeMenuWithCachedValues()
            }
        }
    }
    
    private func fetchBatteryLevel() async {
        // Route through the resolved brand plugin over the serialized channel. The plugin
        // owns the brand-specific encode/decode; this layer just stores and displays.
        guard let plugin = activePlugin, let channel = deviceChannel else { return }

        if let level = await plugin.readBatteryLevel(over: channel) {
            cachedBatteryLevel = level // Cache the battery level
            DispatchQueue.main.async {
                self.updateBatteryInMenu(level)
            }
        }
    }

    private func fetchSerialNumber() async {
        let response = await send(BoseCodec.encodeSerialQuery(), expecting: [0x00, 0x07])

        if let serial = BoseCodec.decodeSerial(response) {
            cachedSerialNumber = serial // Cache the serial number
            storeMetadata(DeviceMetadata(serial: serial))
            DispatchQueue.main.async {
                self.updateSerialInMenu(serial)
            }
        }
    }

    private func fetchDeviceStatus() async {
        let deviceIdResponse = await send(BoseCodec.encodeDeviceIdQuery(), expecting: [0x00, 0x03])
        if let modelId = BoseCodec.decodeModelId(deviceIdResponse) {
            storeMetadata(DeviceMetadata(modelId: modelId))
            DispatchQueue.main.async {
                self.updateInfoRow(tag: 403, label: "Device ID",
                                   value: String(format: "Bose 0x%04X", modelId))
            }
        }

        // The status query provokes several broadcast messages (language, NC, self-voice);
        // collect everything starting with 0x01 over a short window, then parse.
        let statusResponse = await collect([0x01, 0x01, 0x05, 0x00], prefix: [0x01], window: 1.0)
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
    private func getDeviceStatus(address: String) async -> DeviceStatus {
        guard let addressBytes = addressStringToBytes(address) else {
            return .disconnected
        }

        // GET_DEVICE_INFO: [0x04, 0x05, 0x01, 0x06, <6 bytes address>]
        var command: [UInt8] = [0x04, 0x05, 0x01, 0x06]
        command.append(contentsOf: addressBytes)

        let response = await send(command, expecting: [0x04, 0x05, 0x03], timeout: 1.0)
        
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
    
    private func fetchPairedDevices() async {
        let command: [UInt8] = [0x04, 0x04, 0x01, 0x00]
        let response = await send(command, expecting: [0x04, 0x04])
        
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
                let status = await getDeviceStatus(address: address)
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
    
    private func fetchAutoOffStatus() async {
        let command: [UInt8] = [0x01, 0x04, 0x01, 0x00]
        let response = await send(command, expecting: [0x01, 0x04])

        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x04 && response[2] == 0x03 {
            let autoOffValue = response[4]
            DispatchQueue.main.async {
                self.updateAutoOffSelection(level: autoOffValue)
            }
        }
    }

    private func fetchButtonActionStatus() async {
        // Operator 0x01 = GET (length 0x00). The earlier packet used operator 0x03,
        // which is the device's STATUS reply shape, not a request — so first-boot
        // queries got no response and the menu showed no selection. The device
        // replies with the 0x03 ACK that the parsing below reads.
        let command: [UInt8] = [0x01, 0x09, 0x01, 0x00]
        let response = await send(command, expecting: [0x01, 0x09])
        
        print("Button Action Response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: ", "))")
        
        // ACK layout: [0x01, 0x09, 0x03, 0x04, 0x10, 0x04, mode, 0x07]
        // The configured mode is at byte 6; byte 4 is the button-ID (0x10), not the value.
        if response.count >= 8 && response[0] == 0x01 && response[1] == 0x09 && response[2] == 0x03
            && response[4] == 0x10 && response[5] == 0x04 {
            let buttonActionValue = response[6]
            print("Button Action Value: 0x\(String(format: "%02X", buttonActionValue))")
            DispatchQueue.main.async {
                self.updateButtonActionSelection(level: buttonActionValue)
            }
        } else {
            print("Button Action Response validation failed - count: \(response.count)")
        }
    }
    
    private func getAutoOff() async -> AutoOff {
        let command: [UInt8] = [0x01, 0x04, 0x01, 0x00]
        let response = await send(command, expecting: [0x01, 0x04])

        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x04 && response[2] == 0x03 {
            return AutoOff(rawValue: response[4]) ?? .unknown
        }
        return .unknown
    }

    private func setAutoOffValue(_ minutes: AutoOff) async -> Bool {
        let command: [UInt8] = [0x01, 0x04, 0x02, 0x01, minutes.rawValue]
        let response = await send(command, expecting: [0x01, 0x04])

        if response.count >= 4 && response[0] == 0x01 && response[1] == 0x04 {
            // Verify the setting by reading it back
            let gotMinutes = await getAutoOff()
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

        // Forward to the DeviceChannel actor (in arrival order) to satisfy the in-flight
        // command. The actor decides whether this chunk matches via its ResponseMatcher.
        ingestContinuation?.yield(responseData)

        // Independently, react to unsolicited NC status broadcasts so the menu reflects
        // changes made with the physical button even when no command is in flight.
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
                        audioCodec: nil,
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
                audioCodec: nil,
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

            // Persist any static metadata this update carried (e.g. from the slow
            // system_profiler path) so it survives relaunch like the SPP-sourced values.
            let infoMeta = DeviceMetadata(
                firmware: info.firmwareVersion,
                serial: info.serialNumber,
                vendorId: info.vendorId,
                productId: info.productId,
                services: info.services.map { [$0] }
            )
            if !infoMeta.isEmpty { storeMetadata(infoMeta) }
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
        connectionQueue.async { [weak self] in
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
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x06, 0x02, 0x01, level], expecting: [0x01, 0x06])
            DispatchQueue.main.async { self.updateNCSelection(level: level) }
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
        
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            let success = await self.setAutoOffValue(autoOff)
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
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38], expecting: [0x01, 0x0b])
            DispatchQueue.main.async { self.updateSelfVoiceSelection(level: level.rawValue) }
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        let languageValue = UInt8(sender.tag)

        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x03, 0x02, 0x01, languageValue], expecting: [0x01, 0x03])
            DispatchQueue.main.async {
                if let lang = PromptLanguage(rawValue: languageValue) {
                    self.updateLanguageCheckmark(lang)
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
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x09, 0x02, 0x03, 0x10, 0x04, action.rawValue], expecting: [0x01, 0x09])
            DispatchQueue.main.async { self.updateButtonActionSelection(level: action.rawValue) }
        }
    }

    private func setVoicePrompts(on: Bool) {
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }

            var languageValue = self.currentLanguageValue & 0x7F
            if on {
                languageValue |= 0x80
            }

            _ = await self.send([0x01, 0x03, 0x02, 0x01, languageValue], expecting: [0x01, 0x03])
            DispatchQueue.main.async { self.updateVoicePromptsCheckmark(on) }
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

    /// Ensure an open channel exists, (re)connecting if needed. Returns whether a channel
    /// is available afterward. The blocking IOBluetooth open/SDP query runs on a GCD
    /// background thread (not the Swift cooperative pool) because it depends on that
    /// thread's run loop to receive the open/SDP delegate callbacks.
    private func ensureConnected() async -> Bool {
        if let channel = rfcommChannel, channel.isOpen() { return true }
        guard let deviceAddr = deviceAddress else { return false }

        return await withCheckedContinuation { continuation in
            connectionQueue.async { [weak self] in
                let result = self?.connectToBoseDeviceSync(address: deviceAddr) ?? false
                continuation.resume(returning: result)
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
