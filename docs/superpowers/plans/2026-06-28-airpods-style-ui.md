# AirPods-style Liquid Glass UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `NSMenu`-based menu-bar UI with a SwiftUI `MenuBarExtra(.window)` control tile modeled on the Control Center AirPods module, backed by an `@Observable` controller that wraps the existing Bluetooth stack.

**Architecture:** Extract a `DeviceController` (`@MainActor`, `@Observable`) seam that owns all device state and intent methods. The working IOBluetooth/RFCOMM/lifecycle logic moves into it largely intact; every former `DispatchQueue.main.async { menu mutation }` becomes a property assignment SwiftUI observes. The `NSMenu` plumbing (`MenuTag`, `item(withTag:)`, custom `NSView` builders, `updateMenuItemsVisibility`) is deleted. Deep config moves to a standard `Settings` scene.

**Tech Stack:** Swift 6 / SwiftUI, `MenuBarExtra`, `@Observable`, AppKit `@NSApplicationDelegateAdaptor`, IOBluetooth, the existing `SoundSherpaCore` package (`DeviceChannel` actor, `DevicePlugin`, `DeviceRegistry`).

## Global Constraints

- Minimum deployment target: **macOS 26 (Tahoe)**. Build against the macOS 26 SDK. No fallback code paths for older systems.
- Device art: `headphones.over.ear` SF Symbol only — no shipped product-image assets.
- Info rows (firmware/serial/device ID/services) **hide when their value is nil** — never display a fabricated "Unknown" placeholder (R5.8).
- Preserve the synchronous `connectionQueue.sync { closeChannelLocked() }` teardown on app termination — it prevents orphaning the device's single RFCOMM control channel.
- `SoundSherpaCore` behavior is unchanged; its existing tests must stay green.
- Builds and tests run via the project's native macOS flow (`swift build` / `./build.sh` / `swift test`), not the Linux devcontainer — this target requires the macOS SDK and IOBluetooth.
- NC byte mapping: Off `0x00`, Low `0x03`, High `0x01`. Self Voice byte mapping: Off `0x00`, High `0x01`, Medium `0x02`, Low `0x03`.

---

## File Structure

**Created:**
- `Sources/SoundSherpaCore/DeviceLevels.swift` — `NoiseCancellationLevel`, `SelfVoiceLevel` enums (pure, testable, byte mappings).
- `Sources/SoundSherpa/DeviceController.swift` — `@MainActor @Observable` state + intents; owns the migrated Bluetooth code.
- `Sources/SoundSherpa/Views/ContentTile.swift` — root glass panel.
- `Sources/SoundSherpa/Views/DeviceHeaderView.swift` — hero header.
- `Sources/SoundSherpa/Views/SegmentedSection.swift` — reusable pill section.
- `Sources/SoundSherpa/Views/PairedDevicesList.swift` — paired-device rows.
- `Sources/SoundSherpa/Views/TileFooter.swift` — footer actions.
- `Sources/SoundSherpa/Views/AdvancedSettingsView.swift` — Settings scene content.
- `Sources/SoundSherpa/PairedDeviceTypeIcon.swift` — `PairedDeviceType.iconName` (moved from AppDelegate).
- `Tests/SoundSherpaCoreTests/DeviceLevelsTests.swift` — enum mapping tests.

**Modified:**
- `Package.swift` — platform `.macOS(.v26)`, tools version, restructure `SoundSherpa` target to include `Sources/SoundSherpa/Views`.
- `Info.plist` — `LSMinimumSystemVersion` → `26.0`.
- `Sources/SoundSherpa/main.swift` — replaced by the SwiftUI `App` entry (or a new `SoundSherpaApp.swift`).
- `Sources/SoundSherpa/AppDelegate.swift` — gutted to lifecycle-only adaptor; menu code deleted.

---

## Task 1: Raise platform to macOS 26

**Files:**
- Modify: `Package.swift:6-8`
- Modify: `Info.plist`

**Interfaces:**
- Produces: a package that compiles against the macOS 26 SDK; all later SwiftUI APIs assume this floor.

- [ ] **Step 1: Set the platform floor**

