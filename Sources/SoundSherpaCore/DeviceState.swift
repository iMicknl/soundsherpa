import Foundation

/// Cross-brand active-noise-control state. Used by brands (e.g. Sony) whose ANC is a
/// three-way mode plus an ambient passthrough level and a focus-on-voice flag. Bose does
/// NOT populate this — it uses the `noiseCancellationLevel` parity field on `DeviceState`.
public struct ANCState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case off, noiseCancelling, ambient }
    public var mode: Mode
    public var ambientLevel: Int?    // 0–20 ambient passthrough; nil if N/A
    public var focusOnVoice: Bool?   // nil if N/A
    public init(mode: Mode, ambientLevel: Int? = nil, focusOnVoice: Bool? = nil) {
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
    }
}

/// Equalizer state: an optional brand-defined preset index plus per-band gains in dB.
public struct EqualizerState: Sendable, Equatable {
    public var presetId: Int?        // nil = custom / unknown
    public var bands: [Int]          // per-band gains in dB; empty if unknown
    public init(presetId: Int? = nil, bands: [Int] = []) {
        self.presetId = presetId
        self.bands = bands
    }
}

/// The single brand-agnostic snapshot the controller holds and the UI binds to. A plugin's
/// `readState` fills the fields its brand supports; everything else stays nil. Bose-parity
/// fields preserve the existing Bose controls without forcing them into the generic model.
public struct DeviceState: Sendable, Equatable {
    public var battery: Int?
    public var anc: ANCState?                          // cross-brand (Sony); nil for Bose
    public var equalizer: EqualizerState?
    // Bose-parity fields:
    public var noiseCancellationLevel: NoiseCancellationLevel?
    public var selfVoice: SelfVoiceLevel?
    public var autoOff: AutoOff?
    public var buttonAction: ButtonAction?
    public var promptLanguage: PromptLanguage?
    public var voicePromptsEnabled: Bool?
    public init() {}
}
