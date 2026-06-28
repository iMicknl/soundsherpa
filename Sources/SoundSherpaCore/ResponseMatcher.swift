import Foundation

/// Decides, as bytes arrive on a device channel, whether the reply to the in-flight
/// command is complete. This is the pure, brand-agnostic seam underneath `DeviceChannel`:
/// the transport hands each incoming chunk to the matcher, which says whether to ignore
/// it, accumulate it, or treat the reply as done.
///
/// Different brands frame replies differently, so this is strategy-based. Bose identifies
/// a reply by a leading byte prefix; a future `SonyCodec` can construct a matcher with its
/// own framing rule without changing the transport or the actor.
public struct ResponseMatcher: Sendable {

    /// The outcome of consuming one incoming chunk.
    public enum Outcome: Equatable, Sendable {
        /// Chunk is unrelated to the in-flight command; drop it (e.g. an unsolicited
        /// status broadcast arriving while we await a battery reply).
        case ignore
        /// Chunk belongs to this reply but the reply isn't finished; keep waiting.
        /// Carries the full buffer accumulated so far.
        case accumulate([UInt8])
        /// The reply is complete. Carries the full reply bytes.
        case complete([UInt8])
    }

    private let consumer: @Sendable (_ existing: [UInt8], _ chunk: [UInt8]) -> Outcome

    private init(consumer: @escaping @Sendable (_ existing: [UInt8], _ chunk: [UInt8]) -> Outcome) {
        self.consumer = consumer
    }

    public func consume(existing: [UInt8], chunk: [UInt8]) -> Outcome {
        consumer(existing, chunk)
    }

    // MARK: - Strategies

    /// A reply is the first chunk whose leading bytes equal `prefix`. The whole matching
    /// chunk is the complete reply. The full prefix is checked (not just the first two
    /// bytes), so a three-byte prefix discriminates families that share two leading bytes.
    public static func prefix(_ prefix: [UInt8]) -> ResponseMatcher {
        ResponseMatcher { _, chunk in
            guard hasPrefix(chunk, prefix) else { return .ignore }
            return .complete(chunk)
        }
    }

    /// Accumulates every chunk sharing `prefix`'s leading bytes and never declares
    /// completion — the caller bounds collection with a timeout window. Used for commands
    /// that provoke several distinct broadcast messages (e.g. the Bose status query, which
    /// yields separate language / noise-cancellation / self-voice messages).
    public static func collecting(prefix: [UInt8]) -> ResponseMatcher {
        ResponseMatcher { existing, chunk in
            guard hasPrefix(chunk, prefix) else { return .ignore }
            return .accumulate(existing + chunk)
        }
    }

    // MARK: - Helpers

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty, bytes.count >= prefix.count else { return false }
        for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
        return true
    }
}
