# Settings Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the settings window from "Advanced Settings" (General/Voice/About) into a plain "Settings" window with General (app prefs) / Device (set-once device controls) / About tabs, and add the app's first app-level preferences (Start on login, Menu bar icon style).

**Architecture:** A new pure `MenuBarIconStyle` enum in `SoundSherpaCore` resolves the menu bar SF Symbol name and is unit-tested there. `SoundSherpaApp` reads the persisted icon style via `@AppStorage` so the `MenuBarExtra` symbol recomputes live. `AdvancedSettingsView` is renamed to `SettingsView` and restructured into three tabs; a new General tab hosts a `Start on login` toggle (source of truth = `SMAppService.mainApp.status`, no stored duplicate) and an icon-style picker.

**Tech Stack:** Swift 6.2 (Swift 5 language mode), SwiftUI, ServiceManagement (`SMAppService`), Swift Package Manager, XCTest.

## Global Constraints

- Platform floor: macOS 26 (`.macOS(.v26)` in Package.swift); `SMAppService` available.
- Language mode pinned to Swift 5 (`swiftLanguageModes: [.v5]`).
- Only `SoundSherpaCore` is unit-testable (Foundation-only, no AppKit/IOBluetooth). Anything needing a test goes there. Tests live in `Tests/SoundSherpaCoreTests/`.
- `Start on login` MUST NOT be stored in `@AppStorage`; its source of truth is `SMAppService.mainApp.status` queried directly, to avoid drift from the real login-item registration.
- Build/run/test through the project's native macOS toolchain (see memory `soundsherpa-build-and-test`); device settings bindings to `DeviceController` are unchanged from current code.
- The popover (`ContentTile`) does NOT gain any device control; only the footer label changes.

---

### Task 1: `MenuBarIconStyle` enum in Core (TDD)

**Files:**
- Create: `Sources/SoundSherpaCore/MenuBarIconStyle.swift`
- Test: `Tests/SoundSherpaCoreTests/MenuBarIconStyleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum MenuBarIconStyle: String, CaseIterable, Identifiable` with cases `.followConnection`, `.alwaysShow`; `public var id: String { rawValue }`; `public var displayName: String`; `public func symbolName(isConnected: Bool) -> String`. Symbol mapping: `.followConnection` → `"headphones.over.ear"` when connected else `"headphones.slash"`; `.alwaysShow` → always `"headphones.over.ear"`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SoundSherpaCore

final class MenuBarIconStyleTests: XCTestCase {
    func testFollowConnectionReflectsState() {
        XCTAssertEqual(MenuBarIconStyle.followConnection.symbolName(isConnected: true), "headphones.over.ear")
        XCTAssertEqual(MenuBarIconStyle.followConnection.symbolName(isConnected: false), "headphones.slash")
    }

    func testAlwaysShowIgnoresState() {
        XCTAssertEqual(MenuBarIconStyle.alwaysShow.symbolName(isConnected: true), "headphones.over.ear")
        XCTAssertEqual(MenuBarIconStyle.alwaysShow.symbolName(isConnected: false), "headphones.over.ear")
    }

