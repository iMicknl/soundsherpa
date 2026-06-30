# Settings View Native Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the Settings window's three tabs to feel native (grouped Forms), give the Device tab clear hierarchy with a header / Controls / About-this-device / Advanced-details structure, handle the disconnected state, and add selective control descriptions.

**Architecture:** All UI changes land in `Sources/SoundSherpa/Views/SettingsView.swift`. The one piece of testable pure logic — mapping a battery level (0–100) to an SF Symbol name — is extracted from the private helper in `DeviceHeaderView.swift` into `DeviceDisplay` (Core, Foundation-only) so it can be unit-tested and shared. A small shared SwiftUI `BatteryLabel` view renders icon+percent and is reused by both `DeviceHeaderView` and the Device tab, avoiding duplication.

**Tech Stack:** Swift, SwiftUI, SwiftPM. Two targets matter here: `SoundSherpaCore` (pure, Foundation-only, testable) and `SoundSherpa` (executable, AppKit+SwiftUI). Tests use XCTest in `SoundSherpaCoreTests`.

## Global Constraints

- This is a native macOS app; it CANNOT run in a dev container. Run all commands natively on the host.
- Build: `swift build -c release`
- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test` (CommandLineTools lacks XCTest).
- `SoundSherpaCore` is Foundation-only — no SwiftUI/AppKit imports may be added to it. Color/View logic stays in the `SoundSherpa` target.
- Follow existing code style: comments explain *why*, `LabeledContent` for read-only rows, `Binding(get:set:)` bridging to `DeviceController`.
- Connection source of truth is `controller.isConnected` (Bool), not `deviceName != nil`.
- All `DeviceController` values already exist: `isConnected`, `deviceName`, `batteryLevel: Int?`, `firmware: String?`, `serial: String?`, `deviceId: String?`, `services: [String]?`. Do NOT change `DeviceController`.

---

### Task 1: Extract battery-symbol mapping into Core (testable)

The level→SF-Symbol mapping currently lives as a private `batterySymbol(_:)` in `DeviceHeaderView.swift`. Move the pure mapping into `DeviceDisplay` so it is unit-tested and reusable by the Settings tab.

**Files:**
- Modify: `Sources/SoundSherpaCore/DeviceDisplay.swift` (add `batterySymbolName(forLevel:)`)
- Test: `Tests/SoundSherpaCoreTests/DeviceDisplayTests.swift`

**Interfaces:**
- Consumes: existing `DeviceDisplay` enum/struct and its `batteryTier(forLevel:)`.
- Produces: `static func batterySymbolName(forLevel level: Int) -> String` on `DeviceDisplay`, returning one of `"battery.0percent"`, `"battery.25percent"`, `"battery.50percent"`, `"battery.75percent"`, `"battery.100percent"`.

- [ ] **Step 1: Confirm the type shape of `DeviceDisplay`**

Run: `grep -n "batteryTier\|enum DeviceDisplay\|struct DeviceDisplay\|static func" Sources/SoundSherpaCore/DeviceDisplay.swift`
Expected: shows whether `DeviceDisplay` is an `enum` or `struct` and the signature style of `batteryTier(forLevel:)`. Match that style for the new function.

- [ ] **Step 2: Write the failing test**

Add to `Tests/SoundSherpaCoreTests/DeviceDisplayTests.swift` (create the file if it does not exist, mirroring the imports/style of a neighboring test file such as the existing Core tests):

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceDisplayBatterySymbolTests: XCTestCase {
    func testBatterySymbolNameBoundaries() {
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 0), "battery.0percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 10), "battery.0percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 11), "battery.25percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 35), "battery.25percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 36), "battery.50percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 60), "battery.50percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 61), "battery.75percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 85), "battery.75percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 86), "battery.100percent")
        XCTAssertEqual(DeviceDisplay.batterySymbolName(forLevel: 100), "battery.100percent")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceDisplayBatterySymbolTests`
Expected: FAIL — compile error, `batterySymbolName` not a member of `DeviceDisplay`.

- [ ] **Step 4: Implement the mapping in Core**

Add to `DeviceDisplay` (match `enum`/`struct` form found in Step 1):

