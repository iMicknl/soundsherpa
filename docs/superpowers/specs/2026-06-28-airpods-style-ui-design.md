# SoundSherpa UI v3 — AirPods-style Liquid Glass control tile

**Date:** 2026-06-28
**Status:** Approved design, pre-implementation

## Goal

Replace the current `NSMenu`-based menu-bar UI with a clean, Apple-native control
tile modeled on the macOS Control Center AirPods module: a glass panel with a hero
device header, segmented "pill" controls, and progressive disclosure for advanced
options. Deep configuration moves to a standard SwiftUI Settings window.

The information architecture of the current app is correct; this is a
**presentation rewrite**, not a behavior change. The Bluetooth/RFCOMM/lifecycle
logic — which carries hard-won fixes (single-channel teardown, sleep/wake handling,
the `DeviceChannel` actor) — is preserved.

## Locked decisions

1. **OS target:** Require macOS 26 (Tahoe). Raise the SPM minimum deployment target
   to `.macOS(.v26)` and build against the macOS 26 SDK. One code path, authentic
   Liquid Glass, native SwiftUI APIs — no fallback branches.
2. **UI container:** SwiftUI `MenuBarExtra(..., .window)` replacing `NSMenu`.
3. **Disclosure model:** Minimal default panel (hero header + Noise Cancellation),
   with an inline "More" disclosure revealing Self Voice + Paired Devices. Deep
   config lives in a separate Settings window.
4. **Device art:** Reuse the `headphones.over.ear` SF Symbol on a tinted circle
   (no shipped product-image assets).
5. **Settings surface:** Standard SwiftUI `Settings` scene (native ⌘, window with
   system toolbar-tab chrome).

## Architecture

### The controller seam

Today `AppDelegate` (~2,600 lines) tangles three concerns: IOBluetooth transport,
app lifecycle, and UI (mutating `NSMenu` via `DispatchQueue.main.async`). Only the
UI concern is being replaced. We extract a seam:

- **`DeviceController` (`@MainActor`, `@Observable`)** — the single source of truth
  the SwiftUI views observe. Holds published state and exposes intent methods.
  - **State:** `deviceName: String?`, `batteryLevel: Int?`, `isConnected: Bool`,
    `ncLevel: NoiseCancellationLevel?`, `selfVoiceLevel: SelfVoiceLevel?`,
    `pairedDevices: [PairedDeviceInfo]`, and advanced fields (`autoOff`, `language`,
    `voicePromptsEnabled`, `buttonAction`, plus read-only `firmware`, `serial`,
    `deviceId`, `services`).
  - **Intents:** `setNoiseCancellation(_:)`, `setSelfVoice(_:)`,
    `connectPairedDevice(_:)`, `disconnectPairedDevice(_:)`, `setAutoOff(_:)`,
    `setLanguage(_:)`, `setVoicePrompts(_:)`, `setButtonAction(_:)`, `refresh()`.
- The existing IOBluetooth code (scanning, RFCOMM open/teardown, SDP, the
  `DeviceChannel` actor I/O, the `DeviceRegistry`/`DevicePlugin` routing) moves
  largely intact into `DeviceController` or a helper it owns. Each place that today
  does `DispatchQueue.main.async { self.updateNCSelection(...) }` becomes a plain
  property assignment on the `@Observable`; SwiftUI re-renders automatically.
- This **deletes** the `MenuTag` enum, every `item(withTag:)` lookup, all custom
  `NSView` item builders, and `updateMenuItemsVisibility` (~1,000 lines of menu
  plumbing).
- **`AppDelegate`** shrinks to lifecycle only — Bluetooth connect/disconnect
  notifications, sleep/wake observers, and synchronous termination teardown — wired
  in via `@NSApplicationDelegateAdaptor`. The synchronous `connectionQueue.sync`
  teardown on terminate is preserved exactly (it prevents orphaning the device's
  single control channel).

### Concurrency note

`DeviceController` is `@MainActor`. The blocking IOBluetooth open + SDP query must
still run off the main thread on the existing serial `connectionQueue` (the
documented root cause of the "detected but shows nothing" bug is delegate-callback
delivery requiring an off-main run loop). Command I/O remains serialized by the
`DeviceChannel` actor. The controller bridges these with `await`/continuation hops,
exactly as `ensureConnected()` does today; only the final UI update changes from
menu mutation to property assignment.

## View hierarchy

