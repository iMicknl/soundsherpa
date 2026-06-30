# Sony WH-1000XM5 / WH-1000XM4 Device Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sony WH-1000XM5 (protocol V2) and WH-1000XM4 (protocol V1) support to SoundSherpa as a purely additive `DevicePlugin` with battery, metadata, ANC/ambient, and EQ — plus the four shared-infrastructure fixes Sub-project A deferred.

**Architecture:** A pure framing layer (`SonyFrame`) and a version-parameterized codec (`SonyCodec`) in SoundSherpaCore, driven by a `SonyPlugin` that negotiates the V1/V2 dialect once on connect and threads it through every codec call (Approach A — mirrors the existing `BoseCodec`/`BosePlugin` shape). The brand-agnostic `DeviceChannel` actor, registry, and UI layers are reused unchanged except for four bounded fixes (128-bit UUID matching, plugin-provided deviceId formatting, multipoint UI gating, generalized unsolicited-broadcast hook) and the new Sony ANC/EQ UI controls.

**Tech Stack:** Swift 5.9+, SwiftPM, XCTest, IOBluetooth (app target only), SwiftUI (menu-bar UI). Core target is Foundation-only and fully unit-testable without hardware.

**Reference:** Spec at `docs/superpowers/specs/2026-06-30-sony-plugin-design.md`. Wire protocol anchored on Gadgetbridge (`codeberg.org/Freeyourgadget/Gadgetbridge`, V1/V2 split + unit-test vectors), cross-checked against Plutoberth/SonyHeadphonesClient and ibatra (MIT). Byte vectors below are quoted from Gadgetbridge tests/source unless flagged DERIVED or NEEDS-HARDWARE.

## Global Constraints

- **No device available.** Verification is unit-test byte-parity only; live verification is a deferred phase. Never fabricate a wire vector as certainty — fixtures flagged NEEDS-HARDWARE in this plan are built from documented index rules and MUST carry a `// VERIFY ON HARDWARE` comment in the test so a future correction is a one-line change.
- **No-throw plugin contract.** `readState`/`readBatteryLevel`/`readMetadata`/`apply` never throw and never fabricate. Missing/garbled reply → `nil`/empty/`false`. Swallow `DeviceError` to `nil`/`[]` like `BosePlugin` does.
- **Decoder safety.** Every `decode*` validates markers/length/prefix *before* indexing; returns `nil`/empty on any mismatch; never crashes on a short or corrupt buffer.
- **Bose wire output unchanged.** No task may alter Bose bytes. The Bose byte-parity tests in `BoseCodecTests`/`BosePluginTests` must stay green.
- **Core stays Foundation-only.** No IOBluetooth/AppKit import in any `SoundSherpaCore` file.
- **Build:** `swift build -c release`.
- **Test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test` (CommandLineTools lacks XCTest). Filter with `--filter ClassName`.
- **`@unchecked Sendable` boxes** are safe only because one plugin value runs over one serializing `DeviceChannel` actor. Do not share a channel across plugins. Copy the `LanguageBox` safety-comment idiom verbatim in tone.
- **Commit after every task** (each task ends green).

## Wire-protocol reference (frozen for this plan)

**Framing** (`Message.java`): `0x3E` start, `0x3C` end, `0x3D` escape, mask `0xEF`.
Frame = `0x3E || escape( type || seq || len[4 BE] || payload || checksum ) || 0x3C`.
Checksum = `sum(type, seq, len[4], payload) & 0xFF`, computed before escaping.
Escape rule: for each byte `b` in {`0x3E`,`0x3C`,`0x3D`}, emit `0x3D` then `b & 0xEF`. Unescape: on `0x3D`, next byte `| 0x10`.

**Message types:** `ACK=0x01`, `COMMAND_1=0x0C` (used for nearly all commands), `COMMAND_2=0x0E`, `UNKNOWN=0xFF`.

**Init/negotiation:** request = type `0x0C`, payload `[0x00,0x00]`. Reply classified by payload length: **4 → V1**, **8 → V2**.

**File structure (decisions locked here):**
- `Sources/SoundSherpaCore/SonyFrame.swift` — framing only (markers/escape/checksum/seq/type). One responsibility.
- `Sources/SoundSherpaCore/SonyProtocol.swift` — `SonyProtocol` enum + `classify`.
- `Sources/SoundSherpaCore/SonyCodec.swift` — pure payload builders/parsers, version-parameterized.
- `Sources/SoundSherpaCore/SonyPlugin.swift` — `DevicePlugin` conformance + negotiated-version box.
- `Sources/SoundSherpaCore/DeviceRegistry.swift` — register Sony (modify).
- `Sources/SoundSherpaCore/DevicePlugin.swift` — add `deviceIdLabel` default + optional `decodeUnsolicited` hook (modify).
- `Sources/SoundSherpa/DeviceController.swift` — 128-bit UUID branch, formatter wiring, generalized broadcast hook (modify).
- `Sources/SoundSherpa/Views/ContentTile.swift` — gate multipoint, add Sony ANC/ambient/EQ controls (modify).
- `Sources/SoundSherpa/Views/AmbientSection.swift` — new Sony ANC/ambient control (create).
- Tests mirror each Core file under `Tests/SoundSherpaCoreTests/`.

---

### Task 1: `SonyFrame` — framing encode/decode

**Files:**
- Create: `Sources/SoundSherpaCore/SonyFrame.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyFrameTests.swift`

**Interfaces:**
- Produces: `enum SonyMessageType: UInt8 { case ack = 0x01, command1 = 0x0C, command2 = 0x0E }`; `struct SonyFrame { let type: SonyMessageType; let seq: UInt8; let payload: [UInt8] }`; `enum SonyFraming { static func encode(type:seq:payload:) -> [UInt8]; static func decode(_:) -> SonyFrame? }`.

- [ ] **Step 1: Write the failing test** (`SonyFrameTests.swift`)

```swift
import XCTest
@testable import SoundSherpaCore

final class SonyFrameTests: XCTestCase {

    // Verbatim asserted V2 vector (Gadgetbridge SonyProtocolImplV2Test.setEqualizerPreset, OFF):
    // 3e:0c:01:00:00:00:04:58:00:00:00:69:3c — checksum 0x69 = 0x0C+0x01+0x04+0x58.
    func testEncodeMatchesKnownV2Frame() {
        let frame = SonyFraming.encode(type: .command1, seq: 0x01,
                                       payload: [0x58, 0x00, 0x00, 0x00])
        XCTAssertEqual(frame, [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x04,
                               0x58, 0x00, 0x00, 0x00, 0x69, 0x3C])
    }

    func testRoundTripPreservesTypeSeqPayload() {
        let payload: [UInt8] = [0x68, 0x15, 0x01, 0x01, 0x00, 0x03, 0x01, 0x0F]
        let encoded = SonyFraming.encode(type: .command1, seq: 0x00, payload: payload)
        let decoded = SonyFraming.decode(encoded)
        XCTAssertEqual(decoded?.type, .command1)
        XCTAssertEqual(decoded?.seq, 0x00)
        XCTAssertEqual(decoded?.payload, payload)
    }

    // Escaping is DERIVED from the mask rule (no asserted escaping vector upstream):
    // payload byte 0x3E -> 0x3D,0x2E ; 0x3C -> 0x3D,0x2C ; 0x3D -> 0x3D,0x2D.
    func testEncodeEscapesSpecialPayloadBytes() {
        let encoded = SonyFraming.encode(type: .command1, seq: 0x00,
                                         payload: [0x3E, 0x3C, 0x3D])
        // Markers must appear only as the outer frame bounds.
        XCTAssertEqual(encoded.first, 0x3E)
        XCTAssertEqual(encoded.last, 0x3C)
        // The three special payload bytes appear escaped.
        let inner = Array(encoded.dropFirst().dropLast())
        XCTAssertTrue(inner.contains([0x3D, 0x2E]).isPresent)
        XCTAssertTrue(inner.contains([0x3D, 0x2C]).isPresent)
        XCTAssertTrue(inner.contains([0x3D, 0x2D]).isPresent)
        // And round-trips back to the original payload.
        XCTAssertEqual(SonyFraming.decode(encoded)?.payload, [0x3E, 0x3C, 0x3D])
    }

    func testDecodeRejectsBadChecksum() {
        var frame = SonyFraming.encode(type: .command1, seq: 0x01,
                                       payload: [0x58, 0x00, 0x00, 0x00])
        frame[11] = 0x00 // corrupt the checksum byte
        XCTAssertNil(SonyFraming.decode(frame))
    }

    func testDecodeRejectsTruncatedAndMissingMarkers() {
        XCTAssertNil(SonyFraming.decode([]))
        XCTAssertNil(SonyFraming.decode([0x3E, 0x0C]))                 // too short
        XCTAssertNil(SonyFraming.decode([0x00, 0x0C, 0x00, 0x3C]))     // no start marker
        let noEnd: [UInt8] = [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x04, 0x58, 0x00, 0x00, 0x00, 0x69]
        XCTAssertNil(SonyFraming.decode(noEnd))                        // no end marker
    }
}

