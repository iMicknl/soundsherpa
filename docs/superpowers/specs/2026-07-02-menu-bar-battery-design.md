# Menu bar battery display — design

**Date:** 2026-07-02
**Status:** Approved (pending spec review)

## Motivation

The menu bar is where a headphones utility earns its keep: an at-a-glance read
without clicking. Battery level is the single most useful thing to surface there,
and the data is already live (`DeviceController.batteryLevel: Int?`).

This work also retires the existing `MenuBarIconStyle` setting, whose labels
("Follow connection" / "Always show") were misleading — the icon is *always*
shown; only the glyph changed. It is replaced by a clearer setting that also
carries the new battery option.

## Behavior

A single **"Menu bar"** setting (General tab) with two options:

- **Icon only** (default) — headphones glyph, following connection state:
  - Connected → `headphones.over.ear`
  - Disconnected → `headphones.slash`
  - (Identical to today's "Follow connection" behavior.)
- **Icon + battery** — headphones glyph followed by the battery percentage,
  e.g. `🎧 75%`.

### Nil handling

When `batteryLevel == nil` (disconnected, or connected but not yet read),
**"Icon + battery" falls back to icon-only** — the connection glyph with no
percentage text and no placeholder. No stray "%", "—", or "?".

### Color (subtle by design)

- **Monochrome by default.** Both the headphones glyph and the percentage text
  render as template content that follows the native menu bar tint (adapts to
  light/dark, matches system menu extras).
- **Tint only when low**, as the single exception to monotone:
  - **Amber** when level ≤ 30
  - **Red** when level ≤ 15

These menu-bar thresholds are deliberately lower than the in-app battery pill's
(amber ≤50, red ≤20) so the menu bar stays monochrome the large majority of the
time and only lights up when charge genuinely matters. The in-app pill keeps its
existing thresholds unchanged.

## Components

### Core (testable, no AppKit/SwiftUI)

- **`MenuBarContent` enum** (replaces `MenuBarIconStyle`) in `SoundSherpaCore`:
  - Cases: `iconOnly`, `iconAndBattery`
  - `String` raw value, `CaseIterable`, `Identifiable`
  - `displayName` → "Icon only" / "Icon + battery"
  - `connectionSymbolName(isConnected:)` → headphones glyph (shared logic)
  - `showsBattery: Bool`
- **`DeviceDisplay.menuBarBatteryTier(forLevel:)`** — new pure mapping returning
  `BatteryTier` at the subtler ≤15 critical / ≤30 low thresholds. Existing
  `batteryTier(forLevel:)` (≤20 / ≤50) is untouched, still used by the pill.

### App (SwiftUI)

- **`SoundSherpaApp`**: switch `MenuBarExtra` from the `systemImage:` initializer
  to a `label:` closure that renders the headphones glyph and, when
  `content == .iconAndBattery` and a level is available, the percentage text with
  the menu-bar tint applied. `@AppStorage` key migrated to the new enum.
- **`SettingsView`**: replace the "Menu bar icon" picker with a "Menu bar" picker
  bound to `MenuBarContent`.

## Data flow

`DeviceController.batteryLevel` (live) + persisted `MenuBarContent`
→ `SoundSherpaApp` `MenuBarExtra` label closure
→ glyph (+ optional tinted percentage).

No new plumbing; battery is already read and published.

## Migration

The `@AppStorage("menuBarIconStyle")` key is replaced by a new key for
`MenuBarContent`. Old values (`followConnection` / `alwaysShow`) both map to the
new default `iconOnly` — "Always show" had no real behavioral distinction worth
preserving. No user-visible regression.

## Testing

- Unit tests for `MenuBarContent`: `displayName`, `connectionSymbolName`,
  `showsBattery` per case (replacing `MenuBarIconStyleTests`).
- Unit tests for `DeviceDisplay.menuBarBatteryTier`: boundary values
  (15/16, 30/31, 0, 100).
- SwiftUI assembly stays thin; logic lives in the tested core.

## Out of scope

- Dual-battery (per-earbud/case) rendering — current model is a single `Int?`.
- Charging-state indicator.
- Battery-glyph shape in the menu bar (chose number-only for width/subtlety).