```
SoundSherpaApp (App)
├─ MenuBarExtra("SoundSherpa", systemImage: "headphones.over.ear") { ContentTile() }
│      .menuBarExtraStyle(.window)
└─ Settings { AdvancedSettingsView() }          ← native ⌘, window

ContentTile                                       ← the glass panel
├─ DeviceHeaderView         hero: glyph-in-circle, name, battery pill
├─ Divider
├─ SegmentedSection("Noise Cancellation")         NC pills (Off · Low · High)
├─ DisclosureGroup("More")  ← collapsed by default
│   ├─ SegmentedSection("Self Voice")             (Off · Low · Med · High)
│   └─ PairedDevicesList                           resolved names + active dot
├─ Divider
└─ TileFooter              Advanced Settings… · About · Quit
```

All views observe `DeviceController` from the SwiftUI environment.

### Components

- **`SegmentedSection<Option>`** — reusable. A
  `.subheadline.weight(.semibold).foregroundStyle(.secondary)` label above a
  horizontal row of **pills**. Each pill is icon-over-label; the selected pill fills
  with `.tint` and a glass highlight. Generic over a `CaseIterable` enum of options
  (each supplying a title + SF Symbol name), so the NC and Self Voice sections share
  one implementation. Selection binds to a controller intent. This is the central
  AirPods element and replaces both checkmark-lists.
- **`DeviceHeaderView`** — `headphones.over.ear` SF Symbol on a tinted `Circle`,
  name in `.headline`, battery rendered as a colored battery SF Symbol + `%`. Color
  thresholds reuse the existing logic (≤20 red, ≤50 amber, else normal) and the
  existing `batteryIconNameForLevel` mapping.
- **`PairedDevicesList`** — resolved names only. Unresolved addresses render as
  "Unknown Device" with the type glyph (reusing `DeviceTypeResolver` and the
  `PairedDeviceType.iconName` extension, which moves into the SwiftUI layer). The
  active device shows a filled accent dot, not a checkmark. Tapping a row toggles
  connect/disconnect via controller intents.
- **`TileFooter`** — "Advanced Settings…" (opens the Settings scene), "About
  SoundSherpa", "Quit". `About` may stay an `NSAlert` or move into the Settings
  About tab; either is acceptable.
- **Disconnected state** — when `!isConnected`, the tile collapses to just the
  header ("No device connected") and a Connect affordance; the NC/More/Paired
  sections are hidden. Replaces `updateMenuItemsVisibility`.

## Styling (Liquid Glass / Tahoe)

- Panel chrome comes from `.menuBarExtraStyle(.window)`. Inner cards use
  `.background(.regularMaterial, in: .rect(cornerRadius:))` with **concentric**
  radii (outer panel radius larger than inner control radii).
- `.tint(.accentColor)` throughout so pills and the active-device dot pick up the
  system accent.
- 16–20pt padding, consistent SF Symbol sizing, `.controlSize(.large)` on the
  segmented pills.

## Settings window

`AdvancedSettingsView` in a `Settings` scene, organized as a `TabView` with
toolbar-tab styling:

- **General** — Auto-Off (`Picker`), Button Action (`Picker`).
- **Voice** — Language (`Picker`), Voice Prompts (`Toggle`).
- **About** — read-only device info (firmware, serial, device ID, services) as a
  list, plus the existing About copy. Each info row **hides when its value is nil**,
  preserving the R5.8 rule (no fabricated "Unknown" placeholders).

Every control binds to a `DeviceController` intent — the same RFCOMM command bytes
as today, driven by SwiftUI bindings instead of `@objc` selectors.

## Domain types

Introduce small enums to replace raw `UInt8` state and the magic tag offsets:

- `NoiseCancellationLevel { off, low, high }` with byte mappings (0x00 / 0x03 / 0x01).
- `SelfVoiceLevel { off, low, medium, high }` (reuse existing `SelfVoice` raw values).
- The existing `AutoOff`, `PromptLanguage`, `ButtonAction`, `PairedDeviceInfo`, and
  `PairedDeviceType` types are reused; `PromptLanguage`/`SelfVoice`/`AutoOff`/
  `ButtonAction` move into a shared location accessible to the controller and views.

## Testing

- `SoundSherpaCore` tests remain green and untouched — no core logic changes.
- `DeviceController`'s pure state-mapping (battery→color, NC byte↔segment,
  paired-device name resolution) is unit-testable by injecting a mock channel; lift
  the existing `ScriptedTransport` from the test suite for this.
- SwiftUI views are validated by building and running the app against macOS 26.

## Out of scope

- No new device-protocol features or command changes.
- No shipped product-image assets (SF Symbol art only).
- No support for macOS versions below 26.
- No changes to `SoundSherpaCore` behavior.

## Migration / build impact

- `Package.swift`: bump `swift-tools-version` as needed and set platform to
  `.macOS(.v26)`.
- Build must use the macOS 26 SDK toolchain (per global instruction, via the
  devcontainer CLI / project build script).
- `Info.plist` `LSMinimumSystemVersion` updated to 26.0.
