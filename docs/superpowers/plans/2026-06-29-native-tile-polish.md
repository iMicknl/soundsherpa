# Native Control Center Tile Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SoundSherpa `MenuBarExtra` tile read like a native macOS Control Center / Sound-Output panel at the current 280pt width.

**Architecture:** Pure SwiftUI view changes across `MenuRow`, `DeviceHeaderView`, `TileFooter`, `PairedDevicesList`, and `ContentTile`. A small reusable `DeviceBadge` view captures the circular icon-badge idiom shared by the header and paired rows. No model/controller changes.

**Tech Stack:** Swift, SwiftUI, SwiftPM. macOS menu-bar app (`SoundSherpa` executable target).

## Global Constraints

- Tile width stays **280pt** (`ContentTile.frame(width: 280)`).
- Row body text is native **13pt** (`.body`); section group headers stay small secondary-gray (`.caption.weight(.semibold)`).
- These views live in the `SoundSherpa` executable target (AppKit) — **no XCTest harness**. Verification is `swift build -c release` (must compile) plus visual inspection of the running app.
- Run the app natively on the host (NOT in a devcontainer). Always `pkill -9 -f SoundSherpa` before relaunch.
- Build command: `swift build -c release`. App bundle + run: `./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && open SoundSherpa.app`.

---

### Task 1: Reusable `DeviceBadge` view

**Files:**
- Create: `Sources/SoundSherpa/Views/DeviceBadge.swift`

**Interfaces:**
- Produces: `struct DeviceBadge: View { init(systemImage: String, isConnected: Bool, diameter: CGFloat = 30) }` — a circular badge: `.tint` fill + white glyph when `isConnected`, else `.quaternary` fill + primary glyph.

- [ ] **Step 1: Create the badge view**

```swift
import SwiftUI

/// Circular device icon badge matching the native Sound Output list:
/// accent-blue fill with a white glyph when connected, gray fill with a
/// primary glyph otherwise. Shared by the device header and paired-device rows.
struct DeviceBadge: View {
    let systemImage: String
    var isConnected: Bool = false
    var diameter: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: diameter, height: diameter)
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.47, weight: .medium))
                .foregroundStyle(isConnected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/DeviceBadge.swift
git commit -m "feat(ui): reusable DeviceBadge for native icon badges"
```

---

### Task 2: Adopt the badge in `DeviceHeaderView`

**Files:**
- Modify: `Sources/SoundSherpa/Views/DeviceHeaderView.swift`

**Interfaces:**
- Consumes: `DeviceBadge` from Task 1.

- [ ] **Step 1: Replace the inline ZStack avatar with `DeviceBadge` and bump the name font**

Replace the `ZStack { Circle()... }` block with:

```swift
DeviceBadge(systemImage: "headphones.over.ear", isConnected: true)
```

And change the name line from `.font(.subheadline.weight(.semibold))` to:

```swift
Text(name).font(.body.weight(.semibold))
```

(The header device is always the connected one, so `isConnected: true` keeps it blue.)

- [ ] **Step 2: Verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/DeviceHeaderView.swift
git commit -m "feat(ui): header uses DeviceBadge and native 13pt name"
```

---

### Task 3: Native 13pt body in `MenuRow`

**Files:**
- Modify: `Sources/SoundSherpa/Views/MenuRow.swift`

- [ ] **Step 1: Change the row font from `.subheadline` to `.body`**

In `MenuRow.body`, change `.font(.subheadline)` to:

```swift
.font(.body)
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/MenuRow.swift
git commit -m "feat(ui): MenuRow uses native 13pt body text"
```

---

### Task 4: Strip footer icons

**Files:**
- Modify: `Sources/SoundSherpa/Views/TileFooter.swift`

- [ ] **Step 1: Remove `systemImage` from all three footer rows**

```swift
MenuRow(title: "Refresh") { controller.refresh() }
MenuRow(title: "Advanced Settings…") {
    openSettings()
    NSApp.activate(ignoringOtherApps: true)
}
MenuRow(title: "Quit SoundSherpa") {
    NSApplication.shared.terminate(nil)
}
```

(Keep the existing comment on the Advanced Settings activation.)

- [ ] **Step 2: Verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/TileFooter.swift
git commit -m "feat(ui): drop leading icons from footer actions"
```

---

### Task 5: Native Output-style paired rows

**Files:**
- Modify: `Sources/SoundSherpa/Views/PairedDevicesList.swift`

**Interfaces:**
- Consumes: `DeviceBadge` from Task 1; existing `MenuRow` (with the `customLeading` change from Step 1 below).

**Note on MenuRow:** `MenuRow` currently renders only an SF Symbol via `systemImage`. The paired rows need a full `DeviceBadge` as the leading element. Add a leading view-builder to `MenuRow` rather than overloading `systemImage`.

- [ ] **Step 1: Add a leading view-builder to `MenuRow`**

