# Design: Multi-Device & Reliability

## Overview

This design turns SoundSherpa from one ~2,700-line `AppDelegate` into a layered, modular app.
The guiding split:

- **Transport** (`DeviceChannel`) — the *only* code that touches `IOBluetooth` RFCOMM. An actor
  that serializes commands. This layer is where reliability is won.
- **Codec** — pure `Foundation`-only functions: typed command → bytes, bytes → typed result.
  This layer is where testability is won.
- **Plugin** — per-brand logic (identification, capabilities, command orchestration) behind the
  `DevicePlugin` protocol. This layer is where modularity is won.
- **App/UI** — `AppDelegate`, `ConnectionManager`, `DeviceRegistry`, `MenuController`. Brand-
  agnostic; talks only to the `DevicePlugin` interface.

It deliberately differs from the original draft per decisions D1–D7 in requirements.md:
compiled-in plugins (not dynamic), no `system_profiler`, actor-based async, pure codec test seam,
reliability as a requirement, untested models aspirational, settings deferred.

## Architecture

```
┌────────────────────────────────────────────┐
│ App / UI (brand-agnostic)                    │
│  AppDelegate · ConnectionManager             │
│  DeviceRegistry · MenuController             │
└───────────────┬──────────────────────────────┘
                │ DevicePlugin protocol
┌───────────────▼──────────────────────────────┐
│ Plugins (compiled-in)                         │
│  BosePlugin   [SonyPlugin (aspirational)]     │
└───────┬───────────────────────┬───────────────┘
        │ Codec (pure)           │ DeviceChannel (async)
┌───────▼─────────┐    ┌─────────▼───────────────┐
│ BoseCodec       │    │ DeviceChannel (actor)    │
│ Foundation only │    │ owns IOBluetooth RFCOMM  │
│ bytes <-> types │    │ serializes commands      │
└─────────────────┘    └──────────────────────────┘
```

### Module / target layout (SwiftPM)

```
Sources/
  SoundSherpaCore/        # no IOBluetooth, no AppKit — pure, testable
    Models.swift          # capabilities, levels, PairedDevice, DeviceError, BluetoothDeviceInfo
    DevicePlugin.swift    # protocol + default "unsupported" implementations
    DeviceRegistry.swift  # matching by confidence
    Codec/
      BoseCodec.swift     # encode/decode pure functions
    Identification/
      DeviceTypeResolver.swift  # OUI + name -> PairedDeviceType (fixes Apple-icon bug)
      OUIPrefixes.swift         # vendor prefix tables (data, not logic)
  SoundSherpaBluetooth/   # IOBluetooth transport
    DeviceChannel.swift   # actor owning one RFCOMM channel
    ConnectionManager.swift
  SoundSherpa/            # executable: AppKit UI + wiring
    main.swift
    AppDelegate.swift
    MenuController.swift
    Plugins/
      BosePlugin.swift    # orchestrates BoseCodec over a DeviceChannel
Tests/
  SoundSherpaCoreTests/
    BoseCodecTests.swift
    DeviceTypeResolverTests.swift
    DeviceRegistryTests.swift
    PropertyTests/...
```

Rationale: `SoundSherpaCore` compiles and tests without any Apple-framework hardware
dependency. `IOBluetooth`/AppKit are isolated to the two outer targets.

## Components

### DeviceChannel (actor) — the reliability core

Owns exactly one RFCOMM channel and a single in-flight command at a time. Replaces today's
shared `responseBuffer` / `responseSemaphore` / `expectedResponsePrefix` + `NSLock`.

```swift
actor DeviceChannel {
    // Set up by ConnectionManager from an opened IOBluetoothRFCOMMChannel.
    // Internally bridges the RFCOMM delegate callback to a CheckedContinuation.

    /// Send a command and await the matching response. Serialized: callers queue.
    func send(_ command: [UInt8],
              expecting prefix: [UInt8],
              timeout: TimeInterval) async throws -> [UInt8]

    var isOpen: Bool { get }
    func close()
}
```

