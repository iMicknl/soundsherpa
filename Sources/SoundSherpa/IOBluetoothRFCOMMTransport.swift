import Foundation
import IOBluetooth
import SoundSherpaCore

/// Adapts a concrete `IOBluetoothRFCOMMChannel` to the brand-agnostic `RFCOMMTransport`
/// seam the `DeviceChannel` actor writes through. This is the only place IOBluetooth meets
/// the actor; everything above it is testable, hardware-free Core.
///
/// `@unchecked Sendable`: `IOBluetoothRFCOMMChannel` predates Sendable but is safe to write
/// to from another thread (the existing code already writes from background GCD queues),
/// and we only ever hold an immutable reference here.
final class IOBluetoothRFCOMMTransport: RFCOMMTransport, @unchecked Sendable {
    private let channel: IOBluetoothRFCOMMChannel

    init(channel: IOBluetoothRFCOMMChannel) {
        self.channel = channel
    }

    func write(_ bytes: [UInt8]) async throws {
        guard channel.isOpen() else { throw DeviceError.channelClosed }
        var data = bytes
        var refcon: [UInt8] = []
        let result = channel.writeAsync(&data, length: UInt16(bytes.count), refcon: &refcon)
        guard result == kIOReturnSuccess else { throw DeviceError.channelClosed }
    }

    func close() async {
        if channel.isOpen() {
            _ = channel.close()
        }
    }
}
