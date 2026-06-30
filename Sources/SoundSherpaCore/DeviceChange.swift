import Foundation

/// The set of controllable features a brand may expose. The UI renders only the controls
/// whose feature is in a plugin's `supportedFeatures`.
public enum DeviceFeature: Sendable, Hashable, CaseIterable {
    case noiseCancellation   // ANC mode / level
    case ambientLevel        // 0–20 ambient passthrough (Sony)
    case focusOnVoice        // Sony
    case equalizer
    case selfVoice           // Bose
    case autoOff             // Bose
    case buttonAction        // Bose
    case promptLanguage      // Bose
    case multipoint          // paired-device management (Bose today)
}

/// A single typed mutation a plugin can apply to a device. A brand uses whichever cases
/// match its capabilities; `apply` returns false for changes it doesn't support.
public enum DeviceChange: Sendable {
    case anc(ANCState)                                 // cross-brand (Sony)
    case noiseCancellation(NoiseCancellationLevel)     // Bose off/low/high
    case equalizer(EqualizerState)
    case selfVoice(SelfVoiceLevel)
    case autoOff(AutoOff)
    case buttonAction(ButtonAction)
    case promptLanguage(PromptLanguage)
    case voicePrompts(Bool)
}
