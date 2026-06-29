import SwiftUI

/// A titled row of AirPods-style pills. The selected pill fills with the accent tint;
/// tapping a pill invokes `onSelect`. Generic over the option's value type.
struct SegmentedSection<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, title: String, systemImage: String)]
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 7)
            HStack(spacing: 6) {
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
            VStack(spacing: 3) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(option.title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}