// Small helper so the escaping test reads clearly.
private extension Array where Element == UInt8 {
    func contains(_ subsequence: [UInt8]) -> (isPresent: Bool, Void) {
        guard !subsequence.isEmpty, count >= subsequence.count else { return (false, ()) }
        for start in 0...(count - subsequence.count) where Array(self[start..<start+subsequence.count]) == subsequence {
            return (true, ())
        }
        return (false, ())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyFrameTests`
Expected: FAIL — `cannot find 'SonyFraming' in scope`.

- [ ] **Step 3: Write minimal implementation** (`SonyFrame.swift`)

```swift
import Foundation

/// Pure framing for the Sony WH-1000XM control protocol (the layer shared by every command,
/// identical across the V1/XM4 and V2/XM5 dialects). No IOBluetooth — bytes in, bytes out.
///
/// Frame: 0x3E start, then ESCAPED (type, seq, 4-byte big-endian length, payload, checksum),
/// then 0x3C end. Checksum = sum(type, seq, length, payload) & 0xFF, computed BEFORE escaping.
/// Escape: each of 0x3E/0x3C/0x3D becomes 0x3D followed by (byte & 0xEF); unescape ORs 0x10
/// back in. Constants verified against Gadgetbridge Message.java.
public enum SonyMessageType: UInt8, Sendable, Equatable {
    case ack = 0x01
    case command1 = 0x0C
    case command2 = 0x0E
}

public struct SonyFrame: Sendable, Equatable {
    public let type: SonyMessageType
    public let seq: UInt8
    public let payload: [UInt8]
    public init(type: SonyMessageType, seq: UInt8, payload: [UInt8]) {
        self.type = type
        self.seq = seq
        self.payload = payload
    }
}

public enum SonyFraming {
    private static let start: UInt8 = 0x3E
    private static let end: UInt8 = 0x3C
    private static let escape: UInt8 = 0x3D
    private static let escapeMask: UInt8 = 0xEF

    public static func encode(type: SonyMessageType, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, seq]
        body.append(UInt8((length >> 24) & 0xFF))
        body.append(UInt8((length >> 16) & 0xFF))
        body.append(UInt8((length >> 8) & 0xFF))
        body.append(UInt8(length & 0xFF))
        body.append(contentsOf: payload)
        let checksum = UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF)
        body.append(checksum)

        var out: [UInt8] = [start]
        for byte in body {
            if byte == start || byte == end || byte == escape {
                out.append(escape)
                out.append(byte & escapeMask)
            } else {
                out.append(byte)
            }
        }
        out.append(end)
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> SonyFrame? {
        guard bytes.count >= 9, bytes.first == start, bytes.last == end else { return nil }

        // Unescape the interior (between the markers).
        var body: [UInt8] = []
        var i = 1
        let lastIndex = bytes.count - 1
        while i < lastIndex {
            let byte = bytes[i]
            if byte == escape {
                guard i + 1 < lastIndex else { return nil }
                body.append(bytes[i + 1] | 0x10)
                i += 2
            } else {
                body.append(byte)
                i += 1
            }
        }

        // body = type, seq, len[4], payload..., checksum
        guard body.count >= 7 else { return nil }
        let stated = body.removeLast()
        let computed = UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF)
        guard stated == computed else { return nil }

        guard let type = SonyMessageType(rawValue: body[0]) else { return nil }
        let seq = body[1]
        let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        let payload = Array(body[6...])
        guard payload.count == length else { return nil }
        return SonyFrame(type: type, seq: seq, payload: payload)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyFrameTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyFrame.swift Tests/SoundSherpaCoreTests/SonyFrameTests.swift
git commit -m "feat(core): SonyFrame framing layer (markers/escape/checksum, V1/V2-shared)"
```

---

### Task 2: `SonyProtocol` — dialect enum + classification

**Files:**
- Create: `Sources/SoundSherpaCore/SonyProtocol.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyProtocolTests.swift`

**Interfaces:**
- Produces: `enum SonyProtocol: Sendable, Equatable { case v1, v2 }` with `static func classify(initReplyPayloadLength: Int) -> SonyProtocol?`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SoundSherpaCore

final class SonyProtocolTests: XCTestCase {
    func testClassifyByInitReplyLength() {
        // Gadgetbridge SonyHeadphonesProtocol: payload length 4 -> v1, 8 -> v2.
        XCTAssertEqual(SonyProtocol.classify(initReplyPayloadLength: 4), .v1)
        XCTAssertEqual(SonyProtocol.classify(initReplyPayloadLength: 8), .v2)
    }

    func testClassifyReturnsNilForUnknownLength() {
        XCTAssertNil(SonyProtocol.classify(initReplyPayloadLength: 0))
        XCTAssertNil(SonyProtocol.classify(initReplyPayloadLength: 6))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyProtocolTests`
Expected: FAIL — `cannot find 'SonyProtocol' in scope`.

- [ ] **Step 3: Write minimal implementation** (`SonyProtocol.swift`)

```swift
import Foundation

/// Which Sony control-protocol dialect a connected device speaks. WH-1000XM4 → v1,
/// WH-1000XM5 → v2. Negotiated at runtime, never assumed from the model name.
public enum SonyProtocol: Sendable, Equatable {
    case v1
    case v2

    /// Classify by the init-handshake reply's payload length (Gadgetbridge rule):
    /// length 4 → v1, length 8 → v2. Any other length is unknown (nil).
    public static func classify(initReplyPayloadLength length: Int) -> SonyProtocol? {
        switch length {
        case 4: return .v1
        case 8: return .v2
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyProtocolTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyProtocol.swift Tests/SoundSherpaCoreTests/SonyProtocolTests.swift
git commit -m "feat(core): SonyProtocol dialect enum + classify-by-init-reply-length"
```

---

### Task 3: `SonyCodec` — init + battery payloads

**Files:**
- Create: `Sources/SoundSherpaCore/SonyCodec.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyCodecTests.swift`

**Interfaces:**
- Consumes: `SonyProtocol` (Task 2).
- Produces (on `enum SonyCodec`): `static func encodeInitQuery() -> [UInt8]`; `static func encodeBatteryQuery(version:) -> [UInt8]`; `static func decodeBattery(_:version:) -> Int?`. These are *payload* builders (no framing — `SonyPlugin` frames them in Task 9 via the channel transport, which is responsible for framing/unframing — see Task 9 note).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SoundSherpaCore

final class SonyCodecTests: XCTestCase {

    // MARK: - Init (asserted: encodeInit payload 00 00)
    func testInitQueryPayload() {
        XCTAssertEqual(SonyCodec.encodeInitQuery(), [0x00, 0x00])
    }

    // MARK: - Battery requests (asserted, SonyProtocolImplV1Test/V2Test getBattery)
    func testBatteryQueryV1() {
        XCTAssertEqual(SonyCodec.encodeBatteryQuery(version: .v1), [0x10, 0x00])
    }

    func testBatteryQueryV2() {
        XCTAssertEqual(SonyCodec.encodeBatteryQuery(version: .v2), [0x22, 0x00])
    }

    // MARK: - Battery reply decode
    // NEEDS-HARDWARE: handleBattery is a // TODO stub upstream — no asserted reply vector.
    // Fixture built from the documented index rule (response type = request+1; level at idx 2).
    func testBatteryReplyDecodeV1() {
        // [0x11, state, level, ...] per handleBattery index rule. VERIFY ON HARDWARE.
        XCTAssertEqual(SonyCodec.decodeBattery([0x11, 0x00, 0x5A, 0x01], version: .v1), 90)
    }

    func testBatteryReplyDecodeV2() {
        // V2 response type = request(0x22)+1 = 0x23. VERIFY ON HARDWARE.
        XCTAssertEqual(SonyCodec.decodeBattery([0x23, 0x00, 0x5A, 0x01], version: .v2), 90)
    }

    func testBatteryDecodeRejectsShortOrWrongPrefix() {
        XCTAssertNil(SonyCodec.decodeBattery([], version: .v1))
        XCTAssertNil(SonyCodec.decodeBattery([0x99, 0x00], version: .v1))
        XCTAssertNil(SonyCodec.decodeBattery([0x11], version: .v1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: FAIL — `cannot find 'SonyCodec' in scope`.

- [ ] **Step 3: Write minimal implementation** (`SonyCodec.swift`)

```swift
import Foundation

/// Pure payload builders/parsers for the Sony WH-1000XM control protocol. These produce/parse
/// the PAYLOAD only; SonyFraming wraps them on the wire. Every builder takes the negotiated
/// `SonyProtocol` because the V1 (XM4) and V2 (XM5) dialects share commands but differ in
/// payload layout. Decoders validate before indexing and return nil on any mismatch.
///
/// Byte values anchored on Gadgetbridge (V1/V2 impl + tests), cross-checked vs Plutoberth.
/// Reply decoders flagged VERIFY ON HARDWARE are built from documented index rules where the
/// upstream test asserts no literal reply vector.
public enum SonyCodec {

    // MARK: - Init / negotiation
    /// Init/protocol-info request payload (type COMMAND_1 on the wire). Reply length → version.
    public static func encodeInitQuery() -> [UInt8] { [0x00, 0x00] }

    // MARK: - Battery
    public static func encodeBatteryQuery(version: SonyProtocol) -> [UInt8] {
        switch version {
        case .v1: return [0x10, 0x00]
        case .v2: return [0x22, 0x00]
        }
    }

    /// Battery percentage (0–100). VERIFY ON HARDWARE: response type byte and level index are
    /// from the documented rule (level at index 2), not an asserted upstream vector.
    public static func decodeBattery(_ payload: [UInt8], version: SonyProtocol) -> Int? {
        let expectedType: UInt8 = (version == .v1) ? 0x11 : 0x23
        guard payload.count >= 3, payload[0] == expectedType else { return nil }
        return Int(payload[2])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyCodec.swift Tests/SoundSherpaCoreTests/SonyCodecTests.swift
git commit -m "feat(core): SonyCodec init + battery payloads (V1/V2)"
```

---

### Task 4: `SonyCodec` — ANC/ambient (command 0x68)

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyCodec.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyCodecTests.swift` (add a new section)

**Interfaces:**
- Consumes: `ANCState` (Core, existing: `mode ∈ {.off,.noiseCancelling,.ambient}`, `ambientLevel: Int?` 0–20, `focusOnVoice: Bool?`), `SonyProtocol`.
- Produces: `static func encodeANC(_ state: ANCState, version:) -> [UInt8]`; `static func encodeAmbientStatusQuery(version:) -> [UInt8]`; `static func decodeANC(_:version:) -> ANCState?`.

- [ ] **Step 1: Write the failing test** (append to `SonyCodecTests.swift`)

```swift
extension SonyCodecTests {

    // MARK: - ANC/ambient V1 (asserted, SonyProtocolImplV1Test.setAmbientSoundControl)
    // V1 layout: [0x68,0x02,<mode 0x00 off/0x11 on>,0x00,<nc>,0x01,<focus>,<level>]
    func testEncodeANCV1Off() {
        let s = ANCState(mode: .off)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    func testEncodeANCV1AmbientLevel10() {
        let s = ANCState(mode: .ambient, ambientLevel: 10, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x00, 0x01, 0x00, 0x0A])
    }

    func testEncodeANCV1AmbientFocusOnVoiceLevel15() {
        let s = ANCState(mode: .ambient, ambientLevel: 15, focusOnVoice: true)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x00, 0x01, 0x01, 0x0F])
    }

    func testEncodeANCV1NoiseCancelling() {
        let s = ANCState(mode: .noiseCancelling)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v1),
                       [0x68, 0x02, 0x11, 0x00, 0x01, 0x01, 0x00, 0x00])
    }

    // MARK: - ANC/ambient V2 (asserted bare payloads, SonyProtocolImplV2Test)
    // V2 layout: [0x68,0x17,0x01,<off 0x00/on 0x01>,<ambientFlag>,<focus>,<level>]
    func testEncodeANCV2AmbientLevel20() {
        let s = ANCState(mode: .ambient, ambientLevel: 20, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x14])
    }

    func testEncodeANCV2AmbientFocusOnVoice() {
        let s = ANCState(mode: .ambient, ambientLevel: 20, focusOnVoice: true)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14])
    }

    func testEncodeANCV2NoiseCancellingLevel20() {
        let s = ANCState(mode: .noiseCancelling, ambientLevel: 20)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14])
    }

    func testEncodeANCV2Off() {
        let s = ANCState(mode: .off, ambientLevel: 20)
        XCTAssertEqual(SonyCodec.encodeANC(s, version: .v2),
                       [0x68, 0x17, 0x01, 0x00, 0x00, 0x00, 0x14])
    }

    // Ambient level must be clamped to 0–20 regardless of input.
    func testEncodeANCClampsAmbientLevel() {
        let hi = ANCState(mode: .ambient, ambientLevel: 99, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(hi, version: .v2).last, 0x14)  // 20
        let lo = ANCState(mode: .ambient, ambientLevel: -5, focusOnVoice: false)
        XCTAssertEqual(SonyCodec.encodeANC(lo, version: .v2).last, 0x00)
    }

    // MARK: - Ambient status query (asserted: 0x66 0x02 both dialects)
    func testAmbientStatusQuery() {
        XCTAssertEqual(SonyCodec.encodeAmbientStatusQuery(version: .v1), [0x66, 0x02])
        XCTAssertEqual(SonyCodec.encodeAmbientStatusQuery(version: .v2), [0x66, 0x02])
    }

    // MARK: - ANC reply decode
    // NEEDS-HARDWARE: ambient reply is a // TODO stub upstream. Fixture mirrors the V2 set
    // layout under response type 0x67 (request 0x66 + 1). VERIFY ON HARDWARE.
    func testDecodeANCV2Ambient() {
        let decoded = SonyCodec.decodeANC([0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0F], version: .v2)
        XCTAssertEqual(decoded?.mode, .ambient)
        XCTAssertEqual(decoded?.ambientLevel, 15)
        XCTAssertEqual(decoded?.focusOnVoice, false)
    }

    func testDecodeANCRejectsGarbage() {
        XCTAssertNil(SonyCodec.decodeANC([0x00], version: .v2))
        XCTAssertNil(SonyCodec.decodeANC([], version: .v1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: FAIL — `type 'SonyCodec' has no member 'encodeANC'`.

- [ ] **Step 3: Write minimal implementation** (append to `SonyCodec.swift`, inside the enum)

```swift
    // MARK: - ANC / ambient (command 0x68)

    private static func clampLevel(_ level: Int?) -> UInt8 {
        UInt8(min(20, max(0, level ?? 0)))
    }

    /// Encode a sound-control change. V1 (XM4) and V2 (XM5) use different payload layouts for
    /// the same 0x68 command — see the per-dialect builders. The "no wind-noise capability"
    /// V1 form is used (byte[3]=0x00); wind-noise reduction is out of scope for v1.
    public static func encodeANC(_ state: ANCState, version: SonyProtocol) -> [UInt8] {
        let level = clampLevel(state.ambientLevel)
        let focus: UInt8 = (state.focusOnVoice == true) ? 0x01 : 0x00
        switch version {
        case .v1:
            // [0x68,0x02,<modeOn>,0x00,<nc>,0x01,<focus>,<level>]
            let modeOn: UInt8 = (state.mode == .off) ? 0x00 : 0x11
            let nc: UInt8 = (state.mode == .noiseCancelling) ? 0x01 : 0x00
            return [0x68, 0x02, modeOn, 0x00, nc, 0x01, focus, level]
        case .v2:
            // [0x68,0x17,0x01,<off 0x00/on 0x01>,<ambientFlag>,<focus>,<level>]
            let on: UInt8 = (state.mode == .off) ? 0x00 : 0x01
            let ambientFlag: UInt8 = (state.mode == .ambient) ? 0x01 : 0x00
            return [0x68, 0x17, 0x01, on, ambientFlag, focus, level]
        }
    }

    public static func encodeAmbientStatusQuery(version: SonyProtocol) -> [UInt8] {
        [0x66, 0x02]
    }

    /// Decode an ambient/ANC status reply. VERIFY ON HARDWARE: built from the V2 set layout
    /// under response type 0x67; the upstream reply decoder is a stub.
    public static func decodeANC(_ payload: [UInt8], version: SonyProtocol) -> ANCState? {
        switch version {
        case .v2:
            guard payload.count >= 7, payload[0] == 0x67, payload[1] == 0x17 else { return nil }
            let on = payload[3] != 0x00
            let ambient = payload[4] != 0x00
            let mode: ANCState.Mode = !on ? .off : (ambient ? .ambient : .noiseCancelling)
            return ANCState(mode: mode,
                            ambientLevel: Int(payload[6]),
                            focusOnVoice: payload[5] != 0x00)
        case .v1:
            guard payload.count >= 8, payload[0] == 0x67, payload[1] == 0x02 else { return nil }
            let on = payload[2] != 0x00
            let nc = payload[4] != 0x00
            let mode: ANCState.Mode = !on ? .off : (nc ? .noiseCancelling : .ambient)
            return ANCState(mode: mode,
                            ambientLevel: Int(payload[7]),
                            focusOnVoice: payload[6] != 0x00)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: PASS (all SonyCodec tests, including the new ANC section).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyCodec.swift Tests/SoundSherpaCoreTests/SonyCodecTests.swift
git commit -m "feat(core): SonyCodec ANC/ambient encode + decode (0x68, V1/V2 layouts)"
```

---

### Task 5: `SonyCodec` — EQ (command 0x58)

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyCodec.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyCodecTests.swift` (add a section)

**Interfaces:**
- Consumes: `EqualizerState` (Core, existing: `presetId: Int?`, `bands: [Int]` gains in dB), `SonyProtocol`.
- Produces: `static func encodeEQ(_ state: EqualizerState, version:) -> [UInt8]`; `static func encodeEQStatusQuery(version:) -> [UInt8]`; `static func decodeEQ(_:version:) -> EqualizerState?`. EQ preset IDs are reused from `EqualizerState.presetId` (raw Sony IDs: OFF=0x00 … BASS_BOOST=0x16, CUSTOM_1=0xA1). `nil`/0xA1 presetId with non-empty `bands` → custom-bands payload.

- [ ] **Step 1: Write the failing test** (append)

```swift
extension SonyCodecTests {

    // MARK: - EQ preset (asserted, setEqualizerPreset; V1 byte1=0x01, V2 byte1=0x00)
    func testEncodeEQPresetV1Off() {
        let s = EqualizerState(presetId: 0x00, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1), [0x58, 0x01, 0x00, 0x00])
    }

    func testEncodeEQPresetV1BassBoost() {
        let s = EqualizerState(presetId: 0x16, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1), [0x58, 0x01, 0x16, 0x00])
    }

    func testEncodeEQPresetV2Off() {
        let s = EqualizerState(presetId: 0x00, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2), [0x58, 0x00, 0x00, 0x00])
    }

    func testEncodeEQPresetV2Bright() {
        let s = EqualizerState(presetId: 0x10, bands: [])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2), [0x58, 0x00, 0x10, 0x00])
    }

    // MARK: - EQ custom bands (asserted; 6 bands, gain+10; V1 marker 0xFF, V2 marker 0xA0)
    func testEncodeEQCustomBandsV1Flat() {
        let s = EqualizerState(presetId: 0xA1, bands: [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v1),
                       [0x58, 0x01, 0xFF, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A])
    }

    func testEncodeEQCustomBandsV2Mixed() {
        // gains [0,0,1,2,3,1] -> +10 -> [0x0A,0x0A,0x0B,0x0C,0x0D,0x0B]
        let s = EqualizerState(presetId: 0xA1, bands: [0, 0, 1, 2, 3, 1])
        XCTAssertEqual(SonyCodec.encodeEQ(s, version: .v2),
                       [0x58, 0x00, 0xA0, 0x06, 0x0A, 0x0A, 0x0B, 0x0C, 0x0D, 0x0B])
    }

    // MARK: - EQ status query (asserted: V1 0x56 0x01; V2 0x56 0x00)
    func testEncodeEQStatusQuery() {
        XCTAssertEqual(SonyCodec.encodeEQStatusQuery(version: .v1), [0x56, 0x01])
        XCTAssertEqual(SonyCodec.encodeEQStatusQuery(version: .v2), [0x56, 0x00])
    }

    // MARK: - EQ status reply decode (asserted V2 full-frame payloads, handleEqualizer)
    // OFF reply payload: 59 00 00 06 0a 0a 0a 0a 0a 0a ; MANUAL: 59 00 a0 06 0a 0a 0a 0a 0a 0a
    func testDecodeEQV2OffPreset() {
        let payload: [UInt8] = [0x59, 0x00, 0x00, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A]
        let s = SonyCodec.decodeEQ(payload, version: .v2)
        XCTAssertEqual(s?.presetId, 0x00)
        XCTAssertEqual(s?.bands, [0, 0, 0, 0, 0, 0])
    }

    func testDecodeEQRejectsGarbage() {
        XCTAssertNil(SonyCodec.decodeEQ([0x00], version: .v2))
        XCTAssertNil(SonyCodec.decodeEQ([], version: .v1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: FAIL — `type 'SonyCodec' has no member 'encodeEQ'`.

- [ ] **Step 3: Write minimal implementation** (append to `SonyCodec.swift`, inside the enum)

```swift
    // MARK: - Equalizer (command 0x58)

    private static let customPresetId = 0xA1  // CUSTOM_1

    /// Encode an EQ change. Preset IDs are the raw Sony values stored on `EqualizerState`.
    /// A custom preset (presetId 0xA1 with bands) emits the 6-band payload; gains are encoded
    /// as value+10. V1 vs V2 differ in the byte after the 0x58 command (V1=0x01, V2=0x00) and
    /// the custom-bands marker (V1=0xFF, V2=0xA0).
    public static func encodeEQ(_ state: EqualizerState, version: SonyProtocol) -> [UInt8] {
        let dialectByte: UInt8 = (version == .v1) ? 0x01 : 0x00
        let isCustom = (state.presetId == customPresetId) && !state.bands.isEmpty
        if isCustom {
            let marker: UInt8 = (version == .v1) ? 0xFF : 0xA0
            var out: [UInt8] = [0x58, dialectByte, marker, UInt8(state.bands.count)]
            out.append(contentsOf: state.bands.map { UInt8(min(255, max(0, $0 + 10))) })
            return out
        }
        let preset = UInt8(state.presetId ?? 0x00)
        return [0x58, dialectByte, preset, 0x00]
    }

    public static func encodeEQStatusQuery(version: SonyProtocol) -> [UInt8] {
        switch version {
        case .v1: return [0x56, 0x01]
        case .v2: return [0x56, 0x00]
        }
    }

    /// Decode an EQ status reply `[0x59, <dialect>, <presetId>, <count>, <bands…>]`.
    /// Bands are decoded from value+10 back to signed dB. Asserted against V2 vectors.
    public static func decodeEQ(_ payload: [UInt8], version: SonyProtocol) -> EqualizerState? {
        guard payload.count >= 4, payload[0] == 0x59 else { return nil }
        let presetId = Int(payload[2])
        let count = Int(payload[3])
        guard payload.count >= 4 + count else {
            return EqualizerState(presetId: presetId, bands: [])
        }
        let bands = payload[4..<(4 + count)].map { Int($0) - 10 }
        return EqualizerState(presetId: presetId, bands: Array(bands))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyCodec.swift Tests/SoundSherpaCoreTests/SonyCodecTests.swift
git commit -m "feat(core): SonyCodec EQ encode + decode (0x58, presets + custom bands)"
```

---

### Task 6: `SonyCodec` — metadata (firmware/serial/model)

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyCodec.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyCodecTests.swift` (add a section)

**Interfaces:**
- Consumes: `SonyProtocol`.
- Produces: `static func encodeFirmwareQuery(version:) -> [UInt8]`; `static func decodeFirmware(_:version:) -> String?`. (Serial/model deferred: no asserted vectors; see note.)

- [ ] **Step 1: Write the failing test** (append)

```swift
extension SonyCodecTests {

    // MARK: - Firmware (asserted request V1 0x04 0x02; reply NEEDS-HARDWARE)
    func testFirmwareQueryV1() {
        XCTAssertEqual(SonyCodec.encodeFirmwareQuery(version: .v1), [0x04, 0x02])
    }

    func testFirmwareQueryV2() {
        // V2 firmware request not asserted upstream; we send the V1 code as a best effort.
        // VERIFY ON HARDWARE.
        XCTAssertEqual(SonyCodec.encodeFirmwareQuery(version: .v2), [0x04, 0x02])
    }

    // NEEDS-HARDWARE: handleFirmwareVersion is a stub upstream. Fixture assumes response type
    // 0x05 (request+1) carrying ASCII. VERIFY ON HARDWARE.
    func testDecodeFirmwareFromAsciiReply() {
        // "1.0.4" = 0x31 0x2E 0x30 0x2E 0x34
        let payload: [UInt8] = [0x05, 0x00, 0x31, 0x2E, 0x30, 0x2E, 0x34]
        XCTAssertEqual(SonyCodec.decodeFirmware(payload, version: .v1), "1.0.4")
    }

    func testDecodeFirmwareRejectsWrongPrefix() {
        XCTAssertNil(SonyCodec.decodeFirmware([0x99, 0x00], version: .v1))
        XCTAssertNil(SonyCodec.decodeFirmware([], version: .v1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: FAIL — `type 'SonyCodec' has no member 'encodeFirmwareQuery'`.

- [ ] **Step 3: Write minimal implementation** (append to `SonyCodec.swift`, inside the enum)

```swift
    // MARK: - Metadata (firmware)
    //
    // NEEDS-HARDWARE: only the V1 firmware REQUEST (0x04 0x02) is asserted upstream; the reply
    // decoder and serial/model queries are stubs. We decode an ASCII firmware string from a
    // response prefixed 0x05; serial/model are deferred until a device confirms their frames.

    public static func encodeFirmwareQuery(version: SonyProtocol) -> [UInt8] { [0x04, 0x02] }

    public static func decodeFirmware(_ payload: [UInt8], version: SonyProtocol) -> String? {
        guard payload.count >= 3, payload[0] == 0x05 else { return nil }
        let ascii = Array(payload[2...])
        return String(bytes: ascii, encoding: .utf8)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyCodecTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyCodec.swift Tests/SoundSherpaCoreTests/SonyCodecTests.swift
git commit -m "feat(core): SonyCodec firmware query + ASCII decode (serial/model deferred)"
```

---

### Task 7: `DevicePlugin` — `deviceIdLabel` default + `decodeUnsolicited` hook

This task generalizes two brand-specific pieces in the controller into plugin-provided behavior, so Sony isn't mislabeled "Bose" and Sony's unsolicited broadcasts can reflect live. Done before `SonyPlugin` so the plugin can adopt them.

**Files:**
- Modify: `Sources/SoundSherpaCore/DevicePlugin.swift`
- Modify: `Sources/SoundSherpaCore/BosePlugin.swift` (adopt the formatter to preserve "Bose 0x%04X")
- Test: `Tests/SoundSherpaCoreTests/BosePluginTests.swift` (add)

**Interfaces:**
- Produces: on `DevicePlugin` — `func deviceIdLabel(modelId: Int) -> String` (default extension `"\(identifier) 0x...."`); `func decodeUnsolicited(_ bytes: [UInt8]) -> DeviceChange?` (default returns nil). Consumed by the controller in Tasks 13/16.

- [ ] **Step 1: Write the failing test** (append to `BosePluginTests.swift`)

```swift
extension BosePluginTests {
    func testDeviceIdLabelFormatsWithBrand() {
        XCTAssertEqual(BosePlugin().deviceIdLabel(modelId: 0x4014), "Bose 0x4014")
    }

    func testDecodeUnsolicitedNCBroadcast() {
        // Bose NC broadcast [0x01,0x06,0x03,0x01,<level>] -> a noiseCancellation change.
        let change = BosePlugin().decodeUnsolicited([0x01, 0x06, 0x03, 0x01, 0x01])
        guard case .noiseCancellation(let level)? = change else {
            return XCTFail("expected a noiseCancellation change")
        }
        XCTAssertEqual(level, .high)
    }

    func testDecodeUnsolicitedIgnoresUnrelated() {
        XCTAssertNil(BosePlugin().decodeUnsolicited([0x02, 0x02, 0x03, 0x01, 0x5A]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: FAIL — `value of type 'BosePlugin' has no member 'deviceIdLabel'`.

- [ ] **Step 3: Write minimal implementation**

In `DevicePlugin.swift`, add to the protocol body:

```swift
    /// Human-readable device-id label for a brand-specific model code, shown in the Info row.
    /// Default formats as "<identifier> 0xNNNN"; a brand may override for a nicer label.
    func deviceIdLabel(modelId: Int) -> String

    /// Decode an unsolicited broadcast frame (e.g. ANC changed via an on-device button) into a
    /// `DeviceChange` the controller can reflect in the UI, or nil if the bytes aren't one.
    func decodeUnsolicited(_ bytes: [UInt8]) -> DeviceChange?
```

Add a default-implementation extension at the bottom of `DevicePlugin.swift`:

```swift
public extension DevicePlugin {
    func deviceIdLabel(modelId: Int) -> String {
        String(format: "\(identifier) 0x%04X", modelId)
    }

    func decodeUnsolicited(_ bytes: [UInt8]) -> DeviceChange? { nil }
}
```

In `BosePlugin.swift`, add the unsolicited decoder (move the controller's Bose-specific NC logic here):

```swift
    public func decodeUnsolicited(_ bytes: [UInt8]) -> DeviceChange? {
        // Unsolicited NC status: [0x01, 0x06, <0x03|0x04>, …, <level at index 4>].
        guard bytes.count >= 5, bytes[0] == 0x01, bytes[1] == 0x06 else { return nil }
        return .noiseCancellation(NoiseCancellationLevel(byte: bytes[4]))
    }
```

(`BosePlugin` uses the default `deviceIdLabel`, which yields "Bose 0x%04X" because its identifier is "Bose" — preserving the existing label.)

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/DevicePlugin.swift Sources/SoundSherpaCore/BosePlugin.swift Tests/SoundSherpaCoreTests/BosePluginTests.swift
git commit -m "feat(core): DevicePlugin deviceIdLabel + decodeUnsolicited hooks; Bose adopts them"
```

---

### Task 8: `SonyPlugin` — identity, discovery descriptor, capabilities

**Files:**
- Create: `Sources/SoundSherpaCore/SonyPlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyPluginTests.swift`

**Interfaces:**
- Consumes: `DevicePlugin`, `DiscoveryDescriptor`, `ServiceMatcher`, `DeviceFeature`.
- Produces: `struct SonyPlugin: DevicePlugin` with `identifier == "Sony"`; `handles` matches Sony WH-1000XM names; `discoveryDescriptor` lists both vendor UUIDs (V2 first), no channel hints; `supportedFeatures == [.noiseCancellation, .ambientLevel, .focusOnVoice, .equalizer]`. (readState/apply/readMetadata stubbed minimal here; filled in Tasks 9–11.)

- [ ] **Step 1: Write the failing test** (`SonyPluginTests.swift`)

```swift
import XCTest
@testable import SoundSherpaCore

final class SonyPluginTests: XCTestCase {

    func testIdentifier() {
        XCTAssertEqual(SonyPlugin().identifier, "Sony")
    }

    func testHandlesSonyNamedDevices() {
        let p = SonyPlugin()
        XCTAssertTrue(p.handles(deviceNamed: "WH-1000XM5"))
        XCTAssertTrue(p.handles(deviceNamed: "Sony WH-1000XM4"))
        XCTAssertTrue(p.handles(deviceNamed: "wh-1000xm3"))
        XCTAssertFalse(p.handles(deviceNamed: "Bose QC35 II"))
        XCTAssertFalse(p.handles(deviceNamed: ""))
    }

    func testDiscoveryDescriptorListsBothVendorUUIDsV2First() {
        let d = SonyPlugin().discoveryDescriptor
        XCTAssertEqual(d.serviceMatchers, [
            .uuid("956C7B26-D49A-4BA8-B03F-B17D393CB6E2"),  // V2 / XM5
            .uuid("96CC203E-5068-46AD-B32D-E316F5E069BA"),  // V1 / XM4
        ])
        XCTAssertEqual(d.channelHints, [])  // channel resolved from SDP, never hardcoded
    }

    func testSupportedFeatures() {
        let f = SonyPlugin().supportedFeatures
        XCTAssertEqual(f, [.noiseCancellation, .ambientLevel, .focusOnVoice, .equalizer])
        XCTAssertFalse(f.contains(.multipoint))   // deferred (no documented protocol)
        XCTAssertFalse(f.contains(.selfVoice))     // Bose-only
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: FAIL — `cannot find 'SonyPlugin' in scope`.

- [ ] **Step 3: Write minimal implementation** (`SonyPlugin.swift`)

```swift
import Foundation

/// The Sony implementation of `DevicePlugin` for WH-1000XM4 (protocol V1) and WH-1000XM5
/// (protocol V2). Like `BosePlugin` it owns no I/O machinery: it pairs the pure `SonyCodec`
/// (payload bytes) and `SonyFraming` (wire frame) with whatever `DeviceChannel` it's handed.
///
/// The V1/V2 dialect is negotiated once on connect and cached in `versionBox`; every codec
/// call is threaded with it. Multipoint is intentionally NOT in `supportedFeatures` (no
/// documented protocol — deferred to a device-required sub-project).
public struct SonyPlugin: DevicePlugin {
    public let identifier = "Sony"

    // Negotiated dialect + the toggling sequence byte, for the lifetime of one channel. Boxed
    // because SonyPlugin is a Sendable value type. SAFETY (@unchecked Sendable): the box has no
    // internal locking; it is safe ONLY because one SonyPlugin value is driven over one
    // serializing `DeviceChannel` actor, so reads/writes never overlap. The version is CHANNEL
    // state — it MUST be reset when a new channel is attached (a reconnect could be a different
    // dialect). Do not share a channel across plugin instances.
    private let versionBox = SonyVersionBox()

    public init() {}

    public func handles(deviceNamed name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("wh-1000") || n.contains("sony")
    }

    public var discoveryDescriptor: DiscoveryDescriptor {
        DiscoveryDescriptor(
            serviceMatchers: [
                .uuid("956C7B26-D49A-4BA8-B03F-B17D393CB6E2"),  // V2 / XM5
                .uuid("96CC203E-5068-46AD-B32D-E316F5E069BA"),  // V1 / XM4
            ],
            channelHints: [])
    }

    public var supportedFeatures: Set<DeviceFeature> {
        [.noiseCancellation, .ambientLevel, .focusOnVoice, .equalizer]
    }

    // Filled in Tasks 9–11.
    public func readBatteryLevel(over channel: DeviceChannel) async -> Int? { nil }
    public func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata { DeviceMetadata() }
    public func readState(over channel: DeviceChannel) async -> DeviceState { DeviceState() }
    public func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool { false }
}

/// Reference box for the negotiated dialect + sequence byte. See the SAFETY note on
/// `SonyPlugin.versionBox` — single-channel serialization is what makes @unchecked safe.
final class SonyVersionBox: @unchecked Sendable {
    var version: SonyProtocol?
    var seq: UInt8 = 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyPlugin.swift Tests/SoundSherpaCoreTests/SonyPluginTests.swift
git commit -m "feat(core): SonyPlugin identity, dual-UUID discovery, capabilities"
```

---

### Task 9: `SonyPlugin` — framed send helper, version negotiation, battery + metadata reads

This task adds the on-channel send path. Because `SonyCodec` produces *payloads* but the channel moves *frames*, `SonyPlugin` wraps payloads with `SonyFraming.encode` before sending and unframes replies with `SonyFraming.decode`. The `DeviceChannel`'s `ResponseMatcher` matches on the framed bytes' leading marker.

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyPlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyPluginTests.swift` (add)

**Interfaces:**
- Consumes: `DeviceChannel.send(_:matcher:timeout:)`, `ResponseMatcher.prefix([0x3E])` (frames always start with 0x3E), `SonyFraming`, `SonyCodec`.
- Produces: private `func negotiateVersion(over:) async -> SonyProtocol?` (caches into `versionBox`, returns it); real `readBatteryLevel`, `readMetadata`.

- [ ] **Step 1: Write the failing test** (append)

```swift
extension SonyPluginTests {

    // Helper: build a full reply frame from a payload the test wants the "device" to send.
    private func frame(_ payload: [UInt8], seq: UInt8 = 0) -> [UInt8] {
        SonyFraming.encode(type: .command1, seq: seq, payload: payload)
    }

    func testReadBatteryNegotiatesV2ThenDecodes() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = SonyPlugin()

        async let level = plugin.readBatteryLevel(over: channel)
        // 1) init query -> V2 reply (payload length 8)
        try await transport.awaitWrite(count: 1)
        await channel.ingest(frame([0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // 2) battery query -> reply payload [0x23,0x00,0x5A,...] = 90% (VERIFY ON HARDWARE)
        try await transport.awaitWrite(count: 2)
        await channel.ingest(frame([0x23, 0x00, 0x5A, 0x01]))

        let result = await level
        XCTAssertEqual(result, 90)

        // First write must be the framed init query (payload 00 00).
        let writes = await transport.writes
        XCTAssertEqual(writes.first, SonyFraming.encode(type: .command1, seq: 0, payload: [0x00, 0x00]))
        // Second write must be the V2 battery query payload, framed.
        XCTAssertEqual(writes[1], SonyFraming.encode(type: .command1, seq: writes[1][2], payload: [0x22, 0x00]))
    }

    func testReadBatteryReturnsNilWhenNegotiationFails() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        // No init reply ingested -> negotiation times out -> nil, never a throw/crash.
        let result = await SonyPlugin().readBatteryLevel(over: channel)
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: FAIL — battery returns nil (stub), assertion `XCTAssertEqual(result, 90)` fails.

- [ ] **Step 3: Write minimal implementation** (replace the stubs in `SonyPlugin.swift`)

```swift
    // MARK: - Framed send

    /// Frame `payload`, send it, and return the DECODED reply frame's payload (or [] on
    /// timeout/closed). All Sony frames start with 0x3E, so we match on that prefix. Swallows
    /// DeviceError to [] per the no-throw plugin contract.
    private func sendFramed(_ payload: [UInt8],
                            over channel: DeviceChannel,
                            timeout: TimeInterval = 0.5) async -> [UInt8] {
        let seq = versionBox.seq
        let frame = SonyFraming.encode(type: .command1, seq: seq, payload: payload)
        let reply = (try? await channel.send(frame, matcher: .prefix([0x3E]), timeout: timeout)) ?? []
        guard let decoded = SonyFraming.decode(reply) else { return [] }
        return decoded.payload
    }

    /// Negotiate (and cache) the dialect once per channel. Returns nil if the device never
    /// answers the init query, leaving the plugin in the "connected but unreadable" state.
    private func negotiateVersion(over channel: DeviceChannel) async -> SonyProtocol? {
        if let cached = versionBox.version { return cached }
        let reply = await sendFramed(SonyCodec.encodeInitQuery(), over: channel, timeout: 2.0)
        guard let version = SonyProtocol.classify(initReplyPayloadLength: reply.count) else {
            return nil
        }
        versionBox.version = version
        return version
    }

    public func readBatteryLevel(over channel: DeviceChannel) async -> Int? {
        guard let version = await negotiateVersion(over: channel) else { return nil }
        let reply = await sendFramed(SonyCodec.encodeBatteryQuery(version: version), over: channel)
        return SonyCodec.decodeBattery(reply, version: version)
    }

    public func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata {
        var metadata = DeviceMetadata()
        guard let version = await negotiateVersion(over: channel) else { return metadata }
        let fwReply = await sendFramed(SonyCodec.encodeFirmwareQuery(version: version), over: channel)
        if let fw = SonyCodec.decodeFirmware(fwReply, version: version) {
            metadata.firmware = fw
        }
        return metadata
    }
```

> **Note for the implementer:** if `ResponseMatcher.prefix` matching against `[0x3E]` proves too eager (a reply that legitimately starts mid-stream), this is the one spot to revisit — but the existing matcher resolves on the first chunk whose full prefix matches, and Sony frames always begin with `0x3E`, so a single-byte prefix is correct for the request/response dance. Do not change `ResponseMatcher`.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyPlugin.swift Tests/SoundSherpaCoreTests/SonyPluginTests.swift
git commit -m "feat(core): SonyPlugin framed send, version negotiation, battery + firmware reads"
```

---

### Task 10: `SonyPlugin` — `readState`

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyPlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyPluginTests.swift` (add)

**Interfaces:**
- Consumes: `SonyCodec.encodeAmbientStatusQuery/decodeANC`, `encodeEQStatusQuery/decodeEQ`, battery.
- Produces: real `readState(over:) -> DeviceState` filling `battery`, `anc`, `equalizer`.

- [ ] **Step 1: Write the failing test** (append)

```swift
extension SonyPluginTests {
    func testReadStateAssemblesBatteryANCAndEQ() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = SonyPlugin()

        async let state = plugin.readState(over: channel)
        // 1) negotiate -> V2
        try await transport.awaitWrite(count: 1)
        await channel.ingest(frameV2([0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // 2) battery -> 90 (VERIFY ON HARDWARE reply layout)
        try await transport.awaitWrite(count: 2)
        await channel.ingest(frameV2([0x23, 0x00, 0x5A, 0x01]))
        // 3) ambient status -> ambient, level 15, focus off (VERIFY ON HARDWARE reply layout)
        try await transport.awaitWrite(count: 3)
        await channel.ingest(frameV2([0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0F]))
        // 4) EQ status -> OFF preset, flat bands (asserted vector)
        try await transport.awaitWrite(count: 4)
        await channel.ingest(frameV2([0x59, 0x00, 0x00, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A]))

        let s = await state
        XCTAssertEqual(s.battery, 90)
        XCTAssertEqual(s.anc?.mode, .ambient)
        XCTAssertEqual(s.anc?.ambientLevel, 15)
        XCTAssertEqual(s.anc?.focusOnVoice, false)
        XCTAssertEqual(s.equalizer?.presetId, 0x00)
        // Bose-only fields stay nil.
        XCTAssertNil(s.selfVoice)
        XCTAssertNil(s.noiseCancellationLevel)
    }

    func testReadStateEmptyWhenNegotiationFails() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let s = await SonyPlugin().readState(over: channel)
        XCTAssertNil(s.battery)
        XCTAssertNil(s.anc)
        XCTAssertNil(s.equalizer)
    }

    private func frameV2(_ payload: [UInt8]) -> [UInt8] {
        SonyFraming.encode(type: .command1, seq: 0, payload: payload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: FAIL — `readState` returns empty state (stub).

- [ ] **Step 3: Write minimal implementation** (replace `readState` in `SonyPlugin.swift`)

```swift
    public func readState(over channel: DeviceChannel) async -> DeviceState {
        var state = DeviceState()
        guard let version = await negotiateVersion(over: channel) else { return state }

        let batteryReply = await sendFramed(SonyCodec.encodeBatteryQuery(version: version), over: channel)
        state.battery = SonyCodec.decodeBattery(batteryReply, version: version)

        let ancReply = await sendFramed(SonyCodec.encodeAmbientStatusQuery(version: version), over: channel)
        state.anc = SonyCodec.decodeANC(ancReply, version: version)

        let eqReply = await sendFramed(SonyCodec.encodeEQStatusQuery(version: version), over: channel)
        state.equalizer = SonyCodec.decodeEQ(eqReply, version: version)

        return state
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyPlugin.swift Tests/SoundSherpaCoreTests/SonyPluginTests.swift
git commit -m "feat(core): SonyPlugin readState (battery + ANC/ambient + EQ)"
```

---

### Task 11: `SonyPlugin` — `apply` (ANC/EQ ACK-gated; others false)

**Files:**
- Modify: `Sources/SoundSherpaCore/SonyPlugin.swift`
- Test: `Tests/SoundSherpaCoreTests/SonyPluginTests.swift` (add)

**Interfaces:**
- Consumes: `DeviceChange` cases `.anc`, `.equalizer`; `SonyCodec.encodeANC/encodeEQ`.
- Produces: real `apply(_:over:) -> Bool` — true only on an ACK frame within timeout; false for every Bose-only change and on timeout.

- [ ] **Step 1: Write the failing test** (append)

```swift
extension SonyPluginTests {
    func testApplyANCWritesFramedV2PayloadAndAcks() async throws {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = SonyPlugin()

        async let ok = plugin.apply(.anc(ANCState(mode: .ambient, ambientLevel: 20, focusOnVoice: false)),
                                    over: channel)
        // negotiate -> V2
        try await transport.awaitWrite(count: 1)
        await channel.ingest(SonyFraming.encode(type: .command1, seq: 0,
                             payload: [0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // ANC write -> device ACKs (any framed reply is an ACK for our purposes)
        try await transport.awaitWrite(count: 2)
        await channel.ingest(SonyFraming.encode(type: .ack, seq: 1, payload: []))

        XCTAssertTrue(await ok)
        let writes = await transport.writes
        // The 2nd write is the framed V2 ambient payload [0x68,0x17,0x01,0x01,0x01,0x00,0x14].
        let expectedPayload: [UInt8] = [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x14]
        XCTAssertEqual(SonyFraming.decode(writes[1])?.payload, expectedPayload)
    }

    func testApplyRejectsBoseOnlyChanges() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        let plugin = SonyPlugin()
        // No negotiation needed; unsupported changes short-circuit to false without I/O.
        let r1 = await plugin.apply(.selfVoice(.medium), over: channel)
        let r2 = await plugin.apply(.autoOff(.twenty), over: channel)
        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testApplyReturnsFalseOnTimeout() async {
        let transport = ScriptedTransport()
        let channel = DeviceChannel(transport: transport)
        // Negotiation itself times out -> false.
        let r = await SonyPlugin().apply(.equalizer(EqualizerState(presetId: 0x00)), over: channel)
        XCTAssertFalse(r)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: FAIL — `apply` returns false (stub), `XCTAssertTrue(await ok)` fails.

- [ ] **Step 3: Write minimal implementation** (replace `apply` in `SonyPlugin.swift`)

```swift
    public func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool {
        let payload: [UInt8]
        switch change {
        case .anc(let state):
            guard let version = await negotiateVersion(over: channel) else { return false }
            payload = SonyCodec.encodeANC(state, version: version)
        case .equalizer(let eq):
            guard let version = await negotiateVersion(over: channel) else { return false }
            payload = SonyCodec.encodeEQ(eq, version: version)
        case .noiseCancellation, .selfVoice, .autoOff, .buttonAction, .promptLanguage, .voicePrompts:
            // Bose-only changes; Sony does not handle them.
            return false
        }
        let reply = await sendFramed(payload, over: channel)
        return !reply.isEmpty   // any framed reply within the window is treated as an ACK
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SonyPluginTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/SonyPlugin.swift Tests/SoundSherpaCoreTests/SonyPluginTests.swift
git commit -m "feat(core): SonyPlugin apply (ANC/EQ ACK-gated, Bose-only changes rejected)"
```

---

### Task 12: Register `SonyPlugin` in `DeviceRegistry.standard`

**Files:**
- Modify: `Sources/SoundSherpaCore/DeviceRegistry.swift:19`
- Test: `Tests/SoundSherpaCoreTests/DeviceRegistryTests.swift` (add)

**Interfaces:**
- Consumes: `SonyPlugin` (Task 8). Produces: `DeviceRegistry.standard` resolving both brands.

- [ ] **Step 1: Write the failing test** (append to `DeviceRegistryTests.swift`)

```swift
extension DeviceRegistryTests {
    func testStandardRegistryResolvesSony() {
        let registry = DeviceRegistry.standard
        XCTAssertEqual(registry.plugin(forDeviceNamed: "WH-1000XM5")?.identifier, "Sony")
        XCTAssertEqual(registry.plugin(forDeviceNamed: "Sony WH-1000XM4")?.identifier, "Sony")
    }

    func testStandardRegistryStillResolvesBose() {
        XCTAssertEqual(DeviceRegistry.standard.plugin(forDeviceNamed: "Bose QC35 II")?.identifier, "Bose")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceRegistryTests`
Expected: FAIL — Sony resolves to nil.

- [ ] **Step 3: Write minimal implementation** (`DeviceRegistry.swift:19`)

```swift
    public static var standard: DeviceRegistry {
        DeviceRegistry(plugins: [BosePlugin(), SonyPlugin()])
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter DeviceRegistryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpaCore/DeviceRegistry.swift Tests/SoundSherpaCoreTests/DeviceRegistryTests.swift
git commit -m "feat(core): register SonyPlugin in DeviceRegistry.standard"
```

---

### Task 13: 128-bit UUID matching in `serviceRecord` (the BLOCKER)

App-target change (no XCTest for IOBluetooth code; verified by build + the live checklist). Keep the change minimal and additive.

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift:498-518`

**Interfaces:**
- Consumes: `ServiceMatcher.uuid(String)` carrying a 128-bit UUID string. Produces: a matching `IOBluetoothSDPServiceRecord`, from which `connectToService` reads the RFCOMM channel (existing code).

- [ ] **Step 1: Add the 128-bit branch**

In `serviceRecord(matching:in:)`, replace the `case .uuid(let uuidString):` body with:

```swift
            case .uuid(let uuidString):
                // 16-bit short form, e.g. "0x1101" (Bose SPP): match directly.
                if uuidString.hasPrefix("0x"), let v = UInt16(uuidString.dropFirst(2), radix: 16) {
                    for record in records {
                        if record.matchesUUID16(v) { return record }
                    }
                    continue
                }
                // 128-bit vendor UUID (e.g. Sony's V1/V2 service UUIDs): build an
                // IOBluetoothSDPUUID and match it against each record's service UUIDs.
                if let uuid = IOBluetoothSDPUUID(string: uuidString) {
                    for record in records {
                        if record.hasServiceFromArray([uuid]) { return record }
                    }
                }
```

> **Implementer note:** `IOBluetoothSDPServiceRecord.hasServiceFromArray(_:)` returns true when the record advertises any UUID in the array (handles 16-vs-128-bit promotion internally). This is the documented API for 128-bit matching. If a future SDK deprecates it, fall back to iterating `record.getServiceClassUUIDs()` and comparing via `IOBluetoothSDPUUID.isEqual(to:)`.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build -c release`
Expected: Builds with no errors.

- [ ] **Step 3: Verify Bose path is unaffected**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS (the 16-bit `0x1101` branch is unchanged; this confirms no core regression).

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift
git commit -m "fix(app): match 128-bit vendor UUIDs in serviceRecord (Sony discovery blocker)"
```

---

### Task 14: Plugin-provided deviceId label in the controller

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift:800` (`fetchAllDeviceInfo`)
- Modify: `Sources/SoundSherpa/DeviceController.swift:933-934` (`applyCachedMetadata`)

**Interfaces:**
- Consumes: `DevicePlugin.deviceIdLabel(modelId:)` (Task 7).

- [ ] **Step 1: Replace the hardcoded format in `fetchAllDeviceInfo`**

At line ~800, replace:

```swift
        if let modelId = metadata.modelId { self.deviceId = String(format: "Bose 0x%04X", modelId) }
```

with:

```swift
        if let modelId = metadata.modelId { self.deviceId = plugin.deviceIdLabel(modelId: modelId) }
```

(`plugin` is already in scope from the `guard let plugin = activePlugin` earlier in the method.)

- [ ] **Step 2: Replace the hardcoded format in `applyCachedMetadata`**

At lines ~933-934, replace:

```swift
        } else if let modelId = meta.modelId {
            deviceIdValue = String(format: "Bose 0x%04X", modelId)
```

with:

```swift
        } else if let modelId = meta.modelId {
            deviceIdValue = (activePlugin ?? BosePlugin()).deviceIdLabel(modelId: modelId)
```

> **Implementer note:** `applyCachedMetadata` runs on connect before `activePlugin` may be resolved on the slow path, so fall back to `BosePlugin()` to preserve the exact prior label for Bose cached entries. For Sony, `activePlugin` is set in `checkForSupportedDevices` before `applyCachedMetadata` is called (see line ~441 then ~451), so Sony gets "Sony 0x….".

- [ ] **Step 3: Build**

Run: `swift build -c release`
Expected: Builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift
git commit -m "refactor(app): use plugin.deviceIdLabel instead of hardcoded Bose format"
```

---

### Task 15: Gate the multipoint/paired-devices UI on `.multipoint`

**Files:**
- Modify: `Sources/SoundSherpa/Views/ContentTile.swift:51-59`

**Interfaces:**
- Consumes: `controller.supportedFeatures` (existing observable).

- [ ] **Step 1: Gate the disclosure + list**

Wrap the "More" disclosure row and the `PairedDevicesList` so they only render when the active device supports multipoint. Replace lines ~40-59 (the `MenuRow(title: "More" …)` block through the `if showMore { PairedDevicesList… }` block) with the same content guarded:

```swift
                if controller.supportedFeatures.contains(.multipoint) {
                    // Native-style disclosure: a full-width row with a trailing chevron that
                    // rotates when expanded, revealing the paired-device controls inline.
                    MenuRow(title: "More", titleFont: .system(size: 12, weight: .semibold), horizontalInset: 8, trailing: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showMore ? 90 : 0))
                    }, action: { withAnimation(.easeInOut(duration: 0.18)) { showMore.toggle() } })
                    .padding(.horizontal, -6)

                    if showMore {
                        PairedDevicesList(devices: controller.pairedDevices) { device in
                            if device.isConnected {
                                controller.disconnectPairedDevice(device)
                            } else {
                                controller.connectPairedDevice(device)
                            }
                        }
                    }
                }
```

- [ ] **Step 2: Build**

Run: `swift build -c release`
Expected: Builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundSherpa/Views/ContentTile.swift
git commit -m "fix(app): gate multipoint/paired-devices UI on .multipoint feature"
```

---

### Task 16: Generalize the unsolicited-broadcast handler to a plugin hook

**Files:**
- Modify: `Sources/SoundSherpa/DeviceController.swift:1027-1042` (`rfcommChannelData`)
- Modify: `Sources/SoundSherpa/DeviceController.swift` (add a `@MainActor` reflector that applies a `DeviceChange` to observable state)

**Interfaces:**
- Consumes: `DevicePlugin.decodeUnsolicited(_:) -> DeviceChange?` (Task 7).

- [ ] **Step 1: Replace the Bose-gated branch with a plugin-driven one**

Replace the block starting `if activePlugin?.identifier == "Bose",` through its closing brace with:

```swift
        // Independently, let the active plugin decode unsolicited broadcasts (e.g. ANC changed
        // via an on-device button) so the UI reflects them even with no command in flight.
        if let change = activePlugin?.decodeUnsolicited(responseData) {
            Task { @MainActor [weak self] in
                self?.reflectUnsolicited(change)
            }
        }
```

- [ ] **Step 2: Add the reflector method**

Add to the `// MARK: - Intents` section (it mutates observable state, so it's `@MainActor` — the class default):

```swift
    /// Apply a plugin-decoded unsolicited change to observable state. Mirrors the per-feature
    /// observable property the corresponding control binds to. Unsupported cases are ignored.
    private func reflectUnsolicited(_ change: DeviceChange) {
        switch change {
        case .noiseCancellation(let level):
            self.ncLevel = level
        case .anc(let state):
            self.ancState = state
        case .selfVoice(let level):
            self.selfVoiceLevel = level
        case .equalizer, .autoOff, .buttonAction, .promptLanguage, .voicePrompts:
            break  // not reflected from unsolicited broadcasts in this sub-project
        }
    }
```

> **Implementer note:** `ancState` is the observable added in Task 17. If implementing Task 16 before 17, temporarily omit the `.anc` case (add it back in 17). Recommended order: do 17 first, or add the `var ancState: ANCState?` property as part of this step.

- [ ] **Step 3: Build**

Run: `swift build -c release`
Expected: Builds clean (after `ancState` exists).

- [ ] **Step 4: Verify Bose core tests still pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter BosePluginTests`
Expected: PASS (the Bose unsolicited logic now lives in `BosePlugin.decodeUnsolicited`, covered by Task 7's tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundSherpa/DeviceController.swift
git commit -m "refactor(app): route unsolicited broadcasts through plugin.decodeUnsolicited"
```

---

### Task 17: Sony ANC/ambient + EQ UI controls (feature-gated)

**Files:**
- Create: `Sources/SoundSherpa/Views/AmbientSection.swift`
- Modify: `Sources/SoundSherpa/DeviceController.swift` (add `ancState`/`equalizerState` observables + `setANC`/`setEqualizer` intents; populate from `readState` in `fetchAllDeviceInfo`)
- Modify: `Sources/SoundSherpa/Views/ContentTile.swift` (render the Sony controls, gated)

**Interfaces:**
- Consumes: `ANCState`, `EqualizerState`, `controller.supportedFeatures`, `applyChange(.anc/.equalizer)`.
- Produces: observable `ancState: ANCState?`, `equalizerState: EqualizerState?`; intents `setANC(_:)`, `setEqualizer(_:)`.

- [ ] **Step 1: Add observables + intents + state population to `DeviceController`**

Add near the other observable controls (after `selfVoiceLevel`, line ~43):

```swift
    // Sony cross-brand controls (nil for Bose).
    var ancState: ANCState?
    var equalizerState: EqualizerState?
```

Add intents in the `// MARK: - Intents` section:

```swift
    func setANC(_ state: ANCState) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.anc(state)) { self.ancState = state }
        }
    }

    func setEqualizer(_ state: EqualizerState) {
        Task { [weak self] in
            guard let self else { return }
            if await self.applyChange(.equalizer(state)) { self.equalizerState = state }
        }
    }
```

In `fetchAllDeviceInfo`, after the existing `state` fan-out (line ~810), add:

```swift
        if let v = state.anc { self.ancState = v }
        if let v = state.equalizer { self.equalizerState = v }
```

- [ ] **Step 2: Create `AmbientSection.swift`**

```swift
import SwiftUI
import SoundSherpaCore

/// Sony sound-control: a 3-way mode (Off / Noise Cancelling / Ambient), a 0–20 ambient slider
/// shown only in ambient mode, and a focus-on-voice toggle. Bound to `ANCState`; gated by the
/// caller on `.ambientLevel` / `.focusOnVoice`.
struct AmbientSection: View {
    let state: ANCState?
    let onChange: (ANCState) -> Void

    private var mode: ANCState.Mode { state?.mode ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedSection(
                title: "Sound Control",
                options: [(ANCState.Mode.off, "Off", "speaker"),
                          (.noiseCancelling, "NC", "speaker.slash"),
                          (.ambient, "Ambient", "ear")],
                selection: mode,
                onSelect: { newMode in
                    onChange(ANCState(mode: newMode,
                                      ambientLevel: state?.ambientLevel ?? 10,
                                      focusOnVoice: state?.focusOnVoice ?? false))
                })

            if mode == .ambient {
                let level = Binding<Double>(
                    get: { Double(state?.ambientLevel ?? 10) },
                    set: { onChange(ANCState(mode: .ambient,
                                             ambientLevel: Int($0.rounded()),
                                             focusOnVoice: state?.focusOnVoice ?? false)) })
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ambient Level").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: level, in: 0...20, step: 1)
                }

                Toggle("Focus on Voice", isOn: Binding<Bool>(
                    get: { state?.focusOnVoice ?? false },
                    set: { onChange(ANCState(mode: .ambient,
                                             ambientLevel: state?.ambientLevel ?? 10,
                                             focusOnVoice: $0)) }))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}
```

- [ ] **Step 3: Render the Sony controls in `ContentTile`**

In `ContentTile.swift`, after the `.noiseCancellation` Bose `SegmentedSection` block (line ~25) and before the `.selfVoice` block, add:

```swift
                if controller.supportedFeatures.contains(.ambientLevel) {
                    AmbientSection(state: controller.ancState,
                                   onChange: { controller.setANC($0) })
                }

                if controller.supportedFeatures.contains(.equalizer) {
                    SegmentedSection(
                        title: "Equalizer",
                        options: [(0x00, "Off", "slider.horizontal.3"),
                                  (0x10, "Bright", "sun.max"),
                                  (0x16, "Bass", "speaker.wave.3")],
                        selection: controller.equalizerState?.presetId,
                        onSelect: { controller.setEqualizer(EqualizerState(presetId: $0)) })
                }
```

> **Implementer note:** Bose's `.noiseCancellation` (segmented Off/Low/High bound to `ncLevel`) and Sony's `.ambientLevel` (the `AmbientSection`) are mutually exclusive in practice because a device has one plugin — Bose lacks `.ambientLevel`, Sony lacks `.selfVoice`. Both can be present in the `if controller.isConnected` block; only the gated ones for the active brand render. The EQ preset list is a minimal 3-option subset (Off/Bright/Bass) for v1; full preset coverage can follow once verified on hardware.

- [ ] **Step 4: Build**

Run: `swift build -c release`
Expected: Builds clean.

- [ ] **Step 5: Run the full core test suite (no regressions)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
Expected: PASS — all existing Bose/registry/channel tests plus the new Sony tests are green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundSherpa/Views/AmbientSection.swift Sources/SoundSherpa/Views/ContentTile.swift Sources/SoundSherpa/DeviceController.swift
git commit -m "feat(app): Sony ANC/ambient + EQ UI controls, feature-gated"
```

---

## Live-verification checklist (deferred phase — requires physical XM5/XM4)

These cannot be unit-tested. Track them as a follow-up once hardware is available; each corresponds to a fixture marked `VERIFY ON HARDWARE` in the tests:

- [ ] WH-1000XM4 init reply is length 4 (confirms V1 mapping for the over-ear model).
- [ ] Battery reply layout: response type byte (0x11 V1 / 0x23 V2) and level index. Fix `SonyCodec.decodeBattery` + its tests if different.
- [ ] Ambient status reply layout (response type 0x67, field positions). Fix `SonyCodec.decodeANC` + tests.
- [ ] V2 ambient sub-type `0x15` vs `0x17` selection and the wind-noise branch on real XM5 firmware.
- [ ] V2 reversed-boolean polarity (Gadgetbridge `// reversed?`) for focus-on-voice / related toggles.
- [ ] Firmware/serial/model reply frames (decoders are best-effort; serial/model deferred).
- [ ] End-to-end: discovery via the 128-bit UUID, RFCOMM channel resolved from SDP, full connect + negotiate + read on a paired device. Remember `pkill -9 -f SoundSherpa` between launches and ad-hoc sign with the stable identifier.

## Self-review

**Spec coverage:** Dual-dialect V1/V2 (Tasks 1–11), framing (1), negotiation (2,9), battery (3,9), ANC/ambient (4,10,11), EQ (5,10,11), metadata (6,9), discovery+both UUIDs (8), registration (12), 128-bit blocker (13), deviceId formatter (14), multipoint gate (15), unsolicited hook (7,16), UI in scope (17), multipoint deferred (8 omits it, 15 gates it), testing strategy (every Core task is TDD), live-verification deferral (checklist). All spec sections map to a task.

**Placeholder scan:** No "TBD"/"add error handling" placeholders. Every NEEDS-HARDWARE fixture is a concrete byte array with a stated derivation rule and a `VERIFY ON HARDWARE` marker — these are honest uncertainty flags, not placeholders, and each has a real expected value so the test runs.

**Type consistency:** `SonyProtocol`, `SonyFraming`/`SonyFrame`/`SonyMessageType`, `SonyCodec` (encode*/decode* with `version:`), `SonyPlugin` (`versionBox`/`SonyVersionBox`, `sendFramed`, `negotiateVersion`), `DevicePlugin.deviceIdLabel`/`decodeUnsolicited`, controller `ancState`/`equalizerState`/`setANC`/`setEqualizer`/`reflectUnsolicited` are used consistently across tasks. `ANCState`/`EqualizerState`/`DeviceChange`/`DeviceFeature` match the existing Core definitions verified during planning.
