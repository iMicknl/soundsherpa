# CoreBluetooth GATT Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CoreBluetooth-backed BLE/GATT transport alongside the existing IOBluetooth RFCOMM transport, so a device whose control protocol runs over GATT (a possibility for Sennheiser HDB 630 / B&W Px7 S3) can drop into the existing `DeviceChannel` actor without rewriting the command-I/O core.

**Architecture:** The `DeviceChannel` actor already talks to hardware only through a narrow `write([UInt8])` / `close()` seam (today named `RFCOMMTransport`). That seam is genuinely transport-agnostic, so the actor, `ResponseMatcher`, and the plugins need *no* change. The work is entirely below the seam and beside it: (1) rename the seam to tell the truth (`DeviceTransport`), (2) carry a per-brand GATT service/characteristic descriptor as pure data, (3) write a `CoreBluetoothGATTTransport` adapter that mirrors the existing `IOBluetoothRFCOMMTransport`, (4) add a CoreBluetooth connection lifecycle (scan → connect → discover services/characteristics → subscribe) that produces a `DeviceChannel`, (5) route discovery to pick RFCOMM vs GATT per device and key device identity correctly (CoreBluetooth uses a per-Mac peripheral UUID, not a MAC address).

**Tech Stack:** Swift 6.2 (Swift 5 language mode), SwiftPM, `SoundSherpaCore` (pure, Foundation-only, unit-tested), `SoundSherpa` (AppKit + IOBluetooth + **CoreBluetooth** executable), XCTest.

## Global Constraints

