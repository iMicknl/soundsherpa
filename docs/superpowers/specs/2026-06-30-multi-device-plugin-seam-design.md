# Multi-Device Plugin Seam — Design (Sub-project A)

**Date:** 2026-06-30
**Status:** Approved (brainstorm complete)
**Scope:** Generalize SoundSherpa's device-control architecture so that adding a new
headphone brand is a pure additive change (one plugin + registration), with **no changes
to the controller, connection logic, or UI**. Bose is migrated onto the new seam with
**zero behavioral change on the wire** as the regression guard.

> This is the keystone of a three-part effort. It has **no hardware dependency** — it is
> verified entirely by Bose codec round-trip tests and the existing test suite.

---

## The three-part effort (context)

| # | Sub-project | Deliverable | Hardware |
|---|-------------|-------------|----------|
| **A** (this spec) | **Generalize the seam** | Capability-driven `DevicePlugin` owning control + discovery; Bose migrated unchanged; controller/UI brand-agnostic. | None — Bose regression only |
| **B** | **Sony plugin** | `SonyCodec` + MDR `ResponseMatcher` + `SonyPlugin` (battery / ANC / EQ) + vendor-UUID discovery. | **Yes — XM5 / XM4** |
| **C** | **Remaining brands** | Bose QC Ultra Gen 2 config; then Sennheiser HDB 630 / B&W Px7 S3 (gated on HCI capture). | Per device |

B and C get their own brainstorm → spec → plan cycles. **This document specs only A.**

---

## Problem statement

Today the `DevicePlugin` protocol (`Sources/SoundSherpaCore/DevicePlugin.swift`) abstracts
only **battery + metadata reads**. Everything users actually control — ANC
(`setNoiseCancellation`), self-voice, auto-off, language, button action, paired-device
management — is **hardcoded Bose BMAP** directly inside `DeviceController`
(`Sources/SoundSherpa/DeviceController.swift`). Device **discovery** is equally
Bose-shaped: `checkForBoseDevices` matches only `"bose"`; `connectToBoseDeviceSync` hunts
for the `"SPP Dev"` service and brute-forces channels `[8,9,1,2,3]`.

Consequently a second brand cannot be added by "registering a plugin" — the control
surface and discovery must first move behind the plugin seam. That is this sub-project.

## Goals / non-goals

**Goals**
- Move all brand-specific control, state-reading, and discovery knowledge behind
  `DevicePlugin`.
- Introduce brand-agnostic `DeviceState` / `DeviceChange` value types the controller and UI
  speak instead of Bose enums.
- Make the controller render only the controls a plugin declares it `supports`.
- Migrate Bose with **byte-for-byte identical wire behavior** (proven by tests).

**Non-goals**
- No new brand in this sub-project (that is B/C).
- **No change to the deadlock-sensitive concurrency model** in `DeviceController`
  (`connectionQueue`, off-main coordinator warming, `channelOpenSemaphore`, the
  `AsyncStream` ingest drain, the close-before-open discipline). A only changes *what* is
  matched/sent and *which* service/channel is looked up — never *how* the channel is
  opened or drained.
- No CoreBluetooth / GATT work (that is a separate future effort for BLE devices).
- No UI redesign — only conditioning existing controls on `supportedFeatures`.

## Global Constraints

- Swift 6.2 toolchain, **Swift 5 language mode** (`Package.swift` `swiftLanguageModes: [.v5]`).
- Platform floor **macOS 26** (`.macOS(.v26)`).
- `SoundSherpaCore` target is **Foundation-only** — no AppKit, no IOBluetooth. All new
  value types (`DeviceState`, `DeviceChange`, `ANCState`, `EqualizerState`,
  `DeviceFeature`, `DiscoveryDescriptor`) live in Core and must be `Sendable`.
- Plugins are `Sendable` value types held by `DeviceRegistry`.
- Plugins **never throw and never fabricate**: a missing reply is `nil` (reads) or `false`
  (writes). Swallow `DeviceError` at the plugin boundary, exactly as `BosePlugin` does today.
- Tests run natively on the host (not in a dev container): 
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.
- Bose wire output must not change. Any test asserting Bose command bytes is a hard gate.

---

## Architecture

### 1. Capability-driven `DevicePlugin` (Core)

The protocol gains discovery, a capability set, a single full-state read, and a typed apply.
The existing `readBatteryLevel` / `readMetadata` stay (battery is read on a faster cadence
than full state, and metadata is static/persisted separately).