```swift
/// Maps a battery percentage (0–100) to the SF Symbol name used to depict it.
/// Lives here (Foundation-only) so both the menu tile and Settings share one
/// mapping; the tint color stays in the SwiftUI layer.
static func batterySymbolName(forLevel level: Int) -> String {
    switch level {
    case 0...10: return "battery.0percent"
    case 11...35: return "battery.25percent"
    case 36...60: return "battery.50percent"
    case 61...85: return "battery.75percent"
    default: return "battery.100percent"
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceDisplayBatterySymbolTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceDisplay.swift Tests/SoundSherpaCoreTests/DeviceDisplayTests.swift
git commit -m "feat(core): extract testable battery symbol mapping into DeviceDisplay"
```

---

### Task 2: Shared `BatteryLabel` view; adopt in DeviceHeaderView

Create one SwiftUI view that renders the battery icon + percent, using the Core mapping from Task 1, and adopt it in `DeviceHeaderView` so the existing private helpers are removed (no duplication when the Settings tab reuses it in Task 5).

**Files:**
- Create: `Sources/SoundSherpa/Views/BatteryLabel.swift`
- Modify: `Sources/SoundSherpa/Views/DeviceHeaderView.swift`

**Interfaces:**
- Consumes: `DeviceDisplay.batterySymbolName(forLevel:)` and `DeviceDisplay.batteryTier(forLevel:)` from Core.
- Produces: `struct BatteryLabel: View { let level: Int }` — renders `Image(systemName:)` tinted by tier + `Text("\(level)%")`, `.font(.caption)`, secondary percent text. Reused by Task 5.

- [ ] **Step 1: Create `BatteryLabel`**

```swift
import SwiftUI
import SoundSherpaCore

/// Battery icon + percentage, tinted by charge tier. Shared by the menu-bar
/// device header and the Settings → Device "About this device" group so the
/// glyph/color logic lives in exactly one place.
struct BatteryLabel: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: DeviceDisplay.batterySymbolName(forLevel: level))
                .foregroundStyle(tierColor)
            Text("\(level)%").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var tierColor: Color {
        switch DeviceDisplay.batteryTier(forLevel: level) {
        case .critical: return .red
        case .low: return .orange
        case .normal: return .secondary
        }
    }
}
```

- [ ] **Step 2: Adopt it in `DeviceHeaderView` and delete the private helpers**

In `Sources/SoundSherpa/Views/DeviceHeaderView.swift`, replace the inline battery `HStack` (lines ~17–24) with:

```swift
if let level = batteryLevel {
    BatteryLabel(level: level)
}
```

Then delete the now-unused private `batterySymbol(_:)` and `batteryColor(_:)` methods (lines ~32–48).

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors and no "unused function" leftovers referencing the deleted helpers.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/Views/BatteryLabel.swift Sources/SoundSherpa/Views/DeviceHeaderView.swift
git commit -m "refactor(ui): shared BatteryLabel reusing Core symbol mapping"
```

---

### Task 3: Grouped form style + General tab cards

Apply `.formStyle(.grouped)` and split the General tab into two grouped cards. This is the foundational visual change; do it first so later Device-tab work is seen in its final styling.

**Files:**
- Modify: `Sources/SoundSherpa/Views/SettingsView.swift` (`generalTab`, and the `Form` in `deviceTab`)

**Interfaces:**
- Consumes: existing `startOnLogin`, `loginError`, `iconStyleRaw`, `MenuBarIconStyle`.
- Produces: no new symbols; visual change only.

- [ ] **Step 1: Add grouped style to both Forms**

In `generalTab`, add `.formStyle(.grouped)` to the `Form` (after the existing `.onAppear { refreshLoginStatus() }`). In `deviceTab`, add `.formStyle(.grouped)` to its `Form` as well.

- [ ] **Step 2: Split General into two sections**

Replace the body of `generalTab`'s `Form` so login behavior and appearance are distinct `Section`s, keeping the error footnote attached under the login section:

```swift
Form {
    Section {
        Toggle("Start on login", isOn: Binding(
            get: { startOnLogin },
            set: { setStartOnLogin($0) }))
        if let loginError {
            Text(loginError).font(.footnote).foregroundStyle(.red)
        }
    }
    Section {
        Picker("Menu bar icon", selection: Binding(
            get: { MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection },
            set: { iconStyleRaw = $0.rawValue })) {
            ForEach(MenuBarIconStyle.allCases) { Text($0.displayName).tag($0) }
        }
    }
}
.formStyle(.grouped)
.onAppear { refreshLoginStatus() }
```

- [ ] **Step 3: Build and run to verify the grouped look**

Run: `swift build -c release && ./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && pkill -9 -f SoundSherpa; open SoundSherpa.app`
Then open Settings (⌘,) → General.
Expected: two rounded grouped cards (login toggle; menu-bar icon picker), System Settings-style. Device tab still renders (unstyled hierarchy comes in later tasks) but now in grouped cards.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift
git commit -m "feat(ui): grouped form style; General tab as two cards"
```