- **Platform floor:** macOS 26 (`.macOS(.v26)` in `Package.swift`) — do not lower it.
- **Language mode:** Swift 5 (`swiftLanguageModes: [.v5]`) — do not change source to Swift 6 idioms that break this mode.
- **Core purity:** `SoundSherpaCore` imports **only Foundation** — no IOBluetooth, no CoreBluetooth, no AppKit. Anything touching CoreBluetooth lives in the `SoundSherpa` executable target.
- **No fabrication (R6/R7.3):** a missing reply is `nil`/throw, never an invented value. Transports throw `DeviceError`, they never silently succeed.
- **Build:** `swift build -c release`.
- **Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test` (CommandLineTools lacks XCTest).
- **Between GUI launches:** `pkill -9 -f SoundSherpa` to avoid orphaning the device's single control channel.
- **Hardware reality:** CoreBluetooth code cannot be exercised in XCTest. Tasks 1–2 are unit-tested in Core; Tasks 3–5 are verified manually against real hardware with a documented procedure. This mirrors the existing `IOBluetoothRFCOMMTransport`, which is also untested by design.

---

## File Structure

| File | Responsibility | Created/Modified |
|------|----------------|------------------|
| `Sources/SoundSherpaCore/DeviceChannel.swift` | Rename `RFCOMMTransport` → `DeviceTransport`; the actor is unchanged | Modify |
| `Sources/SoundSherpaCore/DeviceTransportDescriptor.swift` | Pure-data description of *how* to reach a device's control protocol (RFCOMM vs GATT + UUIDs) | Create |
| `Sources/SoundSherpaCore/DevicePlugin.swift` | Add a `transportDescriptor` requirement so a brand declares its transport | Modify |
| `Sources/SoundSherpaCore/BosePlugin.swift` | Declare the existing RFCOMM descriptor (no behavior change) | Modify |
| `Sources/SoundSherpa/IOBluetoothRFCOMMTransport.swift` | Update conformance to renamed seam (name of the adapter stays — it *is* RFCOMM) | Modify |
| `Sources/SoundSherpa/CoreBluetoothGATTTransport.swift` | `DeviceTransport` adapter over a `CBPeripheral` + write characteristic | Create |
| `Sources/SoundSherpa/GATTConnectionManager.swift` | `CBCentralManager` lifecycle: scan → connect → discover → subscribe → hand back a `DeviceChannel` + ingest stream | Create |
| `Tests/SoundSherpaCoreTests/ScriptedTransport.swift` | Update conformance to renamed seam | Modify |
| `Tests/SoundSherpaCoreTests/DeviceChannelTests.swift` | Update `FakeTransport` conformance to renamed seam | Modify |
| `Tests/SoundSherpaCoreTests/DeviceTransportDescriptorTests.swift` | Tests for the descriptor value type and plugin wiring | Create |
| `docs/superpowers/plans/2026-06-29-corebluetooth-gatt-transport.md` | This plan | Created |

---

## Task 0 (Spike): Confirm the target device's transport before building

**This is a gate, not throwaway code.** We do not yet know that any target device uses GATT — the Sennheiser GAIA evidence was *refuted* and B&W has no evidence (see `docs/multi-device-integration-research.md`). Do not build Tasks 3–5 against a device until this confirms GATT is the control transport.

- [ ] **Step 1: Capture the device's advertised services**

Pair the device, then in a scratch Swift file or `lldb` session enumerate both stacks:
- Classic/SDP: does it expose an SPP/serial service record (as Bose/Sony do)?
- BLE/GATT: scan with `CBCentralManager` and log advertised + discovered service UUIDs and each characteristic's properties (`read`/`write`/`writeWithoutResponse`/`notify`).

- [ ] **Step 2: Confirm WHERE control traffic flows**

Run a `PacketLogger` (Additional Tools for Xcode) capture while toggling ANC in the vendor app. Confirm the ANC command bytes travel over a **GATT characteristic write**, not an RFCOMM channel. A device can advertise BLE services (battery, fast-pair) while doing real control over RFCOMM — the capture must show the *control* path.

- [ ] **Step 3: Record the GATT profile**

Write down the concrete values for the descriptor in Task 2: control `serviceUUID`, `writeCharacteristicUUID`, `notifyCharacteristicUUID`, and whether writes are with/without response. **If control is RFCOMM, stop — this plan is not needed for that device; use the existing RFCOMM path instead.**

---

## Task 1: Rename the seam to `DeviceTransport`

The protocol contains no RFCOMM-specific member — only `write`/`close`. Renaming makes it honest that it already supports any byte transport, and is a pure rename with no behavior change. The existing `DeviceChannel` tests are the safety net.

**Files:**
- Modify: `Sources/SoundSherpaCore/DeviceChannel.swift:21-26` (protocol decl), `:36` (property type), `:56` (init param type)
- Modify: `Sources/SoundSherpaCore/DevicePlugin.swift:8` (doc comment mention)
- Modify: `Sources/SoundSherpa/IOBluetoothRFCOMMTransport.swift:5,12` (doc + conformance)
- Modify: `Tests/SoundSherpaCoreTests/ScriptedTransport.swift:4,7` (doc + conformance)
- Modify: `Tests/SoundSherpaCoreTests/DeviceChannelTests.swift:157,159` (doc + `FakeTransport` conformance)

**Interfaces:**
- Produces: `public protocol DeviceTransport: Sendable { func write(_ bytes: [UInt8]) async throws; func close() async }` — the renamed seam that every later task conforms to.

- [ ] **Step 1: Run the existing suite to establish a green baseline**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS (all existing tests green before any change).

- [ ] **Step 2: Rename the protocol declaration**

In `Sources/SoundSherpaCore/DeviceChannel.swift`, change the seam. Keep the doc comment but drop the RFCOMM-only framing:

```swift
/// The narrow seam through which `DeviceChannel` talks to a real device link. It carries no
/// transport specifics — only "write these bytes" and "close" — so the actor's
/// serialization/timeout/close logic is unit-tested against a fake and any concrete link
/// (IOBluetooth RFCOMM, CoreBluetooth GATT, a mock) drops in without touching the actor.
///
/// Incoming bytes are NOT part of this protocol: the real adapter receives them on its
/// delegate callback and forwards them to `DeviceChannel.ingest(_:)`.
public protocol DeviceTransport: Sendable {
    /// Write a command's bytes to the link. Throws if the link can't accept them.
    func write(_ bytes: [UInt8]) async throws
    /// Tear down the underlying link.
    func close() async
}
```

- [ ] **Step 3: Update the actor's references**

In the same file, change the stored property and initializer parameter:

```swift
    private let transport: DeviceTransport
