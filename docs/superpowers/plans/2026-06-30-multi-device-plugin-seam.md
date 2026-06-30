# Multi-Device Plugin Seam Implementation Plan (Sub-project A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize SoundSherpa's device-control architecture so the brand-specific control surface and discovery move behind a capability-driven `DevicePlugin`, with Bose migrated onto it at **byte-for-byte identical wire behavior**.

**Architecture:** New brand-agnostic value types (`DeviceState`, `DeviceChange`, `DiscoveryDescriptor`) live in the Foundation-only `SoundSherpaCore`. The `DevicePlugin` protocol gains `discoveryDescriptor`, `supportedFeatures`, `readState`, and `apply`. All Bose byte logic moves out of `DeviceController` into `BosePlugin` + pure `BoseCodec` functions, proven equivalent by byte-parity tests. The deadlock-sensitive connection/ingest machinery in `DeviceController` is preserved verbatim; only *what is matched/sent* and *which service/channel is looked up* changes source.

**Tech Stack:** Swift 6.2 (Swift 5 language mode), SwiftPM, XCTest, IOBluetooth (app target only), SwiftUI.

## Global Constraints

- Swift 6.2 toolchain, **Swift 5 language mode** (`Package.swift` `swiftLanguageModes: [.v5]`).
- Platform floor **macOS 26** (`.macOS(.v26)`).
- `SoundSherpaCore` is **Foundation-only** — no AppKit, no IOBluetooth. All new value types live there and are `Sendable`.
- Plugins are `Sendable` value types; they **never throw and never fabricate** — a missing read is `nil`, a failed write is `false` (swallow `DeviceError` at the plugin boundary).
- **Do not change** the `DeviceController` concurrency model: `connectionQueue`, off-main coordinator warming, `channelOpenSemaphore`, the `AsyncStream` ingest drain, and the close-before-open discipline are copied verbatim.
- **Bose wire output must not change.** Byte-parity tests are the hard gate before any controller wiring lands.
- Build/test natively on the host (NOT in a dev container — this app needs real Mac Bluetooth):
  - Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
  - Build app: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build`
- Spec: `docs/superpowers/specs/2026-06-30-multi-device-plugin-seam-design.md`.

---

## File Structure

**Core — new**
- `Sources/SoundSherpaCore/BoseFeatureTypes.swift` — `AutoOff`, `ButtonAction`, `PromptLanguage` (moved from app).
- `Sources/SoundSherpaCore/DeviceState.swift` — `DeviceState`, `ANCState`, `EqualizerState`.
- `Sources/SoundSherpaCore/DeviceChange.swift` — `DeviceChange`, `DeviceFeature`.
- `Sources/SoundSherpaCore/DiscoveryDescriptor.swift` — `DiscoveryDescriptor`, `ServiceMatcher`.

**Core — modified**
- `Sources/SoundSherpaCore/BoseCodec.swift` — add control encoders/decoders + `decodeStatus`.
- `Sources/SoundSherpaCore/DevicePlugin.swift` — extend protocol.
- `Sources/SoundSherpaCore/BosePlugin.swift` — implement new protocol members.

**App — modified**
- `Sources/SoundSherpa/DeviceTypes.swift` — drop the relocated enums (keep `PairedDeviceInfo`).
- `Sources/SoundSherpa/DeviceController.swift` — brand-agnostic discovery/connect; intents via `apply`; populate from `readState`; expose `supportedFeatures`.
- `Sources/SoundSherpa/Views/SettingsView.swift` & `Sources/SoundSherpa/Views/ContentTile.swift` — gate controls on `supportedFeatures`.

**Tests — new/modified**
- `Tests/SoundSherpaCoreTests/DeviceStateTests.swift` — new.
- `Tests/SoundSherpaCoreTests/DiscoveryDescriptorTests.swift` — new.
- `Tests/SoundSherpaCoreTests/BoseCodecTests.swift` — extend (control codecs + status).
- `Tests/SoundSherpaCoreTests/BosePluginTests.swift` — extend (descriptor, features, apply, readState).

---

## Task 1: Move Bose feature enums into Core

The new `DeviceState`/`DeviceChange` types reference `AutoOff`, `ButtonAction`, and `PromptLanguage`, which currently live in the app target. They must move to Core (Foundation-only) so Core can reference them. Pure relocation — no behavior change.

**Files:**
- Create: `Sources/SoundSherpaCore/BoseFeatureTypes.swift`
- Modify: `Sources/SoundSherpa/DeviceTypes.swift` (remove the three enums, keep `PairedDeviceInfo`)

**Interfaces:**
- Produces: `enum AutoOff: UInt8`, `enum ButtonAction: UInt8`, `enum PromptLanguage: UInt8` — all public, with their existing `displayName` and raw values, now in `SoundSherpaCore`.

- [ ] **Step 1: Create the Core file with the three enums (made `public` + `Sendable`)**

Create `Sources/SoundSherpaCore/BoseFeatureTypes.swift`:

```swift
import Foundation

// Bose-specific feature value types. Moved here from the app target so the brand-agnostic
// DeviceState / DeviceChange types in Core can reference them. Values and displayName text
// are unchanged from the original app-target definitions.

public enum PromptLanguage: UInt8, Sendable {
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

    public var displayName: String {
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

public enum AutoOff: UInt8, Sendable {
    case never = 0x00
    case five = 0x05
    case twenty = 0x14
    case forty = 0x28
    case sixty = 0x3C
    case oneEighty = 0xB4
    case unknown = 0xFF

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .five: return "5 minutes"
        case .twenty: return "20 minutes"
        case .forty: return "40 minutes"
        case .sixty: return "60 minutes"
        case .oneEighty: return "180 minutes"
        case .unknown: return "Unknown"
        }
    }
}

public enum ButtonAction: UInt8, Sendable {
    case alexa = 0x01
    case noiseCancellation = 0x02
    case unknown = 0xFF

    public var displayName: String {
        switch self {
        case .alexa: return "Alexa"
        case .noiseCancellation: return "Noise Cancellation"
        case .unknown: return "Unknown"
        }
    }
}
```

- [ ] **Step 2: Remove the three enums from the app target**

In `Sources/SoundSherpa/DeviceTypes.swift`, delete the `PromptLanguage`, `AutoOff`, and `ButtonAction` enum declarations (lines 15–85). Keep the `import Foundation`, the header comment, and the `PairedDeviceInfo` struct. The file should end up as:

```swift
import Foundation

// MARK: - Shared Device Types
//
// Types referenced by both the legacy NSMenu (AppDelegate) and the new SwiftUI views
// (DeviceController). The Bose feature enums (AutoOff/ButtonAction/PromptLanguage) now live
// in SoundSherpaCore so the brand-agnostic state types can reference them.

struct PairedDeviceInfo {
    let address: String
    let name: String
    let isConnected: Bool
    let isCurrentDevice: Bool
}
```

- [ ] **Step 3: Build to verify the move compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build`
Expected: builds. `DeviceController.swift` and `SettingsView.swift` already `import SoundSherpaCore`, so the moved enums resolve. If any reference fails, it is because that file lacks `import SoundSherpaCore` — add it.