In `Package.swift`, change the platforms array:

```swift
platforms: [
    .macOS(.v26)
],
```

- [ ] **Step 2: Set the Info.plist minimum system version**

In `Info.plist`, ensure these keys exist (add or update):

```xml
<key>LSMinimumSystemVersion</key>
<string>26.0</string>
<key>LSUIElement</key>
<true/>
```

- [ ] **Step 3: Verify it still builds**

Run: `swift build`
Expected: build succeeds (no source changes yet).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Info.plist
git commit -m "build(ui): require macOS 26 for Liquid Glass UI"
```

---

## Task 2: Device level enums in Core

**Files:**
- Create: `Sources/SoundSherpaCore/DeviceLevels.swift`
- Test: `Tests/SoundSherpaCoreTests/DeviceLevelsTests.swift`

**Interfaces:**
- Produces:
  - `enum NoiseCancellationLevel: CaseIterable, Sendable { case off, low, high }` with `var byte: UInt8` and `init?(byte: UInt8)`.
  - `enum SelfVoiceLevel: UInt8, CaseIterable, Sendable { case off = 0x00, high = 0x01, medium = 0x02, low = 0x03 }` with display ordering `[.off, .low, .medium, .high]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/DeviceLevelsTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceLevelsTests: XCTestCase {
    func testNoiseCancellationByteMapping() {
        XCTAssertEqual(NoiseCancellationLevel.off.byte, 0x00)
        XCTAssertEqual(NoiseCancellationLevel.low.byte, 0x03)
        XCTAssertEqual(NoiseCancellationLevel.high.byte, 0x01)
    }

    func testNoiseCancellationRoundTrip() {
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x00), .off)
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x03), .low)
        XCTAssertEqual(NoiseCancellationLevel(byte: 0x01), .high)
        XCTAssertNil(NoiseCancellationLevel(byte: 0xFF))
    }

    func testSelfVoiceByteMapping() {
        XCTAssertEqual(SelfVoiceLevel.off.rawValue, 0x00)
        XCTAssertEqual(SelfVoiceLevel.high.rawValue, 0x01)
        XCTAssertEqual(SelfVoiceLevel.medium.rawValue, 0x02)
        XCTAssertEqual(SelfVoiceLevel.low.rawValue, 0x03)
    }

    func testSelfVoiceDisplayOrder() {
        XCTAssertEqual(SelfVoiceLevel.displayOrder, [.off, .low, .medium, .high])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceLevelsTests`
Expected: FAIL — `NoiseCancellationLevel` / `SelfVoiceLevel` not found.

- [ ] **Step 3: Write the implementation**

Create `Sources/SoundSherpaCore/DeviceLevels.swift`:

```swift
import Foundation

/// Noise-cancellation strength. Byte values are non-contiguous on the wire
/// (Off 0x00, Low 0x03, High 0x01), so the mapping is explicit rather than a raw enum.
public enum NoiseCancellationLevel: CaseIterable, Sendable {
    case off, low, high

    public var byte: UInt8 {
        switch self {
        case .off: return 0x00
        case .low: return 0x03
        case .high: return 0x01
        }
    }

    public init?(byte: UInt8) {
        switch byte {
        case 0x00: self = .off
        case 0x03: self = .low
        case 0x01: self = .high
        default: return nil
        }
    }
}

/// Self-voice (sidetone) level. Raw values match the device protocol directly.
public enum SelfVoiceLevel: UInt8, CaseIterable, Sendable {
    case off = 0x00
    case high = 0x01
    case medium = 0x02
    case low = 0x03

    /// Off → Low → Medium → High, the order the pills are displayed in.
    public static let displayOrder: [SelfVoiceLevel] = [.off, .low, .medium, .high]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DeviceLevelsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceLevels.swift Tests/SoundSherpaCoreTests/DeviceLevelsTests.swift
git commit -m "feat(core): add NoiseCancellationLevel and SelfVoiceLevel enums"
```

---

## Task 3: DeviceController — observable state and pure mappings

**Files:**
- Create: `Sources/SoundSherpa/DeviceController.swift`
- Test: `Tests/SoundSherpaCoreTests/DeviceControllerMappingTests.swift` (pure helpers only — see note)

**Note on test placement:** SwiftUI/AppKit types can't be tested in `SoundSherpaCoreTests`. Keep the *pure* mapping helpers (battery color tier, paired-device display name) as `static` functions in a small `enum DeviceDisplay` inside `SoundSherpaCore` so they're testable, and have `DeviceController` call them. This step adds those pure helpers + tests; the controller shell that holds state is added here too but exercised by running the app.

**Interfaces:**
- Produces:
  - `enum BatteryTier { case normal, low, critical }` + `DeviceDisplay.batteryTier(forLevel: Int) -> BatteryTier` (critical ≤20, low ≤50, else normal) in `SoundSherpaCore`.
  - `DeviceDisplay.pairedDeviceDisplayName(rawName: String, address: String) -> String` — returns `rawName` if non-empty and not equal to the address, else "Unknown Device".
  - `@MainActor @Observable final class DeviceController` with stored properties: `deviceName: String?`, `batteryLevel: Int?`, `isConnected: Bool`, `ncLevel: NoiseCancellationLevel?`, `selfVoiceLevel: SelfVoiceLevel?`, `pairedDevices: [PairedDeviceInfo]`, `firmware: String?`, `serial: String?`, `deviceId: String?`, `services: [String]?`, `autoOff: AutoOff?`, `language: PromptLanguage?`, `voicePromptsEnabled: Bool?`, `buttonAction: ButtonAction?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/DeviceControllerMappingTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceControllerMappingTests: XCTestCase {
    func testBatteryTiers() {
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 15), .critical)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 20), .critical)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 21), .low)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 50), .low)
        XCTAssertEqual(DeviceDisplay.batteryTier(forLevel: 80), .normal)
    }

    func testPairedDeviceDisplayNameFallsBackForAddress() {
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "AC:07:75:42:C8:C0", address: "AC:07:75:42:C8:C0"),
            "Unknown Device")
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "", address: "AC:07:75:42:C8:C0"),
            "Unknown Device")
        XCTAssertEqual(
            DeviceDisplay.pairedDeviceDisplayName(rawName: "Mick's MacBook Pro", address: "AC:07:75:42:C8:C0"),
            "Mick's MacBook Pro")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceControllerMappingTests`
Expected: FAIL — `DeviceDisplay` not found.

- [ ] **Step 3: Add the pure helpers**

Create `Sources/SoundSherpaCore/DeviceDisplay.swift`:

```swift
import Foundation

