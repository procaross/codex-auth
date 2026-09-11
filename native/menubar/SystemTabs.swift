import SwiftUI

/// A system segmented picker owns its material, selection lens and tracking.
/// Keep it free of custom backgrounds, overlays and gestures.
struct SystemTabs: View {
    @Binding var selection: Int

    var body: some View {
        Picker("面板视图", selection: $selection) {
            Text("额度").tag(0)
            Text("重置动态").tag(1)
            Text("统计").tag(2)
        }
        .pickerStyle(.segmented)
        .controlSize(.extraLarge)
        .labelsHidden()
        .tint(Palette.selection)
        .frame(maxWidth: .infinity)
    }
}