- [ ] **Step 4: Run the test suite (regression baseline)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS (all existing tests; no new ones yet).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/BoseFeatureTypes.swift Sources/SoundSherpa/DeviceTypes.swift
git commit -m "refactor(core): move Bose feature enums into Core for shared state types"
```

---

## Task 2: Brand-agnostic state & change value types

**Files:**
- Create: `Sources/SoundSherpaCore/DeviceState.swift`
- Create: `Sources/SoundSherpaCore/DeviceChange.swift`
- Test: `Tests/SoundSherpaCoreTests/DeviceStateTests.swift`

**Interfaces:**
- Consumes: `NoiseCancellationLevel`, `SelfVoiceLevel` (existing, `DeviceLevels.swift`); `AutoOff`, `ButtonAction`, `PromptLanguage` (Task 1).
- Produces:
  - `struct ANCState: Sendable, Equatable` with `enum Mode { case off, noiseCancelling, ambient }`, `mode: Mode`, `ambientLevel: Int?`, `focusOnVoice: Bool?`, `init(mode:ambientLevel:focusOnVoice:)`.
  - `struct EqualizerState: Sendable, Equatable` with `presetId: Int?`, `bands: [Int]`, `init(presetId:bands:)`.
  - `struct DeviceState: Sendable, Equatable` with `battery`, `anc`, `equalizer`, `noiseCancellationLevel`, `selfVoice`, `autoOff`, `buttonAction`, `promptLanguage`, `voicePromptsEnabled` (all optional vars), `init()`.
  - `enum DeviceFeature: Sendable, Hashable, CaseIterable` (cases below).
  - `enum DeviceChange: Sendable` (cases below).

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/DeviceStateTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceStateTests: XCTestCase {
    func testEmptyStateHasAllNilFields() {
        let s = DeviceState()
        XCTAssertNil(s.battery)
        XCTAssertNil(s.anc)
        XCTAssertNil(s.equalizer)
        XCTAssertNil(s.noiseCancellationLevel)
        XCTAssertNil(s.selfVoice)
        XCTAssertNil(s.autoOff)
        XCTAssertNil(s.buttonAction)
        XCTAssertNil(s.promptLanguage)
        XCTAssertNil(s.voicePromptsEnabled)
    }

    func testANCStateEquatableAndDefaults() {
        let a = ANCState(mode: .ambient, ambientLevel: 12, focusOnVoice: true)
        XCTAssertEqual(a.mode, .ambient)
        XCTAssertEqual(a.ambientLevel, 12)
        XCTAssertEqual(a.focusOnVoice, true)

        let plain = ANCState(mode: .off)
        XCTAssertNil(plain.ambientLevel)
        XCTAssertNil(plain.focusOnVoice)
        XCTAssertEqual(plain, ANCState(mode: .off))
        XCTAssertNotEqual(plain, ANCState(mode: .noiseCancelling))
    }

    func testEqualizerStateDefaults() {
        let e = EqualizerState()
        XCTAssertNil(e.presetId)
        XCTAssertTrue(e.bands.isEmpty)
        XCTAssertEqual(EqualizerState(presetId: 2, bands: [0, -3, 5]),
                       EqualizerState(presetId: 2, bands: [0, -3, 5]))
    }

    func testDeviceStateCarriesBoseParityFields() {
        var s = DeviceState()
        s.noiseCancellationLevel = .high
        s.autoOff = .twenty
        s.buttonAction = .noiseCancellation
        s.promptLanguage = .english
        s.voicePromptsEnabled = true
        XCTAssertEqual(s.noiseCancellationLevel, .high)
        XCTAssertEqual(s.autoOff, .twenty)
    }

    func testDeviceFeatureIsCaseIterable() {
        XCTAssertTrue(DeviceFeature.allCases.contains(.noiseCancellation))
        XCTAssertTrue(DeviceFeature.allCases.contains(.equalizer))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceStateTests`
