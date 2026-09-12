import SwiftUI

/// Compact switch styling that stays visually quiet inside translucent menu panels.
struct SoftSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Palette.teal.opacity(0.18) : Color.primary.opacity(0.07))
                        .overlay(Capsule().strokeBorder(configuration.isOn ? Palette.teal.opacity(0.22) : Color.primary.opacity(0.08)))
                    Circle()
                        .fill(configuration.isOn ? Palette.teal : Color.secondary.opacity(0.72))
                        .padding(3)
                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                }
                .frame(width: 34, height: 20)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.48)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
