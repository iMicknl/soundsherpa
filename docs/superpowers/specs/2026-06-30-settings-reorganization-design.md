# Settings Reorganization Design

**Date:** 2026-06-30
**Branch:** v4

## Problem

The single `AdvancedSettingsView` window mixes everything into "Advanced
Settings" with three tabs (General, Voice, About). The name describes neither
the app preferences nor the device controls well, and there are no app-level
preferences at all yet (no launch-at-login, no icon preference).

The key insight: the right axis for *where* a control lives is **how often you
touch it**, not whether it belongs to the app or the device.

- **Frequent / contextual** (Noise Cancellation, Self Voice) → stay in the menu
  bar popover, front and center.
- **Set-once / forget** (Auto-Off, Button Action, Language, Voice Prompts) →
  belong in the Settings window, not buried in the daily popover.

## Goals

1. Rename the window concept from "Advanced Settings" to plain **"Settings"**
   (the conventional macOS ⌘, label).
2. Reorganize the window into three tabs grouped by ownership now that frequency
   has filtered what lives where: **General** (app), **Device** (set-once device
   controls), **About** (read-only info).
3. Introduce the app's first real app-level preferences: **Start on login** and
   **Menu bar icon style**.

## Non-Goals

- Moving any device control *into* the popover (the popover is unchanged except
  the footer label).
- Auto-reconnect-on-wake preference (out of scope for this pass).
- Localizing or restyling the existing device pickers.

## Architecture

### Popover (`ContentTile`) — minimal change

No structural change. The only edit is in `TileFooter`: the footer row label
changes from `"Advanced Settings…"` to `"Settings…"`. The `openSettings()` +
`NSApp.activate` behavior is unchanged.

### Settings window — `AdvancedSettingsView.swift` → `SettingsView.swift`

Rename the file and the struct (`AdvancedSettingsView` → `SettingsView`). Update
the reference in `SoundSherpaApp.swift`'s `Settings { … }` scene.

Three tabs:

**General (new)** — app preferences:
- **Start on login** — a `Toggle` backed by `SMAppService.mainApp`. On appear,
  reflect the current `SMAppService.mainApp.status` (`.enabled` → on). On toggle,
  call `register()` / `unregister()`. These throw — on error, revert the toggle
  to the real status and show a brief inline message.
- **Menu bar icon** — a `Picker` over `MenuBarIconStyle` ("Follow connection"
  vs "Always show"), persisted via `@AppStorage`.

**Device (renamed from General, folds in old Voice tab)** — the set-once device
controls, all four together, with the same bindings to `DeviceController` as
today:
- Auto-Off (`Picker`)
- Button Action (`Picker`)
- Language (`Picker`)
- Voice Prompts (`Toggle`)

**About** — unchanged (firmware / serial / device id / services + version line).

### New file: `AppSettings.swift`

A small source of truth for app-level preferences, shared by `SoundSherpaApp`
(which reads the icon style to choose the `MenuBarExtra` `systemImage`) and the
General tab (which writes it).

```swift
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case followConnection   // headphones.over.ear / headphones.slash by state
    case alwaysShow         // always headphones.over.ear

    var id: String { rawValue }
    var displayName: String { … }

    /// Resolve to an SF Symbol name given the live connection state.
    func symbolName(isConnected: Bool) -> String {
        switch self {
        case .followConnection: return isConnected ? "headphones.over.ear" : "headphones.slash"
        case .alwaysShow:       return "headphones.over.ear"
        }
    }
}
```

The persisted key is read in `SoundSherpaApp` via `@AppStorage` so the
`MenuBarExtra` re-evaluates its `systemImage` when the style changes.

`Start on login` is *not* stored in `@AppStorage` — its source of truth is
`SMAppService.mainApp.status`, queried directly. Storing a duplicate boolean
would risk drift from the real login-item registration.

## Data Flow

- **Icon style:** General tab `Picker` writes `@AppStorage("menuBarIconStyle")`
  → `SoundSherpaApp` reads the same key → `MenuBarExtra` `systemImage` recomputes
  via `style.symbolName(isConnected:)`.
- **Start on login:** General tab toggle ↔ `SMAppService.mainApp` directly. No
  intermediate storage.
- **Device controls:** unchanged — bind to `DeviceController` getters/setters
  exactly as the current General/Voice tabs do.

## Error Handling

- `SMAppService.register()` / `unregister()` throw. Wrap in `do/catch`; on
  failure, re-read `.status` to set the toggle to its true value and display a
  short inline error string below the toggle (cleared on next successful action).
- Icon-style change is pure local state — no failure path.

## Testing

- **Unit:** `MenuBarIconStyle.symbolName(isConnected:)` maps correctly for both
  cases × both connection states. (`CaseIterable` ordering / `displayName`
  optional.)
- **Manual:** Start-on-login round-trip (toggle on → confirm login item appears
  in System Settings → toggle off), and icon-style switch reflecting live in the
  menu bar. `SMAppService` is not unit-testable without the system.

## Files Touched

- `Sources/SoundSherpa/Views/AdvancedSettingsView.swift` → renamed to
  `SettingsView.swift`, restructured into General / Device / About tabs.
- `Sources/SoundSherpa/Views/TileFooter.swift` — footer label
  "Advanced Settings…" → "Settings…".
- `Sources/SoundSherpa/SoundSherpaApp.swift` — reference `SettingsView`; read
  icon-style `@AppStorage` for the `MenuBarExtra` `systemImage`.
- `Sources/SoundSherpa/AppSettings.swift` (new) — `MenuBarIconStyle`.
- `Tests/…` — unit test for `MenuBarIconStyle.symbolName`.