Expected: FAIL — `cannot find 'DeviceState' in scope` (types don't exist yet).

- [ ] **Step 3: Create the state types**

Create `Sources/SoundSherpaCore/DeviceState.swift`:

```swift
import Foundation

/// Cross-brand active-noise-control state. Used by brands (e.g. Sony) whose ANC is a
/// three-way mode plus an ambient passthrough level and a focus-on-voice flag. Bose does
/// NOT populate this — it uses the `noiseCancellationLevel` parity field on `DeviceState`.
public struct ANCState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case off, noiseCancelling, ambient }
    public var mode: Mode
    public var ambientLevel: Int?    // 0–20 ambient passthrough; nil if N/A
    public var focusOnVoice: Bool?   // nil if N/A
    public init(mode: Mode, ambientLevel: Int? = nil, focusOnVoice: Bool? = nil) {
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
    }
}

/// Equalizer state: an optional brand-defined preset index plus per-band gains in dB.
public struct EqualizerState: Sendable, Equatable {
    public var presetId: Int?        // nil = custom / unknown
    public var bands: [Int]          // per-band gains in dB; empty if unknown
    public init(presetId: Int? = nil, bands: [Int] = []) {
        self.presetId = presetId
        self.bands = bands
    }
}

/// The single brand-agnostic snapshot the controller holds and the UI binds to. A plugin's
/// `readState` fills the fields its brand supports; everything else stays nil. Bose-parity
/// fields preserve the existing Bose controls without forcing them into the generic model.
public struct DeviceState: Sendable, Equatable {
    public var battery: Int?
    public var anc: ANCState?                          // cross-brand (Sony); nil for Bose
    public var equalizer: EqualizerState?
    // Bose-parity fields:
    public var noiseCancellationLevel: NoiseCancellationLevel?
    public var selfVoice: SelfVoiceLevel?
    public var autoOff: AutoOff?
    public var buttonAction: ButtonAction?
    public var promptLanguage: PromptLanguage?
    public var voicePromptsEnabled: Bool?
    public init() {}
}
```

Note: `NoiseCancellationLevel` and `SelfVoiceLevel` need `Equatable` for `DeviceState: Equatable` to synthesize. `NoiseCancellationLevel` is a plain enum (auto-Equatable); `SelfVoiceLevel` is a raw `UInt8` enum (auto-Equatable). No change needed there.

- [ ] **Step 4: Create the change/feature types**

Create `Sources/SoundSherpaCore/DeviceChange.swift`:

```swift
import Foundation

/// The set of controllable features a brand may expose. The UI renders only the controls
/// whose feature is in a plugin's `supportedFeatures`.
public enum DeviceFeature: Sendable, Hashable, CaseIterable {
    case noiseCancellation   // ANC mode / level
    case ambientLevel        // 0–20 ambient passthrough (Sony)
    case focusOnVoice        // Sony
    case equalizer
    case selfVoice           // Bose
    case autoOff             // Bose
    case buttonAction        // Bose
    case promptLanguage      // Bose
    case multipoint          // paired-device management (Bose today)
}

/// A single typed mutation a plugin can apply to a device. A brand uses whichever cases
/// match its capabilities; `apply` returns false for changes it doesn't support.
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

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceStateTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceState.swift Sources/SoundSherpaCore/DeviceChange.swift Tests/SoundSherpaCoreTests/DeviceStateTests.swift
git commit -m "feat(core): add brand-agnostic DeviceState/DeviceChange/DeviceFeature types"
```

---

## Task 3: DiscoveryDescriptor

**Files:**
- Create: `Sources/SoundSherpaCore/DiscoveryDescriptor.swift`
- Test: `Tests/SoundSherpaCoreTests/DiscoveryDescriptorTests.swift`

**Interfaces:**
- Produces:
  - `enum ServiceMatcher: Sendable, Equatable { case serviceName(String); case uuid(String) }`
  - `struct DiscoveryDescriptor: Sendable { var serviceMatchers: [ServiceMatcher]; var channelHints: [UInt8]; init(serviceMatchers:channelHints:) }`

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/DiscoveryDescriptorTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DiscoveryDescriptorTests: XCTestCase {
    func testStoresMatchersAndHintsInOrder() {
        let d = DiscoveryDescriptor(
            serviceMatchers: [.serviceName("SPP Dev"), .uuid("0x1101")],
            channelHints: [8, 9, 1, 2, 3])
        XCTAssertEqual(d.serviceMatchers, [.serviceName("SPP Dev"), .uuid("0x1101")])
        XCTAssertEqual(d.channelHints, [8, 9, 1, 2, 3])
    }

    func testServiceMatcherEquatable() {
        XCTAssertEqual(ServiceMatcher.serviceName("SPP Dev"), .serviceName("SPP Dev"))
        XCTAssertNotEqual(ServiceMatcher.serviceName("SPP Dev"), .uuid("0x1101"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DiscoveryDescriptorTests`
Expected: FAIL — `cannot find 'DiscoveryDescriptor' in scope`.

- [ ] **Step 3: Create the type**

Create `Sources/SoundSherpaCore/DiscoveryDescriptor.swift`:

```swift
import Foundation

/// How to find and open a brand's control channel. Pure data supplied by each plugin, so the
/// controller's IOBluetooth connect flow has no hardcoded brand specifics. An entry is either
/// a service NAME (matched against IOBluetoothSDPServiceRecord.getServiceName()) or a UUID
/// string ("0x1101" 16-bit, or a 128-bit vendor UUID like Sony's
/// "96CC203E-5068-46AD-B32D-E316F5E069BA").
public enum ServiceMatcher: Sendable, Equatable {
    case serviceName(String)
    case uuid(String)
}

public struct DiscoveryDescriptor: Sendable {
    /// Service identifiers to look for, in priority order.
    public var serviceMatchers: [ServiceMatcher]
    /// RFCOMM channel IDs to brute-force if SDP channel lookup fails, in order.
    public var channelHints: [UInt8]
    public init(serviceMatchers: [ServiceMatcher], channelHints: [UInt8]) {
        self.serviceMatchers = serviceMatchers
        self.channelHints = channelHints
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DiscoveryDescriptorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/DiscoveryDescriptor.swift Tests/SoundSherpaCoreTests/DiscoveryDescriptorTests.swift
git commit -m "feat(core): add DiscoveryDescriptor for brand-agnostic service/channel lookup"
```

---

## Task 4: Bose control codecs (pure encode/decode)

Add pure functions to `BoseCodec` for the control commands currently built and parsed inline in `DeviceController`. These are the byte-parity foundation: each encoder reproduces the exact bytes the controller sends today; `decodeStatus` reproduces `parseDeviceStatusResponse`.

**Files:**
- Modify: `Sources/SoundSherpaCore/BoseCodec.swift`
- Test: `Tests/SoundSherpaCoreTests/BoseCodecTests.swift` (extend)

**Interfaces:**
- Consumes: `NoiseCancellationLevel`, `SelfVoiceLevel`, `AutoOff`, `ButtonAction`, `PromptLanguage`.
- Produces, all `public static` on `BoseCodec`:
  - `encodeNoiseCancellation(_ level: NoiseCancellationLevel) -> [UInt8]`
  - `encodeStatusQuery() -> [UInt8]`
  - `encodeAutoOffQuery() -> [UInt8]`
  - `encodeAutoOff(_ value: AutoOff) -> [UInt8]`
  - `decodeAutoOff(_ bytes: [UInt8]) -> AutoOff?`
  - `encodeButtonActionQuery() -> [UInt8]`
  - `encodeButtonAction(_ value: ButtonAction) -> [UInt8]`
  - `decodeButtonAction(_ bytes: [UInt8]) -> ButtonAction?`
  - `encodeSelfVoice(_ level: SelfVoiceLevel) -> [UInt8]`
  - `encodeLanguage(_ languageByte: UInt8) -> [UInt8]`
  - `struct BoseStatus: Equatable { var noiseCancellation: NoiseCancellationLevel?; var selfVoice: SelfVoiceLevel?; var promptLanguage: PromptLanguage?; var voicePromptsEnabled: Bool?; var languageByte: UInt8? }`
  - `decodeStatus(_ bytes: [UInt8]) -> BoseStatus`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundSherpaCoreTests/BoseCodecTests.swift` (inside the `final class BoseCodecTests` body, before the closing brace):

```swift
    // MARK: - Control encoders (byte-parity with the old DeviceController)

    func testEncodeNoiseCancellation() {
        // Old: send([0x01,0x06,0x02,0x01,level.byte])
        XCTAssertEqual(BoseCodec.encodeNoiseCancellation(.off),  [0x01, 0x06, 0x02, 0x01, 0x00])
        XCTAssertEqual(BoseCodec.encodeNoiseCancellation(.low),  [0x01, 0x06, 0x02, 0x01, 0x03])
        XCTAssertEqual(BoseCodec.encodeNoiseCancellation(.high), [0x01, 0x06, 0x02, 0x01, 0x01])
    }

    func testEncodeStatusQuery() {
        XCTAssertEqual(BoseCodec.encodeStatusQuery(), [0x01, 0x01, 0x05, 0x00])
    }

    func testEncodeAutoOff() {
        XCTAssertEqual(BoseCodec.encodeAutoOffQuery(), [0x01, 0x04, 0x01, 0x00])
        XCTAssertEqual(BoseCodec.encodeAutoOff(.twenty), [0x01, 0x04, 0x02, 0x01, 0x14])
    }

    func testDecodeAutoOff() {
        // STATUS reply [0x01,0x04,0x03,<len>,<value>]
        XCTAssertEqual(BoseCodec.decodeAutoOff([0x01, 0x04, 0x03, 0x01, 0x14]), .twenty)
        XCTAssertNil(BoseCodec.decodeAutoOff([0x02, 0x02, 0x03, 0x01, 0x14])) // wrong prefix
        XCTAssertNil(BoseCodec.decodeAutoOff([0x01, 0x04, 0x03])) // truncated
    }

    func testEncodeButtonAction() {
        XCTAssertEqual(BoseCodec.encodeButtonActionQuery(), [0x01, 0x09, 0x01, 0x00])
        // Old set: send([0x01,0x09,0x02,0x03,0x10,0x04,value.rawValue])
        XCTAssertEqual(BoseCodec.encodeButtonAction(.alexa),
                       [0x01, 0x09, 0x02, 0x03, 0x10, 0x04, 0x01])
    }

    func testDecodeButtonAction() {
        // ACK [0x01,0x09,0x03,0x04,0x10,0x04,mode,0x07]; mode at byte 6.
        XCTAssertEqual(
            BoseCodec.decodeButtonAction([0x01, 0x09, 0x03, 0x04, 0x10, 0x04, 0x02, 0x07]),
            .noiseCancellation)
        XCTAssertNil(BoseCodec.decodeButtonAction([0x01, 0x09, 0x03, 0x04, 0x11, 0x04, 0x02, 0x07])) // wrong button id
        XCTAssertNil(BoseCodec.decodeButtonAction([0x01, 0x09, 0x03])) // truncated
    }

    func testEncodeSelfVoice() {
        // Old: send([0x01,0x0b,0x02,0x02,0x01,level.rawValue,0x38])
        XCTAssertEqual(BoseCodec.encodeSelfVoice(.medium),
                       [0x01, 0x0b, 0x02, 0x02, 0x01, 0x02, 0x38])
    }

    func testEncodeLanguage() {
        // Old: send([0x01,0x03,0x02,0x01,languageByte])
        XCTAssertEqual(BoseCodec.encodeLanguage(0xA1), [0x01, 0x03, 0x02, 0x01, 0xA1])
    }

    // MARK: - Status decode (parity with parseDeviceStatusResponse)

    func testDecodeStatusParsesLanguageNCAndSelfVoice() {
        // Concatenated broadcasts as collected over the status window:
        //   language: [0x01,0x03,0x03,0x01,0xA1]  (0x21 english + voice-prompt high bit 0x80)
        //   nc:       [0x01,0x06,0x03,0x01,0x01]  (high)
        //   selfvoice:[0x01,0x0b,0x03,0x02,0x01,0x02]  (medium at index i+5)
        let buffer: [UInt8] = [0x01, 0x03, 0x03, 0x01, 0xA1,
                               0x01, 0x06, 0x03, 0x01, 0x01,
                               0x01, 0x0b, 0x03, 0x02, 0x01, 0x02]
        let status = BoseCodec.decodeStatus(buffer)
        XCTAssertEqual(status.promptLanguage, .english)
        XCTAssertEqual(status.voicePromptsEnabled, true)
        XCTAssertEqual(status.languageByte, 0xA1)
        XCTAssertEqual(status.noiseCancellation, .high)
        XCTAssertEqual(status.selfVoice, .medium)
    }

    func testDecodeStatusVoicePromptsOffWhenHighBitClear() {
        let buffer: [UInt8] = [0x01, 0x03, 0x03, 0x01, 0x21] // english, no high bit
        let status = BoseCodec.decodeStatus(buffer)
        XCTAssertEqual(status.promptLanguage, .english)
        XCTAssertEqual(status.voicePromptsEnabled, false)
    }

    func testDecodeStatusEmptyBufferYieldsAllNil() {
        let status = BoseCodec.decodeStatus([])
        XCTAssertNil(status.noiseCancellation)
        XCTAssertNil(status.selfVoice)
        XCTAssertNil(status.promptLanguage)
        XCTAssertNil(status.voicePromptsEnabled)
        XCTAssertNil(status.languageByte)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BoseCodecTests`
Expected: FAIL — `type 'BoseCodec' has no member 'encodeNoiseCancellation'` (etc.).

- [ ] **Step 3: Implement the codecs**

In `Sources/SoundSherpaCore/BoseCodec.swift`, add before the final closing brace of `enum BoseCodec` (after the existing `decodeModelId`, in a new `// MARK: - Control` section):

```swift
    // MARK: - Control encoders

    /// Noise-cancellation set: `[0x01,0x06,0x02,0x01,<level byte>]`.
    public static func encodeNoiseCancellation(_ level: NoiseCancellationLevel) -> [UInt8] {
        [0x01, 0x06, 0x02, 0x01, level.byte]
    }

    /// Device-status query that provokes the language / NC / self-voice broadcasts.
    public static func encodeStatusQuery() -> [UInt8] { [0x01, 0x01, 0x05, 0x00] }

    public static func encodeAutoOffQuery() -> [UInt8] { [0x01, 0x04, 0x01, 0x00] }

    /// Auto-off set: `[0x01,0x04,0x02,0x01,<minutes byte>]`.
    public static func encodeAutoOff(_ value: AutoOff) -> [UInt8] {
        [0x01, 0x04, 0x02, 0x01, value.rawValue]
    }

    public static func encodeButtonActionQuery() -> [UInt8] { [0x01, 0x09, 0x01, 0x00] }

    /// Button-action set: `[0x01,0x09,0x02,0x03,0x10,0x04,<mode>]`.
    public static func encodeButtonAction(_ value: ButtonAction) -> [UInt8] {
        [0x01, 0x09, 0x02, 0x03, 0x10, 0x04, value.rawValue]
    }

    /// Self-voice set: `[0x01,0x0b,0x02,0x02,0x01,<level>,0x38]`.
    public static func encodeSelfVoice(_ level: SelfVoiceLevel) -> [UInt8] {
        [0x01, 0x0b, 0x02, 0x02, 0x01, level.rawValue, 0x38]
    }

    /// Language set: `[0x01,0x03,0x02,0x01,<language byte incl. voice-prompt high bit>]`.
    public static func encodeLanguage(_ languageByte: UInt8) -> [UInt8] {
        [0x01, 0x03, 0x02, 0x01, languageByte]
    }

    // MARK: - Control decoders

    /// Auto-off from a STATUS reply `[0x01,0x04,0x03,<len>,<value>]`.
    public static func decodeAutoOff(_ bytes: [UInt8]) -> AutoOff? {
        guard bytes.count >= 5,
              bytes[0] == 0x01, bytes[1] == 0x04, bytes[2] == 0x03 else { return nil }
        return AutoOff(rawValue: bytes[4])
    }

    /// Button action from the ACK `[0x01,0x09,0x03,0x04,0x10,0x04,<mode>,0x07]` (mode at byte 6).
    public static func decodeButtonAction(_ bytes: [UInt8]) -> ButtonAction? {
        guard bytes.count >= 8,
              bytes[0] == 0x01, bytes[1] == 0x09, bytes[2] == 0x03,
              bytes[4] == 0x10, bytes[5] == 0x04 else { return nil }
        return ButtonAction(rawValue: bytes[6])
    }

    /// Parsed device-status snapshot from the collected broadcast buffer.
    public struct BoseStatus: Equatable, Sendable {
        public var noiseCancellation: NoiseCancellationLevel?
        public var selfVoice: SelfVoiceLevel?
        public var promptLanguage: PromptLanguage?
        public var voicePromptsEnabled: Bool?
        public var languageByte: UInt8?
        public init() {}
    }

    /// Scan the collected status buffer for the language (0x01 0x03 0x03), NC (0x01 0x06 0x03),
    /// and self-voice (0x01 0x0b 0x03) broadcasts. Mirrors the old parseDeviceStatusResponse:
    /// first match of each wins; non-matching/short buffers yield nil fields (never a crash).
    public static func decodeStatus(_ bytes: [UInt8]) -> BoseStatus {
        var status = BoseStatus()

        // Language (+ voice-prompt high bit): value at i+4.
        for i in 0..<bytes.count where i + 4 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x03, bytes[i+2] == 0x03 {
                let langByte = bytes[i+4]
                status.languageByte = langByte
                status.voicePromptsEnabled = (langByte & 0x80) != 0
                status.promptLanguage = PromptLanguage(rawValue: langByte & 0x7F)
                break
            }
        }
        // NC level: value at i+4.
        for i in 0..<bytes.count where i + 4 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x06, bytes[i+2] == 0x03 {
                status.noiseCancellation = NoiseCancellationLevel(byte: bytes[i+4])
                break
            }
        }
        // Self-voice: value at i+5.
        for i in 0..<bytes.count where i + 5 < bytes.count {
            if bytes[i] == 0x01, bytes[i+1] == 0x0b, bytes[i+2] == 0x03 {
                status.selfVoice = SelfVoiceLevel(rawValue: bytes[i+5])
                break
            }
        }
        return status
    }
```

Note the loop bound `i + 4 < bytes.count` (strict `<`) reproduces the old code's exact off-by-one behavior from `parseDeviceStatusResponse`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BoseCodecTests`
Expected: PASS (existing + new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/BoseCodec.swift Tests/SoundSherpaCoreTests/BoseCodecTests.swift
git commit -m "feat(core): add Bose control codecs (NC/auto-off/button/self-voice/language/status)"
```

---

## Task 5: Extend the DevicePlugin protocol + Bose descriptor & capabilities

Extend the protocol with the four new members, and implement the two pure-data ones on `BosePlugin` (`discoveryDescriptor`, `supportedFeatures`). `readState`/`apply` get stub-then-real treatment in Tasks 6–7, but the protocol must compile now, so add minimal placeholder bodies on `BosePlugin` that the next tasks replace.

**Files:**
- Modify: `Sources/SoundSherpaCore/DevicePlugin.swift`
- Modify: `Sources/SoundSherpaCore/BosePlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/BosePluginTests.swift` (extend)

**Interfaces:**
- Consumes: `DiscoveryDescriptor`, `ServiceMatcher` (Task 3); `DeviceFeature`, `DeviceState`, `DeviceChange` (Task 2).
- Produces (protocol additions):
  - `var discoveryDescriptor: DiscoveryDescriptor { get }`
  - `var supportedFeatures: Set<DeviceFeature> { get }`
  - `func readState(over channel: DeviceChannel) async -> DeviceState`
  - `func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool`
- Produces (`BosePlugin`): the Bose descriptor and feature set documented below.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundSherpaCoreTests/BosePluginTests.swift` (inside the class):

```swift
    // MARK: - Discovery descriptor & capabilities

    func testDiscoveryDescriptorMatchesLegacyBoseLookup() {
        let d = BosePlugin().discoveryDescriptor
        XCTAssertEqual(d.serviceMatchers, [.serviceName("SPP Dev"), .uuid("0x1101")])
        XCTAssertEqual(d.channelHints, [8, 9, 1, 2, 3])
    }

    func testSupportedFeaturesCoverExistingBoseControls() {
        let f = BosePlugin().supportedFeatures
        XCTAssertTrue(f.contains(.noiseCancellation))
        XCTAssertTrue(f.contains(.selfVoice))
        XCTAssertTrue(f.contains(.autoOff))
        XCTAssertTrue(f.contains(.buttonAction))
        XCTAssertTrue(f.contains(.promptLanguage))
        // Bose does not expose the Sony-only generic ANC ambient/EQ in this sub-project.
        XCTAssertFalse(f.contains(.equalizer))
        XCTAssertFalse(f.contains(.ambientLevel))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: FAIL — `value of type 'BosePlugin' has no member 'discoveryDescriptor'`.

- [ ] **Step 3: Extend the protocol**

In `Sources/SoundSherpaCore/DevicePlugin.swift`, add these members to the `DevicePlugin` protocol body (after `readMetadata`):

```swift
    /// Pure-data discovery hints: which SPP/vendor service identifiers to look for and which
    /// RFCOMM channels to try. Replaces the controller's hardcoded "SPP Dev"/[8,9,1,2,3].
    var discoveryDescriptor: DiscoveryDescriptor { get }

    /// Which features this brand exposes. The UI renders only controls in this set.
    var supportedFeatures: Set<DeviceFeature> { get }

    /// Read every supported feature's current value in one pass. Unsupported / unavailable
    /// features are left nil on the returned state.
    func readState(over channel: DeviceChannel) async -> DeviceState

    /// Apply one typed mutation. Returns whether the device acknowledged it. Never throws;
    /// returns false for unsupported changes or on timeout / closed channel.
    func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool
```

- [ ] **Step 4: Implement descriptor + features on BosePlugin (with temporary readState/apply stubs)**

In `Sources/SoundSherpaCore/BosePlugin.swift`, add to the struct body (after `readMetadata`). The `readState`/`apply` here are temporary stubs replaced in Tasks 7 and 6; they let the protocol conform and compile now:

```swift
    public var discoveryDescriptor: DiscoveryDescriptor {
        DiscoveryDescriptor(
            serviceMatchers: [.serviceName("SPP Dev"), .uuid("0x1101")],
            channelHints: [8, 9, 1, 2, 3])
    }

    public var supportedFeatures: Set<DeviceFeature> {
        [.noiseCancellation, .selfVoice, .autoOff, .buttonAction, .promptLanguage, .multipoint]
    }

    // Implemented in later tasks (apply: Task 6, readState: Task 7).
    public func readState(over channel: DeviceChannel) async -> DeviceState {
        DeviceState()
    }

    public func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool {
        false
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS (descriptor + features tests; battery/metadata still pass).

- [ ] **Step 6: Run the full suite (protocol change ripple check)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS. (The app target isn't compiled by `swift test`; controller conformance is handled in Task 8.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundSherpaCore/DevicePlugin.swift Sources/SoundSherpaCore/BosePlugin.swift Tests/SoundSherpaCoreTests/BosePluginTests.swift
git commit -m "feat(core): extend DevicePlugin with discovery/capabilities/readState/apply; Bose descriptor+features"
```

---

## Task 6: BosePlugin.apply (byte-parity with the old controller writes)

Replace the `apply` stub with the real implementation that builds the exact bytes the old `DeviceController` intents produced. This is a primary regression gate.

**Files:**
- Modify: `Sources/SoundSherpaCore/BosePlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/BosePluginTests.swift` (extend)

**Interfaces:**
- Consumes: `BoseCodec.encodeNoiseCancellation/encodeSelfVoice/encodeAutoOff/encodeButtonAction/encodeLanguage` (Task 4), `DeviceChange` (Task 2).
- Produces: real `BosePlugin.apply(_:over:)` returning `true` when the device ACKs (reply prefix matches), `false` otherwise.

- [ ] **Step 1: Write the failing tests**

Append to `BosePluginTests.swift`:

```swift
    // MARK: - apply (write byte-parity)

    func testApplyNoiseCancellationWritesExactBytes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let ok = plugin.apply(.noiseCancellation(.high), over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x01, 0x06, 0x03, 0x01, 0x01]) // ACK
        let result = await ok
        XCTAssertTrue(result)
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x01, 0x06, 0x02, 0x01, 0x01]])
    }

    func testApplySelfVoiceWritesExactBytes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let ok = plugin.apply(.selfVoice(.medium), over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x01, 0x0b, 0x03, 0x01, 0x02]) // ACK
        _ = await ok
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x01, 0x0b, 0x02, 0x02, 0x01, 0x02, 0x38]])
    }

    func testApplyAutoOffWritesExactBytes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let ok = plugin.apply(.autoOff(.twenty), over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x01, 0x04, 0x03, 0x01, 0x14]) // ACK
        _ = await ok
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x01, 0x04, 0x02, 0x01, 0x14]])
    }

    func testApplyButtonActionWritesExactBytes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let ok = plugin.apply(.buttonAction(.alexa), over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x01, 0x09, 0x03, 0x04, 0x10, 0x04, 0x01, 0x07]) // ACK
        _ = await ok
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x01, 0x09, 0x02, 0x03, 0x10, 0x04, 0x01]])
    }

    func testApplyLanguageWritesExactBytes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let ok = plugin.apply(.promptLanguage(.french), over: channel)
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x01, 0x03, 0x03, 0x01, 0x22]) // ACK
        _ = await ok
        let writes = await transport.writes
        // French = 0x22; voice-prompt high bit not set by a bare language change.
        XCTAssertEqual(writes, [[0x01, 0x03, 0x02, 0x01, 0x22]])
    }

    func testApplyReturnsFalseOnTimeout() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()
        // No ACK ingested → the send times out → apply reports false, never throws.
        let result = await plugin.apply(.noiseCancellation(.off), over: channel)
        XCTAssertFalse(result)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: FAIL — `apply` stub returns false / writes nothing, so byte assertions and `XCTAssertTrue(result)` fail.

