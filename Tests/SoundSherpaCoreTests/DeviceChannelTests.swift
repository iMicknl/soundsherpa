import XCTest
@testable import SoundSherpaCore

/// Tests for DeviceChannel — the async actor that owns one device channel and serializes
/// commands so a reply can never land in the wrong buffer (the core reliability guarantee,
/// R7.1). It runs against a fake transport, so serialization, timeout, and close behavior
/// are proven with NO IOBluetooth and NO real hardware.
final class DeviceChannelTests: XCTestCase {

    // MARK: - Basic request/response

    func testSendReturnsMatchingResponse() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        async let pending = channel.send([0x02, 0x02, 0x01, 0x00],
                                         matcher: .prefix([0x02, 0x02]),
                                         timeout: 2.0)
        try await transport.awaitWrite()
        await channel.ingest([0x02, 0x02, 0x03, 0x01, 0x64])

        let response = try await pending
        XCTAssertEqual(response, [0x02, 0x02, 0x03, 0x01, 0x64])
        let writes = await transport.writes
        XCTAssertEqual(writes, [[0x02, 0x02, 0x01, 0x00]])
    }

    func testSendIgnoresUnrelatedChunkThenAcceptsMatch() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        async let pending = channel.send([0x02, 0x02, 0x01, 0x00],
                                         matcher: .prefix([0x02, 0x02]),
                                         timeout: 2.0)
        try await transport.awaitWrite()
        // An unsolicited NC broadcast must not satisfy the battery request.
        await channel.ingest([0x01, 0x06, 0x03, 0x01, 0x00])
        await channel.ingest([0x02, 0x02, 0x03, 0x01, 0x2A])

        let response = try await pending
        XCTAssertEqual(response, [0x02, 0x02, 0x03, 0x01, 0x2A])
    }

    func testCollectingSendReturnsAccumulatedBufferAtTimeout() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        async let pending = channel.send([0x01, 0x01, 0x05, 0x00],
                                         matcher: .collecting(prefix: [0x01]),
                                         timeout: 0.3)
        try await transport.awaitWrite()
        await channel.ingest([0x01, 0x03, 0x03, 0x01, 0x21])
        await channel.ingest([0x01, 0x06, 0x03, 0x01, 0x00])

        // No .complete ever fires; the timeout window closes and returns what we gathered.
        let response = try await pending
        XCTAssertEqual(response, [0x01, 0x03, 0x03, 0x01, 0x21, 0x01, 0x06, 0x03, 0x01, 0x00])
    }

    // MARK: - Timeout

    func testSendThrowsTimeoutWhenNoResponse() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        do {
            _ = try await channel.send([0x02, 0x02, 0x01, 0x00],
                                       matcher: .prefix([0x02, 0x02]),
                                       timeout: 0.2)
            XCTFail("Expected commandTimeout")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .commandTimeout)
        }
    }

    // MARK: - Serialization (the R7.1 guarantee)

    func testCommandsAreSerializedOneAtATime() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        let cmdA: [UInt8] = [0x02, 0x02, 0x01, 0x00]
        let cmdB: [UInt8] = [0x00, 0x07, 0x01, 0x00]

        // Fire two commands concurrently.
        async let a = channel.send(cmdA, matcher: .prefix([0x02, 0x02]), timeout: 3.0)
        async let b = channel.send(cmdB, matcher: .prefix([0x00, 0x07]), timeout: 3.0)

        // Exactly one command may be in flight: only one write until the first resolves.
        try await transport.awaitWrite()
        let afterFirst = await transport.writes
        XCTAssertEqual(afterFirst.count, 1, "second command must wait for the first")

        // Respond to whichever acquired the channel first.
        let first = afterFirst[0]
        await channel.ingest(response(for: first))

        // Now the second command proceeds and writes.
        try await transport.awaitWrite(count: 2)
        let afterSecond = await transport.writes
        XCTAssertEqual(afterSecond.count, 2)
        await channel.ingest(response(for: afterSecond[1]))

        let r1 = try await a
        let r2 = try await b
        XCTAssertEqual(r1, response(for: cmdA))
        XCTAssertEqual(r2, response(for: cmdB))
    }

    // MARK: - Close

    func testCloseFailsPendingCommandWithChannelClosed() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)

        async let pending = channel.send([0x02, 0x02, 0x01, 0x00],
                                         matcher: .prefix([0x02, 0x02]),
                                         timeout: 5.0)
        try await transport.awaitWrite()
        await channel.close()

        do {
            _ = try await pending
            XCTFail("Expected channelClosed")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .channelClosed)
        }
        let open = await channel.isOpen
        XCTAssertFalse(open)
        let closed = await transport.isClosed
        XCTAssertTrue(closed)
    }

    func testSendAfterCloseThrowsNotConnected() async throws {
        let transport = FakeTransport()
        let channel = DeviceChannel(transport: transport)
        await channel.close()

        do {
            _ = try await channel.send([0x02, 0x02, 0x01, 0x00],
                                       matcher: .prefix([0x02, 0x02]),
                                       timeout: 1.0)
            XCTFail("Expected notConnected")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    // MARK: - Helpers

    /// Canned response for a command: same first two bytes, operator 0x03, one payload byte.
    private func response(for command: [UInt8]) -> [UInt8] {
        [command[0], command[1], 0x03, 0x01, 0x55]
    }
}

/// A fake RFCOMMTransport that records writes and lets tests await them, so the actor's
/// serialization/timeout/close logic can be exercised deterministically without hardware.
private actor FakeTransport: RFCOMMTransport {
    private(set) var writes: [[UInt8]] = []
    private(set) var isClosed = false
    private var writeWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func write(_ bytes: [UInt8]) throws {
        guard !isClosed else { throw DeviceError.channelClosed }
        writes.append(bytes)
        let count = writes.count
        writeWaiters.removeAll { waiter in
            if count >= waiter.target {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    func close() {
        isClosed = true
    }

    /// Suspends until at least `count` writes have been recorded.
    func awaitWrite(count: Int = 1) async throws {
        if writes.count >= count { return }
        await withCheckedContinuation { continuation in
            writeWaiters.append((target: count, continuation: continuation))
        }
    }
}
