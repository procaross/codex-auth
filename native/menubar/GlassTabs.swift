import SwiftUI

/// The selection uses native Liquid Glass; the track has no segment dividers.
struct GlassTabs: View {
    @Binding var selection: Int
    let labels: [String]
    let accessibilityTitle: String
    let segmentWidth: CGFloat
    let segmentHeight: CGFloat
    let fontSize: CGFloat
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(labels.indices, id: \.self) { index in
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            selection = index
                        }
                    } label: {
                        let label = Text(labels[index])
                            .font(.system(size: fontSize, weight: selection == index ? .semibold : .medium))
                            .frame(width: segmentWidth, height: segmentHeight)
                            .contentShape(Capsule())
                        if selection == index {
                            label
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .glassEffectID("selection", in: glass)
                        } else {
                            label
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == index ? .isSelected : [])
                }
            }
        }
        .padding(3)
        .background(.primary.opacity(0.055), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }
}