- [ ] **Step 3: Implement apply**

In `BosePlugin.swift`, replace the temporary `apply` stub with:

```swift
    public func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool {
        switch change {
        case .noiseCancellation(let level):
            return await acked(BoseCodec.encodeNoiseCancellation(level),
                               prefix: [0x01, 0x06], over: channel)
        case .selfVoice(let level):
            return await acked(BoseCodec.encodeSelfVoice(level),
                               prefix: [0x01, 0x0b], over: channel)
        case .autoOff(let value):
            return await acked(BoseCodec.encodeAutoOff(value),
                               prefix: [0x01, 0x04], over: channel)
        case .buttonAction(let value):
            return await acked(BoseCodec.encodeButtonAction(value),
                               prefix: [0x01, 0x09], over: channel)
        case .promptLanguage(let value):
            return await acked(BoseCodec.encodeLanguage(value.rawValue),
                               prefix: [0x01, 0x03], over: channel)
        case .voicePrompts(let on):
            // Preserve the currently-selected language; toggle only the high bit.
            let base = (lastLanguageByte ?? PromptLanguage.english.rawValue) & 0x7F
            let byte = on ? (base | 0x80) : base
            return await acked(BoseCodec.encodeLanguage(byte),
                               prefix: [0x01, 0x03], over: channel)
        case .anc, .equalizer:
            // Bose does not use the generic ANC/EQ model in this sub-project.
            return false
        }
    }

    /// Send `command` and treat any reply matching `prefix` as an acknowledgement. A timeout /
    /// closed channel yields false — never a throw — matching the plugin no-throw contract.
    private func acked(_ command: [UInt8], prefix: [UInt8], over channel: DeviceChannel) async -> Bool {
        let reply = (try? await channel.send(command, matcher: .prefix(prefix), timeout: 0.5)) ?? []
        return !reply.isEmpty
    }
```