```

```swift
    public init(transport: DeviceTransport) {
        self.transport = transport
    }
```

- [ ] **Step 4: Update all conformances and the doc mention**

`Sources/SoundSherpa/IOBluetoothRFCOMMTransport.swift:12` — note the *adapter* keeps its RFCOMM name because it genuinely is RFCOMM:

```swift
final class IOBluetoothRFCOMMTransport: DeviceTransport, @unchecked Sendable {
```

`Tests/SoundSherpaCoreTests/ScriptedTransport.swift:7`:

```swift
actor ScriptedTransport: DeviceTransport {
```

`Tests/SoundSherpaCoreTests/DeviceChannelTests.swift:159`:

```swift
private actor FakeTransport: DeviceTransport {
```

In `Sources/SoundSherpaCore/DevicePlugin.swift:8`, change the words "the `RFCOMMTransport` that moves bytes" to "the `DeviceTransport` that moves bytes".

- [ ] **Step 5: Confirm no stragglers remain**

Run: `grep -rn "RFCOMMTransport" Sources Tests`
Expected: only `IOBluetoothRFCOMMTransport` (the concrete adapter type and its filename) appears; the bare protocol name `RFCOMMTransport` appears nowhere.

- [ ] **Step 6: Build and run the full suite — behavior must be identical**

Run: `swift build -c release && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS (same tests as Step 1, proving the rename changed nothing).

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceChannel.swift Sources/SoundSherpaCore/DevicePlugin.swift Sources/SoundSherpa/IOBluetoothRFCOMMTransport.swift Tests/SoundSherpaCoreTests/ScriptedTransport.swift Tests/SoundSherpaCoreTests/DeviceChannelTests.swift
git commit -m "refactor(core): rename RFCOMMTransport seam to DeviceTransport"
```

---

## Task 2: Add a pure-data transport descriptor and have plugins declare it

A brand must be able to say "reach me over RFCOMM/SPP" or "reach me over GATT on these UUIDs." This is pure data, lives in Core, and is unit-tested. It is what the connection layer (Task 5) reads to decide which transport to build.

**Files:**
- Create: `Sources/SoundSherpaCore/DeviceTransportDescriptor.swift`
- Modify: `Sources/SoundSherpaCore/DevicePlugin.swift` (add `transportDescriptor` requirement)
- Modify: `Sources/SoundSherpaCore/BosePlugin.swift` (declare `.classicRFCOMM`)
- Test: `Tests/SoundSherpaCoreTests/DeviceTransportDescriptorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum DeviceTransportDescriptor: Sendable, Equatable` with cases `.classicRFCOMM` and `.bleGATT(GATTProfile)`.
  - `public struct GATTProfile: Sendable, Equatable` with `serviceUUID: String`, `writeCharacteristicUUID: String`, `notifyCharacteristicUUID: String`, `writeWithResponse: Bool`, and a memberwise `public init`.
  - `DevicePlugin` gains `var transportDescriptor: DeviceTransportDescriptor { get }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/DeviceTransportDescriptorTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceTransportDescriptorTests: XCTestCase {

    func testBosePluginDeclaresClassicRFCOMM() {
        XCTAssertEqual(BosePlugin().transportDescriptor, .classicRFCOMM)
    }

    func testGATTProfileCarriesServiceAndCharacteristicUUIDs() {
        let profile = GATTProfile(
            serviceUUID: "A2129FF3-081B-4C45-8AFE-469D9C4842EC",
            writeCharacteristicUUID: "A2129FF4-081B-4C45-8AFE-469D9C4842EC",
            notifyCharacteristicUUID: "A2129FF5-081B-4C45-8AFE-469D9C4842EC",
            writeWithResponse: false
        )
        let descriptor = DeviceTransportDescriptor.bleGATT(profile)

        guard case let .bleGATT(p) = descriptor else {
            return XCTFail("expected .bleGATT case")
        }
        XCTAssertEqual(p.serviceUUID, "A2129FF3-081B-4C45-8AFE-469D9C4842EC")
        XCTAssertEqual(p.writeCharacteristicUUID, "A2129FF4-081B-4C45-8AFE-469D9C4842EC")
        XCTAssertEqual(p.notifyCharacteristicUUID, "A2129FF5-081B-4C45-8AFE-469D9C4842EC")
        XCTAssertFalse(p.writeWithResponse)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceTransportDescriptorTests`
Expected: FAIL — `GATTProfile`/`DeviceTransportDescriptor` undefined and `BosePlugin` has no `transportDescriptor`.

- [ ] **Step 3: Create the descriptor types**

Create `Sources/SoundSherpaCore/DeviceTransportDescriptor.swift`:

```swift
import Foundation

/// Pure-data description of HOW to reach a device's control protocol. A plugin returns one
/// of these so the connection layer knows which concrete transport to build — without the
/// connection layer hard-coding brand knowledge. RFCOMM needs no parameters (the SDP query
/// finds the channel); GATT needs the exact service/characteristic UUIDs because BLE has no
/// equivalent of SDP channel discovery for an opaque control protocol.
public enum DeviceTransportDescriptor: Sendable, Equatable {
    /// Bluetooth Classic SPP/RFCOMM — the channel is found via SDP at connect time.
    case classicRFCOMM
    /// Bluetooth Low Energy GATT — control runs over the named characteristics.
    case bleGATT(GATTProfile)
}

/// The service and characteristics that carry a GATT control protocol. UUIDs are strings so
/// Core stays Foundation-only (CoreBluetooth's `CBUUID` is constructed in the app target).
public struct GATTProfile: Sendable, Equatable {
    /// The GATT service that owns the control characteristics.
    public let serviceUUID: String
    /// Characteristic the app writes command bytes to.
    public let writeCharacteristicUUID: String
    /// Characteristic the app subscribes to for reply/notification bytes.
    public let notifyCharacteristicUUID: String
    /// True → write-with-response (`.withResponse`); false → write-without-response.
    public let writeWithResponse: Bool

    public init(serviceUUID: String,
                writeCharacteristicUUID: String,
                notifyCharacteristicUUID: String,
                writeWithResponse: Bool) {
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUID = notifyCharacteristicUUID
        self.writeWithResponse = writeWithResponse
    }
}
```

- [ ] **Step 4: Add the requirement to the plugin protocol**

In `Sources/SoundSherpaCore/DevicePlugin.swift`, add to the protocol body (after `identifier`):

```swift
    /// How this brand's control protocol is reached. The connection layer reads this to
    /// build the right transport (RFCOMM vs GATT) without embedding brand knowledge.
    var transportDescriptor: DeviceTransportDescriptor { get }
```

- [ ] **Step 5: Declare Bose's descriptor**

In `Sources/SoundSherpaCore/BosePlugin.swift`, add the property to the struct (Bose is RFCOMM, so no behavior changes):

```swift
    public var transportDescriptor: DeviceTransportDescriptor { .classicRFCOMM }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS — new descriptor tests green, all existing tests still green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceTransportDescriptor.swift Sources/SoundSherpaCore/DevicePlugin.swift Sources/SoundSherpaCore/BosePlugin.swift Tests/SoundSherpaCoreTests/DeviceTransportDescriptorTests.swift
git commit -m "feat(core): add DeviceTransportDescriptor so plugins declare RFCOMM vs GATT"
```

---

## Task 3: Write the `CoreBluetoothGATTTransport` adapter

This mirrors `IOBluetoothRFCOMMTransport` exactly: a thin `@unchecked Sendable` class that satisfies the `DeviceTransport` seam by writing to a held CoreBluetooth write characteristic. It lives in the app target (imports CoreBluetooth) and is verified manually, just like its RFCOMM sibling.

**Files:**
- Create: `Sources/SoundSherpa/CoreBluetoothGATTTransport.swift`
- Reference (do not modify): `Sources/SoundSherpa/IOBluetoothRFCOMMTransport.swift:12-32` (the pattern to follow)

**Interfaces:**
- Consumes: `DeviceTransport` (Task 1), `GATTProfile.writeWithResponse` (Task 2).
- Produces: `final class CoreBluetoothGATTTransport: DeviceTransport, @unchecked Sendable` with `init(peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic, writeWithResponse: Bool)`. Task 4 constructs it after characteristic discovery.

- [ ] **Step 1: Create the adapter**

Create `Sources/SoundSherpa/CoreBluetoothGATTTransport.swift`:

```swift
import Foundation
import CoreBluetooth
import SoundSherpaCore

/// Adapts a CoreBluetooth GATT write characteristic to the brand-agnostic `DeviceTransport`
/// seam the `DeviceChannel` actor writes through. The GATT analogue of
/// `IOBluetoothRFCOMMTransport`: where RFCOMM is a byte pipe, GATT writes target a specific
/// characteristic, so this holds the resolved write characteristic and converts the actor's
/// `[UInt8]` into a `Data` write. Incoming bytes are NOT handled here — the peripheral
/// delegate forwards notification updates to `DeviceChannel.ingest` (see GATTConnectionManager).
///
/// `@unchecked Sendable`: `CBPeripheral`/`CBCharacteristic` predate Sendable; we only ever
/// read immutable references and CoreBluetooth tolerates writes from a serialized context
/// (the `DeviceChannel` actor serializes all sends).
final class CoreBluetoothGATTTransport: DeviceTransport, @unchecked Sendable {
    private let peripheral: CBPeripheral
    private let writeCharacteristic: CBCharacteristic
    private let writeType: CBCharacteristicWriteType

    init(peripheral: CBPeripheral,
         writeCharacteristic: CBCharacteristic,
         writeWithResponse: Bool) {
        self.peripheral = peripheral
        self.writeCharacteristic = writeCharacteristic
        self.writeType = writeWithResponse ? .withResponse : .withoutResponse
    }

    func write(_ bytes: [UInt8]) async throws {
        guard peripheral.state == .connected else { throw DeviceError.channelClosed }
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: writeType)
    }

    func close() async {
        // The central owns the connection lifecycle; the transport only stops writing.
        // GATTConnectionManager calls cancelPeripheralConnection on teardown.
    }
}
```

- [ ] **Step 2: Build to verify it compiles against the seam**

Run: `swift build -c release`
Expected: SUCCESS — the class satisfies `DeviceTransport` and CoreBluetooth imports resolve.

- [ ] **Step 3: Confirm the existing suite is unaffected**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS — Core tests are independent of the app target; this proves no regression.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/CoreBluetoothGATTTransport.swift
git commit -m "feat(app): add CoreBluetoothGATTTransport adapter for the DeviceTransport seam"
```

---

## Task 4: Add the CoreBluetooth connection lifecycle

CoreBluetooth has no SDP/channel-ID flow. Connecting is a multi-step async dance: power-on the central → scan for the service UUID → connect → discover services → discover characteristics → subscribe to the notify characteristic → only then is the link usable. This manager runs that dance and, on success, builds a `CoreBluetoothGATTTransport` + `DeviceChannel` and pumps notification bytes into `ingest` via the same single-consumer `AsyncStream` pattern AppDelegate already uses for RFCOMM (`AppDelegate.swift:1483-1490`).

**Files:**
- Create: `Sources/SoundSherpa/GATTConnectionManager.swift`
- Reference (do not modify): `Sources/SoundSherpa/AppDelegate.swift:1476-1491` (the `attachChannel` ingest-stream pattern to replicate), `:1898-1907` (the delegate→`ingestContinuation.yield` pattern)

**Interfaces:**
- Consumes: `GATTProfile` (Task 2), `CoreBluetoothGATTTransport` (Task 3), `DeviceChannel` + `DeviceTransport` (Task 1).
- Produces: `final class GATTConnectionManager: NSObject` with
  - `init(profile: GATTProfile)`
  - `func connect(completion: @escaping (Result<GATTConnection, Error>) -> Void)`
  - `func disconnect()`
  - and a value `struct GATTConnection { let channel: DeviceChannel; let peripheralUUID: String }` that Task 5 consumes. `peripheralUUID` is the CoreBluetooth per-Mac identity used as the metadata-store key.

- [ ] **Step 1: Create the connection manager**

Create `Sources/SoundSherpa/GATTConnectionManager.swift`:

```swift
import Foundation
import CoreBluetooth
import SoundSherpaCore

/// The successful result of a GATT connect: a ready `DeviceChannel` plus the peripheral's
/// CoreBluetooth identity. NOTE: `peripheralUUID` is a per-Mac UUID assigned by CoreBluetooth,
/// NOT a Bluetooth MAC address — it is stable on this machine but differs across machines,
/// so it must not be treated as portable hardware identity.
struct GATTConnection {
    let channel: DeviceChannel
    let peripheralUUID: String
}

/// Drives the CoreBluetooth connect lifecycle for one GATT control device and, on success,
/// wraps it in a `DeviceChannel`. This is the GATT analogue of AppDelegate's RFCOMM
/// connect/attach flow; it deliberately owns ONLY the BLE lifecycle so the actor/plugin
/// layers above the `DeviceTransport` seam stay untouched.
final class GATTConnectionManager: NSObject {
    private let profile: GATTProfile
    private let serviceUUID: CBUUID
    private let writeUUID: CBUUID
    private let notifyUUID: CBUUID

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var completion: ((Result<GATTConnection, Error>) -> Void)?

    private var deviceChannel: DeviceChannel?
    private var ingestContinuation: AsyncStream<[UInt8]>.Continuation?

    init(profile: GATTProfile) {
        self.profile = profile
        self.serviceUUID = CBUUID(string: profile.serviceUUID)
        self.writeUUID = CBUUID(string: profile.writeCharacteristicUUID)
        self.notifyUUID = CBUUID(string: profile.notifyCharacteristicUUID)
        super.init()
    }

    /// Begin the connect dance. `completion` fires exactly once: success after the notify
    /// subscription is live, or failure on power-off/timeout/disconnect.
    func connect(completion: @escaping (Result<GATTConnection, Error>) -> Void) {
        self.completion = completion
        // Creating the central with self as delegate kicks off centralManagerDidUpdateState,
        // which starts the scan once Bluetooth is powered on.
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func disconnect() {
        ingestContinuation?.finish()
        ingestContinuation = nil
        if let channel = deviceChannel {
            Task { await channel.close() }
        }
        deviceChannel = nil
        if let central = central, let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
    }

    private func finish(_ result: Result<GATTConnection, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

extension GATTConnectionManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        case .poweredOff, .unauthorized, .unsupported:
            finish(.failure(DeviceError.notConnected))
        default:
            break // .resetting / .unknown — wait for the next state update
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        finish(.failure(error ?? DeviceError.notConnected))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        ingestContinuation?.finish()
        ingestContinuation = nil
        if let channel = deviceChannel {
            Task { await channel.close() }
        }
        deviceChannel = nil
    }
}

extension GATTConnectionManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            return finish(.failure(DeviceError.notConnected))
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil,
              let characteristics = service.characteristics,
              let writeChar = characteristics.first(where: { $0.uuid == writeUUID }),
              let notifyChar = characteristics.first(where: { $0.uuid == notifyUUID }) else {
            return finish(.failure(DeviceError.notConnected))
        }
        // Subscribe first; readiness is confirmed in didUpdateNotificationStateFor.
        peripheral.setNotifyValue(true, for: notifyChar)

        let transport = CoreBluetoothGATTTransport(
            peripheral: peripheral,
            writeCharacteristic: writeChar,
            writeWithResponse: profile.writeWithResponse
        )
        let channel = DeviceChannel(transport: transport)
        self.deviceChannel = channel

        // Single-consumer ingest stream, mirroring AppDelegate.attachChannel for RFCOMM:
        // notification bytes are yielded in arrival order and drained into the actor.
        let stream = AsyncStream<[UInt8]> { continuation in
            self.ingestContinuation = continuation
        }
        Task {
            for await chunk in stream {
                await channel.ingest(chunk)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        guard error == nil, let channel = deviceChannel else {
            return finish(.failure(error ?? DeviceError.notConnected))
        }
        // Notify subscription is live → the link is usable.
        finish(.success(GATTConnection(channel: channel,
                                       peripheralUUID: peripheral.identifier.uuidString)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == notifyUUID,
              let value = characteristic.value else { return }
        // Forward reply/notification bytes to the actor, in arrival order (R7.1).
        ingestContinuation?.yield([UInt8](value))
    }
}
```

- [ ] **Step 2: Build to verify the lifecycle compiles**

Run: `swift build -c release`
Expected: SUCCESS — all CoreBluetooth delegate conformances satisfied.

- [ ] **Step 3: Confirm Core suite still green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS.

- [ ] **Step 4: Add the Bluetooth usage description (required or CoreBluetooth aborts at runtime)**

CoreBluetooth requires `NSBluetoothAlwaysUsageDescription` in the app's `Info.plist`, or the first `CBCentralManager` use crashes. Confirm `build.sh` / the bundle's `Info.plist` includes it; if absent, add:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>SoundSherpa connects to your headphones to read and adjust their settings.</string>
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/GATTConnectionManager.swift
git commit -m "feat(app): add GATTConnectionManager CoreBluetooth connect lifecycle"
```

---

## Task 5: Route discovery by transport and key GATT identity correctly

Wire the descriptor through the connect path: when the resolved plugin declares `.bleGATT`, use `GATTConnectionManager`; otherwise keep the existing RFCOMM flow untouched. Then key the metadata store by the right identity — CoreBluetooth peripherals have no MAC address, so the per-Mac peripheral UUID string becomes the cache key.

**Files:**
- Modify: `Sources/SoundSherpa/AppDelegate.swift` — branch on `activePlugin?.transportDescriptor` at the connect site (around the SDP/RFCOMM path beginning near `:1332`), store a `GATTConnectionManager`, and use `GATTConnection.peripheralUUID` as the metadata key for GATT devices.
- Reference (do not modify): `Sources/SoundSherpaCore/DeviceMetadata.swift:81-93` (the store is keyed by an opaque `String` — a UUID string is a valid key).

**Interfaces:**
- Consumes: `DeviceTransportDescriptor` + `transportDescriptor` (Task 2), `GATTConnectionManager` + `GATTConnection` (Task 4).
- Produces: no new public API; AppDelegate now selects transport per device.

- [ ] **Step 1: Hold a GATT manager reference**

In `AppDelegate.swift`, beside `private var deviceChannel: DeviceChannel?` (`:94`), add:

```swift
    // Retains the CoreBluetooth lifecycle for a GATT-control device; nil for RFCOMM devices.
    private var gattManager: GATTConnectionManager?
```

- [ ] **Step 2: Branch the connect path on the descriptor**

At the point where `activePlugin` is resolved and the code is about to begin the SDP/RFCOMM flow (after `:1311-1313`), branch before `performSDPQuery`:

```swift
        if case let .bleGATT(profile) = activePlugin?.transportDescriptor {
            connectOverGATT(profile: profile)
            return true
        }
        // else: fall through to the existing RFCOMM/SDP path unchanged.
```

- [ ] **Step 3: Add the GATT connect helper that reuses the actor + plugin layers**

Add to `AppDelegate.swift`. This sets `deviceChannel` (same property the rest of the app already drives through `activePlugin`) and keys metadata by the peripheral UUID:

```swift
    /// Connect a GATT-control device. On success this populates `deviceChannel` exactly like
    /// the RFCOMM path, so battery/metadata reads through `activePlugin` work unchanged — the
    /// only difference is the transport beneath the actor and the identity used for caching.
    private func connectOverGATT(profile: GATTProfile) {
        let manager = GATTConnectionManager(profile: profile)
        self.gattManager = manager
        manager.connect { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let connection):
                self.deviceChannel = connection.channel
                // CoreBluetooth identity is the per-Mac peripheral UUID, not a MAC address.
                self.deviceAddress = connection.peripheralUUID
                self.applyCachedMetadata(for: connection.peripheralUUID)
            case .failure:
                self.gattManager = nil
            }
        }
    }
```

> If `applyCachedMetadata` currently takes an `IOBluetoothDevice` rather than an address string, add a small overload that accepts the address key directly; the store lookup at `DeviceMetadata.swift:81` only needs the `String`.

- [ ] **Step 4: Tear the GATT manager down on close**

In `closeChannelLocked()` (`:1509-1524`), after the existing `deviceChannel = nil` handling, add:

```swift
        gattManager?.disconnect()
        gattManager = nil
```

- [ ] **Step 5: Build**

Run: `swift build -c release`
Expected: SUCCESS.

- [ ] **Step 6: Run the full Core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS — no Core regressions (this task only changes app wiring).

- [ ] **Step 7: Manual hardware verification (the only way to test CoreBluetooth)**

This requires a confirmed-GATT device from Task 0 and a temporary plugin returning `.bleGATT(profile)` with that device's real UUIDs.

```bash
pkill -9 -f SoundSherpa            # never leave a stale instance holding the link
swift build -c release && ./build.sh
codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app
open SoundSherpa.app
```

Verify, against the file logger (Swift `print` is unreliable for a GUI-launched app — see build/test notes):
1. Bluetooth permission prompt appears once, then the scan finds the peripheral.
2. The log shows service + both characteristics discovered and the notify subscription going live.
3. A battery/ANC query issued through `activePlugin` returns a real decoded value (proves write → notify → `ingest` → `ResponseMatcher` round-trips over GATT).
4. Quitting the app calls `disconnect()` and the peripheral shows disconnected (no orphaned link).

- [ ] **Step 8: Commit**

```bash
git add Sources/SoundSherpa/AppDelegate.swift
git commit -m "feat(app): route connect by transport descriptor and key GATT identity by peripheral UUID"
```

---

## What deliberately does NOT change (the payoff)

Holding the seam at `write([UInt8])` / `close()` means these are untouched by the entire plan:
- **`DeviceChannel` actor** — serialization, timeout, close, the R7.1 reliability guarantee.
- **`ResponseMatcher`** — `.prefix` / `.collecting` strategies work on GATT notification bytes exactly as on RFCOMM chunks. (A brand whose GATT frames are length-prefixed would add a *new matcher strategy*, but that is brand work, not transport work.)
- **`DevicePlugin` / `BosePlugin` battery & metadata reads** — they call `channel.send(...)`; they never know which transport is beneath.
- **The menu/UI layer** — reads through `activePlugin` + `deviceChannel`.

The cost of GATT is concentrated in exactly three places, which is the answer to "why is GATT an issue": a **different connect lifecycle** (scan/discover/subscribe vs SDP/channel-ID), a **write that targets a characteristic** rather than a pipe, and a **different identity** (per-Mac peripheral UUID vs MAC address). Everything above the seam is reused.

---

## Self-Review

- **Spec coverage:** Task 0 gates on confirming transport (the research's open question for Sennheiser/B&W); Task 1 generalizes the seam; Task 2 carries the GATT UUIDs as data; Task 3 is the write-to-characteristic adapter; Task 4 is the scan/discover/subscribe lifecycle; Task 5 is per-device routing + identity keying. The three GATT-specific costs called out in the research (lifecycle, characteristic-targeted write, identity model) each map to a task. ✓
- **Type consistency:** `DeviceTransport` (Task 1) is the conformance target in Tasks 3–4. `GATTProfile` fields (`serviceUUID`, `writeCharacteristicUUID`, `notifyCharacteristicUUID`, `writeWithResponse`) defined in Task 2 are consumed verbatim in Tasks 3 (`writeWithResponse`) and 4 (all four). `GATTConnection { channel, peripheralUUID }` (Task 4) is consumed in Task 5. ✓
- **Placeholders:** none — every code step shows full code; every test step shows the assertion and the exact run command + expected result. The one conditional (`applyCachedMetadata` overload in Task 5 Step 3) is flagged with its rationale rather than left vague. ✓
- **Honesty about testing:** Tasks 1–2 are XCTest-verified in Core; Tasks 3–5 are build-verified + manually verified, matching the existing untested `IOBluetoothRFCOMMTransport` precedent. Stated explicitly in Global Constraints. ✓