    func testAllCasesHaveDisplayNames() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuBarIconStyleTests`
Expected: FAIL — cannot find `MenuBarIconStyle` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// How the menu bar icon glyph is chosen. Pure (no AppKit) so it lives in the
/// testable core; `SoundSherpaApp` maps the result to the `MenuBarExtra` symbol.
public enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    /// Headphones glyph when connected, slashed glyph when not.
    case followConnection
    /// Always the connected headphones glyph, regardless of state.
    case alwaysShow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .followConnection: return "Follow connection"
        case .alwaysShow:        return "Always show"
        }
    }

    /// Resolve to an SF Symbol name given the live connection state.
    public func symbolName(isConnected: Bool) -> String {
        switch self {
        case .followConnection: return isConnected ? "headphones.over.ear" : "headphones.slash"
        case .alwaysShow:        return "headphones.over.ear"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MenuBarIconStyleTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/MenuBarIconStyle.swift Tests/SoundSherpaCoreTests/MenuBarIconStyleTests.swift
git commit -m "feat(core): add MenuBarIconStyle enum with symbol resolution"
```

---

### Task 2: Rename `AdvancedSettingsView` → `SettingsView` with General/Device/About tabs

**Files:**
- Delete/rename: `Sources/SoundSherpa/Views/AdvancedSettingsView.swift` → `Sources/SoundSherpa/Views/SettingsView.swift`
- Modify: `Sources/SoundSherpa/SoundSherpaApp.swift` (scene reference only)

**Interfaces:**
- Consumes: `DeviceController` env (`autoOff`/`setAutoOff`, `buttonAction`/`setButtonAction`, `language`/`setLanguage`, `voicePromptsEnabled`/`setVoicePrompts`, `firmware`/`serial`/`deviceId`/`services`); `MenuBarIconStyle` (Task 1); `SMAppService`.
- Produces: `struct SettingsView: View` (referenced by `SoundSherpaApp`); the `@AppStorage("menuBarIconStyle")` key written by the General tab's picker (stores the enum `rawValue`), read by Task 3.

- [ ] **Step 1: Create `SettingsView.swift` with three tabs**

Create the new file. The `deviceTab` is the old `generalTab` + `voiceTab` merged verbatim (same bindings). The `aboutTab` is copied unchanged. The `generalTab` is new (Start on login + icon picker).

```swift
import SwiftUI
import ServiceManagement
import SoundSherpaCore

/// The app's Settings window (⌘,). General hosts app-level preferences;
/// Device hosts the set-once headphone controls; About is read-only info.
struct SettingsView: View {
    @Environment(DeviceController.self) private var controller
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    @State private var startOnLogin = false
    @State private var loginError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            deviceTab.tabItem { Label("Device", systemImage: "headphones") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Start on login", isOn: Binding(
                get: { startOnLogin },
                set: { setStartOnLogin($0) }))
            if let loginError {
                Text(loginError).font(.footnote).foregroundStyle(.red)
            }
            Picker("Menu bar icon", selection: Binding(
                get: { MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection },
                set: { iconStyleRaw = $0.rawValue })) {
                ForEach(MenuBarIconStyle.allCases) { Text($0.displayName).tag($0) }
            }
        }
        .onAppear { refreshLoginStatus() }
    }

    private var deviceTab: some View {
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

    // MARK: - Start on login (source of truth: SMAppService, not @AppStorage)

    private func refreshLoginStatus() {
        startOnLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func setStartOnLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
        }
        // Re-read the real status so the toggle reflects truth even on failure.
        refreshLoginStatus()
    }
}
```

- [ ] **Step 2: Delete the old file**

```bash
git rm Sources/SoundSherpa/Views/AdvancedSettingsView.swift
```

- [ ] **Step 3: Update the Settings scene reference**

In `Sources/SoundSherpa/SoundSherpaApp.swift`, change the `Settings { … }` scene's `AdvancedSettingsView()` to `SettingsView()`. Leave the `MenuBarExtra` line untouched for now (Task 3 wires the icon).

```swift
        Settings {
            SettingsView()
                .environment(controller)
        }
```

- [ ] **Step 4: Build to verify**

Run the project's native build (see memory `soundsherpa-build-and-test`).
Expected: builds clean. Open Settings (⌘,): three tabs General/Device/About; Device shows the four old controls; General shows Start on login + Menu bar icon. (The icon picker persists but does not yet move the menu bar glyph — that's Task 3.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift Sources/SoundSherpa/SoundSherpaApp.swift
git rm Sources/SoundSherpa/Views/AdvancedSettingsView.swift
git commit -m "feat(ui): rename Advanced Settings to Settings; General/Device/About tabs"
```

---

### Task 3: Drive the menu bar icon from the persisted style

**Files:**
- Modify: `Sources/SoundSherpa/SoundSherpaApp.swift`

**Interfaces:**
- Consumes: `MenuBarIconStyle` (Task 1); `@AppStorage("menuBarIconStyle")` written by Task 2's General tab; `controller.isConnected`.
- Produces: nothing.

- [ ] **Step 1: Read the icon-style preference and use it for the symbol**

Add `import SoundSherpaCore` if not present. Add the `@AppStorage` property and compute the symbol from it, replacing the inline ternary in the `MenuBarExtra` initializer.

```swift
import SwiftUI
import SoundSherpaCore

@main
struct SoundSherpaApp: App {
    @State private var controller = DeviceController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Persisted menu bar icon preference. Stored as the enum rawValue so the
    // Scene re-evaluates (and the glyph updates) whenever the General tab writes it.
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.followConnection.rawValue

    private var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: iconStyleRaw) ?? .followConnection
    }

