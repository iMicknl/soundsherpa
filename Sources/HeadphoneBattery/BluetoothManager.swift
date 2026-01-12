import Foundation
import IOBluetooth
import Combine

// MARK: - Data Models

struct BoseDevice: Identifiable, Equatable {
    let id: String // MAC address
    let name: String
    var batteryLevel: Int?
    var isConnected: Bool
    var firmwareVersion: String?
    var audioCodec: String?
    var vendorId: String?
    var productId: String?
    var services: String?
    var serialNumber: String?
}

struct PairedDevice: Identifiable, Equatable {
    let id: String // MAC address
    let name: String
    var isConnected: Bool
    var isCurrentDevice: Bool
}

enum NoiseCancellationLevel: UInt8, CaseIterable, Identifiable {
    case off = 0x00
    case low = 0x03
    case high = 0x01
    
    var id: UInt8 { rawValue }
    
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .high: return "High"
        }
    }
    
    var iconName: String {
        switch self {
        case .off: return "speaker.wave.1"
        case .low: return "speaker.wave.2"
        case .high: return "speaker.wave.3"
        }
    }
}

enum SelfVoiceLevel: UInt8, CaseIterable, Identifiable {
    case off = 0x00
    case high = 0x01
    case medium = 0x02
    case low = 0x03
    
    var id: UInt8 { rawValue }
    
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
    
    var iconName: String {
        switch self {
        case .off: return "person"
        case .low: return "person.wave.2"
        case .medium: return "person.wave.2.fill"
        case .high: return "person.2.wave.2.fill"
        }
    }
    
    // Display order for UI
    static var displayOrder: [SelfVoiceLevel] {
        [.off, .low, .medium, .high]
    }
}

enum PromptLanguage: UInt8, CaseIterable, Identifiable {
    case english = 0x21
    case french = 0x22
    case italian = 0x23
    case german = 0x24
    case spanish = 0x26
    case portuguese = 0x27
    case chinese = 0x28
    case korean = 0x29
    case russian = 0x2A
    case polish = 0x2B
    case dutch = 0x2e
    case japanese = 0x2f
    case swedish = 0x32
    
    var id: UInt8 { rawValue }
    
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
        }
    }
}

// MARK: - Bluetooth Manager

