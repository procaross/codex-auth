import SwiftUI

/// A single clear glass lens travels over a smaller blue backing. Keeping the
/// backing out of the glass surface leaves a transparent, refracting perimeter.
/// The old two conditional regular-glass backgrounds looked like flat pills
/// when composited inside the panel's own regular glass material.
struct LiquidGlassTabs: View {
    @Binding var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var pressing = false
    @State private var dragProgress: CGFloat?
    @State private var hovering = false

    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.76) }
    private static let selectedInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white : NSColor(red: 0.04, green: 0.14, blue: 0.26, alpha: 1)
    })

    var body: some View {
        GeometryReader { geometry in
            let segment = (geometry.size.width - 8) / 2
            let progress = dragProgress ?? CGFloat(selection)
            let preview = progress >= 0.5 ? 1 : 0
            ZStack(alignment: .topLeading) {
                Capsule().fill(.primary.opacity(0.045))
                Capsule().strokeBorder(.primary.opacity(0.035), lineWidth: 0.75)

                // An inset color bed gives the clear lens something to refract,
                // including on the otherwise nearly uniform glass dashboard.
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.015, green: 0.43, blue: 0.99), Color(red: 0.07, green: 0.57, blue: 1)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: segment - 12, height: 27)
                    .offset(x: 4 + progress * segment, y: 8.5)
                    .allowsHitTesting(false)

                lens
                    .frame(width: segment - 12, height: 36)
                    .scaleEffect(x: !reduceMotion && pressing ? 1.035 : 1, y: !reduceMotion && pressing ? 1.16 : 1)
                    .offset(x: 16 + progress * segment, y: 4)
                    .animation(motion, value: pressing)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    tab("额度", icon: "chart.bar.xaxis", index: 0, preview: preview)
                    tab("重置动态", icon: "sparkles", index: 1, preview: preview)
                }
                .padding(4)
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        let origin: CGFloat = value.startLocation.x < geometry.size.width / 2 ? 0 : 1
                        dragProgress = min(1, max(0, origin + value.translation.width / segment))
                    }
                    .onEnded { value in
                        let destination = dragProgress.map { $0 >= 0.5 ? 1 : 0 } ?? (value.location.x < geometry.size.width / 2 ? 0 : 1)
                        withAnimation(motion) {
                            selection = destination
                            dragProgress = nil
                        }
                    }
            )
            // Reset transient geometry if tracking is cancelled (Escape, a
            // window close, or another gesture), not just on a normal mouse-up.
            .onChange(of: pressing) { _, pressed in
                if !pressed { withAnimation(motion) { dragProgress = nil } }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("面板视图")
    }

    @ViewBuilder private var lens: some View {
        if reduceTransparency {
            Capsule().fill(Color(red: 0, green: 0.35, blue: 0.8))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        } else {
            Capsule().fill(.clear)
                .glassEffect(.clear.interactive(!reduceMotion), in: .capsule)
                .overlay {
                    // A restrained prismatic rim keeps the lens edge visible
                    // over another glass surface; the body is native material.
                    Capsule().strokeBorder(
                        LinearGradient(stops: [
                            .init(color: .white.opacity(0.95), location: 0),
                            .init(color: .cyan.opacity(0.85), location: 0.22),
                            .init(color: .blue.opacity(0.13), location: 0.44),
                            .init(color: .purple.opacity(0.65), location: 0.64),
                            .init(color: .cyan.opacity(0.80), location: 0.82),
                            .init(color: .white.opacity(0.88), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1
                    )
                    Capsule().inset(by: 1.7).strokeBorder(
                        LinearGradient(colors: [.white.opacity(hovering || pressing ? 0.8 : 0.52), .clear, .white.opacity(0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 0.7
                    )
                }
        }
    }

    private func tab(_ title: String, icon: String, index: Int, preview: Int) -> some View {
        Button { withAnimation(motion) { selection = index } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: preview == index ? .semibold : .medium))
                .foregroundStyle(preview == index ? (reduceTransparency ? Color.white : Self.selectedInk) : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == index ? [.isSelected] : [])
        .onMoveCommand { direction in
            if direction == .left { withAnimation(motion) { selection = 0 } }
            if direction == .right { withAnimation(motion) { selection = 1 } }
        }
    }
}