Key properties (Requirement 7):
- One command at a time → responses can't land in the wrong buffer (R7.1).
- Timeout throws `DeviceError.commandTimeout` — never silently "succeeds" (R4.3, R7.3).
- Channel-closed surfaces as `DeviceError.channelClosed` and notifies up the stack (R7.5).

Implementation note: the RFCOMM delegate (`rfcommChannelData:`) feeds bytes to the actor, which
resumes the pending continuation when the expected prefix arrives or the timeout fires.

#### CONFIRMED root cause of the "detected but shows nothing" instability (on-device spike, 2026-06-28)

The Bose QC35 SPP control channel allows **exactly one RFCOMM connection at a time**. The
current app closes the channel only in `applicationWillTerminate` (graceful quit). On crash,
force-quit, sleep, or unexpected disconnect, the channel is left **half-open**, and the next
session's SDP query returns 0 services and `openRFCOMMChannel` fails with generic error
`0xe00002bc` (kIOReturnError) — while `pairedDevices()` keeps working (it isn't gated). Killing
all stale instances and relaunching once immediately restored full function. This is **not** a
TCC/permission problem (the app shows ON in Privacy & Security → Bluetooth and still failed).

Therefore the DeviceChannel/ConnectionManager MUST:
1. **Defensively close any existing channel before opening a new one** (close-before-open), and
   tolerate a stale channel on the device side (retry after a close + short delay).
2. **Always tear down the channel** on every teardown path — not just graceful quit but also
   `applicationWillTerminate`, sleep/wake (`NSWorkspace.willSleepNotification`), and observed
   disconnect (R7.5).
3. Issue the SDP query / open on a thread with a **live run loop** (main thread): IOBluetooth
   delivers `sdpQueryComplete` and `rfcommChannelOpenComplete` via the calling thread's run
   loop, so background GCD threads never receive the callback. The actor must hop to a
   run-loop-backed context for the open, then can serialize I/O off it.

Spike confirmed that with a single clean connection the full protocol decodes correctly:
firmware (`00 01 03 …` → "1.0.4"), battery (`02 02 03 01 64` → 100%), serial (`00 07 03 …`),
and the paired-devices list (`04 04 03 …`).

### BoseCodec (pure) — the test seam

No `IOBluetooth`. Bytes in, typed values out. Preserves the *exact* existing wire format.

```swift
enum BoseCodec {
    // Encoders (verified against QC35 / QC35 II)
    static func encodeBatteryQuery() -> [UInt8]              // [0x02,0x02,0x01,0x00]
    static func encodeNC(_ level: NoiseCancellationLevel) -> [UInt8]   // [0x01,0x06,0x02,0x01,b]
    static func encodeSelfVoice(_ level: SelfVoiceLevel) -> [UInt8]
    static func encodeAutoOff(_ setting: AutoOffSetting) -> [UInt8]
    static func encodeLanguage(_ lang: DeviceLanguage, voicePrompts: Bool) -> [UInt8]
    static func encodeButtonAction(_ action: ButtonActionSetting) -> [UInt8]
    static func encodePairedDevicesQuery() -> [UInt8]
    static func encodeDeviceInfoQuery(address: [UInt8]) -> [UInt8]
    static func encodeConnect(address: [UInt8]) -> [UInt8]
    static func encodeDisconnect(address: [UInt8]) -> [UInt8]

    // Decoders (return nil / throw on malformed input — never crash)
    static func decodeBattery(_ bytes: [UInt8]) -> Int?
    static func decodeStatus(_ bytes: [UInt8]) -> BoseStatus?   // NC + self-voice + language
    static func decodeSerial(_ bytes: [UInt8]) -> String?
    static func decodePairedDevices(_ bytes: [UInt8]) -> [BosePairedAddress]
    static func decodeAutoOff(_ bytes: [UInt8]) -> AutoOffSetting?
    static func decodeButtonAction(_ bytes: [UInt8]) -> ButtonActionSetting?
}
```

The exact byte values are lifted verbatim from the current working `AppDelegate` (NC: off=0x00,
low=0x03, high=0x01; self-voice high=0x01/med=0x02/low=0x03; etc.) so behavior is preserved.

### DevicePlugin (protocol)

```swift
protocol DevicePlugin: AnyObject {
    var pluginId: String { get }
    var displayName: String { get }
    var capabilities: Set<DeviceCapability> { get }

    /// Confidence 0–100, or nil if this plugin can't handle the device.
    func confidence(for device: BluetoothDeviceInfo) -> Int?

    /// Bind to an open channel; run protocol init. Throws on real failure (no false success).
    func activate(channel: DeviceChannel) async throws
    func deactivate()

    // Capability methods — default impls throw .unsupportedCommand.
    func batteryLevel() async throws -> Int
    func noiseCancellation() async throws -> NoiseCancellationLevel
    func setNoiseCancellation(_ level: NoiseCancellationLevel) async throws
    func selfVoice() async throws -> SelfVoiceLevel
    func setSelfVoice(_ level: SelfVoiceLevel) async throws
    func autoOff() async throws -> AutoOffSetting
    func setAutoOff(_ setting: AutoOffSetting) async throws
    func language() async throws -> DeviceLanguage
    func setLanguage(_ language: DeviceLanguage) async throws
    func voicePromptsEnabled() async throws -> Bool
    func setVoicePromptsEnabled(_ enabled: Bool) async throws
    func buttonAction() async throws -> ButtonActionSetting
    func setButtonAction(_ action: ButtonActionSetting) async throws
    func pairedDevices() async throws -> [PairedDevice]
    func connectPaired(address: String) async throws
    func disconnectPaired(address: String) async throws

    // Optional metadata; hidden in UI when nil (R5.8 — no "Unknown" rows).
    func firmwareVersion() async throws -> String?
    func serialNumber() async throws -> String?
}
```

`BosePlugin` implements this by calling `BoseCodec.encode…` and passing the bytes to
`channel.send(...)`, then `BoseCodec.decode…` on the reply. It is the only place that joins codec
and transport.

### DeviceRegistry

```swift
final class DeviceRegistry {
    init(plugins: [DevicePlugin])          // compiled-in, registered at startup (D1)
    func bestPlugin(for device: BluetoothDeviceInfo) -> DevicePlugin?  // highest confidence
}
```

### ConnectionManager

Owns discovery and lifecycle. Uses `IOBluetooth.pairedDevices()` only (D2 — no
`system_profiler`). Registers connect/disconnect notifications and keeps them valid across
reconnects (R7.5). Opens the RFCOMM channel, wraps it in a `DeviceChannel`, retries with bounded
backoff (R7.4), and reports state changes to `MenuController` via the registry/active plugin.

```swift
enum ConnectionState { case disconnected, connecting, connected(BluetoothDeviceInfo) }
```

### MenuController

Owns the `NSStatusItem` and menu. Renders strictly from the active plugin's `capabilities` and
current values. Keeps last-known-good values on transient errors (R8.1). Hides optional metadata
rows when nil instead of printing "Unknown" (R5.8). Uses a small typed model for menu identity to
replace the magic-number tag offsets (`+600`, `700+index`).

### DeviceTypeResolver — fixes the icon bug

Pure function `(name, address) -> PairedDeviceType`. Correctness fix for the observed
"Mickrosoft → Apple logo": name patterns and OUI tables are checked with explicit precedence, and
a Microsoft OUI/name never falls through to `appleGeneric`. Fully unit-testable.

## Common data models (SoundSherpaCore)

```swift
enum DeviceCapability: String, CaseIterable, Codable {
    case battery, noiseCancellation, selfVoice, autoOff
    case voicePrompts, language, pairedDevices, buttonAction
}
enum NoiseCancellationLevel: String, Codable, CaseIterable { case off, low, medium, high }
enum SelfVoiceLevel: String, Codable, CaseIterable { case off, low, medium, high }
enum AutoOffSetting: Int, Codable, CaseIterable {
    case never = 0, fiveMinutes = 5, twentyMinutes = 20
    case fortyMinutes = 40, sixtyMinutes = 60, oneEightyMinutes = 180
}
enum DeviceLanguage: String, Codable, CaseIterable { /* existing set */ }
enum ButtonActionSetting: String, Codable, CaseIterable { case voiceAssistant, noiseCancellation }
enum PairedDeviceType: String, Codable {
    case iPhone, iPad, macBook, mac, appleWatch, appleTV, airPods, appleGeneric
    case windows, android, unknown
}
struct PairedDevice: Identifiable {
    let id: String  // MAC
    let name: String
    let isConnected: Bool
    let isCurrentDevice: Bool
    let type: PairedDeviceType
}
struct BluetoothDeviceInfo {
    let address: String
    let name: String
    let vendorId: String?
    let productId: String?
    let isConnected: Bool
}
enum DeviceError: Error {
    case notConnected, commandTimeout, invalidResponse, unsupportedCommand, channelClosed
}
```

## Migration plan (pure refactor first, no behavior change)

The revival is a behavior-preserving refactor before any new feature:

1. **Extract `SoundSherpaCore`** — move models, `DeviceCapability`, `DeviceTypeResolver` + OUI
   tables out of `AppDelegate`. Add `Tests/` target. (No behavior change; gains tests for the
   icon bug.)
2. **Extract `BoseCodec`** — lift the exact command bytes and response parsing out of
   `AppDelegate` into pure functions. Cover with round-trip property tests. (No behavior change.)
3. **Introduce `DeviceChannel` actor** — replace the shared buffer/semaphore/lock machinery.
   This is the data-race fix and the bulk of the stability win (R7.1, R7.3).
4. **Introduce `DevicePlugin` + `BosePlugin` + `DeviceRegistry`** — `AppDelegate` now drives the
   active plugin, not Bose directly.
5. **Extract `ConnectionManager` + `MenuController`** — remove `system_profiler` path (D2), add
   event-driven state + backoff retry (R7.2, R7.4, R7.5), hide nil metadata rows (R5.8), unify
   logging on `os.Logger` (R8.4).
6. **Only then**: a second-brand plugin (aspirational, D6) to prove modularity end-to-end.

Each step keeps the app launchable and Bose behavior identical; reliability improves as a side
effect of steps 3 and 5.

## Correctness properties (testable, no hardware)

- **P1 — Registry picks highest confidence.** For any device + set of plugins, `bestPlugin`
  returns the highest non-nil score.
- **P2 — Capability-gated UI.** Menu shows exactly the active plugin's capabilities; disconnected
  hides all device-specific items.
- **P3 — Bose codec round-trip.** For every valid NC/self-voice/auto-off/language/button-action
  value, `decode(encode(x)) == x` (where the command is also a query echo) — and decoders never
  crash on truncated/garbage input.
- **P4 — Paired-device parse count.** A well-formed paired-devices payload with N entries decodes
  to N `BosePairedAddress` values with valid MACs.
- **P5 — Device-type resolution.** Microsoft OUI/name never resolves to an Apple type; Apple OUI
  with iPhone/iPad/Mac name resolves to the specific type. (Locks the icon bug.)
- **P6 — Structured errors.** Every channel failure path throws a specific `DeviceError`, never a
  silent nil/false-success.

## Testing strategy

- **Unit tests**: codec edge cases, device-type resolution, registry matching, menu building.
- **Property tests** (e.g. SwiftCheck or hand-rolled generators), ≥100 iterations: P3, P4, P5.
- All of the above run in `SoundSherpaCoreTests` with no Bluetooth and no AppKit.
- Hardware behaviors (real connect/disconnect, battery over RFCOMM) remain manual smoke tests on
  the host Mac, since they require IOBluetooth and a headset.

## Out of scope (this phase)

- Dynamic/loadable plugins (D1).
- App-side settings persistence (D7).
- Unverified models / brands shipped as confirmed (D6) — designed-for, not asserted-correct.
