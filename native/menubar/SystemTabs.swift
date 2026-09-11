import SwiftUI

struct SystemTabs: View {
    @Binding var selection: Int

    var body: some View {
        GlassTabs(selection: $selection, labels: ["额度", "重置动态", "统计"],
                  accessibilityTitle: "面板视图", segmentWidth: 85, segmentHeight: 36, fontSize: 14)
            .frame(maxWidth: .infinity)
    }
}
