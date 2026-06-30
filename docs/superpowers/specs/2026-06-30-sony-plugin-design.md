# Sony WH-1000XM5 / WH-1000XM4 Device Plugin — Design

**Date:** 2026-06-30
**Branch:** v4
**Status:** Approved (design); implementation pending
**Sub-project:** B (Sony), follows Sub-project A (multi-device plugin seam, `2026-06-30-multi-device-plugin-seam-design.md`)

## Summary

Add support for Sony WH-1000XM5 and WH-1000XM4 headphones as a purely additive
`DevicePlugin`, plus the four shared-infrastructure fixes that Sub-project A
deferred for exactly this moment. The plugin reads battery, metadata, and
ANC/ambient state, and writes ANC/ambient and EQ — gated, like Bose, on the
plugin's `supportedFeatures`.

Unlike Bose, the two Sony models speak **two different protocol dialects** that
share identical framing but differ in payload layout. The dialect is negotiated
at runtime. There is **no physical device available**, so unit-tested byte
parity against reverse-engineering references carries the verification burden
that live byte-parity carried for Bose; live verification is a deferred phase.

## Scope

**Models:** WH-1000XM5 (protocol **V2**) and WH-1000XM4 (protocol **V1**) — full
dual-dialect support.

**Features (v1):**
- Battery level
- Metadata (firmware / serial / model id)
- ANC / ambient sound control: mode (off / noise-cancelling / ambient), ambient
  level 0–20, focus-on-voice toggle
- Equalizer: presets + custom 6-band gains