`lastLanguageByte` is a stored value the plugin tracks from the last `readState` (so a voice-prompt toggle preserves the language, exactly as the old `currentLanguageValue` did). Since `BosePlugin` is a value type used across `await`, store it as a class-backed box. Add at the top of the struct:

```swift
    // Tracks the last-seen language byte (incl. voice-prompt high bit) so a voice-prompt
    // toggle can preserve the chosen language — the role the old controller's
    // `currentLanguageValue` played. Boxed because BosePlugin is a Sendable value type.
    private let languageBox = LanguageBox()
    private var lastLanguageByte: UInt8? {
        get { languageBox.value }
        nonmutating set { languageBox.value = newValue }
    }
```

And add this small final class in the same file (below the struct):

```swift
/// A tiny reference box so the value-type BosePlugin can carry mutable last-language state
/// across the channel's async boundaries without becoming a class itself.
private final class LanguageBox: @unchecked Sendable {
    var value: UInt8?
}
```

(`readState` in Task 7 sets `lastLanguageByte` from the decoded status.)

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/BosePlugin.swift Tests/SoundSherpaCoreTests/BosePluginTests.swift
git commit -m "feat(core): BosePlugin.apply with byte-parity writes + voice-prompt language preservation"
```

---

## Task 7: BosePlugin.readState (read-parity with the old controller fetch)

Replace the `readState` stub with the real implementation: query battery, status broadcasts, auto-off, and button action over the channel, decode via `BoseCodec`, and assemble a `DeviceState`. Also record the language byte into `lastLanguageByte`.

**Files:**
- Modify: `Sources/SoundSherpaCore/BosePlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/BosePluginTests.swift` (extend)

**Interfaces:**
- Consumes: `BoseCodec.encodeStatusQuery/decodeStatus/encodeAutoOffQuery/decodeAutoOff/encodeButtonActionQuery/decodeButtonAction`, `encodeBatteryQuery/decodeBattery` (existing).
- Produces: real `BosePlugin.readState(over:)` populating `battery`, `noiseCancellationLevel`, `selfVoice`, `promptLanguage`, `voicePromptsEnabled`, `autoOff`, `buttonAction` on a `DeviceState`.

- [ ] **Step 1: Write the failing test**

Append to `BosePluginTests.swift`:

```swift
    // MARK: - readState (read parity)

    func testReadStateAssemblesAllControls() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()

        async let state = plugin.readState(over: channel)

        // Order matches readState's send sequence:
        // 1) battery query → 90%
        try await transport.awaitWrite(count: 1)
        await channel.ingest([0x02, 0x02, 0x03, 0x01, 0x5A])
        // 2) status query (collecting over a window): language(english+voice) / NC high / self-voice medium
        try await transport.awaitWrite(count: 2)
        await channel.ingest([0x01, 0x03, 0x03, 0x01, 0xA1])
        await channel.ingest([0x01, 0x06, 0x03, 0x01, 0x01])
        await channel.ingest([0x01, 0x0b, 0x03, 0x02, 0x01, 0x02])
        // 3) auto-off query → 20 minutes
        try await transport.awaitWrite(count: 3)
        await channel.ingest([0x01, 0x04, 0x03, 0x01, 0x14])
        // 4) button-action query → noise cancellation
        try await transport.awaitWrite(count: 4)
        await channel.ingest([0x01, 0x09, 0x03, 0x04, 0x10, 0x04, 0x02, 0x07])

        let s = await state
        XCTAssertEqual(s.battery, 90)
        XCTAssertEqual(s.noiseCancellationLevel, .high)
        XCTAssertEqual(s.selfVoice, .medium)
        XCTAssertEqual(s.promptLanguage, .english)
        XCTAssertEqual(s.voicePromptsEnabled, true)
        XCTAssertEqual(s.autoOff, .twenty)
        XCTAssertEqual(s.buttonAction, .noiseCancellation)
    }

    func testReadStateLeavesNilFieldsWhenNothingResponds() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = BosePlugin()
        let s = await plugin.readState(over: channel) // everything times out
        XCTAssertNil(s.battery)
        XCTAssertNil(s.noiseCancellationLevel)
        XCTAssertNil(s.autoOff)
        XCTAssertNil(s.buttonAction)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: FAIL — `readState` stub returns an empty `DeviceState`, so the populated-field assertions fail.