    var body: some Scene {
        MenuBarExtra("SoundSherpa", systemImage: iconStyle.symbolName(isConnected: controller.isConnected)) {
            ContentTile()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run the project's native build.
Expected: builds clean; menu bar glyph still follows connection by default. Switch "Menu bar icon" to "Always show" in General → glyph stays the connected headphones even when disconnected.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/SoundSherpaApp.swift
git commit -m "feat(ui): drive menu bar icon from persisted MenuBarIconStyle"
```

---

### Task 4: Footer label "Advanced Settings…" → "Settings…"

**Files:**
- Modify: `Sources/SoundSherpa/Views/TileFooter.swift:8`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing.

- [ ] **Step 1: Change the footer row title**

```swift
            MenuRow(title: "Settings…") {
                openSettings()
                // LSUIElement (.accessory) apps never become active on their own, so the
                // Settings window would open behind other apps. Activate to pull it forward.
                NSApp.activate(ignoringOtherApps: true)
            }
```

- [ ] **Step 2: Build and visually verify**

Run the project's native build; open the popover; confirm the footer reads "Settings…" and opens the window.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/TileFooter.swift
git commit -m "feat(ui): rename footer row to Settings…"
```

---

## Self-Review

**Spec coverage:**
- Rename window concept to "Settings" → Tasks 3 (window/struct) + 4 (footer). ✓
- Three tabs General/Device/About → Task 3. ✓
- General tab: Start on login (SMAppService, no @AppStorage) → Task 3 `setStartOnLogin`/`refreshLoginStatus`. ✓
- General tab: Menu bar icon style → Task 1 (enum) + 2 (app reads it) + 3 (picker writes it). ✓
- Device tab folds old General + Voice → Task 3 `deviceTab`. ✓
- About unchanged → Task 3 `aboutTab`. ✓
- New `MenuBarIconStyle` source of truth → Task 1 (placed in Core, not the spec's `AppSettings.swift` in the executable, because only Core is unit-testable — deliberate deviation, noted). ✓
- Unit test for symbol mapping → Task 1. ✓
- Popover unchanged except footer → Tasks only touch `TileFooter` in the popover. ✓

**Deviation from spec:** Spec proposed `Sources/SoundSherpa/AppSettings.swift`. Plan places `MenuBarIconStyle` in `Sources/SoundSherpaCore/MenuBarIconStyle.swift` instead, so it sits in the only unit-testable target. No separate `AppSettings` wrapper is needed — `@AppStorage` is read directly where used. This better satisfies the spec's own testing goal.

**Placeholder scan:** none.

**Type consistency:** `MenuBarIconStyle` rawValue-based `@AppStorage("menuBarIconStyle")` key identical in Tasks 2 and 3; `symbolName(isConnected:)`, `displayName`, `allCases`, `id` consistent across tasks. Device bindings copied verbatim from current source. ✓

**Note on task ordering:** Tasks are now strictly sequential and each builds cleanly: Task 1 (Core enum + test) → Task 2 (SettingsView + scene reference) → Task 3 (wire the icon to the persisted style) → Task 4 (footer label). No forward dependencies.
