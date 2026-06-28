# Multi-Device Integration Research

**Date:** 2026-06-29
**Scope:** Feasibility and integration approach for adding Sony WH-1000XM6, Bose QC Ultra Headphones Gen 2, Sennheiser HDB 630 (Momentum 4 lineage / Smart Control), and Bowers & Wilkins Px7 S3 to SoundSherpa.
**Method:** Multi-source web research with adversarial verification (88 claims extracted → 25 verified → 22 confirmed, 3 refuted), cross-referenced against SoundSherpa's current architecture.

> **No code changes were made.** This is research only.

---

## TL;DR

The four headphones split into **two clear tiers**:

| Tier | Devices | Why |
|------|---------|-----|
| **Ready to build** | Sony WH-1000XM6, Bose QC Ultra Gen 2 | Proprietary control protocols (Sony MDR, Bose BMAP) run over **Bluetooth Classic RFCOMM/SPP** — the exact transport SoundSherpa already drives. Mature open-source projects document the framing and opcodes, and there is a proven macOS IOBluetooth precedent. |
| **Needs primary investigation** | Sennheiser HDB 630, B&W Px7 S3 | No verified protocol evidence survived. The one Sennheiser candidate (GAIA v3) was **refuted** on verification; B&W has **zero** surviving evidence. Transport (RFCOMM vs BLE GATT) is unconfirmed for both. |

The decisive architectural fact: **macOS forces a hard split between IOBluetooth (Classic/RFCOMM) and CoreBluetooth (BLE/GATT)** — they are mutually exclusive frameworks. SoundSherpa's `RFCOMMTransport` seam covers the RFCOMM camp cleanly; a GATT device would require a *second* transport implementation backed by CoreBluetooth.

---

## How this maps onto SoundSherpa's architecture

SoundSherpa already has the right seams for multi-brand support. A new RFCOMM device needs only new pure-data pieces plugged into existing protocols:

