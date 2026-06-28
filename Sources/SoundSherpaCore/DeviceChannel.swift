import Foundation

/// Structured errors surfaced by the device transport layer. Every failure path throws a
/// specific case rather than silently returning empty/false, so callers can never mistake
/// a timeout or a closed channel for a valid reply (R6/R7.3).
public enum DeviceError: Error, Equatable, Sendable {
    case notConnected
    case commandTimeout
    case invalidResponse
    case unsupportedCommand
    case channelClosed
}

/// The narrow seam through which `DeviceChannel` talks to a real RFCOMM channel. Keeping
/// this protocol free of IOBluetooth lets the actor's serialization/timeout/close logic be
/// unit-tested against a fake, and lets a future transport (a different OS, a mock, another
/// brand's link) drop in without touching the actor.
///
/// Incoming bytes are NOT part of this protocol: the real adapter receives them on the
/// IOBluetooth delegate callback and forwards them to `DeviceChannel.ingest(_:)`.
public protocol RFCOMMTransport: Sendable {
    /// Write a command's bytes to the channel. Throws if the channel can't accept them.
    func write(_ bytes: [UInt8]) async throws
    /// Tear down the underlying channel.
    func close() async
}

/// An actor that owns exactly one device channel and runs commands strictly one at a time.
///
/// This is the reliability core (R7.1): because the actor serializes access and holds the
/// in-flight command's buffer privately, a reply can never be written into another
/// command's buffer the way the old shared `responseBuffer`/`responseSemaphore` allowed.
/// Brand specifics live entirely in the `ResponseMatcher` the caller passes in, so the
/// actor is fully device-agnostic and reusable for Bose, Sony, and beyond.
public actor DeviceChannel {
    private let transport: RFCOMMTransport
    private var open = true

    /// The command currently awaiting a reply. Only one exists at a time; the serial gate
    /// below guarantees the next `send` doesn't start until this clears.
    private struct InFlight {
        let matcher: ResponseMatcher
        var buffer: [UInt8]
        let continuation: CheckedContinuation<[UInt8], Error>
        let timeoutTask: Task<Void, Never>
    }
    private var inFlight: InFlight?

    // Serial gate: an async, FIFO mutual-exclusion lock. Because `send` suspends at
    // `await transport.write` and again awaiting the reply, the actor's own reentrancy
    // isn't enough to keep two commands from interleaving — this gate enforces strictly
    // one command at a time (R7.1).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: RFCOMMTransport) {
        self.transport = transport
    }

    public var isOpen: Bool { open }

    /// Send `command` and await its reply, identified by `matcher`. Serialized: concurrent
    /// callers queue and run one after another. Throws `DeviceError` on timeout, close, or
    /// a dead channel — never returns a bogus "success".
    ///
    /// A `.prefix` matcher resolves as soon as a matching chunk arrives. A `.collecting`
    /// matcher gathers matching chunks until `timeout`, then returns the accumulated bytes
    /// (used for commands that provoke several broadcast messages).
    public func send(_ command: [UInt8],
                     matcher: ResponseMatcher,
                     timeout: TimeInterval) async throws -> [UInt8] {
        guard open else { throw DeviceError.notConnected }

        // Acquire the serial gate so only one command runs at a time.
        await acquire()
        guard open else { releaseGate(); throw DeviceError.notConnected }

        do {
            try await transport.write(command)
        } catch {
            releaseGate()
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.resolveOnTimeout()
            }
            inFlight = InFlight(matcher: matcher,
                                buffer: [],
                                continuation: continuation,
                                timeoutTask: timeoutTask)
        }
    }

    // MARK: - Serial gate

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release the gate, handing it to the next FIFO waiter if any.
    private func releaseGate() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()  // gate stays `busy`; ownership passes to the resumed waiter
        }
    }

    /// Feed bytes received from the transport's delegate callback into the in-flight
    /// command. Chunks with no in-flight command (unsolicited broadcasts) are dropped.
    public func ingest(_ chunk: [UInt8]) {
        guard var current = inFlight else { return }
        switch current.matcher.consume(existing: current.buffer, chunk: chunk) {
        case .ignore:
            break
        case .accumulate(let buffer):
            current.buffer = buffer
            inFlight = current
        case .complete(let response):
            finish(current) { $0.resume(returning: response) }
        }
    }

    /// Tear down the channel and fail any in-flight command with `.channelClosed`. Any
    /// commands queued on the gate wake up and throw `.notConnected` (open is now false).
    public func close() async {
        open = false
        if let current = inFlight {
            finish(current, releaseGateAfter: false) { $0.resume(throwing: DeviceError.channelClosed) }
        }
        // Wake every queued waiter so none hangs; each re-checks `open` and bails out.
        let queued = waiters
        waiters.removeAll()
        busy = false
        for waiter in queued { waiter.resume() }
        await transport.close()
    }

    // MARK: - Private

    /// Called by the timeout task. For a `.collecting` command this is the normal end of
    /// the window and returns the accumulated buffer; for a request/response command an
    /// empty buffer means a real timeout.
    private func resolveOnTimeout() {
        guard let current = inFlight else { return }
        if current.buffer.isEmpty {
            finish(current) { $0.resume(throwing: DeviceError.commandTimeout) }
        } else {
            let buffer = current.buffer
            finish(current) { $0.resume(returning: buffer) }
        }
    }

    /// Clear the in-flight slot, cancel its timeout, resume its continuation exactly once,
    /// and release the serial gate to the next waiter. Centralizing this prevents a
    /// double-resume across the timeout/ingest/close paths. `releaseFromClose` is true when
    /// called by `close()`, which manages the gate itself.
    private func finish(_ current: InFlight,
                        releaseGateAfter: Bool = true,
                        _ resume: (CheckedContinuation<[UInt8], Error>) -> Void) {
        inFlight = nil
        current.timeoutTask.cancel()
        resume(current.continuation)
        if releaseGateAfter { releaseGate() }
    }
}
