import AppKit
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @ObservedObject var store: AppStore
    @AppStorage("animationEnabled") private var animationEnabled = true
    @AppStorage("proxyEnabled") private var proxyEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    let close: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 22).padding(.top, 18)
            if store.settings {
                ScrollView {
                    preferences.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            } else {
                hero.padding(.horizontal, 22)
                SystemTabs(selection: $store.tab).padding(.horizontal, 22).padding(.bottom, 15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if let error = store.error { message(error, warning: true) }
                        if let notice = store.notice { message(notice, warning: false) }
                        if store.tab == 0 { accountContent } else { newsContent }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else {
                LinearGradient(colors: [Palette.teal.opacity(colorScheme == .dark ? 0.08 : 0.035), .clear, Palette.mint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .tint(Palette.teal)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.teal)
            Text("CODEX / AUTH").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.2)
            if store.demo { Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                if store.busy { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
                else { Image(systemName: "arrow.clockwise").frame(width: 14, height: 14) }
            }
            .disabled(store.busy).keyboardShortcut("r").help("刷新额度与重置消息").accessibilityLabel("刷新")
            Button { withAnimation(.easeInOut(duration: 0.18)) { store.settings.toggle() } } label: {
                Image(systemName: store.settings ? "xmark" : "slider.horizontal.3").frame(width: 14, height: 14)
            }
            .help(store.settings ? "返回仪表盘" : "设置").accessibilityLabel("设置")
        }
        .buttonStyle(.glass).controlSize(.small).tint(nil as Color?)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(store.busy ? Palette.coral : Palette.teal).frame(width: 5, height: 5)
                    Text(store.busy ? "SYNCING" : "YOUR LITTLE CO-PILOT")
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                }
                Text(store.tab == 0 ? "灵感在线。" : "保持好消息。")
                    .font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                Text(store.tab == 0 ? "额度与账号，一眼就好。" : "重置动态，随时瞄一眼。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 8))
                    Text("HALFTONE COMPANION").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(0.9)
                }
                .foregroundStyle(Palette.teal).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PixelRobot(running: store.visible && animationEnabled).frame(width: 202, height: 190).padding(.trailing, -11)
        }
        .frame(height: 185).padding(.top, 8)
    }

    @ViewBuilder private var accountContent: some View {
        if let account = store.selected {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Palette.teal.opacity(0.09)).frame(width: 38, height: 38)
                        Text(String(account.label.prefix(1)).uppercased()).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(Palette.teal)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(account.planLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.teal)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(Palette.teal.opacity(0.08), in: Capsule())
                        }
                        Text(account.alias.isEmpty ? (account.accountName ?? "个人账号") : account.email)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    accountAction(account)
                }
                HStack(alignment: .top, spacing: 20) {
                    quota("5 小时", window: account.fiveHour)
                    Rectangle().fill(.primary.opacity(0.07)).frame(width: 1, height: 83).padding(.top, 5)
                    quota("每周", window: account.weekly)
                }
                HStack {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text("额度快照 · " + DisplayTime.relative(account.updatedAt)).font(.system(size: 10))
                    Spacer()
                    if min(account.fiveHour?.remaining ?? 100, account.weekly?.remaining ?? 100) <= 10 {
                        Text("额度偏低").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.coral)
                    }
                }.foregroundStyle(.secondary)
            }
            .padding(17).cardSurface()
            subscriptionCard(account)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("我的账号").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%02d", store.accounts.count)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 2)
                VStack(spacing: 2) { ForEach(store.orderedAccounts) { item in accountRow(item) } }
            }

        } else {
            emptyState("还没有保存的账号", detail: "先在终端运行 codex-auth login，完成登录后刷新。", icon: "person.crop.circle.badge.plus")
        }
    }

    private func accountAction(_ account: AccountRecord) -> some View {
        // Reserve the same header space for status and action so previewing an
        // inactive account never inserts content or shifts the cards below it.
        ZStack {
            if account.id == store.activeKey {
                Text("当前登录").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.teal)
            } else {
                Button { Task { await store.switchSelected() } } label: {
                    Label("切换", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.glass).controlSize(.small).disabled(!store.switchAvailable)
                .accessibilityLabel("切换到 " + account.label)
                .accessibilityHint("切换后请手动重启 Codex。")
                .help(store.demo ? "演示模式不会切换真实账号" : "切换登录文件后，请手动重启 Codex。重名账号需先设置唯一别名。")
            }
        }
        .frame(width: 64, height: 28)
    }

    private func quota(_ title: String, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title + "剩余").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(window.map { String(format: "%.0f", $0.remaining) } ?? "—")
                    .font(.system(size: 35, weight: .medium, design: .rounded)).monospacedDigit().tracking(-1.4)
                if window != nil { Text("%").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary) }
            }
            .foregroundStyle((window?.remaining ?? 100) <= 10 ? Palette.coral : Color.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + (window.map { "剩余 \(Int($0.remaining))%" } ?? "暂无数据"))
            DotMeter(remaining: window?.remaining)
            Text(window == nil ? "暂无数据" : DisplayTime.reset(window?.resetDate))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subscriptionCard(_ account: AccountRecord) -> some View {
        let snapshot = store.subscriptions[account.id]
        let days = snapshot?.until.map { Int(floor($0.timeIntervalSinceNow / 86400)) }
        return HStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 15, weight: .light)).foregroundStyle(Palette.teal)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("订阅快照").font(.system(size: 11, weight: .medium))
                    if let days, days >= 0 { Text("记录剩余 \(days) 天").font(.system(size: 10)).foregroundStyle(days <= 3 ? Palette.coral : .secondary) }
                    else if days != nil { Text("旧快照，待更新").font(.system(size: 10)).foregroundStyle(Palette.coral) }
                }
                Text(snapshot?.until == nil ? "登录快照中未提供日期" : "截至 " + DisplayTime.full(snapshot?.until))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("来自已保存的登录信息，不是账单续费日期。时间为本地时间。\n上次核验：" + DisplayTime.full(snapshot?.checked))
        }
        .padding(13).cardSurface()
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        Button { store.selectedKey = account.id; store.notice = nil } label: {
            HStack(spacing: 9) {
                Circle().fill(account.id == store.activeKey ? Palette.teal : Color.secondary.opacity(0.3)).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let name = account.accountName, !name.isEmpty { Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(account.planLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                Image(systemName: account.id == store.selectedKey ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: account.id == store.selectedKey ? 12 : 9)).foregroundStyle(account.id == store.selectedKey ? Palette.teal : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(account.id == store.selectedKey ? Palette.teal.opacity(0.065) : Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).accessibilityLabel("查看 " + account.label)
        .accessibilityAddTraits(account.id == store.selectedKey ? [.isSelected] : [])
    }

    @ViewBuilder private var newsContent: some View {
        HStack {
            Text("公共重置公告").font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(store.newsStale ? "缓存 · " + DisplayTime.relative(store.newsChecked) : DisplayTime.relative(store.newsChecked))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if store.news.isEmpty {
            emptyState(store.newsChecked == nil ? "等待第一条消息" : "暂无重置动态", detail: "点右上角刷新，读取最新的公共重置公告。", icon: "sparkles")
        } else {
            ForEach(store.news) { item in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: item.kind == .announced ? "arrow.counterclockwise.circle.fill" : item.kind == .planned ? "calendar.badge.clock" : "sparkles")
                            .font(.system(size: 20, weight: .light)).foregroundStyle(item.kind == .forecast ? Palette.coral : Palette.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Text(item.date == nil ? "具体时间待定" : DisplayTime.full(item.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let url = item.url {
                        Link(destination: url) {
                            HStack(spacing: 4) { Text("查看原公告"); Image(systemName: "arrow.up.right") }.font(.system(size: 10, weight: .medium))
                        }.buttonStyle(.plain).foregroundStyle(Palette.teal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
            }
        }
        Text("公共公告不代表你的账号拥有重置次数。具体资格与余额以 Codex 为准。")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Link(destination: URL(string: "https://codex-resets.com")!) {
            Label("消息来源 · Codex Resets", systemImage: "arrow.up.right.square").font(.system(size: 10))
        }.foregroundStyle(.secondary)
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("按你的节奏。").font(.system(size: 25, weight: .semibold)).padding(.top, 15)
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $animationEnabled) { preferenceLabel("像素动画", detail: "呼吸、扫描与轻微悬停响应") }
                Divider()
                Toggle(isOn: $proxyEnabled) { preferenceLabel("使用本地代理", detail: "127.0.0.1:7890 · 下次刷新生效") }.disabled(store.busy)
                Divider()
                Toggle(isOn: Binding(get: { loginEnabled }, set: { enabled in
                    guard !store.demo else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    } catch { store.error = "登录启动设置未完成，请在系统设置中检查登录项。" }
                })) { preferenceLabel("登录时启动", detail: "只显示菜单栏图标，不弹出面板") }.disabled(store.demo)
            }
            .toggleStyle(.switch).controlSize(.small).padding(17).cardSurface()
            Text("面板收起后，动画和网络轮询会暂停。系统的“减少动态效果”和“降低透明度”设置同样有效。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("账号来自本机 Codex 登录文件。切换账号后，请手动重启 Codex。这里不会领取或消耗重置次数。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.error { message(error, warning: true) }
            Link(destination: URL(string: "https://github.com/procaross/codex-auth")!) {
                Label("开源项目", systemImage: "arrow.up.right.square").font(.system(size: 12))
            }
            Button("退出 Codex Auth", action: quit).buttonStyle(.glass)
        }
    }

    private func preferenceLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(Palette.teal.opacity(0.65)).frame(width: 4, height: 4)
            Text(store.demo ? "演示数据 · 不连接真实账号" : "本机账号 · " + (proxyEnabled ? "代理 7890" : "直接连接"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Button("收起", action: close).font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24).padding(.vertical, 13).background(.primary.opacity(0.025))
    }

    private func message(_ text: String, warning: Bool) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.circle" : "checkmark.circle")
            .font(.system(size: 11)).foregroundStyle(warning ? Palette.coral : Palette.teal)
            .fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((warning ? Palette.coral : Palette.teal).opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Palette.teal)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 20).cardSurface()
    }
}

private extension View {
    func cardSurface() -> some View {
        self.background(.background.opacity(0.36), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.045), lineWidth: 0.7))
    }
}