- [ ] **Step 3: Implement readState**

In `BosePlugin.swift`, replace the temporary `readState` stub with:

```swift
    public func readState(over channel: DeviceChannel) async -> DeviceState {
        var state = DeviceState()

        // Battery (reuse the existing battery path).
        state.battery = await readBatteryLevel(over: channel)

        // Status broadcasts: collect everything starting 0x01 over a 1s window, then decode.
        let statusBuffer = (try? await channel.send(
            BoseCodec.encodeStatusQuery(),
            matcher: .collecting(prefix: [0x01]),
            timeout: 1.0)) ?? []
        let status = BoseCodec.decodeStatus(statusBuffer)
        state.noiseCancellationLevel = status.noiseCancellation
        state.selfVoice = status.selfVoice
        state.promptLanguage = status.promptLanguage
        state.voicePromptsEnabled = status.voicePromptsEnabled
        if let langByte = status.languageByte { lastLanguageByte = langByte }

        // Auto-off.
        let autoOffReply = await sendExpecting(BoseCodec.encodeAutoOffQuery(),
                                               prefix: [0x01, 0x04], over: channel)
        state.autoOff = BoseCodec.decodeAutoOff(autoOffReply)

        // Button action.
        let buttonReply = await sendExpecting(BoseCodec.encodeButtonActionQuery(),
                                              prefix: [0x01, 0x09], over: channel)
        state.buttonAction = BoseCodec.decodeButtonAction(buttonReply)

        return state
    }
```

(`sendExpecting` already exists on `BosePlugin` from the battery/metadata code.)

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS. The Core seam is now complete and proven byte-equivalent to the old Bose path.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundSherpaCore/BosePlugin.swift Tests/SoundSherpaCoreTests/BosePluginTests.swift
git commit -m "feat(core): BosePlugin.readState assembling battery+status+autoOff+buttonAction"
```

---

## Task 8: Controller — brand-agnostic discovery & connection

Rewire `DeviceController`'s detection and connect path to be brand-agnostic, driven by the registry + the active plugin's `discoveryDescriptor`. **Concurrency mechanics are copied verbatim** — only the name match and the service/channel lookup change source. The app target is `@MainActor`/IOBluetooth and has no unit tests; verification is `swift build` + the manual on-device smoke test at the end of Task 10.

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift`