/// Battery color tier shared by the menu-bar icon and the header pill.
public enum BatteryTier: Sendable { case normal, low, critical }

/// Pure presentation mappings used by the UI layer. Kept in the core so they're
/// unit-testable without AppKit/SwiftUI.
public enum DeviceDisplay {
    /// ≤20 critical (red), ≤50 low (amber), else normal. Matches the legacy thresholds.
    public static func batteryTier(forLevel level: Int) -> BatteryTier {
        if level <= 20 { return .critical }
        if level <= 50 { return .low }
        return .normal
    }

    /// A paired device's human label, or "Unknown Device" when all we have is its address.
    public static func pairedDeviceDisplayName(rawName: String, address: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Unknown Device" }
        if trimmed.caseInsensitiveCompare(address) == .orderedSame { return "Unknown Device" }
        return trimmed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DeviceControllerMappingTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the controller shell**

Create `Sources/SoundSherpa/DeviceController.swift`. This step adds only the observable state container and empty intent methods; the Bluetooth body is migrated in Task 4.

```swift
import Foundation
import Observation
import SoundSherpaCore

/// Single source of truth the SwiftUI views observe. Holds all device state as
/// observable properties and exposes intent methods the views call. The Bluetooth
/// implementation is migrated in from AppDelegate (Task 4); this shell defines the seam.
@MainActor
@Observable
final class DeviceController {
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

    // Intents — bodies filled in Task 4.
    func refresh() {}
    func setNoiseCancellation(_ level: NoiseCancellationLevel) {}
    func setSelfVoice(_ level: SelfVoiceLevel) {}
    func connectPairedDevice(_ device: PairedDeviceInfo) {}
    func disconnectPairedDevice(_ device: PairedDeviceInfo) {}
    func setAutoOff(_ value: AutoOff) {}
    func setLanguage(_ value: PromptLanguage) {}
    func setVoicePrompts(_ on: Bool) {}
    func setButtonAction(_ value: ButtonAction) {}
}
```

Note: `PairedDeviceInfo`, `AutoOff`, `PromptLanguage`, `ButtonAction` are referenced here. Task 4 moves these types out of `AppDelegate` into a file `DeviceController` can see (`Sources/SoundSherpa/DeviceTypes.swift`). To keep this task compiling on its own, also create `Sources/SoundSherpa/DeviceTypes.swift` now by **moving** the `PairedDeviceInfo` struct and the `PromptLanguage`, `SelfVoice`→(delete, replaced by `SelfVoiceLevel`), `AutoOff`, `ButtonAction` enums out of `AppDelegate.swift` into it. Leave `AppDelegate` otherwise intact for now (it still references them).

- [ ] **Step 6: Verify build**

Run: `swift build`
Expected: succeeds. (`AppDelegate` and `DeviceController` both compile; old menu still works.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceDisplay.swift Sources/SoundSherpa/DeviceController.swift Sources/SoundSherpa/DeviceTypes.swift Sources/SoundSherpa/AppDelegate.swift Tests/SoundSherpaCoreTests/DeviceControllerMappingTests.swift
git commit -m "feat(ui): add DeviceController observable shell and pure display mappings"
```

---

## Task 4: Migrate Bluetooth logic into DeviceController

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift`
- Modify: `Sources/SoundSherpa/AppDelegate.swift` (move device/RFCOMM code out)

**Interfaces:**
- Consumes: `DeviceChannel`, `DevicePlugin`, `DeviceRegistry.standard`, `DeviceMetadataStore`, `IOBluetoothRFCOMMTransport`, the `RFCOMMTransport` seam — all unchanged.
- Produces: a `DeviceController` whose intent methods drive real RFCOMM commands and whose observable properties update on replies. The `IOBluetoothRFCOMMChannelDelegate` conformance and the serial `connectionQueue` live here.

**Migration rule:** Move — don't rewrite — the following from `AppDelegate` into `DeviceController`, converting each `DispatchQueue.main.async { self.updateXxx(...) }` UI call into a direct property assignment (the controller is already `@MainActor`):

| Old menu mutation | New assignment |
|---|---|
| `updateNCSelection(level:)` | `ncLevel = NoiseCancellationLevel(byte: level)` |
| `updateSelfVoiceSelection(level:)` | `selfVoiceLevel = SelfVoiceLevel(rawValue: level)` |
| `updateBatteryInMenu(_:)` | `batteryLevel = level` |
| `updateDeviceHeader(name:battery:isConnected:)` | `deviceName = name; isConnected = …` |
| `updatePairedDevicesMenu(...)` | `pairedDevices = devices` (names via `DeviceDisplay.pairedDeviceDisplayName`) |
| `updateInfoRow(401/403/404/405)` | `firmware` / `deviceId` / `services` / `serial` |
| `updateAutoOffSelection` | `autoOff = AutoOff(rawValue: level)` |
| `updateLanguageCheckmark` / `updateVoicePromptsCheckmark` | `language` / `voicePromptsEnabled` |
| `updateButtonActionSelection` | `buttonAction = ButtonAction(rawValue: level)` |

Carry over verbatim: `connectionQueue`, `deviceChannel`, `ingestContinuation`, `attachChannel`, `closeChannel`/`closeChannelLocked`, `connectToBoseDeviceSync`, `connectToService`, `openChannel`, `ensureConnected`, `send`/`collect`, `initBoseConnection`, `fetchAllDeviceInfo` and its `fetch*` helpers, `checkForBoseDevices`, `sdpMetadata`/`sdpUInt16Hex`, `getDeviceStatus`, `fetchPairedDevices`, `parseDeviceStatusResponse`, the `metadataStore`, and the `rfcommChannel*` delegate methods. These are the hardened core — keep their bodies unchanged except for the UI-update lines above.

- [ ] **Step 1: Move the IOBluetooth code**

Cut the device-discovery, RFCOMM, SDP, command-I/O, and delegate code listed above from `AppDelegate.swift` into `DeviceController.swift`. Make `DeviceController` conform to `NSObject, IOBluetoothRFCOMMChannelDelegate` (it must subclass `NSObject` for the delegate; keep `@MainActor @Observable`). Replace each menu-mutation call site with the property assignment from the table.

- [ ] **Step 2: Implement the intent methods**

Fill the intents using the migrated `send`/`ensureConnected`:

```swift
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
```

Port `connectPairedDevice`, `disconnectPairedDevice`, `setAutoOff`, `setLanguage`, `setVoicePrompts`, `setButtonAction`, and `refresh()` (calls `checkForBoseDevices()`) the same way — same command bytes as the current `@objc` handlers, ending in a property assignment instead of a menu update.

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: succeeds. `AppDelegate` no longer contains device I/O; it will be reduced further in Task 9.

- [ ] **Step 4: Verify core tests still green**

Run: `swift test`
Expected: PASS — all existing `SoundSherpaCore` tests plus the new mapping tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift Sources/SoundSherpa/AppDelegate.swift
git commit -m "refactor(ui): migrate Bluetooth I/O from AppDelegate into DeviceController"
```

---

## Task 5: SegmentedSection pill control

**Files:**
- Create: `Sources/SoundSherpa/Views/SegmentedSection.swift`
- Modify: `Package.swift` (ensure `Sources/SoundSherpa` picks up the `Views` subfolder — SPM includes subfolders by default, so no change is normally needed; verify build).

**Interfaces:**
- Produces:
  - `struct PillOption: Identifiable { let id: …; let title: String; let systemImage: String }` — lightweight descriptor.
  - `struct SegmentedSection<Value: Hashable>: View` initialized with `title: String`, `options: [(value: Value, title: String, systemImage: String)]`, `selection: Value?`, `onSelect: (Value) -> Void`.

- [ ] **Step 1: Write the view**

Create `Sources/SoundSherpa/Views/SegmentedSection.swift`:

```swift
import SwiftUI

/// A titled row of AirPods-style pills. The selected pill fills with the accent tint;
/// tapping a pill invokes `onSelect`. Generic over the option's value type.
struct SegmentedSection<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, title: String, systemImage: String)]
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    pill(option)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(_ option: (value: Value, title: String, systemImage: String)) -> some View {
        let isSelected = option.value == selection
        Button {
            onSelect(option.value)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(option.title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/SegmentedSection.swift
git commit -m "feat(ui): add reusable SegmentedSection pill control"
```

---

## Task 6: DeviceHeaderView, PairedDevicesList, icon mapping

**Files:**
- Create: `Sources/SoundSherpa/Views/DeviceHeaderView.swift`
- Create: `Sources/SoundSherpa/Views/PairedDevicesList.swift`
- Create: `Sources/SoundSherpa/PairedDeviceTypeIcon.swift` (moved from `AppDelegate`)

**Interfaces:**
- Consumes: `DeviceController` (environment), `DeviceDisplay.batteryTier`, `DeviceTypeResolver`, `PairedDeviceInfo`.
- Produces: `DeviceHeaderView`, `PairedDevicesList` views; `PairedDeviceType.iconName` extension.

- [ ] **Step 1: Move the icon mapping**

Cut the `private extension PairedDeviceType { var iconName … }` block from `AppDelegate.swift` into a new `Sources/SoundSherpa/PairedDeviceTypeIcon.swift`, changing `private extension` to `extension` (drop `private` so the views can use it):

```swift
import SoundSherpaCore

extension PairedDeviceType {
    var iconName: String {
        switch self {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .macBook: return "laptopcomputer"
        case .mac: return "desktopcomputer"
        case .appleWatch: return "applewatch"
        case .appleTV: return "appletv"
        case .airPods: return "airpods"
        case .appleGeneric: return "apple.logo"
        case .windows: return "pc"
        case .android: return "smartphone"
        case .unknown: return "display"
        }
    }
}
```

- [ ] **Step 2: Write the header view**

Create `Sources/SoundSherpa/Views/DeviceHeaderView.swift`:

```swift
import SwiftUI
import SoundSherpaCore

struct DeviceHeaderView: View {
    let name: String
    let batteryLevel: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.tint).frame(width: 36, height: 36)
                Image(systemName: "headphones.over.ear")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                if let level = batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(level))
                            .foregroundStyle(batteryColor(level))
                        Text("\(level)%").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Spacer()
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch DeviceDisplay.batteryTier(forLevel: level) {
        case .critical: return .red
        case .low: return .orange
        case .normal: return .secondary
        }
    }
}
```

- [ ] **Step 3: Write the paired devices list**

Create `Sources/SoundSherpa/Views/PairedDevicesList.swift`:

```swift
import SwiftUI
import SoundSherpaCore

struct PairedDevicesList: View {
    let devices: [PairedDeviceInfo]
    let onToggle: (PairedDeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired Devices")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(devices, id: \.address) { device in
                Button {
                    onToggle(device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: device))
                            .frame(width: 20)
                        Text(DeviceDisplay.pairedDeviceDisplayName(rawName: device.name, address: device.address))
                        Spacer()
                        if device.isConnected {
                            Circle().fill(.tint).frame(width: 8, height: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func iconName(for device: PairedDeviceInfo) -> String {
        DeviceTypeResolver.resolve(name: device.name, address: device.address).iconName
    }
}
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/Views/DeviceHeaderView.swift Sources/SoundSherpa/Views/PairedDevicesList.swift Sources/SoundSherpa/PairedDeviceTypeIcon.swift Sources/SoundSherpa/AppDelegate.swift
git commit -m "feat(ui): add device header and paired-devices SwiftUI views"
```

---

## Task 7: ContentTile and TileFooter

**Files:**
- Create: `Sources/SoundSherpa/Views/ContentTile.swift`
- Create: `Sources/SoundSherpa/Views/TileFooter.swift`

**Interfaces:**
- Consumes: `DeviceController` from the environment, `DeviceHeaderView`, `SegmentedSection`, `PairedDevicesList`.
- Produces: `ContentTile` (root panel) and `TileFooter`.

- [ ] **Step 1: Write the footer**

Create `Sources/SoundSherpa/Views/TileFooter.swift`:

```swift
import SwiftUI

struct TileFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 4) {
            Button("Advanced Settings…") { openSettings() }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Quit SoundSherpa") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}
```

- [ ] **Step 2: Write the content tile**

Create `Sources/SoundSherpa/Views/ContentTile.swift`:

```swift
import SwiftUI
import SoundSherpaCore

struct ContentTile: View {
    @Environment(DeviceController.self) private var controller
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceHeaderView(name: controller.deviceName ?? "No device connected",
                             batteryLevel: controller.batteryLevel)

            if controller.isConnected {
                Divider()

                SegmentedSection(
                    title: "Noise Cancellation",
                    options: [(.off, "Off", "speaker.wave.1"),
                              (.low, "Low", "speaker.wave.2"),
                              (.high, "High", "speaker.wave.3")],
                    selection: controller.ncLevel,
                    onSelect: { controller.setNoiseCancellation($0) })

                DisclosureGroup("More", isExpanded: $showMore) {
                    VStack(alignment: .leading, spacing: 14) {
                        SegmentedSection(
                            title: "Self Voice",
                            options: [(.off, "Off", "person"),
                                      (.low, "Low", "person.wave.2"),
                                      (.medium, "Medium", "person.wave.2.fill"),
                                      (.high, "High", "person.spatialaudio.stereo.fill")],
                            selection: controller.selfVoiceLevel,
                            onSelect: { controller.setSelfVoice($0) })

                        PairedDevicesList(devices: controller.pairedDevices) { device in
                            if device.isConnected {
                                controller.disconnectPairedDevice(device)
                            } else {
                                controller.connectPairedDevice(device)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }

            Divider()
            TileFooter()
        }
        .padding(18)
        .frame(width: 320)
        .tint(.accentColor)
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/Views/ContentTile.swift Sources/SoundSherpa/Views/TileFooter.swift
git commit -m "feat(ui): add ContentTile glass panel and footer"
```

---

## Task 8: AdvancedSettingsView

**Files:**
- Create: `Sources/SoundSherpa/Views/AdvancedSettingsView.swift`

**Interfaces:**
- Consumes: `DeviceController` from the environment; `AutoOff`, `PromptLanguage`, `ButtonAction` enums.
- Produces: `AdvancedSettingsView` — a `TabView` with General / Voice / About tabs.

- [ ] **Step 1: Write the settings view**

Create `Sources/SoundSherpa/Views/AdvancedSettingsView.swift`:

```swift
import SwiftUI
import SoundSherpaCore

struct AdvancedSettingsView: View {
    @Environment(DeviceController.self) private var controller

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            voiceTab.tabItem { Label("Voice", systemImage: "waveform") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Picker("Auto-Off", selection: Binding(
                get: { controller.autoOff ?? .never },
                set: { controller.setAutoOff($0) })) {
                ForEach([AutoOff.never, .five, .twenty, .forty, .sixty, .oneEighty], id: \.rawValue) {
                    Text($0.displayName).tag($0)
                }
            }
            Picker("Button Action", selection: Binding(
                get: { controller.buttonAction ?? .noiseCancellation },
                set: { controller.setButtonAction($0) })) {
                Text("Alexa").tag(ButtonAction.alexa)
                Text("Noise Cancellation").tag(ButtonAction.noiseCancellation)
            }
        }
    }

    private var voiceTab: some View {
        Form {
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

    private var aboutTab: some View {
        Form {
            if let v = controller.firmware { LabeledContent("Firmware", value: v) }
            if let v = controller.serial { LabeledContent("Serial Number", value: v) }
            if let v = controller.deviceId { LabeledContent("Device ID", value: v) }
            if let v = controller.services, !v.isEmpty {
                LabeledContent("Services", value: v.joined(separator: ", "))
            }
            Text("Smart controls for non-Apple headphones. Version 1.0")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var languageChoices: [PromptLanguage] {
        [.chinese, .dutch, .english, .french, .german, .italian, .japanese,
         .korean, .polish, .portuguese, .russian, .spanish, .swedish]
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/AdvancedSettingsView.swift
git commit -m "feat(ui): add Advanced Settings window content"
```

---

## Task 9: App entry, lifecycle adaptor, delete old menu

**Files:**
- Create: `Sources/SoundSherpa/SoundSherpaApp.swift`
- Delete: `Sources/SoundSherpa/main.swift`
- Modify: `Sources/SoundSherpa/AppDelegate.swift` (reduce to lifecycle-only)
- Modify: `Package.swift` (no `main.swift`; SwiftUI `@main` drives the executable)

**Interfaces:**
- Consumes: `DeviceController`, `ContentTile`, `AdvancedSettingsView`.
- Produces: the `@main` `SoundSherpaApp`; a slimmed `AppDelegate` holding only Bluetooth connect/disconnect notifications, sleep/wake observers, and termination teardown that calls into the shared `DeviceController`.

- [ ] **Step 1: Reduce AppDelegate to lifecycle-only**

In `AppDelegate.swift`, delete everything related to the menu (`setupMenuBar`, `setupMenu`, `createDeviceHeaderItem`, `createNCMenuItem`, `createSelfVoiceMenuItem`, `createSectionHeader`, `createSettingsSubmenu`, all `update*` menu mutators, `MenuTag`, `statusItem`, and the `@objc` action handlers — these now live in `DeviceController` or are obsolete). Keep: `setupBluetoothNotifications`, `setupSleepWakeNotifications`, `deviceConnected`/`deviceDisconnected`, `systemWillSleep`/`systemDidWake`, `applicationWillTerminate` with its synchronous teardown. Give `AppDelegate` a reference to the shared `DeviceController` and forward connect/disconnect/wake to `controller.refresh()` / `controller`'s close path. The `connectionQueue.sync { closeChannelLocked() }` teardown must call the controller's teardown (move `closeChannelLocked` accessibility as needed).

```swift
import Cocoa
import IOBluetooth

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: DeviceController

    init(controller: DeviceController) {
        self.controller = controller
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.startMonitoring()   // wraps setupBluetoothNotifications + sleep/wake + initial scan
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutDown()           // performs the synchronous connectionQueue.sync teardown
    }
}
```

Move `setupBluetoothNotifications`, `setupSleepWakeNotifications`, the notification `@objc` handlers, and the synchronous teardown into `DeviceController` as `startMonitoring()` / `shutDown()`. (They were migrated alongside the RFCOMM code in Task 4; this step just exposes the two entry points.)

- [ ] **Step 2: Create the App entry**

Delete `main.swift` and create `Sources/SoundSherpa/SoundSherpaApp.swift`:

```swift
import SwiftUI

@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Hand the same controller instance to the AppDelegate created by the adaptor.
        // (Adaptor instantiates via init(); see Step 3 for the shared-instance wiring.)
    }

    var body: some Scene {
        MenuBarExtra("SoundSherpa", systemImage: "headphones.over.ear") {
            ContentTile()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AdvancedSettingsView()
                .environment(controller)
        }
    }
}
```

- [ ] **Step 3: Wire the shared controller instance**

`@NSApplicationDelegateAdaptor` requires `AppDelegate` to have a no-arg `init()`. Resolve the shared-instance need by making `DeviceController` a singleton accessed by both:

```swift
// In DeviceController.swift
@MainActor @Observable final class DeviceController {
    static let shared = DeviceController()
    // ...
}
```

Then in `SoundSherpaApp` use `@State private var controller = DeviceController.shared`, give `AppDelegate` a plain `override init()` that reads `DeviceController.shared`, and drop the custom `init(controller:)`.

- [ ] **Step 4: Build the app bundle and verify it launches**

Run: `./build.sh && open SoundSherpa.app`
Expected: build succeeds; a menu-bar headphones icon appears; clicking it shows the glass tile. With a Bose device connected, the header, battery, and NC pills populate; "More" reveals Self Voice + paired devices; "Advanced Settings…" opens the Settings window.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: PASS — all `SoundSherpaCore` tests green (no regressions).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(ui): switch to SwiftUI MenuBarExtra app, retire NSMenu"
```

---

## Self-Review

**Spec coverage:**
- OS target macOS 26 → Task 1. ✓
- `NoiseCancellationLevel`/`SelfVoiceLevel` enums → Task 2. ✓
- `DeviceController` `@Observable` seam + pure mappings → Tasks 3–4. ✓
- Bluetooth logic preserved (channel teardown, sleep/wake, actor I/O) → Task 4 + Task 9. ✓
- `SegmentedSection` pills → Task 5. ✓
- `DeviceHeaderView`, `PairedDevicesList`, icon mapping moved → Task 6. ✓
- `ContentTile` + minimal-default + inline "More" disclosure → Task 7. ✓
- Standard `Settings` window with General/Voice/About + nil-row hiding (R5.8) → Task 8. ✓
- `MenuBarExtra(.window)` app entry + lifecycle adaptor + delete menu plumbing → Task 9. ✓
- SF Symbol art only → Tasks 6/7. ✓
- Disconnected state collapses tile → Task 7 (`if controller.isConnected`). ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete code. The only deliberately-deferred bodies are the Task 3 intent stubs, explicitly filled in Task 4.

**Type consistency:** `NoiseCancellationLevel(byte:)`, `SelfVoiceLevel(rawValue:)`, `DeviceDisplay.batteryTier(forLevel:)`, `DeviceDisplay.pairedDeviceDisplayName(rawName:address:)`, and the `DeviceController` property/intent names are used identically across Tasks 3–9. `PairedDeviceInfo.address`/`.name`/`.isConnected` match the struct in `AppDelegate`/`DeviceTypes.swift`.

**Known risk flagged for execution:** `@NSApplicationDelegateAdaptor` + shared controller instance (Task 9 Step 3) is the one spot most likely to need adjustment against the real macOS 26 SwiftUI behavior; the singleton approach is the fallback if direct injection isn't available.
