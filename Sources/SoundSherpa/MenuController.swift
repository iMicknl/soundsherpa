import Cocoa
import Foundation

/// Delegate protocol for MenuController events
public protocol MenuControllerDelegate: AnyObject {
    /// Called when a capability value is changed by the user
    func menuController(_ controller: MenuController, didChangeValue value: Any, for capability: DeviceCapability)
    
    /// Called when user requests to connect to a device
    func menuControllerDidRequestConnect(_ controller: MenuController)
    
    /// Called when user requests to disconnect
    func menuControllerDidRequestDisconnect(_ controller: MenuController)
    
    /// Called when user selects a paired device
    func menuController(_ controller: MenuController, didSelectPairedDevice deviceId: String)
}

/// Menu item tags for capability-based menu items
private enum MenuTag: Int {
    case deviceHeader = 100
    case batteryInfo = 101
    case errorIndicator = 102
    case capabilityBase = 1000  // Capabilities start at 1000+
    case pairedDevicesBase = 2000  // Paired devices start at 2000+
    case settingsSubmenu = 500
    case aboutItem = 600
    case quitItem = 700
}

/// Controls the menu bar UI with device-specific capability handling
public class MenuController {
    private let statusItem: NSStatusItem
    private weak var delegate: MenuControllerDelegate?
    
    /// Current device capabilities
    private var currentCapabilities: DeviceCapabilitySet = DeviceCapabilitySet()
    
    /// Current device name
    private var currentDeviceName: String?
    
    /// Current battery level
    private var currentBatteryLevel: Int?
    
    /// Current error message (if any)
    private var currentError: String?
    
    /// Whether Bluetooth is enabled
    private var isBluetoothEnabled: Bool = true
    
    /// Whether a device is connected
    private var isDeviceConnected: Bool = false
    
    /// Current capability values
    private var capabilityValues: [DeviceCapability: Any] = [:]
    
    /// Paired devices list
    private var pairedDevices: [PairedDevice] = []
    