**Explicitly deferred:**
- **Multipoint / paired-device management.** No documented protocol exists in
  any reviewed reference (Gadgetbridge stubs it: "Connection to two devices not
  implemented"); no command bytes are known. It requires a physical device plus
  an HCI packet capture from the Sony | Headphones Connect app. Sony's
  `supportedFeatures` omits `.multipoint`, so the UI hides it automatically.
  Tracked as a future device-required sub-project.

## Reference sources

The wire protocol is anchored on open-source reverse-engineering, cross-validated
across three independent codebases (no hardware to verify against):

- **Primary — Gadgetbridge** (`codeberg.org/Freeyourgadget/Gadgetbridge`, AGPLv3).
  Only reference with explicit, separate coverage of both WH-1000XM4 and
  WH-1000XM5, the clean `protocol/impl/v1/` vs `protocol/impl/v2/` split, and
  byte-level unit tests (`SonyProtocolImplV1Test.java`,
  `SonyProtocolImplV2Test.java`) usable as test vectors. Frame format documented
  in `Message.java`.
- **Secondary — Plutoberth/SonyHeadphonesClient** (MIT, archived). Confirms V1
  framing constants in `Client/Constants.h` / `Client/CommandSerializer.cpp`.
  XM3/V1-era; XM4 partial, XM5 unsupported — framing sanity-check only.
- **Tertiary — `ibatra/sony-headphones-client`** (Rust, MIT) confirms framing
  constants byte-for-byte; **`andersnsouza/sony-xm6-web`** (Python + PyObjC
  IOBluetooth, MIT) is the most macOS-relevant and independently reports the V2
  UUID + RFCOMM channel 9; **`mos9527/SonyHeadphonesClient`** fork has XM5/XM6
  generated protocol files for deeper byte tables if needed.

**Licensing:** Gadgetbridge is AGPLv3 — protocol *facts* (byte values, UUIDs)
are not copyrightable, but re-derive code from the MIT constants and the
published frame spec, using Gadgetbridge's V2 logic and unit-test vectors as a
reference/validator rather than copying source.

## Architecture

The plugin is additive on top of the brand-agnostic seam from Sub-project A
(`DevicePlugin`, `DeviceState`, `DeviceChange`, `ANCState`, `EqualizerState`,
`DeviceChannel` actor, `ResponseMatcher`, `RFCOMMTransport`). Approach chosen:
**one codec with the protocol version threaded through as data** (rather than two
plugins or a strategy-object hierarchy), to mirror the proven `BoseCodec` /
`BosePlugin` shape and keep framing tested in exactly one place.

### New files (SoundSherpaCore — pure, no IOBluetooth, fully unit-testable)

- **`SonyFrame.swift`** — shared framing layer. `encode(payload:seq:type:) ->
  [UInt8]` and `decode(_:) -> SonyFrame?`. Owns markers, escaping, checksum,
  length, message type, sequence byte. Highest-confidence (triple-confirmed)
  code; exhaustively tested.
- **`SonyCodec.swift`** — pure payload builders/parsers, each taking
  `version: SonyProtocol`. `encodeANC`/`decodeANC`, `encodeEQ`/`decodeEQ`,
  `encodeBatteryQuery`/`decodeBattery`, metadata queries, init/version query.
  Flat-namespace style mirroring `BoseCodec`.
- **`SonyProtocol.swift`** — `enum SonyProtocol { case v1, v2 }` plus
  `classify(initReplyPayloadLength:) -> SonyProtocol?` (4 → v1, 8 → v2).
- **`SonyPlugin.swift`** — implements `DevicePlugin`. Negotiates version once on
  connect, caches it, threads it into every codec call.
  `supportedFeatures = [.noiseCancellation, .ambientLevel, .focusOnVoice,
  .equalizer]` (no `.multipoint`).

### New supporting type

- A small `@unchecked Sendable` box (analogous to Bose's `LanguageBox`) held by
  `SonyPlugin` to cache the negotiated `SonyProtocol` and the toggling sequence
  byte for the connection. Safe **only** because one plugin value runs over one
  serializing `DeviceChannel` actor — do not share a channel across plugins.

### Shared-infrastructure fixes (the deferred Sub-project A prerequisites)

1. **128-bit UUID matching (the BLOCKER).** `DeviceController.serviceRecord(matching:in:)`
   currently only handles `0x`-prefixed 16-bit UUIDs. Add the
   `IOBluetoothSDPUUID(string:)` branch: build the UUID, match against each
   record's service UUID, and **read the RFCOMM channel from the matched
   record** (never hardcode — the channel varies per device/model).
2. **Plugin-provided deviceId formatter.** Move the `"Bose 0x%04X"` format out of
   `DeviceController` (`fetchAllDeviceInfo` + `applyCachedMetadata`) so Sony
   renders "Sony …", not "Bose …".
3. **Gate multipoint UI.** `ContentTile`'s `PairedDevicesList` currently renders
   unconditionally when connected; gate it on
   `supportedFeatures.contains(.multipoint)`.
4. **Generalize the unsolicited-broadcast handler.** The handler in
   `rfcommChannelData` is gated on `activePlugin?.identifier == "Bose"`;
   generalize to a plugin hook so Sony's unsolicited ANC/ambient frames reflect
   live.

### Registration

One line: `DeviceRegistry.standard` becomes `[BosePlugin(), SonyPlugin()]`.

## Wire protocol — frame format (triple-confirmed)

```
[0x3E START] [MSG_TYPE 1B] [SEQ 1B] [LEN 4B big-endian] [PAYLOAD …] [CHECKSUM 1B] [0x3C END]
                └──────────────── escaped + covered by checksum ────────────────┘
```

| Field | Rule |
|---|---|
| Start marker | `0x3E` |
| End marker | `0x3C` (distinct from start) |
| Escape byte | `0x3D`; emit `0x3D` then `(byte & 0xEF)`; unescape `byte \| 0x10`. Only `0x3E`/`0x3C`/`0x3D` escaped → `0x3D 0x2E` / `0x3D 0x2C` / `0x3D 0x2D`. |
| Checksum | 1-byte sum (mod 256) over `MSG_TYPE + SEQ + LEN + PAYLOAD`, computed before escaping, then itself escaped if needed. |
| Sequence | 1 byte toggling 0x00↔0x01; advances on ACK; an ACK to an incoming message uses `1 - seq`. |
| Message type | `ACK=0x01`, `COMMAND_1=0x0C`, `COMMAND_2=0x0E`. The command/payload type is the **first payload byte**, not a header field. |

## Discovery, connection & version negotiation

1. **Detection (name-based, pre-channel).** `checkForSupportedDevices` asks the
   registry `plugin(forDeviceNamed:)`. `SonyPlugin.handles(deviceNamed:)` matches
   Sony WH-1000XM names (exact predicate pinned during planning; "sony" /
   "wh-1000" lowercased substring — first-match-wins registry, Sony is the only
   Sony plugin). Sets `activePlugin`.
2. **SDP service match (BLOCKER fix).** `discoveryDescriptor` lists both vendor
   UUIDs in priority order (V2 first), no channel hints:
   ```
   serviceMatchers: [.uuid("956C7B26-D49A-4BA8-B03F-B17D393CB6E2"),  // V2 / XM5
                     .uuid("96CC203E-5068-46AD-B32D-E316F5E069BA")]  // V1 / XM4
   channelHints: []
   ```
   `serviceRecord` matches via `IOBluetoothSDPUUID(string:)` and reads the RFCOMM
   channel from the matched record.
3. **Open channel & attach the `DeviceChannel` actor** — unchanged,
   brand-agnostic.
4. **Version negotiation (post-connect, before any feature command).** Send the
   init command (`COMMAND_1` payload `00 00`); await the reply (`COMMAND_1`,
   first payload byte `0x01`); classify by **payload length** (4 → V1, 8 → V2).
   Cache the negotiated `SonyProtocol` for the connection's lifetime; thread it
   into every subsequent codec call.

**Precedence:** if the UUID picked and the negotiated version disagree (unlikely),
the **negotiated handshake wins** — it is the authoritative runtime signal; the
UUID only selects which service to open.

**Negotiation failure** (no/garbled init reply, or orphaned channel): reads return
empty/nil per the no-throw contract; the UI shows last-known-good cached
metadata — same path as the Bose orphaned-channel failure mode.

## Feature data flow

### Reads — `SonyPlugin.readState(over:) -> DeviceState`

- Negotiate version (cached if already done this session).
- **Battery** (`0x10` V1 / `0x22` V2) → `DeviceState.battery`.
- **ANC/ambient** (combined sound-control `0x68`) → `DeviceState.anc =
  ANCState(mode:, ambientLevel:, focusOnVoice:)`. Mode → `.off` /
  `.noiseCancelling` / `.ambient`; `ambientLevel` 0–20 (nil in NC/off);
  `focusOnVoice` from the bool byte.
- **EQ** (`0x58`) → `DeviceState.equalizer = EqualizerState(presetId:, bands:)`.
  Preset IDs from Sony's table (OFF `0x00` … BASS_BOOST `0x16`, CUSTOM `0xA1`);
  6 bands stored as gain+10, decoded to signed dB.
- Bose-only fields stay nil; UI doesn't render them (gated on `supportedFeatures`).

### Writes — `SonyPlugin.apply(_ change:over:) -> Bool`

- `.anc(ANCState)` → `encodeANC(state, version:)` → send → return true only on
  device ACK within timeout.
- `.equalizer(EqualizerState)` → `encodeEQ(state, version:)` → ACK-gated.
- All other `DeviceChange` cases → `false` (unsupported), consistent with the
  ACK-gated contract from Sub-project A (UI updates only on ACK within timeout).

### Metadata — `readMetadata(over:) -> DeviceMetadata`

- Firmware/serial/model queries (V1 `0x18` / V2 `0x12`). Unreported fields stay
  nil; total failure → empty `DeviceMetadata`. Model id feeds the plugin-provided
  deviceId formatter → "Sony …".

### Unsolicited broadcasts (fix #4)

On-device ANC/ambient changes push an unsolicited `0x68` frame. The generalized
handler routes it to `SonyPlugin` to decode → updates `ANCState` on `@MainActor`,
mirroring Bose's live-NC reflection. A checksum mismatch on an inbound frame is
treated as a decode failure and dropped (a corrupt push must not move the UI).

## UI (in scope)

Bose's NC is a 3-way segmented control bound to `NoiseCancellationLevel`. Sony's
model is `ANCState`: a 3-way mode (off / NC / ambient), a conditional 0–20
ambient slider (shown only in ambient mode), and a focus-on-voice toggle, plus
the EQ controls. These controls are bound to `ANCState` / `EqualizerState` and
gated on `.ambientLevel` / `.focusOnVoice` / `.equalizer`. In scope because the
plugin otherwise reads/writes state nothing renders.

## Error handling & invariants

- **No-throw plugin contract.** Reads/`apply` never throw, never fabricate. Missing
  reply → nil/empty/false. The `DeviceChannel` actor throws typed `DeviceError`;
  `SonyPlugin` swallows to nil/`[]` via a private `sendExpecting` helper (like
  `BosePlugin`).
- **Frame-decode safety.** `SonyFrame.decode` and every `decodeX` validate
  markers/length/prefix before indexing; return nil on mismatch; never crash on a
  short or corrupt buffer.
- **Checksum mismatch** on inbound frames → decode failure (drop), never act on it.
- **Lifecycle (from Sub-project A).** `activePlugin` is **device identity** —
  `closeChannelLocked()` must NOT clear it. The negotiated-version + sequence box
  is **channel state** and **must reset on each new channel** (a reconnect could be
  a different dialect). This distinction is bug-prone; honor it explicitly.
- **ACK-gating** carried over: UI updates only on ACK within the timeout.
- **Concurrency.** All command I/O serializes through the one `DeviceChannel`
  actor; the `@unchecked Sendable` version box is safe only under that
  single-channel guarantee.

## Testing strategy

No device — unit tests carry the verification burden, anchored on Gadgetbridge's
V1/V2 test vectors, cross-checked against Plutoberth/ibatra MIT constants.

1. **`SonyFrameTests` (highest priority).** Round-trip encode/decode with and
   without escaped bytes; exact escape sequences (`0x3D 0x2E`/`0x2C`/`0x2D`);
   checksum from known vectors; flipped byte / truncated / missing-end-marker /
   bad-checksum → nil, no crash; sequence toggling.
2. **`SonyCodecTests` (per-feature, per-dialect byte parity).** For battery,
   ANC/ambient, focus-on-voice, EQ, metadata, init query: assert
   `encodeX(..., version: .v1)` and `.v2` produce the exact reference byte arrays
   (literal byte-parity gate). Decode parity → assert decoded
   `ANCState`/`EqualizerState`/battery/etc. Edges: ambient clamp 0–20, EQ band
   gain+10 ↔ signed dB. Explicit test pinning the V2 reversed-boolean polarity
   flagged in research.
3. **`SonyProtocolTests`.** `classify(initReplyPayloadLength:)` → 4=v1, 8=v2,
   else nil.
4. **`SonyPluginTests` (scripted transport).** Reuse Sub-project A's
   `ScriptedTransport`/`DeviceChannel` harness: version negotiated once and
   cached; `readState` assembles the right `DeviceState`; `apply` true only on
   scripted ACK, false on timeout/unsupported; unsupported `DeviceChange`
   short-circuits to false; negotiation failure → empty state.
5. **`DeviceRegistryTests` (extend).** `SonyPlugin` claims Sony names, Bose still
   claims Bose, no cross-claiming.
6. **App-side `serviceRecord` 128-bit branch.** Unit-test the matcher against fake
   SDP records where feasible; IOBluetooth-bound parts covered by the live
   checklist below.

## Requires a physical device (deferred live-verification phase)

These cannot be covered by unit tests and must be confirmed on real XM5/XM4
hardware before the plugin is considered fully verified:

- WH-1000XM4 exact init-reply length (the over-ear XM4 → V1 mapping is inference;
  Gadgetbridge's named comment covers the WF-1000XM4 earbuds + XM5).
- V2 ambient sub-type `0x15` vs `0x17` and the wind-noise branch for specific XM5
  firmware.
- V2 reversed-boolean polarity (`isEnabled() ? 0x00 : 0x01` `// reversed?` in
  Gadgetbridge) for relevant toggles.
- Actual RFCOMM channel (resolved from SDP; channel 9 observed for V2 but not
  guaranteed).
- End-to-end discovery via the 128-bit UUID path and the full connect handshake.
- Multipoint command bytes (entire feature; deferred sub-project).

## Out of scope

- Multipoint / paired-device management (see above).
- Bose-only features for Sony (`selfVoice`, `autoOff`, `buttonAction`,
  `promptLanguage`, `voicePrompts`).
- Audio codec display (unobtainable on macOS, hidden for all brands).
- Any change to Bose wire output (byte-for-byte unchanged).
