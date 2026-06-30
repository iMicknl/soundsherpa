# Settings Window — Native Redesign

**Date:** 2026-06-30
**Status:** Approved design, ready for implementation plan
**File touched:** `Sources/SoundSherpa/Views/SettingsView.swift`

## Problem

The Settings window (⌘,) reads like a flat spec sheet rather than a native
macOS settings panel. The root cause is that both the General and Device tabs
use a bare `Form` with no `.formStyle(.grouped)`, so macOS falls back to the
ungrouped label-left / control-right layout. The Device tab in particular:

- shows the device name as just another `LabeledContent` row, when it is really
  the subject of the whole tab;
- floats "Voice Prompts" below the control group in its own indent;
- dumps Firmware, Serial Number, Device ID, and a long comma-joined Services
  string as equally-weighted rows — mixing genuinely useful identity with pure
  debug information;
- renders controls with `nil`-coalesced defaults even when no device is
  connected, which is misleading because changing them does nothing.

## Goals

Make all three tabs feel native and consistent, give the Device tab a clear
hierarchy, separate useful device identity from debug detail, handle the
disconnected state explicitly, and add discoverable descriptions to the controls
that need them.

## Design

### Global

- Apply `.formStyle(.grouped)` to the General and Device `Form`s. This is the
  single biggest visual win — it produces rounded grouped cards, proper label
  alignment, and section headers that read as System Settings-native.
- The About tab is **not** a `Form` and stays as-is (a centered identity/marketing
  panel). Only verify its spacing/typography remain consistent.

### General tab

Two grouped cards:

1. **Login behavior** — "Start on login" toggle. The login-error footnote, when
   present, stays attached under this group.
2. **Appearance** — "Menu bar icon" picker.

No functional change beyond grouping.

### Device tab

**When `controller.isConnected == false`:** show a centered empty state instead
of the controls. `isConnected` (not `deviceName != nil`) is the source of truth.

```
                    🎧            ← headphones glyph, dimmed/secondary
              No device connected
      Connect your headphones to manage
           their settings here.
```

**When connected:**

1. **Device header** (not a Form row) — device name as the title, with a
   secondary "Connected · <brand>" subtitle and a headphones glyph. This is the
   subject of the tab, not a setting.

2. **Controls group** — `Section` containing, in order:
   - Auto-Off (Picker)
   - Button Action (Picker)
   - Language (Picker)
   - Voice Prompts (Toggle) — moved *into* this group as a trailing toggle
     rather than floating below.

3. **About this device group** — `Section("About this device")` with always-
   visible, glanceable rows (each gated individually; hidden when nil):
   - **Battery** — `controller.batteryLevel`, rendered with the battery
     SF Symbol + color logic already used in `DeviceHeaderView` (extract/reuse,
     do not duplicate). Live/dynamic value; hidden when `batteryLevel == nil`.
   - **Firmware** — `controller.firmware`
   - **Serial Number** — `controller.serial`

4. **Advanced details** — a `DisclosureGroup`, collapsed by default, holding the
   pure-debug fields:
   - **Device ID** — `controller.deviceId`
   - **Services** — `controller.services`, joined; allowed to wrap rather than
     forced onto one long line.

   The disclosure (and its contents) only appears when at least one of those
   fields is non-nil/non-empty (preserve the existing `hasDeviceInfo`-style
   gating, scoped to these two fields).

### Control descriptions

Use **Option 1 (caption text under the control)**, applied *selectively* — only
to controls that genuinely need explanation, to avoid making the tab tall:

- **Auto-Off** — e.g. "Turn the headphones off after a period of inactivity to
  save battery."
- **Button Action** — e.g. describe what the action button does for each mode.

Self-explanatory controls (Language, Voice Prompts) get no caption.

Captions are `.caption`/secondary styling beneath the control. **Fallback:** if
the grouped Form layout doesn't accommodate captions cleanly, fall back to
**Option 2** (`.help()` hover tooltips) for those controls.

## Out of scope

- No change to the About tab's content/structure.
- No change to `DeviceController` APIs (all needed values — `isConnected`,
  `deviceName`, `batteryLevel`, `firmware`, `serial`, `deviceId`, `services` —
  already exist).
- No new persisted settings.

## Verification

- Build natively and open Settings (⌘,).
- Connected device: header shows name; controls grouped with Voice Prompts
  inside; About-this-device shows Battery/Firmware/Serial; Advanced details
  collapsed and expandable showing Device ID + Services.
- Disconnected: Device tab shows the empty state; no stale control rows.
- General: two grouped cards; login error still surfaces.
- Captions appear under Auto-Off and Button Action.
