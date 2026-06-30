import Foundation

/// The Bose implementation of `DevicePlugin`. It owns no I/O machinery of its own: it pairs
/// the pure `BoseCodec` (encode/decode) with whatever `DeviceChannel` it's handed, so the
/// same serialized-channel guarantees apply to every brand uniformly.
///
/// Verified against the QC35 / QC35 II SPP protocol. Newer Bose models that share this
/// control protocol are handled by the same plugin; a model that diverges would get its own
/// codec while reusing this structure.
public struct BosePlugin: DevicePlugin {
    public let identifier = "Bose"

    public init() {}

    public func handles(deviceNamed name: String) -> Bool {
        name.lowercased().contains("bose")
    }

    public func readBatteryLevel(over channel: DeviceChannel) async -> Int? {
        let response = await sendExpecting(BoseCodec.encodeBatteryQuery(),
                                           prefix: [0x02, 0x02],
                                           over: channel)
        return BoseCodec.decodeBattery(response)
    }

    public func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata {
        var metadata = DeviceMetadata()

        // Firmware arrives on the init-handshake reply (function 0x01); BoseCodec decodes
        // both that and the dedicated firmware query.
        let initReply = await sendExpecting([0x00, 0x01, 0x01, 0x00],
                                            prefix: [0x00, 0x01],
                                            over: channel,
                                            timeout: 5.0)
        if let firmware = BoseCodec.decodeFirmware(initReply) {
            metadata.firmware = firmware
        }

        let serialReply = await sendExpecting(BoseCodec.encodeSerialQuery(),
                                              prefix: [0x00, 0x07],
                                              over: channel)
        if let serial = BoseCodec.decodeSerial(serialReply) {
            metadata.serial = serial
        }

        let modelReply = await sendExpecting(BoseCodec.encodeDeviceIdQuery(),
                                             prefix: [0x00, 0x03],
                                             over: channel)
        if let modelId = BoseCodec.decodeModelId(modelReply) {
            metadata.modelId = modelId
        }

        return metadata
    }

    public var discoveryDescriptor: DiscoveryDescriptor {
        DiscoveryDescriptor(
            serviceMatchers: [.serviceName("SPP Dev"), .uuid("0x1101")],
            channelHints: [8, 9, 1, 2, 3])
    }

    public var supportedFeatures: Set<DeviceFeature> {
        [.noiseCancellation, .selfVoice, .autoOff, .buttonAction, .promptLanguage, .multipoint]
    }

    // Implemented in later tasks (apply: Task 6, readState: Task 7).
    public func readState(over channel: DeviceChannel) async -> DeviceState {
        DeviceState()
    }

    public func apply(_ change: DeviceChange, over channel: DeviceChannel) async -> Bool {
        false
    }

    // MARK: - Private

    /// Send `command` and await the reply identified by `prefix`, returning the reply bytes
    /// or an empty array on timeout / closed channel. Swallowing the `DeviceError` here lets
    /// decoders treat "no reply" as `nil` uniformly, matching the plugin's no-throw contract.
    private func sendExpecting(_ command: [UInt8],
                               prefix: [UInt8],
                               over channel: DeviceChannel,
                               timeout: TimeInterval = 0.5) async -> [UInt8] {
        (try? await channel.send(command, matcher: .prefix(prefix), timeout: timeout)) ?? []
    }
}