**Interfaces:**
- Consumes: `DeviceRegistry.plugin(forDeviceNamed:)` (existing), `activePlugin.discoveryDescriptor`, `ServiceMatcher` (Task 3).
- Produces: `checkForSupportedDevices()`, `isSupportedDevice(_:)`, `connectSupportedDeviceSync(address:)`, `serviceRecord(matching:in:)`, and descriptor-driven `openChannel`. (These rename/replace `checkForBoseDevices`, `isBoseDevice`, `connectToBoseDeviceSync`.)

- [ ] **Step 1: Rename detection to be registry-driven**

In `DeviceController.swift`, rename `checkForBoseDevices()` → `checkForSupportedDevices()` and change the name filter to ask the registry. Replace the paired-device loop condition:

```swift
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
```

Update the two timer/notification call sites that call `checkForBoseDevices()` (in `finishStartMonitoring` and `systemDidWake` and `deviceConnected`) to call `checkForSupportedDevices()`.

- [ ] **Step 2: Make device-match brand-agnostic**

Replace `isBoseDevice(_:)` with:

```swift
    private func isSupportedDevice(_ device: IOBluetoothDevice) -> Bool {
        guard let name = device.name else { return false }
        return deviceRegistry.plugin(forDeviceNamed: name) != nil
    }
```

Update `deviceConnected` and `deviceDisconnected` to call `isSupportedDevice(device)` instead of `isBoseDevice(device)`. Rename the `currentBoseDevice` references only if you wish; leaving the property name is acceptable (it is private state), but prefer renaming to `currentDevice` for clarity in a follow-up — out of scope here to keep the diff minimal.

- [ ] **Step 3: Descriptor-drive the SDP service lookup**

Rename `connectToBoseDeviceSync(address:)` → `connectSupportedDeviceSync(address:)`. Keep the device-finding, `openConnection`, `performSDPQuery`, and retry logic **verbatim**. Replace only the service-selection block (the `"SPP Dev"` lookup) with a descriptor-driven search. Add this helper:

```swift
    /// Find the first SDP service record matching any of the descriptor's matchers, in order.
    nonisolated private func serviceRecord(matching matchers: [ServiceMatcher],
                                           in records: [IOBluetoothSDPServiceRecord]) -> IOBluetoothSDPServiceRecord? {
        for matcher in matchers {
            switch matcher {
            case .serviceName(let wanted):
                if let r = records.first(where: { $0.getServiceName() == wanted }) { return r }
            case .uuid(let uuidString):
                if let r = records.first(where: { record in
                    if uuidString.hasPrefix("0x"), let v = UInt16(uuidString.dropFirst(2), radix: 16) {
                        return record.matchesUUID16(v)
                    }
                    if let uuid = IOBluetoothSDPUUID(string: uuidString) {
                        return record.hasServiceFromArray([uuid])
                    }
                    return false
                }) { return r }
            }
        }
        return nil
    }
```

Then in `connectSupportedDeviceSync`, replace:

```swift
        guard let sppService = services.first(where: { $0.getServiceName() == "SPP Dev" }) else {
            // ... fallback ...
        }
        return connectToService(device: device, service: sppService)
```

with:

```swift
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
```

Also update the `activePlugin == nil` resolution inside `connectSupportedDeviceSync` (it currently checks `name.contains("Bose")`); replace that fallback `device.name.contains("Bose")` matcher in the `first(where:)` device search with `isSupportedDevice(device)` so a non-Bose supported device is found by address too. The address-equality branches stay unchanged.

- [ ] **Step 4: Descriptor-drive the channel brute-force**

In `openChannel(device:channelId:)`, replace the hardcoded:

```swift
        let channelIdsToTry: [BluetoothRFCOMMChannelID] = [8, 9, 1, 2, 3]
```

with:

```swift
        let channelIdsToTry: [BluetoothRFCOMMChannelID] =
            (activePlugin?.discoveryDescriptor.channelHints ?? [8, 9, 1, 2, 3])
            .map { BluetoothRFCOMMChannelID($0) }
```

- [ ] **Step 5: Rename the detection-start method**

Rename `detectNoiseCancellationStatusAsync()` → `detectDeviceStateAsync()` (it now reads full state, not only NC). Keep its body's connect-on-`connectionQueue` structure verbatim; only the inner fetch call changes in Task 9. Update its call sites (`checkForSupportedDevices`, the `ncPollTimer` closure in `finishStartMonitoring`).

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build`
Expected: builds. (Intents still reference old methods — those are migrated in Task 9. If the build fails only on `setNoiseCancellation`/`fetchAllDeviceInfo` internals, that's expected; this task's rename should compile on its own since those methods still exist. If a renamed method is referenced anywhere you missed, the compiler names the file/line — fix and rebuild.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift
git commit -m "refactor(app): brand-agnostic device discovery + descriptor-driven connect"
```

---

## Task 9: Controller — route intents through the plugin & populate from readState

Make the controller's intent methods build `DeviceChange` and call `activePlugin.apply`, and replace the Bose-specific fetch methods with a single `plugin.readState` call that fans out into the existing observable properties. Delete the now-dead Bose byte logic from the controller.

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift`

**Interfaces:**
- Consumes: `activePlugin.apply(_:over:)`, `activePlugin.readState(over:)`, `DeviceChange`, `DeviceState`.
- Produces: `var supportedFeatures: Set<DeviceFeature>` (observable), reworked intents, `fetchAllDeviceInfo` using `readState`.

- [ ] **Step 1: Add an observable supportedFeatures and a helper to apply a change**

Add an observable property near the other observable state:

```swift
    // Which controls the active device exposes; drives UI gating. Empty when disconnected.
    var supportedFeatures: Set<DeviceFeature> = []
```

Add a private helper that runs a change through the active plugin over the channel:

```swift
    /// Apply a typed change through the active plugin over the serialized channel. Returns
    /// whether it was acknowledged. Mirrors the old per-intent send, but brand-agnostic.
    private func applyChange(_ change: DeviceChange) async -> Bool {
        guard await ensureConnected(), let plugin = activePlugin, let channel = deviceChannel else {
            return false
        }
        return await plugin.apply(change, over: channel)
    }
```

- [ ] **Step 2: Rewrite the intent methods as DeviceChange wrappers**

Replace the bodies of the existing intents. `setNoiseCancellation`:

```swift
    func setNoiseCancellation(_ level: NoiseCancellationLevel) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.noiseCancellation(level)) {
                self.ncLevel = level
            }
        }
    }
```

`setSelfVoice`:

```swift
    func setSelfVoice(_ level: SelfVoiceLevel) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.selfVoice(level)) {
                self.selfVoiceLevel = level
            }
        }
    }
```

`setAutoOff`:

```swift
    func setAutoOff(_ value: AutoOff) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.autoOff(value)) {
                self.autoOff = value
            }
        }
    }
```

`setLanguage`:

```swift
    func setLanguage(_ value: PromptLanguage) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.promptLanguage(value)) {
                self.language = value
            }
        }
    }
```

`setVoicePrompts`:

```swift
    func setVoicePrompts(_ on: Bool) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.voicePrompts(on)) {
                self.voicePromptsEnabled = on
            }
        }
    }
```

`setButtonAction`:

```swift
    func setButtonAction(_ value: ButtonAction) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.buttonAction(value)) {
                self.buttonAction = value
            }
        }
    }
