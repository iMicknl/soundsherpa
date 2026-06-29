import AppKit
import Foundation
import IOBluetooth
import Observation
import SoundSherpaCore

/// Single source of truth the SwiftUI views observe. Holds all device state as
/// observable properties and exposes intent methods the views call.
///
/// The class is `@MainActor @Observable` so observable property reads/writes are on the
/// main actor (where SwiftUI observes them). It also subclasses `NSObject` and conforms to
/// `IOBluetoothRFCOMMChannelDelegate` so it can be the RFCOMM delegate.
///
/// CONCURRENCY MODEL (migrated verbatim from the old AppDelegate — do not redesign):
/// - The blocking IOBluetooth open/SDP work runs on a single serial `connectionQueue`
///   (a nonisolated stored property). `connectToBoseDeviceSync` / `connectToService` /
///   `openChannel` / `closeChannelLocked` stay `nonisolated` and run off the main actor;
///   moving them onto the main actor reintroduces the documented "detected but shows
///   nothing" deadlock.
/// - The IOBluetooth delegate callbacks arrive on a background run loop, so they are
///   `nonisolated`. They push bytes into `ingestContinuation` (nonisolated-safe) and hop to
///   the main actor only for observable-property updates.
/// - The mutable channel/connection state below is `nonisolated(unsafe)`: its thread-safety
///   comes from the serial `connectionQueue` discipline (only one connect/teardown touches
///   it at a time) and the delegate callbacks, exactly as in the original AppDelegate — not
///   from actor isolation.
@MainActor
@Observable
final class DeviceController: NSObject, IOBluetoothRFCOMMChannelDelegate {
    /// Shared singleton so the SwiftUI `App` scene and the `@NSApplicationDelegateAdaptor`
    /// AppDelegate observe and drive the SAME controller instance.
    @ObservationIgnored static let shared = DeviceController()

    // MARK: - Observable state (main actor)

    // Connection + identity
    var deviceName: String?
    var isConnected: Bool = false
    var batteryLevel: Int?

    // Primary controls
    var ncLevel: NoiseCancellationLevel?
    var selfVoiceLevel: SelfVoiceLevel?

    // Paired devices
    var pairedDevices: [PairedDeviceInfo] = []

    // Advanced settings
    var autoOff: AutoOff?
    var language: PromptLanguage?
    var voicePromptsEnabled: Bool?
    var buttonAction: ButtonAction?

    // Read-only info (nil → row hidden)
    var firmware: String?
    var serial: String?
    var deviceId: String?
    var services: [String]?

    // MARK: - Nonisolated channel / connection state
    //
    // Touched from `connectionQueue` and the IOBluetooth delegate callbacks, never from the
    // main actor except where noted. Safety is the serial-queue discipline carried over from
    // AppDelegate, not actor isolation, hence `nonisolated(unsafe)`.

    @ObservationIgnored nonisolated(unsafe) private var deviceAddress: String?
    @ObservationIgnored nonisolated(unsafe) private var rfcommChannel: IOBluetoothRFCOMMChannel?
    @ObservationIgnored nonisolated(unsafe) private var channelOpenSemaphore: DispatchSemaphore?
    @ObservationIgnored nonisolated(unsafe) private var isChannelReady = false

    // The DeviceChannel actor serializes all command I/O over the open RFCOMM channel so a
    // reply can never land in the wrong command's buffer (R7.1). Recreated on each open,
    // torn down on close. Incoming delegate bytes are forwarded to `deviceChannel.ingest`.
    @ObservationIgnored nonisolated(unsafe) private var deviceChannel: DeviceChannel?

    // The brand registry resolves which DevicePlugin speaks a connected device's protocol,
    // from its advertised name alone. Battery and static-metadata reads route through the
    // resolved plugin, so supporting a new brand (Sony, …) is registering one more plugin in
    // DeviceRegistry.standard — no change here. `activePlugin` is the plugin for the device
    // we're currently talking to, resolved on connect.
    nonisolated private let deviceRegistry = DeviceRegistry.standard
    @ObservationIgnored nonisolated(unsafe) private var activePlugin: DevicePlugin?