class BluetoothManager: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    static let shared = BluetoothManager()
    
    // Published state for SwiftUI
    @Published var currentDevice: BoseDevice?
    @Published var pairedDevices: [PairedDevice] = []
    @Published var noiseCancellation: NoiseCancellationLevel = .off
    @Published var selfVoice: SelfVoiceLevel = .off
    @Published var currentLanguage: PromptLanguage = .english
    @Published var voicePromptsEnabled: Bool = true
    @Published var isScanning: Bool = false
    
    // Internal state
    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var channelOpenSemaphore: DispatchSemaphore?
    private var isChannelReady = false
    private var responseBuffer: [UInt8] = []
    private var responseSemaphore: DispatchSemaphore?
    private var expectedResponsePrefix: [UInt8] = []
    private let responseLock = NSLock()
    private var currentLanguageValue: UInt8 = 0x21
    
    private var updateTimer: Timer?
    private var ncUpdateTimer: Timer?
    
    override init() {
        super.init()
    }
    
    func startMonitoring() {
        checkForBoseDevices()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkForBoseDevices()
        }
        
        ncUpdateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            if self?.currentDevice?.isConnected == true {
                self?.detectNoiseCancellationStatusAsync()
            }
        }
    }
    
    func stopMonitoring() {
        updateTimer?.invalidate()
        ncUpdateTimer?.invalidate()
        
        if let channel = rfcommChannel, channel.isOpen() {
            _ = channel.close()
        }
    }
    
    func refresh() {
        checkForBoseDevices()
    }

    
    // MARK: - Device Discovery
    
    func checkForBoseDevices() {
        isScanning = true
        
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
                        self?.isScanning = false
                        self?.detectNoiseCancellationStatusAsync()
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.currentDevice = nil
                        self?.isScanning = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.currentDevice = nil
                    self?.isScanning = false
                }
            }
        }
    }
    
    private func parseBoseInfoFromSystemProfiler(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        var currentDeviceName: String?
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
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine == "Connected:" {
                inConnectedSection = true
                continue
            }
            if trimmedLine == "Not Connected:" {
                inConnectedSection = false
                continue
            }
            
            if trimmedLine.contains("Bose") && trimmedLine.hasSuffix(":") {
                currentDeviceName = String(trimmedLine.dropLast())
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
        }
        
        if let name = currentDeviceName, name.contains("Bose"), let address = deviceAddress {
            let device = BoseDevice(
                id: address,
                name: name,
                batteryLevel: batteryLevel,
                isConnected: isConnected,
                firmwareVersion: firmwareVersion,
                audioCodec: determineAudioCodec(from: services),
                vendorId: vendorId,
                productId: productId,
                services: services,
                serialNumber: nil
            )
            self.currentDevice = device
        } else if !foundBoseDevice {
            self.currentDevice = nil
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

    
    // MARK: - Connection Management
    
    func connectDevice(_ device: PairedDevice) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.attemptConnection(address: device.id)
        }
    }
    
    func connectCurrentDevice() {
        guard let device = currentDevice else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.attemptConnection(address: device.id)
        }
    }
    
    func disconnectDevice(_ device: PairedDevice) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.attemptDisconnection(address: device.id)
        }
    }
    
    private func attemptConnection(address: String) {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return
        }
        
        guard let device = pairedDevices.first(where: { device in
            if let deviceAddress = device.addressString {
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                return cleanDeviceAddr == cleanTargetAddr
            }
            return false
        }) else {
            return
        }
        
        if !device.isConnected() {
            let result = device.openConnection()
            if result == kIOReturnSuccess {
                Thread.sleep(forTimeInterval: 1.0)
                DispatchQueue.main.async {
                    self.checkForBoseDevices()
                }
            }
        }
    }
    
    private func attemptDisconnection(address: String) {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return
        }
        
        guard let device = pairedDevices.first(where: { device in
            if let deviceAddress = device.addressString {
                let cleanDeviceAddr = deviceAddress.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                let cleanTargetAddr = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
                return cleanDeviceAddr == cleanTargetAddr
            }
            return false
        }) else {
            return
        }
        
        if device.isConnected() {
            let result = device.closeConnection()
            if result == kIOReturnSuccess {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async {
                    self.checkForBoseDevices()
                }
            }
        }
    }
    
    // MARK: - RFCOMM Connection
    
    private func detectNoiseCancellationStatusAsync() {
        guard let device = currentDevice else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.connectToBoseDeviceSync(address: device.id) {
                if self.initBoseConnection() {
                    self.fetchAllDeviceInfo()
                } else {
                    self.fetchAllDeviceInfo()
                }
            }
        }
    }
    
    private func connectToBoseDeviceSync(address: String) -> Bool {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return false
        }
        
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
            return false
        }
        
        if !device.isConnected() {
            let connectResult = device.openConnection()
            if connectResult != kIOReturnSuccess {
                // Connection failed
            } else {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        
        let ret = device.performSDPQuery(self, uuids: [])
        if ret != kIOReturnSuccess {
            // SDP Query unsuccessful
        }
        
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            return false
        }
        
        guard let sppService = services.first(where: { $0.getServiceName() == "SPP Dev" }) else {
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
        
        return waitResult != .timedOut || (responseBuffer.count >= 4 && responseBuffer[0] == 0x00 && responseBuffer[1] == 0x01)
    }

    
    // MARK: - Fetch Device Info
    
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
                self.currentDevice?.batteryLevel = level
                NotificationCenter.default.post(name: NSNotification.Name("BatteryLevelChanged"), object: nil)
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
                        self.currentDevice?.serialNumber = serial
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
                        self.currentLanguage = lang
                        self.voicePromptsEnabled = voicePromptsOn
                    }
                }
                break
            }
        }
        
        // Parse NC level
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x06 && response[i+2] == 0x03 {
                let ncLevel = response[i+4]
                if let level = NoiseCancellationLevel(rawValue: ncLevel) {
                    DispatchQueue.main.async {
                        self.noiseCancellation = level
                    }
                }
                break
            }
        }
        
        // Parse Self Voice level
        for i in 0..<response.count {
            if i + 5 < response.count && response[i] == 0x01 && response[i+1] == 0x0b && response[i+2] == 0x03 {
                let selfVoiceLevel = response[i+5]
                if let level = SelfVoiceLevel(rawValue: selfVoiceLevel) {
                    DispatchQueue.main.async {
                        self.selfVoice = level
                    }
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
            
            var devices: [PairedDevice] = []
            var offset = 5
            
            for i in 0..<numDevices {
                if offset + 6 <= response.count {
                    let addressBytes = Array(response[offset..<(offset + 6)])
                    let address = addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                    
                    var deviceName: String
                    if i == 0 {
                        deviceName = Host.current().localizedName ?? getDeviceNameForAddress(address) ?? address
                    } else {
                        deviceName = getDeviceNameForAddress(address) ?? address
                    }
                    
                    let device = PairedDevice(
                        id: address,
                        name: deviceName,
                        isConnected: i < numConnected,
                        isCurrentDevice: i == 0
                    )
                    devices.append(device)
                    
                    offset += 6
                }
            }
            
            DispatchQueue.main.async {
                self.pairedDevices = devices
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

    
    // MARK: - Command Helpers
    
    private func sendCommandAndWait(command: [UInt8], expectedPrefix: [UInt8], timeout: TimeInterval = 0.5) -> [UInt8] {
        guard let channel = rfcommChannel, channel.isOpen() else { return [] }
        
        responseLock.lock()
        responseBuffer = []
        self.expectedResponsePrefix = expectedPrefix
        responseLock.unlock()
        
        responseSemaphore = DispatchSemaphore(value: 0)
        
        var data = command
        var result: [UInt8] = []
        let writeResult = channel.writeAsync(&data, length: UInt16(data.count), refcon: &result)
        if writeResult != kIOReturnSuccess {
            responseSemaphore = nil
            responseLock.lock()
            self.expectedResponsePrefix = []
            responseLock.unlock()
            return []
        }
        
        _ = responseSemaphore?.wait(timeout: .now() + timeout)
        responseSemaphore = nil
        
        responseLock.lock()
        let resultBuffer = responseBuffer
        self.expectedResponsePrefix = []
        responseLock.unlock()
        
        return resultBuffer
    }
    
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
                if let device = self.currentDevice {
                    let result = self.connectToBoseDeviceSync(address: device.id)
                    completion(result)
                } else {
                    completion(false)
                }
            } else {
                completion(true)
            }
        }
    }
    
    // MARK: - Settings Actions
    
    func setNoiseCancellation(_ level: NoiseCancellationLevel) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x06, 0x02, 0x01, level.rawValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.noiseCancellation = level
                }
            }
        }
    }
    
    func setSelfVoice(_ level: SelfVoiceLevel) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.selfVoice = level
                }
            }
        }
    }
    
    func setLanguage(_ language: PromptLanguage) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, language.rawValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.currentLanguage = language
                }
            }
        }
    }
    
    func setVoicePrompts(_ enabled: Bool) {
        ensureConnectionAsync { [weak self] connected in
            guard connected, let self = self else { return }
            
            var languageValue = self.currentLanguageValue & 0x7F
            if enabled {
                languageValue |= 0x80
            }
            
            let command: [UInt8] = [0x01, 0x03, 0x02, 0x01, languageValue]
            self.sendCommandAsync(command) { _ in
                DispatchQueue.main.async {
                    self.voicePromptsEnabled = enabled
                }
            }
        }
    }
    
    // MARK: - RFCOMM Delegate
    
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = dataPointer.assumingMemoryBound(to: UInt8.self)
        var responseData: [UInt8] = []
        for i in 0..<dataLength {
            responseData.append(bytes[i])
        }
        
        responseLock.lock()
        let expectedPrefix = self.expectedResponsePrefix
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
            if let level = NoiseCancellationLevel(rawValue: ncLevel) {
                DispatchQueue.main.async {
                    self.noiseCancellation = level
                }
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
}
