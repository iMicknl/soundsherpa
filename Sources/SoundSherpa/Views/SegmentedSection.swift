import SwiftUI

/// A titled row of AirPods-style pills. The selected pill fills with the accent tint;
/// tapping a pill invokes `onSelect`. Generic over the option's value type.
struct SegmentedSection<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, title: String, systemImage: String)]
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    pill(option)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(_ option: (value: Value, title: String, systemImage: String)) -> some View {
        let isSelected = option.value == selection
        Button {
            onSelect(option.value)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(option.title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}