---

### Task 4: Device tab — disconnected empty state + header

Gate the Device tab on `controller.isConnected`: show a centered empty state when disconnected, and a device-name header when connected. The control/info groups (Task 5) will be inserted after the header in the connected branch.

**Files:**
- Modify: `Sources/SoundSherpa/Views/SettingsView.swift` (`deviceTab`)

**Interfaces:**
- Consumes: `controller.isConnected`, `controller.deviceName`, `controller.batteryLevel`.
- Produces: `deviceTab` now branches on connection; a private `deviceDisconnected` view and a `deviceHeader` view. The connected Form retains the existing Controls/Information sections for now (restructured in Task 5).

- [ ] **Step 1: Add the empty-state and header subviews**

Add these private computed views to `SettingsView`:

```swift
private var deviceDisconnected: some View {
    VStack(spacing: 8) {
        Image(systemName: "headphones")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
        Text("No device connected")
            .font(.headline)
        Text("Connect your headphones to manage their settings here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
}

/// Device name as the subject of the tab (not a settings row), with battery
/// when known. Brand is derived from the existing deviceId prefix when present.
private var deviceHeader: some View {
    HStack(spacing: 10) {
        Image(systemName: "headphones")
            .font(.title2)
            .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.deviceName ?? "Device")
                .font(.headline)
            Text("Connected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
}
```

- [ ] **Step 2: Branch `deviceTab` on connection**

Wrap the existing `deviceTab` content so it shows `deviceDisconnected` when not connected. Keep the existing `Form` (with its current Controls/Information `Section`s and the `.formStyle(.grouped)` from Task 3) for the connected branch; the header goes above it. Remove the old "Device" `LabeledContent` row (the name now lives in `deviceHeader`):

```swift
private var deviceTab: some View {
    Group {
        if controller.isConnected {
            VStack(spacing: 0) {
                deviceHeader
                    .padding(.horizontal)
                    .padding(.top)
                Form {
                    Section("Controls") {
                        // ... existing Auto-Off / Button Action / Language / Voice Prompts pickers ...
                    }
                    if hasDeviceInfo {
                        Section("Information") {
                            // ... existing Firmware / Serial / Device ID / Services rows ...
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            deviceDisconnected
        }
    }
}
```

(Leave the inner Section contents exactly as they are — Task 5 restructures them. Just remove the standalone `Section { LabeledContent("Device", ...) }`.)

- [ ] **Step 3: Build and run; verify both states**