```swift
public protocol DevicePlugin: Sendable {
    var identifier: String { get }
    func handles(deviceNamed name: String) -> Bool

    /// Pure-data discovery hints: which SPP/vendor service UUIDs to look for and which
    /// RFCOMM channels to try. Replaces the hardcoded "SPP Dev"/[8,9,1,2,3] in the controller.
    var discoveryDescriptor: DiscoveryDescriptor { get }

    /// Which features this brand exposes. The UI renders only controls in this set.
    var supportedFeatures: Set<DeviceFeature> { get }

    func readBatteryLevel(over channel: DeviceChannel) async -> Int?
    func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata

    /// Read every supported feature's current value in one pass, into the brand-agnostic
    /// state. Fields for unsupported/unavailable features are left nil.
    func readState(over channel: DeviceChannel) async -> DeviceState

    /// Apply one typed mutation. Returns whether the device acknowledged it. Never throws.
    func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool
}
```

### 2. Brand-agnostic state & change types (Core)

```swift
public enum DeviceFeature: Sendable, Hashable, CaseIterable {
    case noiseCancellation   // ANC mode (off / NC / ambient)
    case ambientLevel        // 0–20 ambient passthrough (Sony)
    case focusOnVoice        // Sony
    case equalizer
    case selfVoice           // Bose
    case autoOff             // Bose
    case buttonAction        // Bose
    case promptLanguage      // Bose
    case multipoint          // paired-device management (Bose today)
}

public struct ANCState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case off, noiseCancelling, ambient }
    public var mode: Mode
    public var ambientLevel: Int?    // 0–20 (Sony ambient); nil if N/A
    public var focusOnVoice: Bool?   // Sony; nil if N/A
    public init(mode: Mode, ambientLevel: Int? = nil, focusOnVoice: Bool? = nil)
}

public struct EqualizerState: Sendable, Equatable {
    public var presetId: Int?        // brand-defined preset index, nil = custom
    public var bands: [Int]          // per-band gains in dB; empty if unknown
    public init(presetId: Int? = nil, bands: [Int] = [])
}

public struct DeviceState: Sendable, Equatable {
    public var battery: Int?
    public var anc: ANCState?                          // cross-brand (Sony); nil for Bose
    public var equalizer: EqualizerState?
    // Bose-parity fields (kept so the existing UI binds unchanged):
    public var noiseCancellationLevel: NoiseCancellationLevel?   // Bose off/low/high
    public var selfVoice: SelfVoiceLevel?
    public var autoOff: AutoOff?
    public var buttonAction: ButtonAction?
    public var promptLanguage: PromptLanguage?
    public var voicePromptsEnabled: Bool?
    public init()
}

public enum DeviceChange: Sendable {
    case anc(ANCState)                                 // cross-brand (Sony)
    case noiseCancellation(NoiseCancellationLevel)     // Bose off/low/high
    case equalizer(EqualizerState)
    case selfVoice(SelfVoiceLevel)
    case autoOff(AutoOff)
    case buttonAction(ButtonAction)
    case promptLanguage(PromptLanguage)
    case voicePrompts(Bool)
}
```

**Bose enum relocation.** `AutoOff`, `ButtonAction`, `PromptLanguage` currently live in the
app target (`Sources/SoundSherpa/DeviceTypes.swift`). Because `DeviceState`/`DeviceChange`
reference them and live in Core, these enums **move to Core**
(alongside `NoiseCancellationLevel`/`SelfVoiceLevel` already there). `PairedDeviceInfo`
stays in the app target (it is not part of the state types). This is a mechanical move, not
a redesign.

**Bose ANC handling.** Bose's three-way `NoiseCancellationLevel` (off / low / high) is **not**
forced into the generic `ANCState` tri-state, because Bose "low" is reduced noise-cancelling,
not ambient passthrough — squeezing it into `.off/.noiseCancelling/.ambient` would lose the
low-vs-high distinction. Instead, for A the Bose NC level is preserved verbatim through a
**Bose-parity field** on `DeviceState`: a `NoiseCancellationLevel?` (the existing Core enum).
`BosePlugin.readState` populates it; `BosePlugin.apply(.noiseCancellation(level))` writes the
existing bytes. The generic `anc: ANCState?` field stays **nil for Bose** and is exercised
for real by Sony in sub-project B (off / NC / ambient + ambient level + focus-on-voice).

This means `DeviceState` carries both `anc: ANCState?` (cross-brand) and
`noiseCancellationLevel: NoiseCancellationLevel?` (Bose-parity), and `DeviceChange` carries
both `.anc(ANCState)` and `.noiseCancellation(NoiseCancellationLevel)`. A brand uses whichever
matches its capability; neither leaks the other brand's enum into the controller.

> Design note: the parity fields keep A a strict no-op for Bose while giving B a clean home.
> A later unification (collapsing Bose into the generic `ANCState` once a richer ANC model
> exists) is explicitly out of scope here.

### 3. `DiscoveryDescriptor` (Core, pure data)