```

- [ ] **Step 3: Replace the fetch path with readState**

Replace `fetchAllDeviceInfo()`'s body so it calls the plugin once and fans the result out, plus refreshes `supportedFeatures` and keeps the paired-devices fetch (which stays in the controller for this sub-project):

```swift
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
```

- [ ] **Step 4: Delete the now-dead Bose-specific fetch/parse/set methods**

Remove these methods (their logic now lives in `BosePlugin`/`BoseCodec`):
`initBoseConnection()`, `fetchBatteryLevel()`, `fetchSerialNumber()`, `fetchDeviceStatus()`, `parseDeviceStatusResponse(_:)`, `fetchAutoOffStatus()`, `fetchButtonActionStatus()`, `getAutoOff()`, `setAutoOffValue(_:)`.

Keep: `fetchPairedDevices()`, `getDeviceStatus(address:)`, `connectPairedDevice`, `disconnectPairedDevice`, `addressStringToBytes`, `getDeviceNameForAddress`, the `send`/`collect` helpers (still used by paired-device code), `storeMetadata`, `applyCachedMetadata`, `sdpMetadata`, `sdpUInt16Hex`.

In `detectDeviceStateAsync()` (renamed in Task 8), replace the inner `Task` body that called `initBoseConnection()` + `fetchAllDeviceInfo()`:

```swift
            Task { [weak self] in
                guard let self else { return }
                print(">>> Fetching device info...")
                await self.fetchAllDeviceInfo()
            }
```

- [ ] **Step 5: Keep the unsolicited NC broadcast handler (Bose-shaped, gated)**

In `rfcommChannelData`, the unsolicited NC-status reflection block stays. Guard it so it only runs for the Bose plugin (it is Bose-frame-specific) — change its `if` to also require the active plugin is Bose:

```swift
        if activePlugin?.identifier == "Bose",
           responseData.count >= 5, responseData[0] == 0x01, responseData[1] == 0x06 {
            // ... existing ncByte extraction + Task { @MainActor } update ...
        }
```

(Generalizing this into a plugin hook is deferred to sub-project B when Sony needs live ANC reflection.)

- [ ] **Step 6: Clear supportedFeatures on disconnect**

In `deviceDisconnected` and `rfcommChannelClosed`, where `isConnected`/`deviceName`/`batteryLevel` are cleared, also add:

```swift
            self.supportedFeatures = []
```

- [ ] **Step 7: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build`
Expected: builds with no references to the deleted methods. If the compiler flags a leftover caller (e.g. a `getAutoOff` reference), remove/redirect it.

- [ ] **Step 8: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS (Core tests unaffected; this is an app-target change).

- [ ] **Step 9: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift
git commit -m "refactor(app): route intents through plugin.apply and populate from readState"
```

---

## Task 10: UI feature gating + on-device smoke test

Gate the Device-tab controls and the menu tile on `controller.supportedFeatures` so only supported controls render. For Bose the set covers all currently-visible controls, so the UI is visually unchanged. Then run the manual Bose regression smoke test (the wire behavior is unchanged, so this confirms the refactor end-to-end).

**Files:**
- Modify: `Sources/SoundSherpa/Views/SettingsView.swift`
- Modify: `Sources/SoundSherpa/Views/ContentTile.swift`

**Interfaces:**
- Consumes: `controller.supportedFeatures` (Task 9), `DeviceFeature`.

- [ ] **Step 1: Gate the SettingsView controls**

In `SettingsView.swift`'s `deviceTab`, wrap each control in a `supportedFeatures` check. Replace the `Section("Controls")` body so each picker/toggle is conditional:

```swift
                        Section("Controls") {
                            if controller.supportedFeatures.contains(.autoOff) {
                                Picker("Auto-Off", selection: Binding(
                                    get: { controller.autoOff ?? .never },
                                    set: { controller.setAutoOff($0) })) {
                                    ForEach([AutoOff.never, .five, .twenty, .forty, .sixty, .oneEighty], id: \.rawValue) {
                                        Text($0.displayName).tag($0)
                                    }
                                }
                                Text("Turn the headphones off after a period of inactivity to save battery.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            if controller.supportedFeatures.contains(.buttonAction) {
                                Picker("Button Action", selection: Binding(
                                    get: { controller.buttonAction ?? .noiseCancellation },
                                    set: { controller.setButtonAction($0) })) {
                                    Text("Alexa").tag(ButtonAction.alexa)
                                    Text("Noise Cancellation").tag(ButtonAction.noiseCancellation)
                                }
                                Text("Choose what a press of the headphones' action button does.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            if controller.supportedFeatures.contains(.promptLanguage) {
                                Picker("Language", selection: Binding(
                                    get: { controller.language ?? .english },
                                    set: { controller.setLanguage($0) })) {
                                    ForEach(languageChoices, id: \.rawValue) { Text($0.displayName).tag($0) }
                                }
                                Toggle("Voice Prompts", isOn: Binding(
                                    get: { controller.voicePromptsEnabled ?? false },
                                    set: { controller.setVoicePrompts($0) }))
                            }
                        }
```

- [ ] **Step 2: Gate the menu tile controls**

In `ContentTile.swift`, wrap the NC control (lines ~20–23) and the self-voice control (lines ~29–32) in feature checks. For the NC segment:

```swift
                if controller.supportedFeatures.contains(.noiseCancellation) {
                    // ... existing NC segmented control using controller.ncLevel / setNoiseCancellation ...
                }
```

and for self-voice:

```swift
                if controller.supportedFeatures.contains(.selfVoice) {
                    // ... existing self-voice control using controller.selfVoiceLevel / setSelfVoice ...
                }
```

(Wrap the existing view code unchanged inside these `if` blocks — do not alter the control internals.)

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build`
Expected: builds.

- [ ] **Step 4: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS.

- [ ] **Step 5: On-device Bose smoke test (manual regression gate)**

Build the app bundle, ad-hoc sign with the stable identifier, kill stale instances, and launch:

```bash
pkill -9 -f SoundSherpa || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build
# (sign/launch the produced .app per the project's run procedure)
codesign --force --sign - --identifier nl.imick.soundsherpa <path-to>/SoundSherpa.app
```

With a Bose device connected, verify in the menu/Settings that all behave exactly as before the refactor:
- Battery percentage shows.
- ANC segmented control reads current state and changing it takes effect.
- Self-voice control works.
- Auto-Off, Button Action, Language, Voice Prompts read and write correctly.
- Paired-device list populates.

Because Sub-project A introduces **no wire change**, this should be a pure confirmation. If anything regresses, the byte-parity tests (Tasks 4/6/7) plus the changed call sites in Tasks 8–9 are where to look.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift Sources/SoundSherpa/Views/ContentTile.swift
git commit -m "feat(app): gate device controls on plugin supportedFeatures"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** Tasks map 1:1 onto the spec sections — value types (T2), discovery (T3), protocol extension (T5), Bose control codecs (T4), `apply`/`readState` parity (T6/T7), controller discovery (T8), controller intents/state (T9), UI gating (T10), enum relocation (T1).
- **Deferred per spec (not gaps):** multipoint/paired-device generalization and the unsolicited-broadcast plugin hook remain controller-side and Bose-shaped — intentional, documented in the spec's non-goals.
- **The hard gate** is the byte-parity assertion set in Tasks 4, 6, and 7: if those pass, Bose's wire behavior is provably unchanged before any controller wiring lands.
- **Sony (Sub-project B)** is out of scope here; it adds a `SonyCodec` + marker-delimited `ResponseMatcher` + `SonyPlugin` (with `anc`/`equalizer`/`ambientLevel` via the generic fields this sub-project established) and its own brainstorm/plan cycle.