| Seam | File | What a new brand supplies |
|------|------|---------------------------|
| **`RFCOMMTransport` protocol** | `Sources/SoundSherpaCore/DeviceChannel.swift:14-26` | Nothing for RFCOMM devices (reused as-is). A **new `CoreBluetoothGATTTransport`** only if a device is BLE GATT. |
| **`DeviceChannel` actor** | `Sources/SoundSherpaCore/DeviceChannel.swift:35-177` | Nothing — serialized command I/O is brand-agnostic. |
| **`ResponseMatcher`** | `Sources/SoundSherpaCore/ResponseMatcher.swift:11-65` | A new framing strategy if reply framing differs (e.g. Sony's marker-delimited, length-prefixed frames). |
| **Per-brand codec** | new `SonyCodec.swift` / `BMAPCodec.swift` (cf. `BoseCodec.swift`) | Pure encode/decode functions — opcodes, packet framing, feature parsing. No I/O. |
| **`DevicePlugin`** | new `SonyPlugin.swift` (cf. `BosePlugin.swift:10-67`) | `handles(deviceNamed:)` + feature getters; registered in `DeviceRegistry.standard`. |
| **Feature enums** | new `SonyLevels.swift` (cf. `DeviceLevels.swift`) | Brand-specific ANC/EQ value mappings. |

**Key implication:** Sony and Bose-class devices are a *codec + plugin + matcher* exercise with **no changes to the actor, transport, or AppDelegate**. A BLE GATT device (if Sennheiser/B&W turn out that way) is a larger lift because it needs a parallel CoreBluetooth transport and a discovery path that doesn't go through SDP/RFCOMM-channel lookup.

---

## Per-device findings

### 1. Sony WH-1000XM6 — ✅ High feasibility (RFCOMM)

**Transport:** Proprietary **Sony MDR protocol over Bluetooth Classic RFCOMM/SPP** — *not* BLE GATT. *(confidence: high, 3-0)*

**Service discovery:** SPP resolved via a Sony **vendor-specific 128-bit UUID** `96CC203E-5068-46AD-B32D-E316F5E069BA` — **not** the canonical `0x1101` Serial Port UUID. Discovery must query this vendor UUID. *(high)*

**Packet framing** *(high, 3-0)* — directly reusable for a `ResponseMatcher` + codec:
```
START_MARKER (0x3E '>')
  ESCAPE_SPECIALS(
    <1-byte DATA_TYPE>
    <1-byte SEQUENCE_NUMBER>
    <4-byte BIG-ENDIAN payload length>
    <payload>
    <1-byte additive checksum>
  )
END_MARKER (0x3C '<')
```
- Max message size 2048 bytes.
- Bytes `0x3C / 0x3D / 0x3E` (60/61/62) are byte-stuffed/escaped inside the body.
- This is a **length-prefixed, marker-delimited frame** — a new `ResponseMatcher` strategy distinct from Bose's prefix/collecting matchers.

**Feature opcodes** *(high, 3-0)*:
- ANC/ambient: `NCASM_SET_PARAM = 104`, with `NC_ASM_INQUIRED_TYPE`: `NO_USE=0`, `NOISE_CANCELLING=1`, `NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE=2`, `AMBIENT_SOUND_MODE=3` (+ ambient level / focus-on-voice).
- Also documented: equalizer (presets + custom bands), battery (single/dual/case), firmware version, audio codec, and **fetching existing device settings**.

**Open-source to build on:**
- **[SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient)** (MIT, C++/Obj-C++) — reverse-engineered MDR protocol with a **working macOS IOBluetooth connector** (`Client/macos/MacOSBluetoothConnector.mm`) using the identical `IOBluetoothRFCOMMChannel` + `IOBluetoothSDPUUID` + `getRFCOMMChannelID:` + `openRFCOMMChannelAsync:withChannelID:delegate:` flow SoundSherpa already uses. MIT license makes it usable as a reference for our own implementation. Frame layout lives in `Client/Constants.h` and `Client/CommandSerializer.cpp`.
- **[Gadgetbridge](https://gadgetbridge.org/gadgets/headphones/sony/)** (AGPLv3 — license-incompatible for copying, reference only) lists **WH-1000XM6 as "Partially supported / Experimental."**
- **[ohm-app/sony-headphones-bluetooth-documentation](https://github.com/ohm-app/sony-headphones-bluetooth-documentation)** — standalone protocol notes.

**⚠️ XM6-specific caveat:** No surviving source tested the XM6 first-hand. SonyHeadphonesClient validates only **XM3 (full) / XM4 (partial)** and was **archived read-only in July 2025**. Gadgetbridge added XM6 **"without access to the device,"** reusing the XM4/XM5 code path. The RFCOMM *transport* is reliable, but **command-level opcodes/encodings must be validated against actual XM6 firmware (~3.0.0)** — Sony may have changed encodings even with the transport unchanged.

**Recommended approach:** New `SonyCodec` + `SonyMDRResponseMatcher` (marker-delimited, length-prefixed) + `SonyPlugin`. Reuse the existing RFCOMM transport but extend SDP discovery to accept the **vendor 128-bit UUID**. Start with battery + ANC (lowest-risk, best-evidenced), validate opcodes against real hardware before expanding to EQ.

---

### 2. Bose QC Ultra Headphones Gen 2 — ✅ Highest feasibility (RFCOMM, same family as current Bose)

**Transport:** **Bose BMAP protocol over Bluetooth RFCOMM** — not BLE GATT. Devices auto-detected by **BMAP service UUID**. This is the same protocol family SoundSherpa already speaks. *(high, 3-0)*

**RFCOMM channel:** Differs per model — **QC Ultra 2 responds on channel 2**, QC35 on channel 8 — discovered by probing channels. Best expressed as **config data, not code branches** (the approach `bosectl` takes). *(high, 3-0)*

**BMAP structure** *(high, 3-0)*:
- Organized into **function blocks + operators**: `SET=0`, `GET=1`, `SET_GET=2`, `STATUS=3`, `ERROR=4`, `START=5`...
- **Authentication gotcha:** `SET` (operator 0) is gated behind **cloud-mediated ECDH authentication**. But **`SET_GET` (operator 2) and `START` (operator 5) are unauthenticated** on the **Settings (block 1)** and **AudioModes (block 31)** blocks. No keys are extracted, no encryption broken.
- Function-level exceptions exist: e.g. `Settings.CNC [1.5]` and `AudioModes.CurrentMode [31.3]` may still require auth; `START` is broadly unauthenticated mainly on AudioModes (block 31).

**Open-source to build on:**
- **[bosectl](https://github.com/aaronsb/bosectl)** — libraries in Python/Rust/C++ implementing **BMAP over RFCOMM**, with **QC Ultra Headphones 2 in the verified supported-devices list**: CNC control, 3-band EQ, spatial audio, profiles, button remapping. Transport described as "RFCOMM socket with drain mode for async responses" — conceptually identical to SoundSherpa's `DeviceChannel` ingest model.
- **[based-connect](https://github.com/Denton-L/based-connect)** — older QC35-era reference (`#define BOSE_CHANNEL 8`).
- **[davidv.dev QC35 writeup](https://blog.davidv.dev/posts/reverse-engineering-the-bose-qc35-bluetooth-protocol/)** — 3-byte header + 1-byte length framing (no checksum), Wireshark `btspp` filter method.

**Recommended approach:** This is likely the **smallest lift** — verify whether SoundSherpa's existing Bose path already covers the QC Ultra Gen 2 (it may need only the channel-2 entry + BMAP feature blocks). Model per-device differences (channel, init packets, feature availability) as **config data**. **Open question:** which specific features (CNC level, 3-band EQ, spatial audio) are reachable via unauthenticated `SET_GET`/`START` vs which require the cloud ECDH `SET` we cannot perform.

---

### 3. Sennheiser HDB 630 — ⚠️ Open investigation (transport unconfirmed)

**No verified evidence survived.** The single candidate source — [f3Y0/momentum4-control](https://github.com/f3Y0/momentum4-control), claiming Qualcomm **GAIA v3 over RFCOMM**, control UUID `A2129FF3-081B-4C45-8AFE-469D9C4842EC`, and ANC opcodes `0x1A04/0x1A05` etc. — was **REFUTED on adversarial verification (1-2 votes)** on all three of its key claims. Do **not** treat these as a starting point without independent confirmation.

**Two compounding uncertainties:**
1. **Device mismatch:** The refuted source targets the **Momentum 4** (Smart Control app). The **HDB 630 is a newer/different product line** — even the protocol mapping between them is unconfirmed.
2. **Transport unknown:** Whether the HDB 630 uses RFCOMM/SPP *or* BLE GATT is undetermined.

**Context (unverified, background only):** GAIA (Generic Application Interface Architecture) originated at CSR (acquired by Qualcomm 2015) and is used by Qualcomm/CSR audio chips. GAIA can run over **both** classic RFCOMM/SPP **and** BLE GATT, so confirming "it's GAIA" would *not* by itself settle the transport question.

**Recommended approach:** **Primary investigation required before any commitment.** Pair the headphones, run an HCI/btsnoop capture (or `PacketLogger` on macOS) while exercising the Smart Control app, and determine: (a) RFCOMM/SPP vs BLE GATT, (b) service UUID(s), (c) framing. Only then decide whether it fits the existing `RFCOMMTransport` seam or needs the CoreBluetooth path. **Lowest priority of the four** until transport is confirmed.

---

### 4. Bowers & Wilkins Px7 S3 — ⚠️ Entirely open (no evidence)

**Zero surviving evidence.** No claim about transport, service UUIDs, protocol structure, or any open-source project survived (or was even refuted — there simply were none). The **B&W Music app** is the only known control surface; transport and protocol are completely undetermined.

**Recommended approach:** Fully greenfield reverse-engineering. Scan for advertised services (SPP vs GATT), HCI-snoop the B&W Music app, and characterize the protocol from scratch. **Highest-effort, highest-uncertainty** of the four — defer until Sony/Bose are shipped and the RE toolchain (capture + decode workflow) is established.

---

## Cross-cutting: macOS transport feasibility

**IOBluetooth RFCOMM is the correct, current path** for the SPP devices *(high, 3-0, four corroborating claims)*:
- `IOBluetoothRFCOMMChannel` is **non-deprecated** (only two legacy `write:length:sleep:` *methods* are method-level deprecated; the class is current, framework since macOS 10.2).
- Canonical discovery flow, which SoundSherpa already implements (`AppDelegate.swift:1443`):
  ```
  serviceUUID (0x1101 standard, or vendor 128-bit for Sony)
    → device.getServiceRecordForUUID:
    → record.getRFCOMMChannelID:
    → device.openRFCOMMChannelAsync:withChannelID:delegate:
  ```
- **Gotcha:** `getServiceRecordForUUID:` reads **cached** SDP records — a prior `performSDPQuery:` may be needed before the lookup succeeds.

**The IOBluetooth ↔ CoreBluetooth split is load-bearing** *(high, 3-0)*:
- **IOBluetooth** = Classic Bluetooth / RFCOMM / SPP (Sony, Bose).
- **CoreBluetooth** = BLE / GATT **only** — no RFCOMM/SPP support.
- They are mutually exclusive. A confirmed-GATT device (possible for Sennheiser/B&W) would need a **new `CoreBluetoothGATTTransport: RFCOMMTransport`** conformer plus a different discovery/identity model (CoreBluetooth uses per-machine peripheral UUIDs, not Bluetooth addresses).

**Reusable GATT pattern (if needed):** [SoundcoreManager](https://github.com/gmallios/SoundcoreManager) and [OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30) (both Soundcore, *not* target devices) demonstrate a clean GATT abstraction: a `BLEConnectionUuidSet { service_uuid, read_uuid, write_uuid }` with WriteWithResponse/WithoutResponse, backend-agnostic (btleplug → CoreBluetooth on macOS). OpenSCQ30's per-device-module + `DeviceModel` registry is also a strong **architectural reference** for SoundSherpa's plugin approach. Their "request-state packet → one large state-update packet" pattern (sound mode as single bytes, EQ as preset-id + 8 band dB values where `120 == 0.0 dB`, serial as 16 hex bytes, firmware `[0-9]{2}.[0-9]{2}`) is a useful state-modeling template.

---

## Recommended sequencing

1. **Bose QC Ultra Gen 2 first** — same protocol family as current Bose; likely smallest delta (channel-2 + BMAP feature blocks, config-driven). Validate which features are reachable without cloud ECDH auth.
2. **Sony WH-1000XM6 second** — well-documented MDR protocol, MIT reference implementation with macOS IOBluetooth precedent. New codec + marker-delimited matcher + vendor-UUID discovery. **Validate opcodes against real XM6 firmware** before building beyond battery/ANC.
3. **Sennheiser HDB 630** — blocked on primary investigation (HCI capture) to confirm transport. Don't commit a design until RFCOMM-vs-GATT is settled.
4. **B&W Px7 S3** — greenfield RE, defer until the capture/decode workflow is proven on the others.

---

## Open questions

1. **Sony XM6 opcodes:** Do SonyHeadphonesClient's XM3/XM4-derived MDR opcodes (`NCASM_SET_PARAM=104`, EQ commands) work unmodified on XM6 firmware ~3.0.0, or did Sony change command-level encodings while keeping the RFCOMM transport?
2. **Bose auth boundary:** For QC Ultra Gen 2, which specific features (CNC level, 3-band EQ, spatial audio) are reachable via unauthenticated `SET_GET`/`START` vs which require the cloud-mediated ECDH `SET` that open-source clients cannot perform?
3. **Is QC Ultra Gen 2 already partly handled** by SoundSherpa's existing Bose path, and what is the minimal delta?
4. **Sennheiser HDB 630 transport:** RFCOMM/SPP or BLE GATT? And does the HDB 630 share the Momentum 4's protocol at all?
5. **B&W Px7 S3:** everything — transport, UUIDs, framing, protocol.

---

## Caveats & confidence

- **Coverage is uneven by design of what exists publicly.** Sony and Bose are backed by primary, unanimously-verified sources and a working macOS precedent. Sennheiser and B&W are essentially unevidenced — treat their sections as "what we *don't* know."
- The Sennheiser GAIA findings are **refuted, not merely unverified** — they failed adversarial checks. Don't anchor on them.
- Some of the strongest protocol *patterns* (OpenSCQ30, SoundcoreManager) come from **Soundcore**, not the four targets — useful as architecture/RE templates only.
- License watch: **SonyHeadphonesClient is MIT** (safe to reference/adapt). **Gadgetbridge is AGPLv3** — reference for behavior, do not copy code into a differently-licensed app.

---

## Sources

**Primary / high-value:**
- SonyHeadphonesClient — https://github.com/Plutoberth/SonyHeadphonesClient (+ `Constants.h`, `CommandSerializer.cpp`, `macos/MacOSBluetoothConnector.mm`)
- bosectl — https://github.com/aaronsb/bosectl
- Gadgetbridge Sony page — https://gadgetbridge.org/gadgets/headphones/sony/
- ohm-app Sony protocol docs — https://github.com/ohm-app/sony-headphones-bluetooth-documentation
- Apple IOBluetoothRFCOMMChannel — https://developer.apple.com/documentation/iobluetooth/iobluetoothrfcommchannel
- macOS RFCOMM/SPP example — https://github.com/orklann/macOS-bluetooth-example

**Patterns / reference (non-target devices):**
- OpenSCQ30 — https://github.com/Oppzippy/OpenSCQ30
- SoundcoreManager — https://github.com/gmallios/SoundcoreManager
- Bleak macOS backend (CoreBluetooth/BLE) — https://bleak.readthedocs.io/en/latest/backends/macos.html
- Bose QC35 RE writeup — https://blog.davidv.dev/posts/reverse-engineering-the-bose-qc35-bluetooth-protocol/
- based-connect — https://github.com/Denton-L/based-connect

**Refuted (do not rely on):**
- f3Y0/momentum4-control (Sennheiser GAIA v3 claims, 1-2 refuted) — https://github.com/f3Y0/momentum4-control