```swift
public struct DiscoveryDescriptor: Sendable {
    /// Service identifiers to match, in priority order. An entry is either a service NAME
    /// (matched against IOBluetoothSDPServiceRecord.getServiceName(), e.g. "SPP Dev") or a
    /// UUID string (16-bit like "0x1101", or a 128-bit vendor UUID like
    /// "96CC203E-5068-46AD-B32D-E316F5E069BA"). The controller tries each in order.
    public var serviceMatchers: [ServiceMatcher]
    /// RFCOMM channel IDs to brute-force if SDP channel lookup fails, in order.
    public var channelHints: [UInt8]
    public init(serviceMatchers: [ServiceMatcher], channelHints: [UInt8])
}

public enum ServiceMatcher: Sendable, Equatable {
    case serviceName(String)   // e.g. "SPP Dev"
    case uuid(String)          // "0x1101" or 128-bit vendor UUID string
}
```

Bose descriptor (reproducing today's behavior exactly):
```swift
DiscoveryDescriptor(
    serviceMatchers: [.serviceName("SPP Dev"), .uuid("0x1101")],
    channelHints: [8, 9, 1, 2, 3]
)
```
The fallback "any service whose name contains spp/serial" that
`connectToBoseDeviceSync` does today is preserved by the controller as a last resort after
the descriptor's matchers, so behavior is unchanged.

### 4. Controller changes (app target, minimal & concurrency-preserving)

`DeviceController` keeps its entire concurrency model. The changes are surgical:

- **State:** replace the scattered observable feature properties' *population* path with a
  single `var state = DeviceState()` source, **but keep the existing individual observable
  properties** (`ncLevel`, `selfVoiceLevel`, `autoOff`, `buttonAction`, `language`,
  `voicePromptsEnabled`, `batteryLevel`) as computed/derived from `state` OR keep them and
  sync from `state` after each read. **Decision: keep the existing observable properties and
  derive them from `state`** so `SettingsView` bindings are untouched (smallest UI delta).
  The controller writes `state = await plugin.readState(over:)` then fans the fields out to
  the existing observable properties.
- **Intents:** `setNoiseCancellation`, `setSelfVoice`, `setAutoOff`, `setLanguage`,
  `setVoicePrompts`, `setButtonAction` become thin wrappers that build a `DeviceChange` and
  call `activePlugin.apply(_:over:)`, then update the observable property on success. The
  Bose byte-building moves into `BosePlugin.apply`.
- **Discovery:** `checkForBoseDevices` → `checkForSupportedDevices`: iterate paired devices,
  resolve `deviceRegistry.plugin(forDeviceNamed:)`, and treat **any** claimed+connected
  device as the active device (not just `"bose"`). `isBoseDevice` →
  `isSupportedDevice(_:)` delegating to the registry.
- **Connection:** `connectToBoseDeviceSync` → `connectSupportedDeviceSync`. The SDP service
  lookup uses `activePlugin.discoveryDescriptor.serviceMatchers`; the channel brute-force
  uses `discoveryDescriptor.channelHints`. The open/SDP/semaphore/retry mechanics are
  copied verbatim.
- **Feature gating:** expose `var supportedFeatures: Set<DeviceFeature>` (from
  `activePlugin`) so `SettingsView` can hide unsupported rows. For A, Bose's set reproduces
  today's visible controls, so the UI looks identical.
- **The unsolicited NC-broadcast handling** in `rfcommChannelData` (the live button-press
  reflection) stays. For A it remains Bose-shaped behind an `activePlugin`-keyed check; a
  later refactor can route it through a plugin hook, but that is **out of scope** for A to
  keep the change minimal.

### 5. `BosePlugin` absorbs the control surface

`BosePlugin` gains `discoveryDescriptor`, `supportedFeatures`, `readState`, and `apply`,
implemented by moving the existing Bose byte logic out of `DeviceController`
(`setNoiseCancellation`, `fetchDeviceStatus`, `parseDeviceStatusResponse`,
`fetchAutoOffStatus`, `fetchButtonActionStatus`, the self-voice/language/button writes) into
the plugin, reusing `BoseCodec` and adding new pure codec functions where parsing currently
lives inline in the controller. Paired-device management (`fetchPairedDevices`,
`connectPairedDevice`, `getDeviceStatus`) **stays in the controller for A** (it is
multipoint, not core state, and is heavily IOBluetooth-name-resolution coupled); generalize
it in a later pass if a second brand needs it.

---

## Data flow

```
30s scan / connect notification
      │
      ▼
checkForSupportedDevices ── registry.plugin(forDeviceNamed:) ──▶ activePlugin
      │
      ▼  (connectionQueue, off-main — UNCHANGED mechanics)
connectSupportedDeviceSync ── descriptor.serviceMatchers / channelHints
      │
      ▼
attachChannel → DeviceChannel actor (UNCHANGED)
      │
      ▼
plugin.readState(over:) ──▶ DeviceState ──▶ fan out to observable props ──▶ SwiftUI
      ▲                                                                        │
      └────────────── plugin.apply(change) ◀── intent (DeviceChange) ◀── user action
```

## Error handling

Unchanged contract. `readState` returns a `DeviceState` with nil fields for anything that
timed out; `apply` returns `false`. The controller leaves the corresponding observable
property unchanged on failure (the next read reconciles), exactly as today. The
`DeviceChannel` actor's `DeviceError` throwing is swallowed at the plugin boundary.

## Testing strategy

All Core types and `BosePlugin` are tested in `Tests/SoundSherpaCoreTests` against
`ScriptedTransport` / `FakeTransport` (the existing seam doubles). The decisive tests:

1. **Bose ANC apply parity** — `BosePlugin.apply(.noiseCancellation(level))` writes the
   **exact** bytes the old `setNoiseCancellation` produced (`[0x01,0x06,0x02,0x01,<byte>]`).
2. **Bose readState parity** — feeding the recorded status-broadcast bytes through
   `BosePlugin.readState` yields the same `ncLevel`/`selfVoice`/`autoOff`/`buttonAction`/
   `language` values the old `parseDeviceStatusResponse` produced.
3. **Discovery descriptor** — `BosePlugin.discoveryDescriptor` equals the documented Bose
   matchers/hints.
4. **State round-trips** — `DeviceState`/`DeviceChange`/`ANCState`/`EqualizerState`
   `Equatable` and field-mapping unit tests.
5. **Existing suite stays green** — `DeviceChannelTests`, `BoseCodec` tests, matcher tests.

Manual on-device Bose smoke test after A: connect a Bose device, confirm battery, ANC
toggle, self-voice, auto-off, button action, and paired-device list all behave exactly as
before. (A introduces no wire change, so this should be a formality.)

---

## File structure

**Core — new files**
- `Sources/SoundSherpaCore/DeviceState.swift` — `DeviceState`, `ANCState`, `EqualizerState`.
- `Sources/SoundSherpaCore/DeviceChange.swift` — `DeviceChange`, `DeviceFeature`.
- `Sources/SoundSherpaCore/DiscoveryDescriptor.swift` — `DiscoveryDescriptor`, `ServiceMatcher`.

**Core — modified**
- `Sources/SoundSherpaCore/DevicePlugin.swift` — extend protocol.
- `Sources/SoundSherpaCore/BosePlugin.swift` — add `discoveryDescriptor`,
  `supportedFeatures`, `readState`, `apply`; absorb control logic.
- `Sources/SoundSherpaCore/BoseCodec.swift` — add pure encoders/decoders for the control
  commands that are currently inline in the controller (NC set, status parse, auto-off,
  button action, self-voice, language).
- `Sources/SoundSherpaCore/BoseFeatureTypes.swift` (new) → **move** `AutoOff`,
  `ButtonAction`, `PromptLanguage` here from `Sources/SoundSherpa/DeviceTypes.swift`; leave
  `PairedDeviceInfo` in the app target.

**App — modified**
- `Sources/SoundSherpa/DeviceController.swift` — rename Bose-specific discovery/connect
  members to brand-agnostic ones; route intents through `apply`; populate from `readState`;
  expose `supportedFeatures`. Concurrency mechanics unchanged.
- `Sources/SoundSherpa/DeviceTypes.swift` — drop the relocated enums (keep
  `PairedDeviceInfo`).
- `Sources/SoundSherpa/Views/SettingsView.swift` — gate feature rows on
  `supportedFeatures` (Bose set = current visible rows, so no visible change).

**Tests — new/modified**
- `Tests/SoundSherpaCoreTests/BosePluginTests.swift` — new: apply/readState/descriptor parity.
- `Tests/SoundSherpaCoreTests/DeviceStateTests.swift` — new: value-type round-trips.

---

## Open questions (resolved for A)

- *Keep individual observable props or expose one `DeviceState`?* → **Keep individual props,
  derive from `state`** (smallest UI delta).
- *Generalize multipoint/paired-devices now?* → **No**, defer until a second brand needs it.
- *Generalize the unsolicited-broadcast hook now?* → **No**, keep Bose-shaped behind an
  `activePlugin` check; revisit when Sony needs live ANC reflection in B.

## Risks

- **Regressing Bose wire behavior.** Mitigated by byte-parity tests (testing strategy §1–2)
  as the gate before any controller wiring lands.
- **Touching the concurrency model.** Mitigated by the non-goal: connection mechanics are
  copied verbatim; only lookup *data* (service/channel) changes source.
- **Enum relocation churn.** Mechanical; compiler-checked. The app target re-exports via
  `import SoundSherpaCore`.
