# SoundSherpa — Multi-Device & Reliability Requirements

## Introduction

This document specifies the requirements for reviving SoundSherpa and refactoring it from a
single-file, Bose-specific menu-bar app into a modular system that:

1. **Is reliable** — connection state and battery always reflect reality; commands don't race.
2. **Is modular** — new headphone brands/models can be added behind a stable interface without
   touching core app, UI, or Bluetooth-transport code.
3. **Is testable** — the device protocol logic (encode/decode) runs in unit tests with no
   headphones, no Bluetooth, and no AppKit attached.
4. **Targets modern macOS** — current toolchain, modern AppKit, async/await.

The current implementation lives entirely in one ~2,700-line `AppDelegate.swift`. The
reverse-engineered Bose QC35 / QC35 II protocol works and must be preserved exactly.

## Glossary

- **DevicePlugin**: A self-contained, compiled-in module implementing device-specific
  identification, capabilities, and command logic for one brand/model family.
- **DeviceRegistry**: Holds the compiled-in plugins and matches a connected device to the
  best plugin.
- **DeviceCapability**: A feature a headphone may support (battery, noise cancellation, etc.).
- **DeviceChannel**: An `actor` that owns a single Bluetooth RFCOMM channel, serializes all
  commands, and exposes an async send/receive interface. Replaces the shared-buffer + semaphore
  machinery.
- **Codec**: Pure functions that turn typed commands into bytes and bytes into typed results.
  Imports only `Foundation` — no `IOBluetooth`, no AppKit.
- **MenuController**: Builds and updates the menu-bar UI from the active device's capabilities
  and state.
- **ConnectionManager**: Owns Bluetooth discovery and connection lifecycle, drives the registry.

## Design decisions (settled)

These override the original `.kiro` draft:

- **D1 — Compiled-in plugins, not dynamic loading.** Plugins are registered in an array at
  startup. No bundle loading / no "add a plugin without recompiling." This delivers the
  modularity goal without the machinery.
- **D2 — Kill `system_profiler` scraping.** Device discovery and metadata come from
  `IOBluetooth` and the device protocol only. The text scraper is removed.
- **D3 — Async via an actor-owned channel.** All device comms go through one `DeviceChannel`
  actor that serializes commands. No shared `responseBuffer` / `responseSemaphore` /
  `expectedResponsePrefix` across concurrent callers.
- **D4 — Pure codec is the test seam.** Protocol encode/decode lives in a `Foundation`-only
  module and is covered by unit + property tests that need no hardware.
- **D5 — Reliability is a first-class requirement** (see Requirement 7), not a side effect.
- **D6 — Untested models are aspirational.** Only QC35 / QC35 II wire formats are confirmed.
  Other Bose models and other brands (Sony, etc.) are designed-for but not assumed-correct
  until verified against hardware.
- **D7 — Settings persistence is deferred.** The headphones store their own state; an app-side
  settings store is out of scope for the revival.

## Requirements

### Requirement 1: Plugin Architecture (compiled-in)

**User Story:** As a developer, I want a plugin-based architecture, so that I can add support
for new headphone brands by adding one module behind a stable interface, without modifying
core/UI/transport code.

#### Acceptance Criteria

1. THE DeviceRegistry SHALL hold a fixed set of compiled-in DevicePlugins registered at startup.
2. THE DevicePlugin interface SHALL define methods for device identification, capability
   enumeration, and command execution.
3. Adding a new DevicePlugin SHALL require changes only to the plugin's own module plus a single
   registration line — no changes to MenuController, ConnectionManager, or DeviceChannel.
4. THE DevicePlugin's protocol logic SHALL NOT import `IOBluetooth` or AppKit.

> Note: This explicitly drops the original "available without recompilation" criterion (D1).

### Requirement 2: Device Identification

**User Story:** As a user, I want the app to automatically detect my headphone model, so that I
get the correct features and controls.

#### Acceptance Criteria

1. WHEN a Bluetooth device connects, THE DeviceRegistry SHALL query each DevicePlugin for a
   confidence score and select the highest non-nil match.
2. THE DevicePlugin SHALL identify devices using name patterns and, where available, vendor/
   product identifiers from `IOBluetooth`.
3. IF multiple plugins match, THEN THE DeviceRegistry SHALL select the highest confidence score.
4. WHEN no plugin matches, THE app SHALL show the device as "Unsupported Device" with basic
   connection status only.
5. Paired-device type/icon detection (Apple/Microsoft/etc.) SHALL be correct: a device SHALL NOT
   be shown with an Apple icon unless it is identified as Apple. (Fixes the observed
   "Mickrosoft → Apple logo" bug.)

### Requirement 3: Capability-Based UI

**User Story:** As a user, I want the menu to show only the features my headphones support.

#### Acceptance Criteria

1. THE DevicePlugin SHALL declare supported DeviceCapabilities.
2. WHEN a device connects, THE MenuController SHALL render only menu items for supported
   capabilities.
