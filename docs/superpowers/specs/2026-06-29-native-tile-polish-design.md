# Native Control Center polish for the SoundSherpa tile

Date: 2026-06-29
Branch: v4

## Goal

Make the `MenuBarExtra` tile read like a native macOS Control Center / menu
panel (Wi-Fi panel, Sound Output list) rather than a custom popover. The tile
stays at its current **280pt** width; the changes are typographic, alignment,
and the paired-device row treatment.

## Reference

- Native Wi-Fi panel: 13pt body rows, small gray group headers, bottom actions
  ("Other…", "Wi-Fi Settings…") with **no** leading icons.
- Native Sound **Output** list: each device is a circular icon badge + name.
  The badge is **accent-blue with a white glyph when connected**, gray
  otherwise. No trailing dot, no per-device battery text.

## Changes

### 1. Typography (native 13pt body)

- `MenuRow`: row font `.subheadline` → `.body` (13pt). Affects More, footer,
  and paired-device rows.
- `DeviceHeaderView`: device name `.subheadline.weight(.semibold)` →
  `.body.weight(.semibold)`. Battery line stays `.caption`.
- Section group headers (`SegmentedSection` title, "Paired Devices" header):
  **unchanged** — they stay the small secondary-gray header that matches native
  group headers like "Known Networks".

### 2. Shared left inset / "More" alignment

- Adopt a single shared left inset so the header avatar, section titles,
  "More" row, pills, and footer all share one leading edge.
- Reduce `MenuRow` horizontal padding to align its text with the section
  content leading edge (the current 7pt inset is what makes "More" sit right of
  the "Noise Cancellation" title). Target: a consistent ~4pt content inset
  across the tile, with the row hover-highlight extending to the row edges.

### 3. Footer — remove icons

- `TileFooter`: drop `systemImage` from Refresh, Advanced Settings…, and Quit
  SoundSherpa. Plain text rows, left-aligned at the shared inset — matching
  native bottom actions which carry no leading icons.
- `MenuRow` already only indents text when an icon is present, so icon-less
  rows sit flush at the inset with no extra work beyond removing the glyph.

### 4. Paired device rows — native Output-list style

- Each paired row becomes: `[circular badge] DeviceName`, full-width, with the
  row hover-highlight. 13pt body text.
- **Circular icon badge**, 30pt (matching `DeviceHeaderView` avatar):
  - **Connected:** accent-blue (`.tint`) filled circle, white device-type glyph.
  - **Not connected:** quaternary-filled circle, primary-color device-type glyph.
- The blue badge **fully replaces** the previous trailing connected-dot — the
  trailing accessory is removed.
- **No battery / no trailing text** on paired rows. We don't have per-device
  battery; the active device's battery already shows in the header.
- Device-type glyphs (laptop/phone/speaker/Apple TV/etc.) stay — identity
  icons, as in the native list.

### Out of scope (kept structurally as-is)

- NC / Self Voice segmented pills — the app's signature control, no native
  equivalent. Inherit the 13pt-era changes only where they already sit
  (`.caption2` pill labels unchanged). Verify the 4-up Self Voice row still
  fits at 280pt.
- The accent-tint, glass background, dividers, and overall vertical rhythm.

## Implementation notes

- Affected files: `MenuRow.swift`, `DeviceHeaderView.swift`, `TileFooter.swift`,
  `PairedDevicesList.swift`, `ContentTile.swift` (inset constant if shared).
- The 30pt badge logic in the header and the paired list is the same shape — a
  small reusable `DeviceBadge`-style view is worth extracting so the two stay
  consistent.

## Success criteria

- Rows render at native 13pt; header/section/More/footer share one left edge.
- Footer actions have no leading icons.
- Paired rows show a circular badge that is blue when connected, gray
  otherwise; no trailing dot; no battery text.
- Tile remains 280pt wide; Self Voice 4-up pills still fit without truncation.
