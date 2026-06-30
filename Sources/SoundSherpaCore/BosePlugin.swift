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

    // Tracks the last-seen language byte (incl. voice-prompt high bit) so a voice-prompt
    // toggle can preserve the chosen language — the role the old controller's
    // `currentLanguageValue` played. Boxed because BosePlugin is a Sendable value type.
    private let languageBox = LanguageBox()
    private var lastLanguageByte: UInt8? {
        get { languageBox.value }
        nonmutating set { languageBox.value = newValue }
    }

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
        switch change {
        case .noiseCancellation(let level):
            return await acked(BoseCodec.encodeNoiseCancellation(level),
                               prefix: [0x01, 0x06], over: channel)
        case .selfVoice(let level):
            return await acked(BoseCodec.encodeSelfVoice(level),
                               prefix: [0x01, 0x0b], over: channel)
        case .autoOff(let value):
            return await acked(BoseCodec.encodeAutoOff(value),
                               prefix: [0x01, 0x04], over: channel)
        case .buttonAction(let value):
            return await acked(BoseCodec.encodeButtonAction(value),
                               prefix: [0x01, 0x09], over: channel)
        case .promptLanguage(let value):
            return await acked(BoseCodec.encodeLanguage(value.rawValue),
                               prefix: [0x01, 0x03], over: channel)
        case .voicePrompts(let on):
            // Preserve the currently-selected language; toggle only the high bit.
            let base = (lastLanguageByte ?? PromptLanguage.english.rawValue) & 0x7F
            let byte = on ? (base | 0x80) : base
            return await acked(BoseCodec.encodeLanguage(byte),
                               prefix: [0x01, 0x03], over: channel)
        case .anc, .equalizer:
            // Bose does not use the generic ANC/EQ model in this sub-project.
            return false
        }
    }

    // MARK: - Private

    /// Send `command` and treat any reply matching `prefix` as an acknowledgement. A timeout /
    /// closed channel yields false — never a throw — matching the plugin no-throw contract.
    private func acked(_ command: [UInt8], prefix: [UInt8], over channel: DeviceChannel) async -> Bool {
        let reply = (try? await channel.send(command, matcher: .prefix(prefix), timeout: 0.5)) ?? []
        return !reply.isEmpty
    }

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

/// A tiny reference box so the value-type BosePlugin can carry mutable last-language state
/// across the channel's async boundaries without becoming a class itself.
private final class LanguageBox: @unchecked Sendable {
    var value: UInt8?
}