In `Sources/SoundSherpa/Views/MenuRow.swift`, generalize the leading slot. Add a `Leading` generic and builder, defaulting (via the existing convenience init) to the `systemImage` glyph. Concretely, add a second generic parameter and a leading builder:

```swift
struct MenuRow<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading()
                Text(title)
                Spacer(minLength: 0)
                trailing()
            }
            .font(.body)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// Convenience: SF Symbol leading glyph (or none), no trailing.
extension MenuRow where Leading == AnyView, Trailing == EmptyView {
    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.init(
            title: title,
            leading: {
                if let systemImage {
                    AnyView(Image(systemName: systemImage).frame(width: 20))
                } else {
                    AnyView(EmptyView())
                }
            },
            trailing: { EmptyView() },
            action: action)
    }
}

// Convenience: SF Symbol leading glyph (or none), custom trailing.
extension MenuRow where Leading == AnyView {
    init(title: String,
         systemImage: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         action: @escaping () -> Void) {
        self.init(
            title: title,
            leading: {
                if let systemImage {
                    AnyView(Image(systemName: systemImage).frame(width: 20))
                } else {
                    AnyView(EmptyView())
                }
            },
            trailing: trailing,
            action: action)
    }
}
```

This keeps every existing `MenuRow(...)` call site (footer, More, paired) working while adding a `leading:` slot for the badge.

- [ ] **Step 2: Verify the whole project still compiles**

Run: `swift build -c release`
Expected: builds with no errors (footer + More + existing paired call sites still valid).

- [ ] **Step 3: Use `DeviceBadge` as the paired-row leading, remove the trailing dot**

Rewrite `PairedDevicesList.body`'s `MenuRow` to use the new `leading:` slot and drop the trailing dot:

```swift
ForEach(devices, id: \.address) { device in
    MenuRow(
        title: DeviceDisplay.pairedDeviceDisplayName(rawName: device.name, address: device.address),
        leading: {
            DeviceBadge(systemImage: iconName(for: device),
                        isConnected: device.isConnected,
                        diameter: 28)
        },
        trailing: { EmptyView() },
        action: { onToggle(device) })
}
```

(Badge 28pt here so the dense list stays compact; header stays 30pt.)

- [ ] **Step 4: Verify it compiles**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/Views/MenuRow.swift Sources/SoundSherpa/Views/PairedDevicesList.swift
git commit -m "feat(ui): native Output-style paired rows with connection badge"
```

---

### Task 6: Final visual verification & shared inset check

**Files:**
- Modify (only if alignment is visibly off): `Sources/SoundSherpa/Views/ContentTile.swift`, `Sources/SoundSherpa/Views/SegmentedSection.swift`, `Sources/SoundSherpa/Views/PairedDevicesList.swift`

- [ ] **Step 1: Build, bundle, sign, run**

```bash
pkill -9 -f SoundSherpa; swift build -c release && ./build.sh && codesign --force --sign - --identifier nl.imick.soundsherpa SoundSherpa.app && open SoundSherpa.app
```

- [ ] **Step 2: Visually verify against the spec**

Open the menu-bar tile and confirm:
- Rows render at native 13pt (visibly larger than before).
- "More" text left edge lines up with the "Noise Cancellation" section title and the header name. If "More" is still inset right of the section titles, give the `SegmentedSection`/`PairedDevicesList` titles a matching `.padding(.leading, 7)` so all leading edges align, rebuild, recheck.
- Footer actions (Refresh / Advanced Settings… / Quit) have NO leading icons.
- Paired rows show a circular badge: blue with white glyph when connected, gray otherwise; no trailing dot; no battery text.
- Self Voice 4-up pills still fit without truncation at 280pt.

- [ ] **Step 3: Commit any alignment fix (if one was needed)**

```bash
git add -A
git commit -m "fix(ui): align section titles to shared leading inset"
```

(Skip this commit if no alignment change was required.)

---

## Self-Review

**Spec coverage:**
- §1 Typography → Tasks 2 (header name), 3 (`MenuRow.body` font). Section headers intentionally unchanged. ✓
- §2 Shared inset / More alignment → Task 6 Step 2 (verify + conditional fix). ✓
- §3 Footer no icons → Task 4. ✓
- §4 Output-style paired rows (badge, blue-when-connected, no dot, no battery) → Tasks 1 + 5. ✓
- Out-of-scope pills/glass → untouched; pill fit verified in Task 6. ✓

**Placeholder scan:** No TBD/TODO; all code shown. The only conditional is Task 6's alignment fix, which is gated on a concrete visual check with the exact remedy specified. ✓

**Type consistency:** `DeviceBadge(systemImage:isConnected:diameter:)` defined in Task 1, consumed identically in Tasks 2 and 5. `MenuRow` generics extended in Task 5 Step 1 with convenience inits preserving all prior call sites. ✓