    // All RFCOMM connect/teardown runs on this single serial queue so only one connection
    // attempt touches the channel state (rfcommChannel/deviceChannel/isChannelReady/
    // activePlugin) at a time. It stays a GCD worker (not @MainActor): the blocking open/SDP
    // query must run off the main thread, and the execution context is otherwise identical so
    // IOBluetooth delegate delivery is unchanged.
    nonisolated private let connectionQueue = DispatchQueue(label: "nl.imick.soundsherpa.connection")

    // Incoming RFCOMM bytes are pushed here from the delegate callback (synchronously, so
    // arrival order is preserved) and drained by a single consumer task into the actor's
    // `ingest`. This keeps ordered delivery without spawning an unordered Task per chunk.
    @ObservationIgnored nonisolated(unsafe) private var ingestContinuation: AsyncStream<[UInt8]>.Continuation?

    // Persisted, address-keyed static metadata (firmware/serial/model/VID/PID/services).
    // Survives relaunch so the Info shows last-known-good values instantly on connect, even
    // before a healthy RFCOMM channel is established.
    nonisolated private let metadataStore = DeviceMetadataStore(persistence: FileMetadataPersistence())

    // Bluetooth connection monitoring
    @ObservationIgnored nonisolated(unsafe) private var currentBoseDevice: IOBluetoothDevice?
    @ObservationIgnored nonisolated(unsafe) private var connectionNotification: IOBluetoothUserNotification?
    @ObservationIgnored nonisolated(unsafe) private var disconnectionNotification: IOBluetoothUserNotification?

    // Tracks the language byte (incl. the voice-prompt high bit) so voice-prompt toggles can
    // preserve the selected language. Carried over from AppDelegate.
    @ObservationIgnored nonisolated(unsafe) private var currentLanguageValue: UInt8 = 0x21

    // Throttle the full fetch burst: skip it if we fetched within the last 30s. Pure timing
    // state (Date only, no UI dependency) carried over verbatim from AppDelegate. Touched only
    // from the @MainActor `fetchAllDeviceInfo`, so plain stored properties suffice.
    @ObservationIgnored private var lastDataFetchTime: Date?
    @ObservationIgnored private let cacheValidityDuration: TimeInterval = 30.0 // Cache is valid for 30 seconds

    // Periodic refresh timers carried over from the old AppDelegate. The 30s scan timer
    // rescans/reconnects; the 10s NC-poll timer re-reads noise-cancellation status while
    // connected. Both run on the main run loop and their closures are @MainActor context
    // (the controller is @MainActor), so they can call the actor-isolated refresh methods
    // directly. Invalidated in `shutDown()` before the channel teardown.
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var ncPollTimer: Timer?

    override init() {
        super.init()
    }

    // MARK: - Lifecycle / Monitoring
    //
    // Relocated verbatim from the old AppDelegate. `startMonitoring` is the single entry
    // point the app lifecycle calls on launch; `shutDown` is the synchronous teardown on
    // terminate.

