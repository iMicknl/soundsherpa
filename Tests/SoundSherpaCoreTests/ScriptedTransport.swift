import Foundation
@testable import SoundSherpaCore

/// A shared fake `RFCOMMTransport` for plugin/channel tests: records every write and lets a
/// test await the Nth write before ingesting the matching reply. This makes the serialized
/// request/response dance deterministic with no IOBluetooth and no real hardware.
actor ScriptedTransport: RFCOMMTransport {
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