    public init(delegate: MenuControllerDelegate? = nil) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.delegate = delegate
        setupStatusItem()
        setupMenu()
    }
    
    // MARK: - Setup
    
    private func setupStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "SoundSherpa"
        }
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // Device header (always present)
        let deviceItem = createDeviceHeaderItem(name: "No Device Connected", battery: nil, isConnected: false)
        deviceItem.tag = MenuTag.deviceHeader.rawValue
        menu.addItem(deviceItem)
        
        // Battery info (hidden when no device)
        let batteryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryItem.tag = MenuTag.batteryInfo.rawValue
        batteryItem.isEnabled = false
        batteryItem.isHidden = true
        menu.addItem(batteryItem)
        
        // Error indicator (hidden by default)
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.tag = MenuTag.errorIndicator.rawValue
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // About item
        let aboutItem = NSMenuItem(title: "About SoundSherpa", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.tag = MenuTag.aboutItem.rawValue
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.tag = MenuTag.quitItem.rawValue
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    // MARK: - Public Methods
    
    /// Rebuild menu for current device capabilities
    public func rebuildMenu(for capabilities: DeviceCapabilitySet, deviceName: String) {
        self.currentCapabilities = capabilities
        self.currentDeviceName = deviceName
        self.isDeviceConnected = true
        
        guard let menu = statusItem.menu else { return }
        
        // Remove all capability items (keep header, about, quit)
        removeCapabilityItems(from: menu)
        
        // Find insertion point (after battery info)
        var insertIndex = 3  // After device header, battery, error indicator
        
        // Add main menu capabilities
        let mainConfigs = capabilities.mainMenuConfigs.sorted { $0.capability.rawValue < $1.capability.rawValue }
        for config in mainConfigs {
            if config.capability == .pairedDevices {
                // Paired devices handled separately
                continue
            }
            
            let items = createCapabilityMenuItems(for: config)
            for item in items {
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
            
            // Add separator after each capability section
            let separator = NSMenuItem.separator()
            menu.insertItem(separator, at: insertIndex)
            insertIndex += 1
        }
        
        // Add paired devices section if supported
        if capabilities.isSupported(.pairedDevices) {
            let pairedHeader = createSectionHeader(title: "Paired Devices")
            menu.insertItem(pairedHeader, at: insertIndex)
            insertIndex += 1
            
            // Paired device items will be added dynamically
            let separator = NSMenuItem.separator()
            menu.insertItem(separator, at: insertIndex)
            insertIndex += 1
        }
        
        // Add settings submenu for non-main capabilities
        let submenuConfigs = capabilities.submenuConfigs
        if !submenuConfigs.isEmpty {
            let settingsItem = createSettingsSubmenu(for: submenuConfigs)
            menu.insertItem(settingsItem, at: insertIndex)
            insertIndex += 1
            
            let separator = NSMenuItem.separator()
            menu.insertItem(separator, at: insertIndex)
        }
        
        // Update device header
        updateDeviceHeader(name: deviceName, battery: currentBatteryLevel, isConnected: true)
    }
    
    /// Update battery display
    public func updateBattery(level: Int) {
        currentBatteryLevel = level
        updateDeviceHeader(name: currentDeviceName ?? "Unknown Device", battery: level, isConnected: isDeviceConnected)
        updateStatusBarIcon(batteryLevel: level)
    }
    
    /// Update a capability value with device-specific handling
    public func updateCapabilityValue(_ value: Any, for capability: DeviceCapability, config: DeviceCapabilityConfig) {
        capabilityValues[capability] = value
        
        guard let menu = statusItem.menu else { return }
        
        // Find and update the menu items for this capability
        updateCapabilityMenuItems(in: menu, for: capability, value: value, config: config)
    }
    
    /// Update paired devices list
    public func updatePairedDevices(_ devices: [PairedDevice]) {
        self.pairedDevices = devices
        
        guard let menu = statusItem.menu else { return }
        
        // Remove existing paired device items
        removePairedDeviceItems(from: menu)
        
        // Find the paired devices header
        guard let headerIndex = findPairedDevicesHeaderIndex(in: menu) else { return }
        
        // Insert new paired device items
        var insertIndex = headerIndex + 1
        for device in devices {
            let item = createPairedDeviceMenuItem(device)
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
        }
    }
    
    /// Show disconnected state
    public func showDisconnected() {
        isDeviceConnected = false
        currentDeviceName = nil
        currentBatteryLevel = nil
        currentCapabilities = DeviceCapabilitySet()
        capabilityValues.removeAll()
        pairedDevices.removeAll()
        
        guard let menu = statusItem.menu else { return }
        
        // Remove all capability items
        removeCapabilityItems(from: menu)
        
        // Update header
        updateDeviceHeader(name: "No Device Connected", battery: nil, isConnected: false)
        
        // Reset status bar icon
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
        }
    }
    
    /// Show error state with brief error indicator
    /// **Validates: Requirements 9.1**
    public func showError(_ message: String) {
        currentError = message
        
        guard let menu = statusItem.menu,
              let errorItem = menu.item(withTag: MenuTag.errorIndicator.rawValue) else { return }
        
        errorItem.title = "⚠️ \(message)"
        errorItem.isHidden = false
        
        // Auto-hide error after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.hideError()
        }
    }
    
    /// Show error from a DeviceError with appropriate formatting
    /// **Validates: Requirements 9.1**
    public func showError(_ error: DeviceError) {
        // Log the error
        ErrorLogger.shared.log(error, context: "MenuController")
        
        // Only show errors that should be displayed to users
        guard error.shouldShowToUser else { return }
        
        // Use the user-friendly message
        showError(error.userMessage)
    }
    
    /// Hide error indicator
    public func hideError() {
        currentError = nil
        
        guard let menu = statusItem.menu,
              let errorItem = menu.item(withTag: MenuTag.errorIndicator.rawValue) else { return }
        
        errorItem.isHidden = true
    }
    
    /// Check if an error is currently being displayed
    public var isShowingError: Bool {
        return currentError != nil
    }
    
    /// Get the current error message if any
    public var currentErrorMessage: String? {
        return currentError
    }
    
    /// Show "Bluetooth Disabled" state
    /// **Validates: Requirements 9.2**
    public func showBluetoothDisabled() {
        isBluetoothEnabled = false
        showDisconnected()
        
        guard let menu = statusItem.menu,
              let deviceItem = menu.item(withTag: MenuTag.deviceHeader.rawValue) else { return }
        
        deviceItem.title = "Bluetooth Disabled"
        
        // Update icon to show disabled state
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "headphones.slash", accessibilityDescription: "Bluetooth Disabled")
            image?.isTemplate = true
            button.image = image
        }
        
        // Log the state change
        ErrorLogger.shared.log(.bluetoothDisabled, context: "MenuController")
    }
    
    /// Show "Bluetooth Unavailable" state
    public func showBluetoothUnavailable() {
        isBluetoothEnabled = false
        showDisconnected()
        
        guard let menu = statusItem.menu,
              let deviceItem = menu.item(withTag: MenuTag.deviceHeader.rawValue) else { return }
        
        deviceItem.title = "Bluetooth Unavailable"
        
        // Update icon to show unavailable state
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Bluetooth Unavailable")
            image?.isTemplate = true
            button.image = image
        }
        
        // Log the state change
        ErrorLogger.shared.log(.bluetoothUnavailable, context: "MenuController")
    }
    
    /// Check if Bluetooth is currently enabled
    public var bluetoothEnabled: Bool {
        return isBluetoothEnabled
    }
    
    /// Update Bluetooth enabled state
    public func setBluetoothEnabled(_ enabled: Bool) {
        if enabled && !isBluetoothEnabled {
            isBluetoothEnabled = true
            // Bluetooth was re-enabled, show disconnected state
            showDisconnected()
        } else if !enabled && isBluetoothEnabled {
            showBluetoothDisabled()
        }
    }
    
    /// Show "Unsupported Device" state with basic connection status only
    public func showUnsupportedDevice(_ device: BluetoothDevice) {
        isDeviceConnected = true
        currentDeviceName = device.name
        currentCapabilities = DeviceCapabilitySet()
        
        guard let menu = statusItem.menu else { return }
        
        // Remove all capability items
        removeCapabilityItems(from: menu)
        
        // Update header to show unsupported device
        updateDeviceHeader(name: "\(device.name) (Unsupported)", battery: nil, isConnected: true)
    }
    
    // MARK: - Private Methods - Menu Item Creation
    
    private func createDeviceHeaderItem(name: String, battery: Int?, isConnected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = !isConnected
        
        if !isConnected {
            item.title = "     \(name)"
            item.action = #selector(connectToDevice)
            item.target = self
            
            // Create grey circle with headphone icon
            let imageSize = NSSize(width: 32, height: 32)
            let compositeImage = NSImage(size: imageSize, flipped: false) { rect in
                NSColor.systemGray.setFill()
                let circlePath = NSBezierPath(ovalIn: rect)
                circlePath.fill()
                
                if let headphoneImage = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones") {
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
        } else {
            // Connected state - show device name with battery if available
            var title = name
            if let battery = battery {
                title += " - \(battery)%"
            }
            item.title = "     \(title)"
            
            // Create blue circle with headphone icon
            let imageSize = NSSize(width: 32, height: 32)
            let compositeImage = NSImage(size: imageSize, flipped: false) { rect in
                NSColor.systemBlue.setFill()
                let circlePath = NSBezierPath(ovalIn: rect)
                circlePath.fill()
                
                if let headphoneImage = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones") {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let configuredImage = headphoneImage.withSymbolConfiguration(config) {
                        NSColor.white.set()
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
        }
        
        return item
    }
    
    private func createSectionHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: attributes)
        
        return item
    }
    
    private func createCapabilityMenuItems(for config: DeviceCapabilityConfig) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        
        // Add section header
        let header = createSectionHeader(title: config.displayName)
        items.append(header)
        
        // Create control items based on value type
        switch config.valueType {
        case .discrete(let values):
            for (index, value) in values.enumerated() {
                let item = createDiscreteMenuItem(
                    title: value.capitalized,
                    value: value,
                    capability: config.capability,
                    index: index
                )
                items.append(item)
            }
            
        case .continuous(let min, let max, let step):
            // For continuous values, create a slider item or discrete steps
            let stepCount = (max - min) / step
            if stepCount <= 5 {
                // Few steps - show as discrete items
                for i in stride(from: min, through: max, by: step) {
                    let item = createDiscreteMenuItem(
                        title: "\(i)",
                        value: String(i),
                        capability: config.capability,
                        index: i
                    )
                    items.append(item)
                }
            } else {
                // Many steps - show as slider (simplified as text for now)
                let item = NSMenuItem(title: "Level: \(min)-\(max)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                items.append(item)
            }
            
        case .boolean:
            let onItem = createDiscreteMenuItem(title: "On", value: "true", capability: config.capability, index: 1)
            let offItem = createDiscreteMenuItem(title: "Off", value: "false", capability: config.capability, index: 0)
            items.append(onItem)
            items.append(offItem)
            
        case .text:
            // Text capabilities are typically handled differently (e.g., language selection)
            let item = NSMenuItem(title: "Configure...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }
        
        return items
    }
    
    private func createDiscreteMenuItem(title: String, value: String, capability: DeviceCapability, index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "    \(title)", action: #selector(capabilityValueSelected(_:)), keyEquivalent: "")
        item.target = self
        item.tag = MenuTag.capabilityBase.rawValue + capability.hashValue + index
        item.representedObject = CapabilityMenuItemData(capability: capability, value: value)
        
        // Add icon based on capability
        if let iconName = iconForCapabilityValue(capability: capability, value: value) {
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
        }
        
        return item
    }
    
    private func createPairedDeviceMenuItem(_ device: PairedDevice) -> NSMenuItem {
        let title = device.isConnected ? "● \(device.name)" : "  \(device.name)"
        let item = NSMenuItem(title: title, action: #selector(pairedDeviceSelected(_:)), keyEquivalent: "")
        item.target = self
        item.tag = MenuTag.pairedDevicesBase.rawValue + device.id.hashValue
        item.representedObject = device.id
        
        // Add device type icon
        let iconName = iconForDeviceType(device.deviceType)
        item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: device.name)
        
        return item
    }
    
    private func createSettingsSubmenu(for configs: [DeviceCapabilityConfig]) -> NSMenuItem {
        let settingsItem = NSMenuItem(title: "Advanced Settings", action: nil, keyEquivalent: "")
        settingsItem.tag = MenuTag.settingsSubmenu.rawValue
        
        let submenu = NSMenu()
        
        for config in configs.sorted(by: { $0.capability.rawValue < $1.capability.rawValue }) {
            let items = createCapabilityMenuItems(for: config)
            for item in items {
                submenu.addItem(item)
            }
            submenu.addItem(NSMenuItem.separator())
        }
        
        settingsItem.submenu = submenu
        return settingsItem
    }
    
    // MARK: - Private Methods - Menu Updates
    
    private func updateDeviceHeader(name: String, battery: Int?, isConnected: Bool) {
        guard let menu = statusItem.menu,
              let oldItem = menu.item(withTag: MenuTag.deviceHeader.rawValue),
              let index = menu.items.firstIndex(of: oldItem) else { return }
        
        let newItem = createDeviceHeaderItem(name: name, battery: battery, isConnected: isConnected)
        newItem.tag = MenuTag.deviceHeader.rawValue
        
        menu.removeItem(oldItem)
        menu.insertItem(newItem, at: index)
    }
    
    private func updateStatusBarIcon(batteryLevel: Int) {
        guard let button = statusItem.button else { return }
        
        let iconName: String
        switch batteryLevel {
        case 0..<20:
            iconName = "battery.0"
        case 20..<40:
            iconName = "battery.25"
        case 40..<60:
            iconName = "battery.50"
        case 60..<80:
            iconName = "battery.75"
        default:
            iconName = "battery.100"
        }
        
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Battery \(batteryLevel)%")
        image?.isTemplate = true
        button.image = image
    }
    
    private func updateCapabilityMenuItems(in menu: NSMenu, for capability: DeviceCapability, value: Any, config: DeviceCapabilityConfig) {
        // Find all items for this capability and update checkmarks
        for item in menu.items {
            if let data = item.representedObject as? CapabilityMenuItemData,
               data.capability == capability {
                let isSelected = isValueSelected(data.value, currentValue: value, valueType: config.valueType)
                item.state = isSelected ? .on : .off
            }
            
            // Also check submenu items
            if let submenu = item.submenu {
                updateCapabilityMenuItems(in: submenu, for: capability, value: value, config: config)
            }
        }
    }
    
    private func isValueSelected(_ itemValue: String, currentValue: Any, valueType: CapabilityValueType) -> Bool {
        switch valueType {
        case .discrete:
            if let stringValue = currentValue as? String {
                return itemValue.lowercased() == stringValue.lowercased()
            }
            return false
        case .continuous:
            if let intValue = currentValue as? Int {
                return itemValue == String(intValue)
            }
            return false
        case .boolean:
            if let boolValue = currentValue as? Bool {
                return itemValue == String(boolValue)
            }
            return false
        case .text:
            if let stringValue = currentValue as? String {
                return itemValue == stringValue
            }
            return false
        }
    }
    
    // MARK: - Private Methods - Menu Item Removal
    
    private func removeCapabilityItems(from menu: NSMenu) {
        // Keep only essential items: device header, battery, error, about, quit, and separators around them
        let tagsToKeep: Set<Int> = [
            MenuTag.deviceHeader.rawValue,
            MenuTag.batteryInfo.rawValue,
            MenuTag.errorIndicator.rawValue,
            MenuTag.aboutItem.rawValue,
            MenuTag.quitItem.rawValue
        ]
        
        var itemsToRemove: [NSMenuItem] = []
        var foundAbout = false
        
        for item in menu.items {
            if tagsToKeep.contains(item.tag) {
                if item.tag == MenuTag.aboutItem.rawValue {
                    foundAbout = true
                }
                continue
            }
            
            // Keep separators around about/quit
            if item.isSeparatorItem && foundAbout {
                continue
            }
            
            // Keep the separator right after error indicator
            if item.isSeparatorItem && itemsToRemove.isEmpty {
                continue
            }
            
            itemsToRemove.append(item)
        }
        
        for item in itemsToRemove {
            menu.removeItem(item)
        }
    }
    
    private func removePairedDeviceItems(from menu: NSMenu) {
        let itemsToRemove = menu.items.filter { $0.tag >= MenuTag.pairedDevicesBase.rawValue && $0.tag < MenuTag.pairedDevicesBase.rawValue + 10000 }
        for item in itemsToRemove {
            menu.removeItem(item)
        }
    }
    
    private func findPairedDevicesHeaderIndex(in menu: NSMenu) -> Int? {
        for (index, item) in menu.items.enumerated() {
            if item.attributedTitle?.string.lowercased().contains("paired") == true {
                return index
            }
        }
        return nil
    }
    
    // MARK: - Private Methods - Icons
    
    private func iconForCapabilityValue(capability: DeviceCapability, value: String) -> String? {
        switch capability {
        case .noiseCancellation:
            switch value.lowercased() {
            case "off": return "speaker.wave.1"
            case "low": return "speaker.wave.2"
            case "medium": return "speaker.wave.2.fill"
            case "high": return "speaker.wave.3"
            case "adaptive": return "waveform"
            default: return "speaker.wave.2"
            }
        case .selfVoice:
            switch value.lowercased() {
            case "off": return "person"
            case "low": return "person.wave.2"
            case "medium": return "person.wave.2.fill"
            case "high": return "person.fill"
            default: return "person.wave.2"
            }
        case .ambientSound:
            return "ear"
        default:
            return nil
        }
    }
    
    private func iconForDeviceType(_ type: PairedDeviceType) -> String {
        switch type {
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
    
    // MARK: - Actions
    
    @objc private func connectToDevice() {
        delegate?.menuControllerDidRequestConnect(self)
    }
    
    @objc private func capabilityValueSelected(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? CapabilityMenuItemData else { return }
        delegate?.menuController(self, didChangeValue: data.value, for: data.capability)
    }
    
    @objc private func pairedDeviceSelected(_ sender: NSMenuItem) {
        guard let deviceId = sender.representedObject as? String else { return }
        delegate?.menuController(self, didSelectPairedDevice: deviceId)
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SoundSherpa"
        alert.informativeText = "A menu bar app for managing your Bluetooth headphones.\n\nVersion 1.0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        
        // Set the app icon in the About dialog
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            alert.icon = icon
        }
        
        alert.runModal()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Helper Types

/// Data stored in menu item's representedObject for capability items
private struct CapabilityMenuItemData {
    let capability: DeviceCapability
    let value: String
}
