# Menu Bar Battery Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show headphone battery percentage in the menu bar as an opt-in setting, subtle/monochrome except a low-battery tint, replacing the misleadingly-named `MenuBarIconStyle` setting.

**Architecture:** A pure core enum `MenuBarContent` (`iconOnly` / `iconAndBattery`) plus a new `DeviceDisplay.menuBarBatteryTier` mapping carry all testable decisions. `SoundSherpaApp` switches its `MenuBarExtra` from the `systemImage:` initializer to a custom `label:` closure that renders the headphones glyph plus optional tinted percentage. `SettingsView` swaps its picker to bind the new enum.

**Tech Stack:** Swift, SwiftUI, XCTest, Swift Package Manager. Native macOS build (see project memory: build/test via the repo's toolchain).

## Global Constraints

- Pure presentation/decision logic lives in `SoundSherpaCore` (Foundation-only, no AppKit/SwiftUI) so it is unit-testable.
- Menu-bar low-battery thresholds: **amber ≤ 30, red ≤ 15**. The in-app pill's existing `batteryTier` (amber ≤50, red ≤20) is UNCHANGED.
- `batteryLevel == nil` → "Icon + battery" renders icon-only (no "%", no placeholder).
- Headphones glyphs: connected `headphones.over.ear`, disconnected `headphones.slash`.
- Default menu bar content is `iconOnly`.

---

### Task 1: `MenuBarContent` core enum (replaces `MenuBarIconStyle`)

**Files:**
- Create: `Sources/SoundSherpaCore/MenuBarContent.swift`
- Delete: `Sources/SoundSherpaCore/MenuBarIconStyle.swift`
- Test: `Tests/SoundSherpaCoreTests/MenuBarContentTests.swift` (replaces `MenuBarIconStyleTests.swift`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum MenuBarContent: String, CaseIterable, Identifiable`
    - cases `iconOnly`, `iconAndBattery`
    - `public var id: String { rawValue }`
    - `public var displayName: String` → "Icon only" / "Icon + battery"
    - `public var showsBattery: Bool` → `false` / `true`
    - `public func connectionSymbolName(isConnected: Bool) -> String` → `"headphones.over.ear"` when connected, `"headphones.slash"` when not (same for both cases).

- [ ] **Step 1: Write the failing test**

Create `Tests/SoundSherpaCoreTests/MenuBarContentTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class MenuBarContentTests: XCTestCase {
    func testConnectionSymbolReflectsState() {
        for content in MenuBarContent.allCases {
            XCTAssertEqual(content.connectionSymbolName(isConnected: true), "headphones.over.ear")
            XCTAssertEqual(content.connectionSymbolName(isConnected: false), "headphones.slash")
        }
    }

    func testShowsBattery() {
        XCTAssertFalse(MenuBarContent.iconOnly.showsBattery)
        XCTAssertTrue(MenuBarContent.iconAndBattery.showsBattery)
    }

    func testAllCasesHaveDisplayNames() {
        for content in MenuBarContent.allCases {
            XCTAssertFalse(content.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Delete the old test and source, run tests to verify failure**

```bash
git rm Tests/SoundSherpaCoreTests/MenuBarIconStyleTests.swift Sources/SoundSherpaCore/MenuBarIconStyle.swift
```

Run the core test suite (per project build/test skill). Expected: FAIL — `MenuBarContent` is not defined, and `SoundSherpaApp`/`SettingsView` still reference `MenuBarIconStyle` (build error). That build break is fixed in Tasks 3–4; this task's own test failing to compile against the missing enum is the signal.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SoundSherpaCore/MenuBarContent.swift`:

```swift
import Foundation

/// What the menu bar shows. Pure (no AppKit) so it lives in the testable core;
/// `SoundSherpaApp` maps the result to the `MenuBarExtra` label.
public enum MenuBarContent: String, CaseIterable, Identifiable {
    /// Headphones glyph only, following connection state.
    case iconOnly
    /// Headphones glyph plus the battery percentage when a level is available.
    case iconAndBattery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly:       return "Icon only"
        case .iconAndBattery: return "Icon + battery"
        }
    }

    /// Whether this content includes the battery percentage.
    public var showsBattery: Bool {
        switch self {
        case .iconOnly:       return false
        case .iconAndBattery: return true
        }
    }

    /// The headphones glyph for the current connection state. Same for both
    /// cases — battery text (if any) is rendered alongside it by the app layer.
    public func connectionSymbolName(isConnected: Bool) -> String {
        isConnected ? "headphones.over.ear" : "headphones.slash"
    }
}
```

- [ ] **Step 4: Run tests to verify the core test passes**

Run the `MenuBarContentTests` (per project test skill). Expected: PASS. (Full app target still won't build until Tasks 3–4 — that's expected mid-plan.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): add MenuBarContent enum, remove MenuBarIconStyle"
```

---

### Task 2: `menuBarBatteryTier` in `DeviceDisplay`

**Files:**
- Modify: `Sources/SoundSherpaCore/DeviceDisplay.swift`
- Test: `Tests/SoundSherpaCoreTests/DeviceDisplayTests.swift` (create if absent; otherwise add the method below)

**Interfaces:**
- Consumes: existing `public enum BatteryTier { case normal, low, critical }`.
- Produces: `public static func menuBarBatteryTier(forLevel level: Int) -> BatteryTier` — `≤15` critical, `≤30` low, else normal.

- [ ] **Step 1: Write the failing test**

Create/append `Tests/SoundSherpaCoreTests/DeviceDisplayTests.swift`:

```swift
import XCTest
@testable import SoundSherpaCore

final class DeviceDisplayMenuBarTierTests: XCTestCase {
    func testMenuBarTierBoundaries() {
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 0), .critical)
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 15), .critical)
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 16), .low)
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 30), .low)
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 31), .normal)
        XCTAssertEqual(DeviceDisplay.menuBarBatteryTier(forLevel: 100), .normal)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `DeviceDisplayMenuBarTierTests` (per project test skill). Expected: FAIL — `menuBarBatteryTier` not defined.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SoundSherpaCore/DeviceDisplay.swift`, add after `batteryTier(forLevel:)` (after line 14):

```swift
    /// Menu-bar low-battery tier. Lower thresholds than `batteryTier` (≤15
    /// critical, ≤30 low) so the menu bar stays monochrome the vast majority of
    /// the time and only tints when charge genuinely matters.
    public static func menuBarBatteryTier(forLevel level: Int) -> BatteryTier {
        if level <= 15 { return .critical }
        if level <= 30 { return .low }
        return .normal
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run `DeviceDisplayMenuBarTierTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): add menuBarBatteryTier with subtler thresholds"
```

---

### Task 3: `SoundSherpaApp` renders the menu bar label

**Files:**
- Modify: `Sources/SoundSherpa/SoundSherpaApp.swift`

**Interfaces:**
- Consumes: `MenuBarContent` (Task 1), `DeviceDisplay.menuBarBatteryTier` (Task 2), `controller.isConnected`, `controller.batteryLevel: Int?`.
- Produces: no new symbols; wires the menu bar.

- [ ] **Step 1: Replace the `MenuBarIconStyle` storage and computed property**

In `Sources/SoundSherpa/SoundSherpaApp.swift`, replace lines 14-20:

```swift
    // Persisted menu bar content preference. Stored as the enum rawValue so the
    // Scene re-evaluates (and the label updates) whenever the General tab writes it.
    @AppStorage("menuBarContent") private var contentRaw = MenuBarContent.iconOnly.rawValue

    private var menuBarContent: MenuBarContent {
        MenuBarContent(rawValue: contentRaw) ?? .iconOnly
    }
```

- [ ] **Step 2: Switch `MenuBarExtra` to a custom label closure**

Replace the `MenuBarExtra("SoundSherpa", systemImage:) { ... }` block (lines 23-26) with:

```swift
        MenuBarExtra {
            ContentTile(dismissMenu: { isMenuPresented = false })
                .environment(controller)
        } label: {
            MenuBarLabel(content: menuBarContent,
                         isConnected: controller.isConnected,
                         batteryLevel: controller.batteryLevel)
        }
```

- [ ] **Step 3: Add the `MenuBarLabel` view**

At the end of `Sources/SoundSherpa/SoundSherpaApp.swift`, after the `SoundSherpaApp` struct's closing brace, add:

```swift
/// The menu bar glyph plus optional battery percentage. Monochrome by default;
/// tints amber/red only at low charge. Falls back to icon-only when there is no
/// battery level (disconnected, or not yet read).
private struct MenuBarLabel: View {
    let content: MenuBarContent
    let isConnected: Bool
    let batteryLevel: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: content.connectionSymbolName(isConnected: isConnected))
            if content.showsBattery, let level = batteryLevel {
                Text("\(level)%").foregroundStyle(tint(forLevel: level))
            }
        }
    }

    /// Monochrome (`.primary`) unless the level is low/critical.
    private func tint(forLevel level: Int) -> Color {
        switch DeviceDisplay.menuBarBatteryTier(forLevel: level) {
        case .critical: return .red
        case .low:      return .orange
        case .normal:   return .primary
        }
    }
}
```

- [ ] **Step 4: Build and verify it compiles**

Build the app target (per project build skill). Expected: builds cleanly. (`SettingsView` still references the old key/enum — if the build surfaces that, it is fixed in Task 4; build `SettingsView` and `SoundSherpaApp` together is fine, but expect the `SettingsView` reference error until Task 4. If building the whole target, do Task 4 before this build step.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/SoundSherpaApp.swift
git commit -m "feat(app): render battery percentage in menu bar label"
```

---

### Task 4: `SettingsView` picker binds `MenuBarContent`

**Files:**
- Modify: `Sources/SoundSherpa/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `MenuBarContent` (Task 1).
- Produces: no new symbols.

- [ ] **Step 1: Replace the `@AppStorage` declaration**

In `Sources/SoundSherpa/Views/SettingsView.swift`, replace line 11:

```swift
    @AppStorage("menuBarContent") private var contentRaw = MenuBarContent.iconOnly.rawValue
```

- [ ] **Step 2: Replace the picker**

Replace the picker block (lines 78-82) with:

```swift
                Picker("Menu bar", selection: Binding(
                    get: { MenuBarContent(rawValue: contentRaw) ?? .iconOnly },
                    set: { contentRaw = $0.rawValue })) {
                    ForEach(MenuBarContent.allCases) { Text($0.displayName).tag($0) }
                }
```

- [ ] **Step 3: Build the full app target**

Build the app + core targets and run the full test suite (per project build/test skill). Expected: build succeeds, all tests pass, no remaining references to `MenuBarIconStyle` or `menuBarIconStyle`.

- [ ] **Step 4: Verify no stale references remain**

```bash
grep -rn "MenuBarIconStyle\|menuBarIconStyle\|iconStyleRaw" Sources Tests
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/Views/SettingsView.swift
git commit -m "feat(app): Settings 'Menu bar' picker binds MenuBarContent"
```

---

### Task 5: Manual verification on hardware

**Files:** none.

- [ ] **Step 1: Run the app and verify behavior**

Launch the app (per project run skill), connect headphones, and confirm:
- Default (Icon only): headphones glyph, solid when connected / slashed when not.
- Switch General → "Menu bar" → "Icon + battery": percentage appears next to the glyph and updates with the live level.
- Percentage is monochrome at normal charge; amber at ≤30; red at ≤15.
- Disconnect: percentage disappears, glyph goes slashed (no stray "%").

- [ ] **Step 2: Verify migration**

Confirm an existing install (previously on `menuBarIconStyle`) launches with the default "Icon only" and no crash — the old key is simply ignored.
