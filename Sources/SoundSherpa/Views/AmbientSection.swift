import SwiftUI
import SoundSherpaCore

/// Sony sound-control: a 3-way mode (Off / Noise Cancelling / Ambient), a 0–20 ambient slider
/// shown only in ambient mode, and a focus-on-voice toggle. Bound to `ANCState`; gated by the
/// caller on `.ambientLevel` / `.focusOnVoice`.
struct AmbientSection: View {
    let state: ANCState?
    let onChange: (ANCState) -> Void

    private var mode: ANCState.Mode { state?.mode ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedSection(
                title: "Sound Control",
                options: [(ANCState.Mode.off, "Off", "speaker"),
                          (.noiseCancelling, "NC", "speaker.slash"),
                          (.ambient, "Ambient", "ear")],
                selection: mode,
                onSelect: { newMode in
                    onChange(ANCState(mode: newMode,
                                      ambientLevel: state?.ambientLevel ?? 10,
                                      focusOnVoice: state?.focusOnVoice ?? false))
                })

            if mode == .ambient {
                let level = Binding<Double>(
                    get: { Double(state?.ambientLevel ?? 10) },
                    set: { onChange(ANCState(mode: .ambient,
                                             ambientLevel: Int($0.rounded()),
                                             focusOnVoice: state?.focusOnVoice ?? false)) })
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ambient Level").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: level, in: 0...20, step: 1)
                }

                Toggle("Focus on Voice", isOn: Binding<Bool>(
                    get: { state?.focusOnVoice ?? false },
                    set: { onChange(ANCState(mode: .ambient,
                                             ambientLevel: state?.ambientLevel ?? 10,
                                             focusOnVoice: $0)) }))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}
