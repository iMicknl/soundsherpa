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
