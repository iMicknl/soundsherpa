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
        // Send the framed command and check if we got *any* reply frame (even with empty payload).
        // Unlike sendFramed which returns the decoded payload, we need the raw bytes here to
        // distinguish "got an ACK with empty payload" from "timeout/no reply".
        let seq = versionBox.seq
        let frame = SonyFraming.encode(type: .command1, seq: seq, payload: payload)
        let reply = (try? await channel.send(frame, matcher: .prefix([0x3E]), timeout: 0.5)) ?? []
        return !reply.isEmpty   // any framed reply within the window is treated as an ACK
    }
}

/// Reference box for the negotiated dialect + sequence byte. See the SAFETY note on
/// `SonyPlugin.versionBox` — single-channel serialization is what makes @unchecked safe.
final class SonyVersionBox: @unchecked Sendable {
    var version: SonyProtocol?
    var seq: UInt8 = 0
}
