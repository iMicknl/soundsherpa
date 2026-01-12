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
                self.detectNoiseCancellationStatus()
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
                parseBoseInfoFromSystemProfiler(output)
                
                // Try to detect noise cancellation status
                detectNoiseCancellationStatus()
            } else {
                print("Failed to get system profiler output")
                updateMenuWithNoDevice()
            }
        } catch {
            print("Error running system_profiler: \(error)")
            updateMenuWithNoDevice()
        }
    }
    
    private func detectNoiseCancellationStatus() {
        guard let deviceAddr = deviceAddress else {
            print("No device address available for NC detection")
            return
        }
        
        // Connect to Bose device using SPP Dev service
        if connectToBoseDevice(address: deviceAddr) {
            // Send command to get NC status
            sendGetNoiseCancellationCommand()
        } else {
            updateNoiseCancellationStatus("Unknown (Connection Failed)")
        }
    }
    
    private func connectToBoseDevice(address: String) -> Bool {
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
        
        // Third try: async with semaphore
        print("Trying async channel open on original channel \(channelId)...")
        channelOpenSemaphore = DispatchSemaphore(value: 0)
        
        let asyncResult = device.openRFCOMMChannelAsync(&channel,
                                                       withChannelID: channelId,
                                                       delegate: self)
        if asyncResult != kIOReturnSuccess {
            print("Async open failed: \(krToString(asyncResult))")
            channelOpenSemaphore = nil
            return false
        }
        
        self.rfcommChannel = channel
        
        // Wait for channel to open (max 5 seconds)
        let waitResult = channelOpenSemaphore?.wait(timeout: .now() + 5.0)
        channelOpenSemaphore = nil
        
        if waitResult == .timedOut {
            print("Timeout waiting for channel to open")
            return false
        }
        
        let success = isChannelReady && (rfcommChannel?.isOpen() ?? false)
        print("Async channel open result: \(success), isOpen: \(rfcommChannel?.isOpen() ?? false)")
        return success
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
        
        // Parse the response for NC status
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
            services: info.services
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
            services: nil
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
                        services: services
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
                services: services
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
        
        // Update connection status (index 9)
        if let connectionItem = menu.item(at: 9) {
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
        // Manually refresh the device info
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
        // Ensure we have a connection
        if rfcommChannel == nil || !(rfcommChannel?.isOpen() ?? false) {
            print("RFCOMM channel not open, attempting to connect...")
            if let deviceAddr = deviceAddress {
                if !connectToBoseDevice(address: deviceAddr) {
                    print("Failed to connect to Bose device")
                    return
                }
            } else {
                print("No device address available")
                return
            }
        }
        
        guard let channel = rfcommChannel, channel.isOpen() else {
            print("RFCOMM channel is not open after connection attempt")
            return
        }
        
        // Bose NC command format: [0x01, 0x06, 0x02, 0x01, level]
        // level: 0x00 = Off, 0x01 = High, 0x03 = Medium
        var data: [UInt8] = [0x01, 0x06, 0x02, 0x01, level]
        var result: [UInt8] = []
        
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            print("Failed to send NC command: \(krToString(writeResult))")
        } else {
            print("NC command sent successfully")
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
    
    private func krToString(_ kr: kern_return_t) -> String {
        if let cStr = mach_error_string(kr) {
            return String(cString: cStr)
        } else {
            return "Unknown kernel error \(kr)"
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}