    /// Register Bluetooth connect/disconnect + sleep/wake observers and run the initial scan.
    /// Called from `applicationDidFinishLaunching`.
    func startMonitoring() {
        setupBluetoothNotifications()
        setupSleepWakeNotifications()
        checkForBoseDevices()

        // Periodic rescan/reconnect every 30s (matches the original AppDelegate). The timer
        // is scheduled on the main run loop, so the closure always fires on the main thread;
        // `assumeIsolated` lets us call the @MainActor members directly without an async hop
        // that could reorder relative to the synchronous teardown in shutDown().
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForBoseDevices()
            }
        }

        // Poll noise-cancellation status every 10s while connected.
        ncPollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isConnected {
                    self.detectNoiseCancellationStatusAsync()
                }
            }
        }
    }

    /// Synchronous termination teardown: the process exits right after this returns, so an
    /// async `closeChannel()` hop onto connectionQueue might never run, orphaning the device's
    /// single control channel (the very failure we guard against). Run it inline on the queue
    /// and wait, so the channel is actually released before we terminate. Called from
    /// `applicationWillTerminate`.
    func shutDown() {
        // Stop the periodic timers BEFORE tearing down the channel so a fired closure can't
        // kick off a new scan/connect that races the synchronous teardown below.
        scanTimer?.invalidate()
        scanTimer = nil
        ncPollTimer?.invalidate()
        ncPollTimer = nil

        connectionNotification?.unregister()
        disconnectionNotification?.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        connectionQueue.sync { closeChannelLocked() }
    }

    private func setupBluetoothNotifications() {
        // Register for general connection notifications. The main benefit is detecting
        // disconnections via the device-specific notification set up on connect.
        connectionNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    /// Register for disconnection notifications on the specific device, only if we don't
    /// already have one registered. `nonisolated` so the connect flow (on connectionQueue,
    /// off the main actor) can arm it during `connectToBoseDeviceSync`, exactly as the old
    /// AppDelegate did. Touches only the `nonisolated(unsafe)` `disconnectionNotification`.
    nonisolated private func setupDeviceSpecificNotifications(for device: IOBluetoothDevice) {
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
        // Just note that a Bose device connected and arm its disconnect notification; don't
        // interfere with normal operation.
        if isBoseDevice(device) {
            print("Bose device connected: \(device.name ?? "Unknown")")
            currentBoseDevice = device
            setupDeviceSpecificNotifications(for: device)
            // Reconnect (e.g. after a Bluetooth toggle, or powering the headphones on) should
            // surface in the UI immediately, not on the next 30s scan tick. The connection may
            // be stale relative to our cache, so force a fresh fetch, then re-scan now.
            lastDataFetchTime = nil
            checkForBoseDevices()
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Only act on disconnection of our current device.
        if isBoseDevice(device) && currentBoseDevice?.addressString == device.addressString {
            print("Bose device disconnected: \(device.name ?? "Unknown")")
            currentBoseDevice = nil
            disconnectionNotification = nil // Clear the notification

            // Release our RFCOMM channel so we don't hold the device's single control
            // channel half-open — otherwise the next connect is refused.
            closeChannel()

            // Reflect disconnected state in the UI.
            self.isConnected = false
            self.deviceName = nil
        }
    }

    private func isBoseDevice(_ device: IOBluetoothDevice) -> Bool {
        guard let name = device.name else { return false }
        return name.lowercased().contains("bose")
    }

    // MARK: - Intents

    func refresh() {
        checkForBoseDevices()
    }

    func setNoiseCancellation(_ level: NoiseCancellationLevel) {
        Task { [weak self] in
            guard let self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x06, 0x02, 0x01, level.byte], expecting: [0x01, 0x06])
            self.ncLevel = level
        }
    }

    func setSelfVoice(_ level: SelfVoiceLevel) {
        Task { [weak self] in
            guard let self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38], expecting: [0x01, 0x0b])
            self.selfVoiceLevel = level
        }
    }

    func connectPairedDevice(_ device: PairedDeviceInfo) {
        let address = device.address
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

    func disconnectPairedDevice(_ device: PairedDeviceInfo) {
        let address = device.address
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

    func setAutoOff(_ value: AutoOff) {
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            let success = await self.setAutoOffValue(value)
            if success {
                self.autoOff = value
            }
            // On failure the observable property is left unchanged (the device kept its old
            // value); the next status fetch will reconcile.
        }
    }

    func setLanguage(_ value: PromptLanguage) {
        let languageValue = value.rawValue
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x03, 0x02, 0x01, languageValue], expecting: [0x01, 0x03])
            self.language = value
        }
    }

    func setVoicePrompts(_ on: Bool) {
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }

            var languageValue = self.currentLanguageValue & 0x7F
            if on {
                languageValue |= 0x80
            }

            _ = await self.send([0x01, 0x03, 0x02, 0x01, languageValue], expecting: [0x01, 0x03])
            self.voicePromptsEnabled = on
        }
    }

    func setButtonAction(_ value: ButtonAction) {
        Task { [weak self] in
            guard let self = self, await self.ensureConnected() else { return }
            _ = await self.send([0x01, 0x09, 0x02, 0x03, 0x10, 0x04, value.rawValue], expecting: [0x01, 0x09])
            self.buttonAction = value
        }
    }

    // MARK: - Device Discovery

    func checkForBoseDevices() {
        print("Checking for Bose devices...")

        // Fast path: Check IOBluetooth paired devices first (much faster than system_profiler)
        if let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in pairedDevices {
                if let name = device.name, name.lowercased().contains("bose"), device.isConnected() {
                    print("Fast path: Found connected Bose device: \(name)")

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

                    self.deviceName = name
                    // isConnected reflects OS-level connection: the device is paired and
                    // connected, so the controls are shown immediately. The RFCOMM control
                    // channel is a separate, lazier concern — it can fail or drop transiently,
                    // and `ensureConnected` (re)opens it on demand when a command is sent. We
                    // deliberately do NOT gate the UI on the channel: doing so hid the entire
                    // tile whenever a channel open failed, even though the device was usable.
                    self.isConnected = true
                    // Show last-known-good static metadata instantly, before RFCOMM I/O.
                    if let address = device.addressString {
                        self.applyCachedMetadata(for: address)
                    }

                    // Start fetching detailed data via RFCOMM
                    self.detectNoiseCancellationStatusAsync()
                    return
                }
            }
        }

        // No connected Bose device found.
        self.isConnected = false
        self.deviceName = nil
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
                print(">>> Connection failed — control channel not open; will retry on next command/scan")
                // Do not flip isConnected: the device is still connected at the OS level and
                // the UI should stay visible. ensureConnected retries the channel when the
                // user next sends a command, and the periodic scan retries detection.
                return
            }
            print(">>> Connection successful, initializing Bose protocol...")

            Task { [weak self] in
                guard let self = self else { return }
                _ = await self.initBoseConnection()
                print(">>> Fetching device info...")
                await self.fetchAllDeviceInfo()
            }
        }
    }

    nonisolated private func connectToBoseDeviceSync(address: String) -> Bool {
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
    nonisolated private func sdpMetadata(for device: IOBluetoothDevice) -> DeviceMetadata {
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
    nonisolated private func sdpUInt16Hex(_ record: IOBluetoothSDPServiceRecord, attributeID: BluetoothSDPServiceAttributeID) -> String? {
        guard let element = record.getAttributeDataElement(attributeID),
              element.getTypeDescriptor() == kBluetoothSDPDataElementTypeUnsignedInt,
              let number = element.getNumberValue() else { return nil }
        return String(format: "0x%04X", number.uint16Value)
    }

    nonisolated private func connectToService(device: IOBluetoothDevice, service: IOBluetoothSDPServiceRecord) -> Bool {
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
    nonisolated private func openChannel(device: IOBluetoothDevice, channelId: BluetoothRFCOMMChannelID) -> Bool {
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
    nonisolated private func attachChannel(_ channel: IOBluetoothRFCOMMChannel) {
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
    nonisolated func closeChannel() {
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
    nonisolated func closeChannelLocked() {
        if let channel = deviceChannel {
            Task { await channel.close() }   // fails any in-flight command with .channelClosed
        }
        deviceChannel = nil
        // NOTE: do NOT clear activePlugin here. It is brand identity resolved from the
        // device name, not channel state, and it must survive the close-before-open cycle
        // that connectToService performs on every connect. Clearing it here left
        // activePlugin nil by the time fetchBatteryLevel ran, so battery never populated.
        // It's re-resolved on the next detection/connect anyway.
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
    nonisolated private func send(_ command: [UInt8], expecting prefix: [UInt8], timeout: TimeInterval = 0.5) async -> [UInt8] {
        guard let channel = deviceChannel else { return [] }
        do {
            return try await channel.send(command, matcher: .prefix(prefix), timeout: timeout)
        } catch {
            return []
        }
    }

    /// Send a command and collect every reply sharing `prefix` until `window` elapses. Used
    /// for the status query, which provokes several distinct broadcast messages.
    nonisolated private func collect(_ command: [UInt8], prefix: [UInt8], window: TimeInterval) async -> [UInt8] {
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
        // discard it; capture it via the pure codec so the Info can show it.
        let response = await send([0x00, 0x01, 0x01, 0x00], expecting: [0x00, 0x01], timeout: 5.0)
        if let firmware = BoseCodec.decodeFirmware(response) {
            storeMetadata(DeviceMetadata(firmware: firmware))
            self.firmware = firmware
        }
        return true
    }

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
        }
        // else: the fetch is throttled (data is < cacheValidityDuration old). No-op — the
        // observable properties still hold the last-fetched values, so there's nothing to
        // repopulate (unlike the legacy menu, which had to re-render from cache here).
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

    private func fetchBatteryLevel() async {
        // Route through the resolved brand plugin over the serialized channel. The plugin
        // owns the brand-specific encode/decode; this layer just stores and displays.
        guard let plugin = activePlugin, let channel = deviceChannel else { return }

        if let level = await plugin.readBatteryLevel(over: channel) {
            self.batteryLevel = level
        }
    }

    private func fetchSerialNumber() async {
        let response = await send(BoseCodec.encodeSerialQuery(), expecting: [0x00, 0x07])

        if let serial = BoseCodec.decodeSerial(response) {
            storeMetadata(DeviceMetadata(serial: serial))
            self.serial = serial
        }
    }

    private func fetchDeviceStatus() async {
        let deviceIdResponse = await send(BoseCodec.encodeDeviceIdQuery(), expecting: [0x00, 0x03])
        if let modelId = BoseCodec.decodeModelId(deviceIdResponse) {
            storeMetadata(DeviceMetadata(modelId: modelId))
            self.deviceId = String(format: "Bose 0x%04X", modelId)
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
                    self.language = lang
                    self.voicePromptsEnabled = voicePromptsOn
                }
                break
            }
        }

        // Parse NC level
        for i in 0..<response.count {
            if i + 4 < response.count && response[i] == 0x01 && response[i+1] == 0x06 && response[i+2] == 0x03 {
                let ncByte = response[i+4]
                self.ncLevel = NoiseCancellationLevel(byte: ncByte)
                break
            }
        }

        // Parse Self Voice level
        for i in 0..<response.count {
            if i + 5 < response.count && response[i] == 0x01 && response[i+1] == 0x0b && response[i+2] == 0x03 {
                let svByte = response[i+5]
                self.selfVoiceLevel = SelfVoiceLevel(rawValue: svByte)
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

                let rawName: String
                if isCurrentDevice {
                    rawName = Host.current().localizedName ?? getDeviceNameForAddress(address) ?? address
                } else {
                    rawName = getDeviceNameForAddress(address) ?? address
                }

                let deviceName = DeviceDisplay.pairedDeviceDisplayName(rawName: rawName, address: address)

                print("Device: \(address) - \(deviceName) - status: \(status)")

                let deviceInfo = PairedDeviceInfo(
                    address: address,
                    name: deviceName,
                    isConnected: isConnected,
                    isCurrentDevice: isCurrentDevice
                )
                devices.append(deviceInfo)
            }

            self.pairedDevices = devices
        }
    }

    private func fetchAutoOffStatus() async {
        let command: [UInt8] = [0x01, 0x04, 0x01, 0x00]
        let response = await send(command, expecting: [0x01, 0x04])

        if response.count >= 5 && response[0] == 0x01 && response[1] == 0x04 && response[2] == 0x03 {
            let autoOffValue = response[4]
            self.autoOff = AutoOff(rawValue: autoOffValue)
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
            self.buttonAction = ButtonAction(rawValue: buttonActionValue)
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

    // MARK: - Metadata helpers

    /// Merge freshly-read static metadata into the persisted, address-keyed store so it
    /// survives relaunch and shows instantly on the next connect.
    nonisolated private func storeMetadata(_ metadata: DeviceMetadata) {
        guard let address = deviceAddress else { return }
        metadataStore.put(metadata, for: address)
    }

    /// Populate the Info fields from persisted metadata for the given address. Called on
    /// connect before any RFCOMM I/O, so last-known-good values appear immediately.
    private func applyCachedMetadata(for address: String) {
        guard let meta = metadataStore.metadata(for: address) else { return }

        let deviceIdValue: String?
        if meta.vendorId != nil || meta.productId != nil {
            deviceIdValue = "\(meta.vendorId ?? "?") / \(meta.productId ?? "?")"
        } else if let modelId = meta.modelId {
            deviceIdValue = String(format: "Bose 0x%04X", modelId)
        } else {
            deviceIdValue = nil
        }

        if let firmware = meta.firmware { self.firmware = firmware }
        if let deviceIdValue { self.deviceId = deviceIdValue }
        if let services = meta.services { self.services = services }
        if let serial = meta.serial { self.serial = serial }
    }

    nonisolated private func getDeviceNameForAddress(_ address: String) -> String? {
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

    nonisolated private func addressStringToBytes(_ address: String) -> [UInt8]? {
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

    // MARK: - Async Helpers

    /// Ensure an open channel exists, (re)connecting if needed. Returns whether a channel
    /// is available afterward. The blocking IOBluetooth open/SDP query runs on a GCD
    /// background thread (not the Swift cooperative pool) because it depends on that
    /// thread's run loop to receive the open/SDP delegate callbacks.
    nonisolated private func ensureConnected() async -> Bool {
        if let channel = rfcommChannel, channel.isOpen() { return true }
        guard let deviceAddr = deviceAddress else { return false }

        return await withCheckedContinuation { continuation in
            connectionQueue.async { [weak self] in
                let result = self?.connectToBoseDeviceSync(address: deviceAddr) ?? false
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private func krToString(_ kr: kern_return_t) -> String {
        if let cStr = mach_error_string(kr) {
            return String(cString: cStr)
        } else {
            return "Unknown kernel error \(kr)"
        }
    }

    // MARK: - RFCOMM Delegate
    //
    // Invoked by IOBluetooth on a background run loop, hence `nonisolated`. They push bytes
    // into `ingestContinuation` (nonisolated-safe) and hop to the main actor only for
    // observable-property updates.

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = dataPointer.assumingMemoryBound(to: UInt8.self)
        var responseData: [UInt8] = []
        for i in 0..<dataLength {
            responseData.append(bytes[i])
        }

        // Forward to the DeviceChannel actor (in arrival order) to satisfy the in-flight
        // command. The actor decides whether this chunk matches via its ResponseMatcher.
        ingestContinuation?.yield(responseData)

        // Independently, react to unsolicited NC status broadcasts so the UI reflects
        // changes made with the physical button even when no command is in flight.
        if responseData.count >= 5 && responseData[0] == 0x01 && responseData[1] == 0x06 {
            var ncByte: UInt8
            if responseData[2] == 0x04 && responseData.count == 5 {
                ncByte = responseData[4]
            } else if responseData[2] == 0x03 && responseData.count >= 5 {
                ncByte = responseData[4]
            } else {
                ncByte = responseData[4]
            }
            Task { @MainActor [weak self] in
                self?.ncLevel = NoiseCancellationLevel(byte: ncByte)
            }
        }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            isChannelReady = true
        } else {
            isChannelReady = false
        }
        channelOpenSemaphore?.signal()
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        print("RFCOMM channel closed")
        self.rfcommChannel = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only update if we currently show as connected. Clear both isConnected and
            // deviceName to stay consistent with the deviceDisconnected path (which clears
            // both); leaving deviceName set would show a phantom device with no channel.
            if self.isConnected {
                self.isConnected = false
                self.deviceName = nil
            }
        }
    }

    nonisolated func newRFCOMMChannelOpened(userNotification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        channel.setDelegate(self)
    }
}
