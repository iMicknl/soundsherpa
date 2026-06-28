import XCTest
@testable import SoundSherpaCore

/// Tests for ResponseMatcher — the pure, brand-agnostic logic that decides when a reply
/// to a command is "complete" given the bytes seen so far. This is the test seam for the
/// DeviceChannel actor: the transport feeds chunks in, the matcher says accumulate vs.
/// done, with NO IOBluetooth and NO concurrency.
///
/// Brands frame replies differently, so matching is strategy-based. Bose replies are
/// identified by a leading byte prefix (e.g. [0x02,0x02] for battery); a future Sony
/// codec can supply a different strategy without touching the transport or the actor.
final class ResponseMatcherTests: XCTestCase {

    // MARK: - Prefix strategy: acceptance

    func testPrefixMatcherAcceptsChunkWithMatchingPrefix() {
        let matcher = ResponseMatcher.prefix([0x02, 0x02])
        let result = matcher.consume(existing: [], chunk: [0x02, 0x02, 0x03, 0x01, 0x64])
        XCTAssertEqual(result, .complete([0x02, 0x02, 0x03, 0x01, 0x64]))
    }

    func testPrefixMatcherChecksFullPrefixNotJustFirstTwoBytes() {
        // Three-byte prefix: a chunk that matches the first two bytes but not the third
        // must NOT be accepted (fixes the old 2-byte-only matching).
        let matcher = ResponseMatcher.prefix([0x04, 0x05, 0x03])
        let wrong = matcher.consume(existing: [], chunk: [0x04, 0x05, 0x01, 0xAA])
        XCTAssertEqual(wrong, .ignore)

        let right = matcher.consume(existing: [], chunk: [0x04, 0x05, 0x03, 0x06, 0x01])
        XCTAssertEqual(right, .complete([0x04, 0x05, 0x03, 0x06, 0x01]))
    }

    func testPrefixMatcherSingleByte() {
        let matcher = ResponseMatcher.prefix([0x01])
        XCTAssertEqual(matcher.consume(existing: [], chunk: [0x01, 0x06, 0x03, 0x05, 0x00]),
                       .complete([0x01, 0x06, 0x03, 0x05, 0x00]))
    }

    // MARK: - Prefix strategy: rejection

    func testPrefixMatcherIgnoresUnrelatedChunk() {
        let matcher = ResponseMatcher.prefix([0x02, 0x02])
        // An unsolicited NC status broadcast [0x01,0x06,...] arriving while we await battery.
        XCTAssertEqual(matcher.consume(existing: [], chunk: [0x01, 0x06, 0x03, 0x05, 0x00]),
                       .ignore)
    }

    func testPrefixMatcherIgnoresEmptyChunk() {
        let matcher = ResponseMatcher.prefix([0x02, 0x02])
        XCTAssertEqual(matcher.consume(existing: [], chunk: []), .ignore)
    }

    func testPrefixMatcherIgnoresChunkShorterThanPrefix() {
        let matcher = ResponseMatcher.prefix([0x04, 0x05, 0x03])
        XCTAssertEqual(matcher.consume(existing: [], chunk: [0x04, 0x05]), .ignore)
    }

    // MARK: - Collecting strategy (multi-chunk broadcast, e.g. device status)

    func testCollectingMatcherAccumulatesAcrossChunksAndNeverCompletes() {
        // The status query provokes several separate broadcast messages (language, NC,
        // self-voice). We collect everything matching the family prefix and let the
        // CALLER stop on a timeout window — the matcher itself never says "complete".
        let matcher = ResponseMatcher.collecting(prefix: [0x01])

        let r1 = matcher.consume(existing: [], chunk: [0x01, 0x03, 0x03, 0x01, 0x21])
        XCTAssertEqual(r1, .accumulate([0x01, 0x03, 0x03, 0x01, 0x21]))

        let r2 = matcher.consume(existing: [0x01, 0x03, 0x03, 0x01, 0x21],
                                 chunk: [0x01, 0x06, 0x03, 0x01, 0x00])
        XCTAssertEqual(r2, .accumulate([0x01, 0x03, 0x03, 0x01, 0x21,
                                        0x01, 0x06, 0x03, 0x01, 0x00]))
    }

    func testCollectingMatcherIgnoresNonMatchingChunk() {
        let matcher = ResponseMatcher.collecting(prefix: [0x01])
        let r = matcher.consume(existing: [0x01, 0x03], chunk: [0x02, 0x02, 0x03])
        XCTAssertEqual(r, .ignore)
    }

    // MARK: - Robustness

    func testMatcherToleratesGarbageWithoutCrashing() {
        let prefix = ResponseMatcher.prefix([0x00, 0x07, 0x03])
        let collecting = ResponseMatcher.collecting(prefix: [0x01])
        let garbage: [[UInt8]] = [[], [0x00], Array(repeating: 0xFF, count: 200)]
        for g in garbage {
            _ = prefix.consume(existing: [], chunk: g)
            _ = collecting.consume(existing: g, chunk: g)
        }
    }
}
