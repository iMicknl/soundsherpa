import AppKit
import Foundation
@preconcurrency import IOBluetooth
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

    // Which controls the active device exposes; drives UI gating. Empty when disconnected.
    var supportedFeatures: Set<DeviceFeature> = []

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
        // DEADLOCK GUARD (do not inline back onto the main thread): the FIRST IOBluetooth
        // call lazily cold-inits `IOBluetoothCoreBluetoothCoordinator`, which spins up a
        // CBCentralManager and blocks on a semaphore until CoreBluetooth delivers its first
        // state update — and that update is dispatched on the MAIN queue. If the first call
        // runs on the main thread (here, inside applicationDidFinishLaunching), the main queue
        // is parked inside that semaphore wait, the state callback can never run, and the app
        // hangs with the menu showing nothing. (Confirmed via a main-thread stack sample:
        // registerForConnectNotifications → coordinator init → semaphore_wait_trap.) It was
        // intermittent only because a background `pairedDevices()` sometimes warmed the
        // coordinator first. So warm it OFF the main thread, leaving the main run loop free to
        // service the callback, then finish setup on the main thread once it's ready.
        connectionQueue.async { [weak self] in
            _ = IOBluetoothDevice.pairedDevices()   // forces coordinator cold-init off-main
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishStartMonitoring() }
            }
        }
    }

    /// Second half of `startMonitoring`, run on the main thread after the IOBluetooth
    /// coordinator has been warmed off-main. Registering the connect/disconnect notifications
    /// must happen on a thread with a live run loop (the main thread), or the callbacks never
    /// fire — hence this can't move onto `connectionQueue`.
    private func finishStartMonitoring() {
        setupBluetoothNotifications()
        setupSleepWakeNotifications()
        checkForSupportedDevices()

        // Periodic rescan/reconnect every 30s (matches the original AppDelegate). The timer
        // is scheduled on the main run loop, so the closure always fires on the main thread;
        // `assumeIsolated` lets us call the @MainActor members directly without an async hop
        // that could reorder relative to the synchronous teardown in shutDown().
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForSupportedDevices()
            }
        }

        // Poll noise-cancellation status every 10s while connected.
        ncPollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isConnected {
                    self.detectDeviceStateAsync()
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
    /// already have one registered.
    ///
    /// MUST register on the MAIN thread: IOBluetooth user-notification callbacks are delivered
    /// on the run loop of the thread that registered them, and `connectionQueue` (the usual
    /// caller, via `connectToBoseDeviceSync`) is a GCD worker with NO run loop — same hazard as
    /// the startup-deadlock fix. A disconnect notification armed there never fires, so a power-off
    /// surfaces only on the next 30s scan instead of immediately. Marshalling onto the main run
    /// loop (where the connect notification is also registered) makes `deviceDisconnected` fire
    /// directly. Routing the nil-check through the main thread too keeps the single-registration
    /// guard race-free. Touches only the `nonisolated(unsafe)` `disconnectionNotification`.
    nonisolated private func setupDeviceSpecificNotifications(for device: IOBluetoothDevice) {
        if Thread.isMainThread {
            armDisconnectNotification(for: device)
        } else {
            DispatchQueue.main.async { [weak self] in self?.armDisconnectNotification(for: device) }
        }
    }

    /// Register the disconnect notification on the main run loop. Always called on the main
    /// thread (see `setupDeviceSpecificNotifications`). The `nil` guard makes registration
    /// idempotent; running it on a single thread keeps that guard race-free. `nonisolated`
    /// because it touches only the `nonisolated(unsafe)` `disconnectionNotification`, like the
    /// rest of the channel/notification state in this file.
    nonisolated private func armDisconnectNotification(for device: IOBluetoothDevice) {
        guard disconnectionNotification == nil else { return }
        disconnectionNotification = device.register(forDisconnectNotification: self,
                                                    selector: #selector(deviceDisconnected(_:device:)))
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
        checkForSupportedDevices()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Just note that a Bose device connected and arm its disconnect notification; don't
        // interfere with normal operation.
        if isSupportedDevice(device) {
            print("Bose device connected: \(device.name ?? "Unknown")")
            currentBoseDevice = device
            setupDeviceSpecificNotifications(for: device)
            // Reconnect (e.g. after a Bluetooth toggle, or powering the headphones on) should
            // surface in the UI immediately, not on the next 30s scan tick. The connection may
            // be stale relative to our cache, so force a fresh fetch, then re-scan now.
            lastDataFetchTime = nil
            checkForSupportedDevices()
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Only act on disconnection of our current device.
        if isSupportedDevice(device) && currentBoseDevice?.addressString == device.addressString {
            print("Bose device disconnected: \(device.name ?? "Unknown")")
            currentBoseDevice = nil
            disconnectionNotification = nil // Clear the notification

            // Release our RFCOMM channel so we don't hold the device's single control
            // channel half-open — otherwise the next connect is refused.
            closeChannel()

            // Reflect disconnected state in the UI.
            self.isConnected = false
            self.deviceName = nil
            self.batteryLevel = nil
            self.supportedFeatures = []
        }
    }

    nonisolated private func isSupportedDevice(_ device: IOBluetoothDevice) -> Bool {
        guard let name = device.name else { return false }
        return deviceRegistry.plugin(forDeviceNamed: name) != nil
    }

    // MARK: - Intents

    /// Apply a typed change through the active plugin over the serialized channel. Returns
    /// whether it was acknowledged. Mirrors the old per-intent send, but brand-agnostic.
    private func applyChange(_ change: DeviceChange) async -> Bool {
        guard await ensureConnected(), let plugin = activePlugin, let channel = deviceChannel else {
            return false
        }
        return await plugin.apply(change, over: channel)
    }

    func setNoiseCancellation(_ level: NoiseCancellationLevel) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.noiseCancellation(level)) {
                self.ncLevel = level
            }
        }
    }

    func setSelfVoice(_ level: SelfVoiceLevel) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.selfVoice(level)) {
                self.selfVoiceLevel = level
            }
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
            guard let self else { return }
            if await self.applyChange(.autoOff(value)) {
                self.autoOff = value
            }
        }
    }

    func setLanguage(_ value: PromptLanguage) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.promptLanguage(value)) {
                self.language = value
            }
        }
    }

    func setVoicePrompts(_ on: Bool) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.voicePrompts(on)) {
                self.voicePromptsEnabled = on
            }
        }
    }

    func setButtonAction(_ value: ButtonAction) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.buttonAction(value)) {
                self.buttonAction = value
            }
        }
    }

    // MARK: - Device Discovery

    func checkForSupportedDevices() {
        print("Checking for supported devices...")

        if let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in pairedDevices {
                guard let name = device.name,
                      let plugin = deviceRegistry.plugin(forDeviceNamed: name),
                      device.isConnected() else { continue }

                print("Found connected supported device: \(name) [\(plugin.identifier)]")
                self.deviceAddress = device.addressString
                self.activePlugin = plugin

                let sdpMeta = self.sdpMetadata(for: device)
                if !sdpMeta.isEmpty, let address = device.addressString {
                    self.metadataStore.put(sdpMeta, for: address)
                }

                self.deviceName = name
                self.isConnected = true
                if let address = device.addressString {
                    self.applyCachedMetadata(for: address)
                }

                self.detectDeviceStateAsync()
                return
            }
        }

        self.isConnected = false
        self.deviceName = nil
        self.batteryLevel = nil
    }

    private func detectDeviceStateAsync() {
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

            guard self.connectSupportedDeviceSync(address: deviceAddr) else {
                print(">>> Connection failed — control channel not open; will retry on next command/scan")
                // Do not flip isConnected: the device is still connected at the OS level and
                // the UI should stay visible. ensureConnected retries the channel when the
                // user next sends a command, and the periodic scan retries detection.
                return
            }
            print(">>> Connection successful, initializing Bose protocol...")

            Task { [weak self] in
                guard let self else { return }
                print(">>> Fetching device info...")
                await self.fetchAllDeviceInfo()
            }
        }
    }

    /// Find the first SDP service record matching any of the descriptor's matchers, in order.
    nonisolated private func serviceRecord(matching matchers: [ServiceMatcher],
                                           in records: [IOBluetoothSDPServiceRecord]) -> IOBluetoothSDPServiceRecord? {
        for matcher in matchers {
            switch matcher {
            case .serviceName(let wanted):
                if let r = records.first(where: { $0.getServiceName() == wanted }) { return r }
            case .uuid(let uuidString):
                // 16-bit short form, e.g. "0x1101" (Bose SPP): match directly.
                if uuidString.hasPrefix("0x"), let v = UInt16(uuidString.dropFirst(2), radix: 16) {
                    for record in records {
                        if record.matchesUUID16(v) { return record }
                    }
                    continue
                }
                // 128-bit vendor UUID (e.g. Sony's V1/V2 service UUIDs): build an
                // IOBluetoothSDPUUID and match it against each record's service UUIDs.
                if let uuid = UUID(uuidString: uuidString) {
                    var uuidBytes = uuid.uuid
                    let data = withUnsafePointer(to: &uuidBytes) { ptr in
                        Data(bytes: ptr, count: MemoryLayout<uuid_t>.size)
                    }
                    let btUUID = IOBluetoothSDPUUID(bytes: (data as NSData).bytes, length: data.count)
                    for record in records {
                        if record.hasService(from: [btUUID]) { return record }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private func connectSupportedDeviceSync(address: String) -> Bool {
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
            return isSupportedDevice(device)
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

        let matchers = activePlugin?.discoveryDescriptor.serviceMatchers
            ?? [.serviceName("SPP Dev"), .uuid("0x1101")]
        if let service = serviceRecord(matching: matchers, in: services) {
            return connectToService(device: device, service: service)
        }
        // Last-resort fallback preserved from the old code: any serial/SPP-named service.
        if let anySerialService = services.first(where: {
            let n = $0.getServiceName() ?? ""
            return n.lowercased().contains("spp") || n.lowercased().contains("serial")
        }) {
            return connectToService(device: device, service: anySerialService)
        }
        return false
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

        let channelIdsToTry: [BluetoothRFCOMMChannelID] =
            (activePlugin?.discoveryDescriptor.channelHints ?? [8, 9, 1, 2, 3])
            .map { BluetoothRFCOMMChannelID($0) }
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

    // MARK: - Fetch All Device Info

    private func fetchAllDeviceInfo() async {
        guard shouldFetchFreshData() else { return }
        guard let plugin = activePlugin, let channel = deviceChannel else { return }

        self.supportedFeatures = plugin.supportedFeatures

        // Static metadata (firmware/serial/model) via the plugin; persists by address.
        let metadata = await plugin.readMetadata(over: channel)
        storeMetadata(metadata)
        if let fw = metadata.firmware { self.firmware = fw }
        if let serial = metadata.serial { self.serial = serial }
        if let modelId = metadata.modelId { self.deviceId = String(format: "Bose 0x%04X", modelId) }

        // Mutable feature state via the plugin, fanned out to the observable properties.
        let state = await plugin.readState(over: channel)
        if let v = state.battery { self.batteryLevel = v }
        if let v = state.noiseCancellationLevel { self.ncLevel = v }
        if let v = state.selfVoice { self.selfVoiceLevel = v }
        if let v = state.autoOff { self.autoOff = v }
        if let v = state.buttonAction { self.buttonAction = v }
        if let v = state.promptLanguage { self.language = v }
        if let v = state.voicePromptsEnabled { self.voicePromptsEnabled = v }

        markDataAsFetched()

        // Paired-device management stays controller-side for this sub-project.
        await fetchPairedDevices()
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
                let result = self?.connectSupportedDeviceSync(address: deviceAddr) ?? false
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
        if activePlugin?.identifier == "Bose",
           responseData.count >= 5, responseData[0] == 0x01, responseData[1] == 0x06 {
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
                self.batteryLevel = nil
                self.supportedFeatures = []
            }
        }
    }

    nonisolated func newRFCOMMChannelOpened(userNotification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        channel.setDelegate(self)
    }
}
