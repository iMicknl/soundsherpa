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
    private var expectedResponsePrefix: [UInt8] = []  // Expected command prefix for response validation
    private let responseLock = NSLock()  // Lock for thread-safe buffer access
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        checkForBoseDevices()
        
        // Set up a timer to check for device updates every 30 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            self.checkForBoseDevices()
        }
        
        // Set up a more frequent timer for noise cancellation detection (every 10 seconds)
        ncUpdateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            if self.currentHeadphoneInfo?.isConnected == true {
                self.detectNoiseCancellationStatusAsync()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        ncUpdateTimer?.invalidate()
        
        // Close RFCOMM channel if open
        if let channel = rfcommChannel, channel.isOpen() {
            _ = channel.close()
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            // Simple SF Symbol configuration that fits well
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
        
        // Device info
        let deviceItem = NSMenuItem(title: "Searching for Bose Device...", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Battery level item
        let batteryItem = NSMenuItem(title: "Battery: Unknown", action: nil, keyEquivalent: "")
        batteryItem.isEnabled = false
        menu.addItem(batteryItem)
        
        // Firmware version
        let firmwareItem = NSMenuItem(title: "Firmware: Unknown", action: nil, keyEquivalent: "")
        firmwareItem.isEnabled = false
        menu.addItem(firmwareItem)
        
        // Noise cancellation status
        let ncItem = NSMenuItem(title: "Noise Cancellation: Unknown", action: nil, keyEquivalent: "")
        ncItem.isEnabled = false
        menu.addItem(ncItem)
        
        // Audio codec
        let codecItem = NSMenuItem(title: "Audio Codec: Unknown", action: nil, keyEquivalent: "")
        codecItem.isEnabled = false
        menu.addItem(codecItem)
        
        // Vendor/Product ID
        let deviceIdItem = NSMenuItem(title: "Device ID: Unknown", action: nil, keyEquivalent: "")
        deviceIdItem.isEnabled = false
        menu.addItem(deviceIdItem)
        
        // Services
        let servicesItem = NSMenuItem(title: "Services: Unknown", action: nil, keyEquivalent: "")
        servicesItem.isEnabled = false
        menu.addItem(servicesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Serial Number
        let serialItem = NSMenuItem(title: "Serial Number: Unknown", action: nil, keyEquivalent: "")
        serialItem.isEnabled = false
        menu.addItem(serialItem)
        
        // Language
        let languageItem = NSMenuItem(title: "Language: Unknown", action: nil, keyEquivalent: "")
        languageItem.isEnabled = false
        menu.addItem(languageItem)
        
        // Voice Prompts
        let voicePromptsItem = NSMenuItem(title: "Voice Prompts: Unknown", action: nil, keyEquivalent: "")
        voicePromptsItem.isEnabled = false
        menu.addItem(voicePromptsItem)
        
        // Self Voice
        let selfVoiceItem = NSMenuItem(title: "Self Voice: Unknown", action: nil, keyEquivalent: "")
        selfVoiceItem.isEnabled = false
        menu.addItem(selfVoiceItem)
        
        // Paired Devices
        let pairedDevicesItem = NSMenuItem(title: "Paired Devices: Unknown", action: nil, keyEquivalent: "")
        pairedDevicesItem.isEnabled = false
        menu.addItem(pairedDevicesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Connection status
        let connectionItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        connectionItem.isEnabled = false
        menu.addItem(connectionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Noise Cancellation Control submenu
        let ncControlItem = NSMenuItem(title: "Set Noise Cancellation", action: nil, keyEquivalent: "")
        let ncSubmenu = NSMenu()
        ncSubmenu.autoenablesItems = false
        
        let ncOffItem = NSMenuItem(title: "Off", action: #selector(setNoiseCancellationOff), keyEquivalent: "")
        ncOffItem.target = self
        let ncLowItem = NSMenuItem(title: "Low", action: #selector(setNoiseCancellationLow), keyEquivalent: "")
        ncLowItem.target = self
        let ncHighItem = NSMenuItem(title: "High", action: #selector(setNoiseCancellationHigh), keyEquivalent: "")
        ncHighItem.target = self
        
        ncSubmenu.addItem(ncOffItem)
        ncSubmenu.addItem(ncLowItem)
        ncSubmenu.addItem(ncHighItem)
        ncControlItem.submenu = ncSubmenu
        menu.addItem(ncControlItem)
        
        // Language Control submenu
        let languageControlItem = NSMenuItem(title: "Set Language", action: nil, keyEquivalent: "")
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
        languageControlItem.submenu = languageSubmenu
        menu.addItem(languageControlItem)
        
        // Voice Prompts Toggle
        let voicePromptsControlItem = NSMenuItem(title: "Set Voice Prompts", action: nil, keyEquivalent: "")
        let voicePromptsSubmenu = NSMenu()
        voicePromptsSubmenu.autoenablesItems = false
        
        let vpOnItem = NSMenuItem(title: "On", action: #selector(setVoicePromptsOn), keyEquivalent: "")
        vpOnItem.target = self
        let vpOffItem = NSMenuItem(title: "Off", action: #selector(setVoicePromptsOff), keyEquivalent: "")
        vpOffItem.target = self
        
        voicePromptsSubmenu.addItem(vpOnItem)
        voicePromptsSubmenu.addItem(vpOffItem)
        voicePromptsControlItem.submenu = voicePromptsSubmenu
        menu.addItem(voicePromptsControlItem)
        
        // Self Voice Control submenu
        let selfVoiceControlItem = NSMenuItem(title: "Set Self Voice", action: nil, keyEquivalent: "")
        let selfVoiceSubmenu = NSMenu()
        selfVoiceSubmenu.autoenablesItems = false
        
        let svOffItem = NSMenuItem(title: "Off", action: #selector(setSelfVoiceOff), keyEquivalent: "")
        svOffItem.target = self
        let svLowItem = NSMenuItem(title: "Low", action: #selector(setSelfVoiceLow), keyEquivalent: "")
        svLowItem.target = self
        let svMediumItem = NSMenuItem(title: "Medium", action: #selector(setSelfVoiceMedium), keyEquivalent: "")
        svMediumItem.target = self
        let svHighItem = NSMenuItem(title: "High", action: #selector(setSelfVoiceHigh), keyEquivalent: "")
        svHighItem.target = self
        
        selfVoiceSubmenu.addItem(svOffItem)
        selfVoiceSubmenu.addItem(svLowItem)
        selfVoiceSubmenu.addItem(svMediumItem)
        selfVoiceSubmenu.addItem(svHighItem)
        selfVoiceControlItem.submenu = selfVoiceSubmenu
        menu.addItem(selfVoiceControlItem)
        
        // Disconnect Device
        let disconnectItem = NSMenuItem(title: "Disconnect Device", action: #selector(disconnectDevice), keyEquivalent: "")
        disconnectItem.target = self
        menu.addItem(disconnectItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Refresh item
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshBattery), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    private func checkForBoseDevices() {
        print("Checking for Bose devices...")
        
        // Run system_profiler in background to not block UI
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
                    }
                    
                    // Try to detect noise cancellation status in background
                    self?.detectNoiseCancellationStatusAsync()
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
        
        // Connect and fetch all device info in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print(">>> Starting connection to device: \(deviceAddr)")
            
            if self.connectToBoseDeviceSync(address: deviceAddr) {
                print(">>> Connection successful, initializing Bose protocol...")
                
                // Initialize connection with Bose protocol
                if self.initBoseConnection() {
                    print(">>> Init successful, fetching device info...")
                    // Fetch all device info
                    self.fetchAllDeviceInfo()
                } else {
                    print(">>> Init failed, trying to fetch without init...")
                    // Try fetching anyway - some devices might not need init
                    self.fetchAllDeviceInfo()
                }
            } else {
                print(">>> Connection failed")
                DispatchQueue.main.async {
                    self.updateNoiseCancellationStatus("Unknown")
                }
            }
        }
    }
    
    // Synchronous connection - must be called from background thread
    private func connectToBoseDeviceSync(address: String) -> Bool {
        // Find the device by address
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            print("No paired devices found")
            return false
        }
        
        print("Looking for device with address: \(address)")
        print("Available paired devices:")
        for device in pairedDevices {
            print("  - \(device.name ?? "Unknown"): \(device.addressString ?? "No address")")
        }
        
        // Find our Bose device - try multiple ways to match
        guard let device = pairedDevices.first(where: { device in
            // Try exact match first
            if let deviceAddress = device.addressString {
                if deviceAddress.uppercased() == address.uppercased() {
                    return true
                }
                // Try without colons
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                if cleanDeviceAddr.uppercased() == cleanTargetAddr.uppercased() {
                    return true
                }
            }
            
            // Also try matching by name if it contains "Bose"
            if let name = device.name, name.contains("Bose") {
                return true
            }
            
            return false
        }) else {
            print("Could not find Bose device in paired devices")
            return false
        }
        
        print("Found Bose device: \(device.name ?? "Unknown") at \(device.addressString ?? "Unknown")")
        print("Device isConnected: \(device.isConnected())")
        
        // If device is not connected, try to connect first
        if !device.isConnected() {
            print("Device not connected, attempting to connect...")
            let connectResult = device.openConnection()
            if connectResult != kIOReturnSuccess {
                print("Failed to open connection: \(krToString(connectResult))")
                // Continue anyway, might still work
            } else {
                print("Connection opened successfully")
                // Wait a bit for connection to stabilize
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        
        // Perform SDP query to get services
        let ret = device.performSDPQuery(self, uuids: [])
        if ret != kIOReturnSuccess {
            print("SDP Query unsuccessful: \(krToString(ret))")
            // Continue anyway, services might already be cached
        }
        
        // Find the SPP Dev service
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            print("No services found on device")
            return false
        }
        
        print("Found \(services.count) services on device")
        for service in services {
            if let serviceName = service.getServiceName() {
                print("  Service: \(serviceName)")
            }
        }
        
        guard let sppService = services.first(where: { service in
            return service.getServiceName() == "SPP Dev"
        }) else {
            print("Could not find SPP Dev service")
            // Try to find any SPP-like service
            if let anySerialService = services.first(where: { service in
                let name = service.getServiceName() ?? ""
                return name.lowercased().contains("spp") || name.lowercased().contains("serial")
            }) {
                print("Found alternative serial service: \(anySerialService.getServiceName() ?? "Unknown")")
                return connectToService(device: device, service: anySerialService)
            }
            return false
        }
        
        print("Found SPP Dev service")
        return connectToService(device: device, service: sppService)
    }
    
    private func connectToService(device: IOBluetoothDevice, service: IOBluetoothSDPServiceRecord) -> Bool {
        // Get RFCOMM channel ID
        var channelId: BluetoothRFCOMMChannelID = BluetoothRFCOMMChannelID()
        let channelResult = service.getRFCOMMChannelID(&channelId)
        if channelResult != kIOReturnSuccess {
            print("Failed to get RFCOMM channel ID: \(channelResult)")
            return false
        }
        
        print("Got RFCOMM channel ID: \(channelId)")
        
        // Check if we already have an open channel
        if let existingChannel = rfcommChannel, existingChannel.isOpen() {
            print("Reusing existing open RFCOMM channel")
            return true
        }
        
        // Reset state
        rfcommChannel = nil
        isChannelReady = false
        
        // Try opening the channel using the class method
        var channel: IOBluetoothRFCOMMChannel?
        
        // First try: use openRFCOMMChannelSync on device
        print("Attempting to open RFCOMM channel \(channelId) on device...")
        var openResult = device.openRFCOMMChannelSync(&channel, 
                                                     withChannelID: channelId, 
                                                     delegate: self)
        
        if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
            self.rfcommChannel = ch
            self.isChannelReady = true
            print("Successfully opened RFCOMM channel synchronously, isOpen: \(ch.isOpen())")
            return true
        }
        
        print("Sync open failed: \(krToString(openResult))")
        
        // Try async with semaphore first before trying other channels
        print("Trying async channel open on channel \(channelId)...")
        channelOpenSemaphore = DispatchSemaphore(value: 0)
        
        let asyncResult = device.openRFCOMMChannelAsync(&channel,
                                                       withChannelID: channelId,
                                                       delegate: self)
        if asyncResult == kIOReturnSuccess {
            self.rfcommChannel = channel
            
            // Wait for channel to open (max 10 seconds)
            let waitResult = channelOpenSemaphore?.wait(timeout: .now() + 10.0)
            channelOpenSemaphore = nil
            
            if waitResult != .timedOut && isChannelReady && (rfcommChannel?.isOpen() ?? false) {
                print("Async channel open succeeded")
                return true
            }
        } else {
            print("Async open failed: \(krToString(asyncResult))")
            channelOpenSemaphore = nil
        }
        
        // Second try: Try different channel IDs (8 and 9 are common for Bose)
        let channelIdsToTry: [BluetoothRFCOMMChannelID] = [8, 9, 1, 2, 3]
        for tryChannelId in channelIdsToTry {
            if tryChannelId == channelId { continue } // Already tried this one
            
            print("Trying alternative channel ID: \(tryChannelId)")
            channel = nil
            openResult = device.openRFCOMMChannelSync(&channel,
                                                     withChannelID: tryChannelId,
                                                     delegate: self)
            
            if openResult == kIOReturnSuccess, let ch = channel, ch.isOpen() {
                self.rfcommChannel = ch
                self.isChannelReady = true
                print("Successfully opened RFCOMM channel \(tryChannelId), isOpen: \(ch.isOpen())")
                return true
            }
            print("Channel \(tryChannelId) failed: \(krToString(openResult))")
        }
        
        print("All channel open attempts failed")
        print("Note: This may require Bluetooth permissions in System Preferences > Security & Privacy > Privacy > Bluetooth")
        return false
    }
    
    // MARK: - Bose Protocol Init
    
    private func initBoseConnection() -> Bool {
        guard let channel = rfcommChannel, channel.isOpen() else {
            print("Cannot init: channel not open")
            return false
        }
        
        // Send INIT_CONNECTION: [0x00, 0x01, 0x01, 0x00]
        // Expected ACK: [0x00, 0x01, 0x03, 0x05]
        let initCommand: [UInt8] = [0x00, 0x01, 0x01, 0x00]
        
        responseBuffer = []
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = initCommand
        var result: [UInt8] = []
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            print("Failed to send init command: \(krToString(writeResult))")
            responseSemaphore = nil
            return false
        }
        
        print(">>> Sent INIT command: \(initCommand.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Wait for response - give it more time
        let waitResult = responseSemaphore?.wait(timeout: .now() + 5.0)
        responseSemaphore = nil
        
        if waitResult == .timedOut {
            print(">>> Timeout waiting for init response")
            // Continue anyway - might still work
            return true
        }
        
        print(">>> Init response: \(responseBuffer.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Check ACK - be more lenient
        if responseBuffer.count >= 4 && responseBuffer[0] == 0x00 && responseBuffer[1] == 0x01 {
            print(">>> Init connection successful")
            return true
        }
        
        // Even if response doesn't match, continue
        print(">>> Init response unexpected, but continuing...")
        return true
    }
    
    // MARK: - Command Helpers
    
    /// Sends a command and waits for a response with the expected prefix
    /// - Parameters:
    ///   - command: The command bytes to send
    ///   - expectedPrefix: The first 2 bytes expected in the response (command echo)
    ///   - timeout: How long to wait for the response
    /// - Returns: The response buffer, or empty if failed/timeout
    private func sendCommandAndWait(command: [UInt8], expectedPrefix: [UInt8], timeout: TimeInterval = 2.0) -> [UInt8] {
        guard let channel = rfcommChannel, channel.isOpen() else { return [] }
        
        // Drain any pending data first by waiting briefly
        Thread.sleep(forTimeInterval: 0.05)
        
        // Set up for new command
        responseLock.lock()
        responseBuffer = []
        expectedResponsePrefix = expectedPrefix
        responseLock.unlock()
        
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = command
        var result: [UInt8] = []
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            print("Failed to send command: \(command.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
            responseSemaphore = nil
            responseLock.lock()
            expectedResponsePrefix = []
            responseLock.unlock()
            return []
        }
        
        print("Sent command: \(command.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
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
        // Get battery level
        fetchBatteryLevel()
        
        // Small delay between commands
        Thread.sleep(forTimeInterval: 0.1)
        
        // Get serial number
        fetchSerialNumber()
        
        Thread.sleep(forTimeInterval: 0.1)
        
        // Get device status (includes NC, language, etc.)
        fetchDeviceStatus()
        
        Thread.sleep(forTimeInterval: 0.1)
        
        // Get paired devices
        fetchPairedDevices()
    }
    
    private func fetchBatteryLevel() {
        // GET_BATTERY_LEVEL_SEND: [0x02, 0x02, 0x01, 0x00]
        // Expected response: [0x02, 0x02, 0x03, 0x01, level]
        let command: [UInt8] = [0x02, 0x02, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x02, 0x02])
        
        if response.count >= 5 && response[0] == 0x02 && response[1] == 0x02 && response[2] == 0x03 {
            let level = Int(response[4])
            print("Battery level: \(level)%")
            DispatchQueue.main.async {
                self.updateBatteryInMenu(level)
            }
        } else {
            print("Unexpected battery response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        }
    }
    
    private func fetchSerialNumber() {
        // GET_SERIAL_NUMBER_SEND: [0x00, 0x07, 0x01, 0x00]
        // Expected response: [0x00, 0x07, 0x03, length, ...serial...]
        let command: [UInt8] = [0x00, 0x07, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x00, 0x07])
        
        if response.count >= 4 && response[0] == 0x00 && response[1] == 0x07 && response[2] == 0x03 {
            let length = Int(response[3])
            if response.count >= 4 + length {
                let serialBytes = Array(response[4..<(4 + length)])
                if let serial = String(bytes: serialBytes, encoding: .utf8) {
                    print("Serial number: \(serial)")
                    DispatchQueue.main.async {
                        self.updateSerialInMenu(serial)
                    }
                }
            }
        } else {
            print("Unexpected serial response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        }
    }
    
    private func fetchDeviceStatus() {
        // First get device ID: [0x00, 0x03, 0x01, 0x00]
        let deviceIdCommand: [UInt8] = [0x00, 0x03, 0x01, 0x00]
        _ = sendCommandAndWait(command: deviceIdCommand, expectedPrefix: [0x00, 0x03])
        
        Thread.sleep(forTimeInterval: 0.1)
        
        // GET_DEVICE_STATUS_SEND: [0x01, 0x01, 0x05, 0x00]
        // This command returns multiple packets with different prefixes (0x01, 0x03), (0x01, 0x06), (0x01, 0x0b)
        // We need to collect all of them
        let statusCommand: [UInt8] = [0x01, 0x01, 0x05, 0x00]
        
        responseLock.lock()
        responseBuffer = []
        expectedResponsePrefix = [0x01]  // Accept any response starting with 0x01
        responseLock.unlock()
        
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = statusCommand
        var result: [UInt8] = []
        let writeResult = rfcommChannel?.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            print("Failed to send status command")
            responseSemaphore = nil
            responseLock.lock()
            expectedResponsePrefix = []
            responseLock.unlock()
            return
        }
        
        print("Sent device status command")
        
        // Wait for first response
        _ = responseSemaphore?.wait(timeout: .now() + 2.0)
        
        // Wait for additional responses (device status comes in multiple packets)
        for _ in 0..<5 {
            responseSemaphore = DispatchSemaphore(value: 0)
            let waitResult = responseSemaphore?.wait(timeout: .now() + 0.5)
            if waitResult == .timedOut {
                break
            }
        }
        responseSemaphore = nil
        
        responseLock.lock()
        let statusResponse = responseBuffer
        expectedResponsePrefix = []
        responseLock.unlock()
        
        print("Device status response: \(statusResponse.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Parse the response - it contains name, language, auto-off, NC level
        parseDeviceStatusResponse(statusResponse)
    }
    
    private func parseDeviceStatusResponse(_ response: [UInt8]) {
        // The device status response is complex and contains multiple parts
        // We need to parse: name, language (with voice prompts bit), auto-off, NC level, self voice
        
        // Skip initial ACK bytes [0x01, 0x01, 0x07, 0x00]
        // Look for language response: [0x01, 0x03, 0x03, 0x05, language, 0x00, ?, ?, 0xde]
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x03 && response[i+2] == 0x03 {
                let langByte = response[i+4]
                let voicePromptsOn = (langByte & 0x80) != 0
                let langValue = langByte & 0x7F
                
                currentLanguageValue = langByte
                
                if let lang = PromptLanguage(rawValue: langValue) {
                    DispatchQueue.main.async {
                        self.updateLanguageInMenu(lang.displayName)
                        self.updateVoicePromptsInMenu(voicePromptsOn)
                    }
                }
                break
            }
        }
        
        // Look for NC response: [0x01, 0x06, 0x03, 0x02, level, 0x0b]
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x06 && response[i+2] == 0x03 {
                let ncLevel = response[i+4]
                let statusText: String
                switch ncLevel {
                case 0x00: statusText = "Off"
                case 0x01: statusText = "High"
                case 0x03: statusText = "Low"
                default: statusText = "Level \(ncLevel)"
                }
                DispatchQueue.main.async {
                    self.updateMenuWithNCStatus(statusText)
                }
                break
            }
        }
        
        // Look for Self Voice response: [0x01, 0x0b, 0x03, 0x03, 0x01, level, 0x0f]
        for i in 0..<response.count {
            if i + 5 < response.count && response[i] == 0x01 && response[i+1] == 0x0b && response[i+2] == 0x03 {
                let selfVoiceLevel = response[i+5]
                let levelText: String
                switch selfVoiceLevel {
                case 0x00: levelText = "Off"
                case 0x01: levelText = "High"
                case 0x02: levelText = "Medium"
                case 0x03: levelText = "Low"
                default: levelText = "Level \(selfVoiceLevel)"
                }
                DispatchQueue.main.async {
                    self.updateSelfVoiceInMenu(levelText)
                }
                break
            }
        }
    }
    
    private func fetchPairedDevices() {
        // GET_PAIRED_DEVICES_SEND: [0x04, 0x04, 0x01, 0x00]
        // Expected response: [0x04, 0x04, 0x03, numDevices*6, numConnected, ...addresses...]
        let command: [UInt8] = [0x04, 0x04, 0x01, 0x00]
        let response = sendCommandAndWait(command: command, expectedPrefix: [0x04, 0x04])
        
        // Expected: [0x04, 0x04, 0x03, numDevices*6, numConnected, ...addresses...]
        // numConnected includes the current device
        // Device order: [current device, other connected devices..., paired but not connected devices...]
        if response.count >= 5 && response[0] == 0x04 && response[1] == 0x04 && response[2] == 0x03 {
            let numDevicesBytes = Int(response[3])
            let numDevices = numDevicesBytes / 6
            let numConnected = Int(response[4])
            
            print("===== PAIRED DEVICES DEBUG =====")
            print("Total paired devices: \(numDevices)")
            print("Number connected (including current): \(numConnected)")
            print("Raw response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
            print("================================")
            
            var devices: [String] = []
            var offset = 5
            
            // According to the protocol:
            // - First device is always the current device (this Mac)
            // - Next (numConnected - 1) devices are other connected devices
            // - Remaining devices are paired but not connected
            for i in 0..<numDevices {
                if offset + 6 <= response.count {
                    let addressBytes = Array(response[offset..<(offset + 6)])
                    let address = addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                    
                    // Try to get the device name
                    var deviceName: String?
                    
                    if i == 0 {
                        // First device is the current device (this Mac)
                        // Try to get the Mac's computer name
                        deviceName = Host.current().localizedName
                        if deviceName == nil {
                            deviceName = getDeviceNameForAddress(address)
                        }
                    } else {
                        // For other devices, look up from Bluetooth
                        deviceName = getDeviceNameForAddress(address)
                    }
                    
                    let indicator: String
                    if i == 0 {
                        // First device is the current device
                        indicator = "! "
                    } else if i < numConnected {
                        // Other connected devices (numConnected includes the current device, so we check i < numConnected)
                        indicator = "* "
                    } else {
                        // Paired but not connected
                        indicator = "  "
                    }
                    
                    // Format: "! Device Name (AA:BB:CC:DD:EE:FF)" or just address if name not found
                    if let name = deviceName {
                        devices.append("\(indicator)\(name) (\(address))")
                    } else {
                        devices.append("\(indicator)\(address)")
                    }
                    
                    offset += 6
                }
            }
            
            DispatchQueue.main.async {
                self.updatePairedDevicesInMenu(devices, totalCount: numDevices, connectedCount: numConnected)
                
                // Also update the currentHeadphoneInfo with paired devices info
                if let info = self.currentHeadphoneInfo {
                    let updatedInfo = HeadphoneInfo(
                        name: info.name,
                        batteryLevel: info.batteryLevel,
                        isConnected: info.isConnected,
                        firmwareVersion: info.firmwareVersion,
                        noiseCancellationEnabled: info.noiseCancellationEnabled,
                        audioCodec: info.audioCodec,
                        vendorId: info.vendorId,
                        productId: info.productId,
                        services: info.services,
                        serialNumber: info.serialNumber,
                        language: info.language,
                        voicePromptsEnabled: info.voicePromptsEnabled,
                        selfVoiceLevel: info.selfVoiceLevel,
                        pairedDevices: devices,
                        pairedDevicesCount: numDevices,
                        connectedDevicesCount: numConnected
                    )
                    self.currentHeadphoneInfo = updatedInfo
                }
            }
        } else {
            print("Unexpected paired devices response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        }
    }
    
    // Helper function to get device name from Bluetooth address
    private func getDeviceNameForAddress(_ address: String) -> String? {
        // Get all paired devices from macOS
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }
        
        // Try to find a device matching this address
        for device in pairedDevices {
            if let deviceAddress = device.addressString {
                // Compare addresses (case-insensitive, handle different formats)
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                
                if cleanDeviceAddr == cleanTargetAddr {
                    // Found matching device, return its name
                    return device.name
                }
            }
        }
        
        return nil
    }
    
    @objc func newRFCOMMChannelOpened(userNotification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        print(">>> New RFCOMM channel opened: \(channel.getID()), isOpen: \(channel.isOpen()), isIncoming: \(channel.isIncoming())")
        channel.setDelegate(self)
    }
    
    private func sendGetNoiseCancellationCommand() {
        guard let channel = rfcommChannel, channel.isOpen() else {
            print("RFCOMM channel is not open for NC query")
            return
        }
        
        // Bose protocol: Try to query NC status
        // The SET command is [0x01, 0x06, 0x02, 0x01, level]
        // The GET command might be [0x01, 0x06, 0x01, 0x01] or similar
        
        // Try format: [0x01, 0x06, 0x01, 0x01] - GET NC status
        var data: [UInt8] = [0x01, 0x06, 0x01, 0x01]
        var result: [UInt8] = []
        
        print(">>> Sending NC GET command: \(data.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            print("Failed to write NC query command: \(krToString(writeResult))")
        } else {
            print("NC query command sent successfully, waiting for response...")
        }
    }
    
    // RFCOMM Channel delegate methods
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        // Convert received data to byte array
        let bytes = dataPointer.assumingMemoryBound(to: UInt8.self)
        var responseData: [UInt8] = []
        for i in 0..<dataLength {
            responseData.append(bytes[i])
        }
        
        print(">>> RECEIVED \(dataLength) bytes: \(responseData.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Thread-safe buffer access
        responseLock.lock()
        
        // Check if this response matches what we're expecting
        let expectedPrefix = expectedResponsePrefix
        var isExpectedResponse = expectedPrefix.isEmpty
        
        if !isExpectedResponse && !responseData.isEmpty {
            if expectedPrefix.count == 1 {
                // Single byte prefix match (used for device status which has multiple response types)
                isExpectedResponse = responseData[0] == expectedPrefix[0]
            } else if expectedPrefix.count >= 2 && responseData.count >= 2 {
                // Two byte prefix match
                isExpectedResponse = responseData[0] == expectedPrefix[0] && responseData[1] == expectedPrefix[1]
            }
        }
        
        if isExpectedResponse {
            // Store response for synchronous commands
            responseBuffer.append(contentsOf: responseData)
            responseLock.unlock()
            responseSemaphore?.signal()
        } else {
            // Log unexpected response but don't add to buffer - it's likely a late response from a previous command
            print(">>> DISCARDING unexpected response (expected prefix: \(expectedPrefix.map { String(format: "0x%02X", $0) }.joined(separator: " ")))")
            responseLock.unlock()
        }
        
        // Parse the response for NC status (always process NC updates)
        // Bose response formats:
        // GET response: [0x01, 0x06, 0x04, 0x01, level] - 5 bytes
        // SET response: [0x01, 0x06, 0x03, 0x02, level, checksum] - 6 bytes
        // where level: 0x00 = Off, 0x01 = High, 0x03 = Low
        if responseData.count >= 5 && responseData[0] == 0x01 && responseData[1] == 0x06 {
            var ncLevel: UInt8
            
            if responseData[2] == 0x04 && responseData.count == 5 {
                // GET response format: level is at index 4
                ncLevel = responseData[4]
            } else if responseData[2] == 0x03 && responseData.count >= 5 {
                // SET response format: level is at index 4
                ncLevel = responseData[4]
            } else {
                // Fallback: try the last meaningful byte
                ncLevel = responseData[4]
            }
            
            let statusText: String
            switch ncLevel {
            case 0x00: statusText = "Off"
            case 0x01: statusText = "High"
            case 0x03: statusText = "Low"
            default: statusText = "Level \(ncLevel)"
            }
            print(">>> Parsed NC status: \(statusText)")
            DispatchQueue.main.async {
                self.updateMenuWithNCStatus(statusText)
            }
        }
    }
    
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            print(">>> RFCOMM channel opened successfully via delegate")
            isChannelReady = true
        } else {
            print(">>> RFCOMM channel open failed via delegate: \(krToString(error))")
            isChannelReady = false
        }
        channelOpenSemaphore?.signal()
    }
    
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        print("RFCOMM channel closed")
        self.rfcommChannel = nil
    }
    
    private func parseNoiseCancellationResponse(_ response: [UInt8]) -> String {
        guard response.count >= 5 else {
            return "Unknown (Invalid Response Length)"
        }
        
        print("Parsing NC response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        
        // Parse Bose NC response format
        // Expected format: [0x01, 0x06, 0x03, 0x01, status]
        if response[0] == 0x01 && response[1] == 0x06 && response[2] == 0x03 {
            let ncLevel = response[4]
            switch ncLevel {
            case 0x00:
                return "Off"
            case 0x01:
                return "High"
            case 0x03:
                return "Low"
            default:
                return "Unknown Level (0x\(String(format: "%02X", ncLevel)))"
            }
        }
        
        return "Unknown (Invalid Response Format)"
    }
    
    private func updateNoiseCancellationStatus(_ status: String) {
        print("Updating NC status to: \(status)")
        
        // Update the current headphone info with NC status
        guard let info = currentHeadphoneInfo else { return }
        
        let updatedInfo = HeadphoneInfo(
            name: info.name,
            batteryLevel: info.batteryLevel,
            isConnected: info.isConnected,
            firmwareVersion: info.firmwareVersion,
            noiseCancellationEnabled: nil, // We'll show status as text instead
            audioCodec: info.audioCodec,
            vendorId: info.vendorId,
            productId: info.productId,
            services: info.services,
            serialNumber: info.serialNumber,
            language: info.language,
            voicePromptsEnabled: info.voicePromptsEnabled,
            selfVoiceLevel: info.selfVoiceLevel,
            pairedDevices: info.pairedDevices,
            pairedDevicesCount: info.pairedDevicesCount,
            connectedDevicesCount: info.connectedDevicesCount
        )
        
        currentHeadphoneInfo = updatedInfo
        
        // Update the menu with the detected NC status
        DispatchQueue.main.async {
            self.updateMenuWithNCStatus(status)
        }
    }
    
    private func updateMenuWithNCStatus(_ status: String) {
        guard let menu = statusItem?.menu else { return }
        
        // Update noise cancellation status (index 4)
        if let ncItem = menu.item(at: 4) {
            ncItem.title = "Noise Cancellation: \(status)"
            
            // Add visual indicator based on status
            if status.contains("Off") {
                ncItem.state = .off
            } else if status.contains("On") {
                ncItem.state = .on
            } else {
                ncItem.state = .mixed
            }
        }
        
        // Also update tooltip with more info
        if let button = statusItem?.button {
            let deviceName = currentHeadphoneInfo?.name ?? "Unknown Device"
            let batteryInfo = currentHeadphoneInfo?.batteryLevel.map { "\($0)%" } ?? "Unknown"
            button.toolTip = "\(deviceName)\nBattery: \(batteryInfo)\nNC: \(status)"
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
            
            // Look for Bose device names (they end with ":")
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
                print("Found Bose device in system profiler: \(currentDevice ?? "Unknown")")
                continue
            }
            
            // Check if we've moved to a different device (not Bose)
            if trimmedLine.hasSuffix(":") && !trimmedLine.contains("Bose") && !trimmedLine.isEmpty {
                isProcessingBoseDevice = false
            }
            
            // Only process lines if we're currently in a Bose device section
            guard isProcessingBoseDevice else { continue }
            
            // Look for Bluetooth address (only for Bose device)
            if trimmedLine.contains("Address:") {
                print("DEBUG: Full address line: '\(trimmedLine)'")
                // Handle MAC address format properly (contains multiple colons)
                if let range = trimmedLine.range(of: "Address:") {
                    let addressPart = String(trimmedLine[range.upperBound...])
                    deviceAddress = addressPart.trimmingCharacters(in: .whitespaces)
                    print("DEBUG: Extracted Bose address: '\(deviceAddress ?? "Unknown")'")
                    print("Found Bose device address: \(deviceAddress ?? "Unknown")")
                }
                continue
            }
            
            // Look for battery level (indented line)
            if trimmedLine.contains("Battery Level:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    let batteryString = components[1].trimmingCharacters(in: .whitespaces)
                    if let percentage = Int(batteryString.replacingOccurrences(of: "%", with: "")) {
                        batteryLevel = percentage
                        print("Found battery level: \(percentage)%")
                    }
                }
                continue
            }
            
            // Look for firmware version (indented line)
            if trimmedLine.contains("Firmware Version:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    firmwareVersion = components[1].trimmingCharacters(in: .whitespaces)
                    print("Found firmware version: \(firmwareVersion ?? "Unknown")")
                }
                continue
            }
            
            // Look for vendor ID
            if trimmedLine.contains("Vendor ID:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    vendorId = components[1].trimmingCharacters(in: .whitespaces)
                    print("Found vendor ID: \(vendorId ?? "Unknown")")
                }
                continue
            }
            
            // Look for product ID
            if trimmedLine.contains("Product ID:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    productId = components[1].trimmingCharacters(in: .whitespaces)
                    print("Found product ID: \(productId ?? "Unknown")")
                }
                continue
            }
            
            // Look for services
            if trimmedLine.contains("Services:") {
                let components = trimmedLine.components(separatedBy: ":")
                if components.count > 1 {
                    services = components[1].trimmingCharacters(in: .whitespaces)
                    print("Found services: \(services ?? "Unknown")")
                }
                continue
            }
            
            // Check if we've reached the end of this device section
            // This happens when we encounter a line that's not indented and not empty
            if !line.hasPrefix("      ") && !trimmedLine.isEmpty && trimmedLine != "Connected:" && trimmedLine != "Not Connected:" {
                // We've moved to a new section, process the current device if it's Bose
                if let device = currentDevice, device.contains("Bose") {
                    // Store the device address for Bluetooth commands
                    self.deviceAddress = deviceAddress
                    print("Storing Bose device address: \(deviceAddress ?? "None")")
                    
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
                    return // Found and processed, exit
                }
                
                // Reset for next device
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
        
        // Handle case where Bose device is the last item in the output
        if let device = currentDevice, device.contains("Bose") {
            // Store the device address for Bluetooth commands
            self.deviceAddress = deviceAddress
            print("Storing Bose device address (end of file): \(deviceAddress ?? "None")")
            
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
        
        // If we didn't find any Bose device
        if !foundBoseDevice {
            print("No Bose device found in system profiler")
            updateMenuWithNoDevice()
        }
    }
    
    private func determineAudioCodec(from services: String?) -> String {
        guard let services = services else { return "Unknown" }
        
        // Check for high-quality codecs first
        if services.contains("A2DP") {
            return "A2DP (High Quality)"
        } else if services.contains("HFP") {
            return "HFP (Voice)"
        } else {
            return "Standard"
        }
    }
    
    private func updateMenuWithHeadphoneInfo(_ info: HeadphoneInfo) {
        guard let menu = statusItem?.menu else { return }
        
        // Update device name (index 0)
        if let deviceItem = menu.item(at: 0) {
            deviceItem.title = info.name
        }
        
        // Update battery level (index 2)
        if let batteryItem = menu.item(at: 2) {
            if let battery = info.batteryLevel {
                batteryItem.title = "Battery: \(battery)%"
                updateStatusBarIcon(batteryLevel: battery)
            } else {
                batteryItem.title = "Battery: Unknown"
            }
        }
        
        // Update firmware (index 3)
        if let firmwareItem = menu.item(at: 3) {
            firmwareItem.title = "Firmware: \(info.firmwareVersion ?? "Unknown")"
        }
        
        // Update noise cancellation (index 4)
        if let ncItem = menu.item(at: 4) {
            if let nc = info.noiseCancellationEnabled {
                ncItem.title = "Noise Cancellation: \(nc ? "On" : "Off")"
            } else {
                ncItem.title = "Noise Cancellation: Unknown"
            }
        }
        
        // Update audio codec (index 5)
        if let codecItem = menu.item(at: 5) {
            codecItem.title = "Audio Codec: \(info.audioCodec ?? "Unknown")"
        }
        
        // Update device ID (index 6)
        if let deviceIdItem = menu.item(at: 6) {
            let vendorText = info.vendorId ?? "Unknown"
            let productText = info.productId ?? "Unknown"
            deviceIdItem.title = "Device ID: \(vendorText) / \(productText)"
        }
        
        // Update services (index 7)
        if let servicesItem = menu.item(at: 7) {
            servicesItem.title = "Services: \(info.services ?? "Unknown")"
        }
        
        // Update serial number (index 9)
        if let serialItem = menu.item(at: 9) {
            serialItem.title = "Serial Number: \(info.serialNumber ?? "Unknown")"
        }
        
        // Update language (index 10)
        if let languageItem = menu.item(at: 10) {
            languageItem.title = "Language: \(info.language ?? "Unknown")"
        }
        
        // Update voice prompts (index 11)
        if let voicePromptsItem = menu.item(at: 11) {
            if let enabled = info.voicePromptsEnabled {
                voicePromptsItem.title = "Voice Prompts: \(enabled ? "On" : "Off")"
            } else {
                voicePromptsItem.title = "Voice Prompts: Unknown"
            }
        }
        
        // Update self voice (index 12)
        if let selfVoiceItem = menu.item(at: 12) {
            selfVoiceItem.title = "Self Voice: \(info.selfVoiceLevel ?? "Unknown")"
        }
        
        // Update paired devices (index 13)
        if let pairedDevicesItem = menu.item(at: 13) {
            if let count = info.pairedDevicesCount, let connectedCount = info.connectedDevicesCount {
                pairedDevicesItem.title = "Paired Devices: \(count) (\(connectedCount) connected)"
                
                // If we have the device list, create a submenu
                if let devices = info.pairedDevices, !devices.isEmpty {
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
                    
                    pairedDevicesItem.submenu = submenu
                    pairedDevicesItem.isEnabled = true  // Enable the menu item
                }
            } else if let devices = info.pairedDevices, !devices.isEmpty {
                pairedDevicesItem.title = "Paired Devices: \(devices.count)"
                
                // Create submenu even without count info
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
                
                pairedDevicesItem.submenu = submenu
                pairedDevicesItem.isEnabled = true  // Enable the menu item
            } else {
                // Only update title if we don't already have a submenu
                // This prevents removing the submenu when info is updated without paired devices data
                if pairedDevicesItem.submenu == nil {
                    pairedDevicesItem.title = "Paired Devices: Unknown"
                    pairedDevicesItem.isEnabled = false  // Keep it disabled if no data
                }
            }
        }
        
        // Update connection status (index 15)
        if let connectionItem = menu.item(at: 15) {
            connectionItem.title = "Status: \(info.isConnected ? "Connected" : "Disconnected")"
        }
        
        currentHeadphoneInfo = info
    }
    
    private func updateStatusBarIcon(batteryLevel: Int) {
        guard let button = statusItem?.button else { return }
        
        // Update icon color based on battery level
        if batteryLevel < 20 {
            button.contentTintColor = .systemRed
        } else if batteryLevel < 50 {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil // Use default system color
        }
    }
    
    @objc private func refreshBattery() {
        // Manually refresh the device info - runs in background
        checkForBoseDevices()
    }
    
    @objc private func setNoiseCancellationOff() {
        print("Setting noise cancellation to OFF")
        sendNoiseCancellationCommand(level: 0x00)
    }
    
    @objc private func setNoiseCancellationLow() {
        print("Setting noise cancellation to LOW")
        sendNoiseCancellationCommand(level: 0x03)
    }
    
    @objc private func setNoiseCancellationHigh() {
        print("Setting noise cancellation to HIGH")
        sendNoiseCancellationCommand(level: 0x01)
    }
    
    private func sendNoiseCancellationCommand(level: UInt8) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else {
                print("Cannot set NC: not connected")
                return
            }
            
            // Bose NC command format: [0x01, 0x06, 0x02, 0x01, level]
            // level: 0x00 = Off, 0x01 = High, 0x03 = Low
            let command: [UInt8] = [0x01, 0x06, 0x02, 0x01, level]
            
            self.sendCommandAsync(command) { response in
                if let response = response {
                    print("NC command response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
                }
                
                // Update the menu to reflect the change
                let statusText: String
                switch level {
                case 0x00: statusText = "Off"
                case 0x01: statusText = "High"
                case 0x03: statusText = "Low"
                default: statusText = "Unknown"
                }
                DispatchQueue.main.async {
                    self.updateMenuWithNCStatus(statusText)
                }
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
    
    // MARK: - Bluetooth Command Methods
    
    private func sendCommandAsync(_ command: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            guard let channel = self.rfcommChannel, channel.isOpen() else {
                print("RFCOMM channel is not open")
                completion(nil)
                return
            }
            
            self.responseBuffer = []
            self.responseSemaphore = DispatchSemaphore(value: 0)
            
            var data = command
            var result: [UInt8] = []
            let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
            if writeResult != kIOReturnSuccess {
                print("Failed to write command: \(self.krToString(writeResult))")
                self.responseSemaphore = nil
                completion(nil)
                return
            }
            
            print("Sent command: \(command.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
            
            let waitResult = self.responseSemaphore?.wait(timeout: .now() + 2.0)
            self.responseSemaphore = nil
            
            if waitResult == .timedOut {
                print("Timeout waiting for response")
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
                print("RFCOMM channel not open, attempting to connect...")
                if let deviceAddr = self.deviceAddress {
                    let result = self.connectToBoseDeviceSync(address: deviceAddr)
                    completion(result)
                } else {
                    print("No device address available")
                    completion(false)
                }
            } else {
                completion(true)
            }
        }
    }
    
    // MARK: - Battery Level (used by menu actions)
    
    // MARK: - Serial Number (used by menu actions)
    
    // MARK: - Language
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let languageValue = UInt8(sender.tag)
        
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else {
                print("Cannot set language: not connected")
                return
            }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, languageValue]
            self.sendCommandAsync(command) { response in
                if let response = response {
                    print("Language set response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
                }
                
                DispatchQueue.main.async {
                    if let lang = PromptLanguage(rawValue: languageValue) {
                        self.updateLanguageInMenu(lang.displayName)
                    }
                }
            }
        }
    }
    
    private func updateLanguageInMenu(_ language: String) {
        guard let menu = statusItem?.menu else { return }
        if let languageItem = menu.item(at: 10) {
            languageItem.title = "Language: \(language)"
        }
    }
    
    // MARK: - Voice Prompts
    
    private var currentLanguageValue: UInt8 = 0x21 // Default to English
    
    @objc private func setVoicePromptsOn() {
        setVoicePrompts(on: true)
    }
    
    @objc private func setVoicePromptsOff() {
        setVoicePrompts(on: false)
    }
    
    private func setVoicePrompts(on: Bool) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else {
                print("Cannot set voice prompts: not connected")
                return
            }
            
            // Voice prompts are controlled via language setting with VP_MASK (0x80)
            var languageValue = self.currentLanguageValue & 0x7F // Clear VP bit
            if on {
                languageValue |= 0x80 // Set VP bit
            }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, languageValue]
            self.sendCommandAsync(command) { response in
                if let response = response {
                    print("Voice prompts set response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
                }
                
                DispatchQueue.main.async {
                    self.updateVoicePromptsInMenu(on)
                }
            }
        }
    }
    
    private func updateVoicePromptsInMenu(_ on: Bool) {
        guard let menu = statusItem?.menu else { return }
        if let voicePromptsItem = menu.item(at: 11) {
            voicePromptsItem.title = "Voice Prompts: \(on ? "On" : "Off")"
        }
    }
    
    // MARK: - Self Voice
    
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
            guard connected, let self = self else {
                print("Cannot set self voice: not connected")
                return
            }
            
            let command: [UInt8] = [0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38]
            self.sendCommandAsync(command) { response in
                if let response = response {
                    print("Self voice set response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
                }
                
                DispatchQueue.main.async {
                    self.updateSelfVoiceInMenu(level.displayName)
                }
            }
        }
    }
    
    private func updateSelfVoiceInMenu(_ level: String) {
        guard let menu = statusItem?.menu else { return }
        if let selfVoiceItem = menu.item(at: 12) {
            selfVoiceItem.title = "Self Voice: \(level)"
        }
    }
    
    // MARK: - Paired Devices (used by menu actions)
    
    // MARK: - Disconnect Device
    
    @objc private func disconnectDevice() {
        guard let deviceAddr = deviceAddress else {
            print("No device address to disconnect")
            return
        }
        
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else {
                print("Cannot disconnect: not connected")
                return
            }
            
            // Convert address string to bytes
            let addressComponents = deviceAddr.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            var addressBytes: [UInt8] = []
            
            var index = addressComponents.startIndex
            while index < addressComponents.endIndex {
                let nextIndex = addressComponents.index(index, offsetBy: 2, limitedBy: addressComponents.endIndex) ?? addressComponents.endIndex
                if let byte = UInt8(addressComponents[index..<nextIndex], radix: 16) {
                    addressBytes.append(byte)
                }
                index = nextIndex
            }
            
            if addressBytes.count == 6 {
                var command: [UInt8] = [0x04, 0x02, 0x05, 0x06]
                command.append(contentsOf: addressBytes)
                
                self.sendCommandAsync(command) { response in
                    if let response = response {
                        print("Disconnect response: \(response.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
                    }
                }
            }
        }
    }
    
    // MARK: - Enhanced Device Info Fetching
    
    private func updateBatteryInMenu(_ level: Int) {
        guard let menu = statusItem?.menu else { return }
        if let batteryItem = menu.item(at: 2) {
            batteryItem.title = "Battery: \(level)%"
            updateStatusBarIcon(batteryLevel: level)
        }
    }
    
    private func updateSerialInMenu(_ serial: String) {
        guard let menu = statusItem?.menu else { return }
        if let serialItem = menu.item(at: 9) {
            serialItem.title = "Serial Number: \(serial)"
        }
    }
    
    private func updatePairedDevicesInMenu(_ devices: [String], totalCount: Int, connectedCount: Int) {
        guard let menu = statusItem?.menu else { return }
        
        // Update the main paired devices item to show count
        if let pairedDevicesItem = menu.item(at: 13) {
            pairedDevicesItem.title = "Paired Devices: \(totalCount) (\(connectedCount) connected)"
            
            // Remove any existing submenu
            pairedDevicesItem.submenu = nil
            
            // Create a submenu to show the device list
            if !devices.isEmpty {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                
                // Add header
                let headerItem = NSMenuItem(title: "! = Current device, * = Connected", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                submenu.addItem(headerItem)
                submenu.addItem(NSMenuItem.separator())
                
                // Add each device
                for device in devices {
                    let deviceItem = NSMenuItem(title: device, action: nil, keyEquivalent: "")
                    deviceItem.isEnabled = false
                    submenu.addItem(deviceItem)
                }
                
                pairedDevicesItem.submenu = submenu
                pairedDevicesItem.isEnabled = true  // Enable the menu item so it can be clicked
            }
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}