3. WHEN a device disconnects, THE MenuController SHALL hide all device-specific items.
4. FOR ALL capability items, THE MenuController SHALL use consistent icons/layout across devices.

### Requirement 4: Protocol Abstraction & Pure Codec

**User Story:** As a developer, I want protocol handling separated from UI and transport, so I
can implement and test new device protocols in isolation.

#### Acceptance Criteria

1. THE Codec SHALL encapsulate all device-specific command encoding and response decoding as
   pure functions (bytes in / typed values out), importing only `Foundation`.
2. THE DeviceChannel SHALL provide an async send-command/await-response interface to plugins and
   SHALL be the only component touching `IOBluetooth` RFCOMM.
3. WHEN a command fails, THE channel SHALL throw a structured `DeviceError` with a specific
   reason (never a silent nil).

### Requirement 5: Bose Device Support (preserve existing behavior)

**User Story:** As a Bose owner, I want every existing QC35 / QC35 II feature to keep working.

#### Acceptance Criteria

1. THE Bose plugin SHALL support battery level for QC35 and QC35 II.
2. THE Bose plugin SHALL support noise cancellation (Off/Low/High) with the existing byte values.
3. THE Bose plugin SHALL support self-voice (Off/Low/Medium/High).
4. THE Bose plugin SHALL support auto-off timer configuration.
5. THE Bose plugin SHALL support voice-prompt language selection and voice-prompt on/off.
6. THE Bose plugin SHALL support paired-device listing and connect/disconnect management.
7. THE Bose plugin SHALL support button-action configuration (Alexa / Noise Cancellation).
8. Firmware and audio codec, where shown, SHALL be obtained via protocol or `IOBluetooth` — never
   `system_profiler`. If unavailable, the field SHALL be hidden rather than shown as "Unknown".
   (Fixes the observed Firmware/Codec/Device ID/Services = "Unknown" bug.)

> Models beyond QC35 / QC35 II are aspirational (D6): structure the plugin to accommodate them,
> but do not ship unverified wire formats as if confirmed.

### Requirement 6: Additional Brand Support (aspirational)

**User Story:** As a developer, I want to prove modularity by adding a second brand later.

#### Acceptance Criteria

1. A second-brand plugin (e.g. Sony WH-1000XM series) SHALL be addable per Requirement 1.3
   without core changes.
2. Brand protocols SHALL NOT be shipped as confirmed until verified against real hardware (D6).

### Requirement 7: Reliability (first-class)

**User Story:** As a user, I want the app to consistently show when my headphones are connected
and consistently report battery — the current build is flaky about both.

#### Acceptance Criteria

1. **Serialized commands.** All device commands SHALL pass through a single DeviceChannel actor;
   no two in-flight commands SHALL share response state. (Fixes battery/NC sometimes missing.)
2. **State reflects reality.** Connected-state and battery SHALL update within a bounded time of
   an actual connect/disconnect, driven by Bluetooth events — not solely a 30s poll.
3. **No false "connected".** Connection SHALL be reported as established only after the protocol
   init actually completes; an init timeout SHALL NOT be treated as success. (Fixes
   `initBoseConnection()` returning true on timeout.)
4. **Retry before failure.** A failed connect or fetch SHALL retry with bounded backoff before
   the UI shows "disconnected"; transient failures SHALL NOT blank out a known-good value.
5. **Graceful disconnect.** WHEN the RFCOMM channel closes, THE app SHALL reflect disconnected
   state, and disconnect notifications SHALL remain correctly registered across reconnects.

### Requirement 8: Error Handling & Bluetooth State

**User Story:** As a user, I want clear feedback when something is wrong.

#### Acceptance Criteria

1. IF a command fails, THEN THE MenuController MAY show a brief, non-blocking error indication
   and SHALL keep the last known-good values.
2. IF Bluetooth is disabled, THEN THE app SHALL display "Bluetooth Disabled".
3. IF a plugin hits an unrecoverable error, THEN THE app SHALL log it and continue with reduced
   functionality.
4. Logging SHALL use a unified logging facility (`os.Logger`), not scattered `print()` calls.

### Requirement 9: Testability

**User Story:** As a developer, I want to test the protocol without headphones attached.

#### Acceptance Criteria

1. THE project SHALL have a `Tests/` target.
2. Codec encode/decode SHALL be covered by unit tests and property tests that require no
   hardware, no Bluetooth, and no AppKit.
3. Device-plugin identification logic SHALL be unit-testable in isolation.

### Requirement 10: Modern macOS & Packaging

**User Story:** As a user/developer, I want it to build and run cleanly on a current Mac and be
straightforward to install and test.

#### Acceptance Criteria

1. THE project SHALL build with the current Swift toolchain with no errors and no new warnings.
   (Baseline verified: builds clean on macOS 26.5.1 / Swift 6.3.2.)
2. Commands SHALL run natively on macOS (IOBluetooth/AppKit require host hardware; no container).
3. THE app bundle SHALL be buildable with a stable signing identity so Bluetooth (TCC) permission
   is not re-prompted/reset on every rebuild. (Investigated separately; not a code blocker.)