Run: `swift build -c release && ./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && pkill -9 -f SoundSherpa; open SoundSherpa.app`
Expected: with a device connected, Device tab shows the name header above the grouped controls (no "Device" row). With no device connected (turn headphones off / disconnect), Device tab shows the centered "No device connected" empty state and no stale control rows.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift
git commit -m "feat(ui): Device tab header + no-device empty state"
```

---

### Task 5: Device tab — restructure info into About + Advanced details

Split the old "Information" section: Battery/Firmware/Serial go into an always-visible "About this device" group; Device ID + Services move into a collapsed `DisclosureGroup`. Move Voice Prompts into the Controls group (it already is in the current code — confirm ordering: Auto-Off, Button Action, Language, Voice Prompts).

**Files:**
- Modify: `Sources/SoundSherpa/Views/SettingsView.swift` (`deviceTab` connected branch, `hasDeviceInfo`)

**Interfaces:**
- Consumes: `controller.batteryLevel`, `controller.firmware`, `controller.serial`, `controller.deviceId`, `controller.services`; `BatteryLabel` (Task 2).
- Produces: a private `hasAdvancedInfo` helper; restructured sections. Each row hidden when its value is nil/empty.

- [ ] **Step 1: Add `hasAdvancedInfo` and keep `hasDeviceInfo` only where still needed**

Add:

```swift
/// Pure-debug identity fields shown under the collapsed "Advanced details".
private var hasAdvancedInfo: Bool {
    controller.deviceId != nil || !(controller.services ?? []).isEmpty
}
```

- [ ] **Step 2: Replace the connected branch's Form body**

```swift
Form {
    Section("Controls") {
        Picker("Auto-Off", selection: Binding(
            get: { controller.autoOff ?? .never },
            set: { controller.setAutoOff($0) })) {
            ForEach([AutoOff.never, .five, .twenty, .forty, .sixty, .oneEighty], id: \.rawValue) {
                Text($0.displayName).tag($0)
            }
        }
        Text("Turn the headphones off after a period of inactivity to save battery.")
            .font(.caption).foregroundStyle(.secondary)

        Picker("Button Action", selection: Binding(
            get: { controller.buttonAction ?? .noiseCancellation },
            set: { controller.setButtonAction($0) })) {
            Text("Alexa").tag(ButtonAction.alexa)
            Text("Noise Cancellation").tag(ButtonAction.noiseCancellation)
        }
        Text("Choose what a press of the headphones' action button does.")
            .font(.caption).foregroundStyle(.secondary)

        Picker("Language", selection: Binding(
            get: { controller.language ?? .english },
            set: { controller.setLanguage($0) })) {
            ForEach(languageChoices, id: \.rawValue) { Text($0.displayName).tag($0) }
        }
        Toggle("Voice Prompts", isOn: Binding(
            get: { controller.voicePromptsEnabled ?? false },
            set: { controller.setVoicePrompts($0) }))
    }

    Section("About this device") {
        if let level = controller.batteryLevel {
            LabeledContent("Battery") { BatteryLabel(level: level) }
        }
        if let v = controller.firmware { LabeledContent("Firmware", value: v) }
        if let v = controller.serial { LabeledContent("Serial Number", value: v) }
    }

    if hasAdvancedInfo {
        Section {
            DisclosureGroup("Advanced details") {
                if let v = controller.deviceId { LabeledContent("Device ID", value: v) }
                if let v = controller.services, !v.isEmpty {
                    LabeledContent("Services") {
                        Text(v.joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }
}
.formStyle(.grouped)
```

- [ ] **Step 3: Remove the now-unused `hasDeviceInfo` if nothing references it**

Run: `grep -n "hasDeviceInfo" Sources/SoundSherpa/Views/SettingsView.swift`
Expected: only the definition remains. If so, delete the `hasDeviceInfo` computed property. If anything else references it, leave it.

- [ ] **Step 4: Build and run; verify structure**

Run: `swift build -c release && ./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && pkill -9 -f SoundSherpa; open SoundSherpa.app`
Open Settings (⌘,) → Device (with device connected).
Expected:
- Controls group: Auto-Off (with caption), Button Action (with caption), Language, Voice Prompts.
- "About this device" group: Battery (icon + %), Firmware, Serial Number.
- "Advanced details" disclosure collapsed by default; expanding shows Device ID and a wrapping Services list.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift
git commit -m "feat(ui): Device tab About-this-device group, Advanced details disclosure, control captions"
```

---

### Task 6: Final verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full build + test**

Run: `swift build -c release && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: build succeeds; all tests pass (including `DeviceDisplayBatterySymbolTests`).

- [ ] **Step 2: Manual sweep of all three tabs**

Run: `./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && pkill -9 -f SoundSherpa; open SoundSherpa.app`
Verify against the spec's Verification section:
- General: two grouped cards; login error still surfaces on failure.
- Device connected: header, Controls (with captions on Auto-Off/Button Action), About-this-device (Battery/Firmware/Serial), Advanced details collapsed/expandable.
- Device disconnected: centered empty state, no stale rows.
- About: unchanged, spacing/typography consistent.

- [ ] **Step 3: Confirm no leftover dead code**

Run: `grep -n "batterySymbol\|batteryColor\|hasDeviceInfo" Sources/SoundSherpa/Views/DeviceHeaderView.swift Sources/SoundSherpa/Views/SettingsView.swift`
Expected: no matches in `DeviceHeaderView.swift`; in `SettingsView.swift`, `hasDeviceInfo` only if still referenced.
