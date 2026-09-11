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
    @State private var editingAccount: AccountRecord?
    let close: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 22).padding(.top, 18)
            if store.settings {
                ScrollView {
                    preferences.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                hero.padding(.horizontal, 22)
                SystemTabs(selection: $store.tab).padding(.horizontal, 22).padding(.bottom, 15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if let error = store.error ?? store.refreshError { message(error, warning: true) }
                        if let notice = store.notice { message(notice, warning: false) }
                        if store.tab == 0 { accountContent }
                        else if store.tab == 1 { newsContent }
                        else { StatisticsView(store: store) }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 18)
                }
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
        .sheet(item: $editingAccount) { account in
            AccountEditor(store: store, account: account)
        }
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
            .disabled(store.busy).keyboardShortcut("r").help("刷新额度、重置消息与本地统计").accessibilityLabel("刷新")
            Button { withAnimation(.easeInOut(duration: 0.18)) { store.settings.toggle() } } label: {
                Image(systemName: store.settings ? "xmark" : "slider.horizontal.3").frame(width: 14, height: 14)
            }
            .help(store.settings ? "返回" : "设置").accessibilityLabel(store.settings ? "返回" : "设置")
            .disabled(store.loginPhase != nil)
        }
        .buttonStyle(.glass).controlSize(.small).tint(nil as Color?)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.loginPhase == .waiting ? "等待登录" : store.loginPhase == .saving ? "正在保存" : store.tab == 0 ? "账号管理" : store.tab == 1 ? "重置动态" : "本机调用")
                    .font(.system(size: 21, weight: .semibold))
                Text(store.loginPhase == .waiting ? "请在浏览器中完成授权" : store.loginPhase == .saving ? "正在更新账号列表" : store.tab == 0 ? "\(store.orderedAccounts.count) 个账号 · 每周额度" : store.tab == 1 ? "来自 Codex Resets" : "Token 用量与 API 等价成本")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let phase = store.loginPhase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        if phase == .waiting {
                            Button("取消") { store.cancelLogin() }.buttonStyle(.glass).controlSize(.small)
                                .accessibilityLabel("取消添加账号")
                        }
                    }.frame(height: 25)
                } else if store.tab == 0 {
                    Button { store.addAccount() } label: {
                        Label("添加账号", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.glass).controlSize(.small).disabled(!store.addAvailable)
                    .help(store.demo ? "演示模式不会打开真实登录" : "在浏览器登录，只添加到列表，不切换当前账号。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PixelRobot(running: store.visible && animationEnabled).frame(width: store.tab == 2 ? 112 : 168, height: store.tab == 2 ? 90 : 140)
        }
        .frame(height: store.tab == 2 ? 90 : 140).padding(.vertical, 4)
    }

    @ViewBuilder private var accountContent: some View {
        if let account = store.selected {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.label(account)).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(account.email)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text(account.planLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.teal)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Palette.teal.opacity(0.08), in: Capsule()).fixedSize()
                        if store.label(account) != account.email {
                            Text(account.email).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(account.email)
                        } else if let name = account.accountName, !name.isEmpty {
                            Text(name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        accountAction(account)
                    }
                }
                quota("每周", window: account.weekly)
                HStack {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text(DisplayTime.relative(account.updatedAt)).font(.system(size: 10))
                        .help("额度更新时间：" + DisplayTime.full(account.updatedAt))
                    Spacer()
                    if (account.weekly?.remaining ?? 100) <= Double(store.companion.lowThreshold) {
                        Text("额度偏低").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.coral)
                    }
                }.foregroundStyle(.secondary)
            }
            .padding(17).cardSurface()
            QuotaHistoryView(points: store.companion.history[account.id] ?? [])
            subscriptionCard(account)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("账号列表").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("每周剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                VStack(spacing: 2) { ForEach(store.orderedAccounts) { item in accountRow(item) } }
            }

        } else {
            emptyState("还没有保存的账号", detail: "点击上方「添加账号」，在浏览器登录后会自动显示在这里。", icon: "person.crop.circle.badge.plus")
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
                .accessibilityLabel("切换到 " + store.label(account))
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
            .foregroundStyle(window == nil ? Color.secondary : ((window?.remaining ?? 100) <= Double(store.companion.lowThreshold) ? Palette.coral : Color.primary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + (window.map { "剩余 \(Int($0.remaining))%" } ?? "暂无数据"))
            DotMeter(remaining: window?.remaining, threshold: Double(store.companion.lowThreshold))
            Text(window == nil ? "未提供此项数据" : DisplayTime.reset(window?.resetDate))
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
                    Text("订阅记录").font(.system(size: 11, weight: .medium))
                    if let days, days >= 0 { Text("剩余 \(days) 天").font(.system(size: 10)).foregroundStyle(days <= 3 ? Palette.coral : .secondary) }
                    else if days != nil { Text("记录已过期").font(.system(size: 10)).foregroundStyle(Palette.coral) }
                }
                Text(snapshot?.until == nil ? "未提供有效期" : "记录有效至 " + DisplayTime.full(snapshot?.until))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("登录时保存的有效期，并非账单续费日期。时间为本地时间。\n上次核验：" + DisplayTime.full(snapshot?.checked))
        }
        .padding(13).cardSurface()
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        HStack(spacing: 0) {
          Button { store.selectedKey = account.id; store.dismissNotice() } label: {
            HStack(spacing: 9) {
                Circle().fill(account.id == store.activeKey ? Palette.teal : Color.secondary.opacity(0.3)).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.label(account)).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(store.note(account).isEmpty ? (account.id == store.activeKey ? "当前登录 · " : "") + account.planLabel : store.note(account))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(account.weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle((account.weekly?.remaining ?? 100) <= Double(store.companion.lowThreshold) ? Palette.coral : Palette.teal)
                    .frame(width: 38, alignment: .trailing)
                Image(systemName: account.id == store.selectedKey ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: account.id == store.selectedKey ? 12 : 9)).foregroundStyle(account.id == store.selectedKey ? Palette.teal : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).accessibilityLabel("查看 " + store.label(account))
        .accessibilityValue(account.id == store.activeKey ? "当前登录" : "已保存")
        .help(account.email + (account.id == store.activeKey ? "\n当前登录账号" : "\n点击查看额度，切换需使用卡片内的按钮。"))
        .accessibilityAddTraits(account.id == store.selectedKey ? [.isSelected] : [])
          Menu {
              Button("编辑名称与备注") { editingAccount = account }
              Button("上移") { store.move(account, by: -1) }.disabled(store.orderedAccounts.first?.id == account.id)
              Button("下移") { store.move(account, by: 1) }.disabled(store.orderedAccounts.last?.id == account.id)
              Divider()
              Button("隐藏此账号") { store.hide(account, hidden: true) }.disabled(account.id == store.activeKey)
          } label: { Image(systemName: "ellipsis").frame(width: 20, height: 28) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 6)
          .accessibilityLabel("管理 " + store.label(account))
        }
        .background(account.id == store.selectedKey ? Palette.teal.opacity(0.065) : Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder private var newsContent: some View {
        HStack {
            Text("公共消息").font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(store.newsStale ? "缓存 · " + DisplayTime.relative(store.newsChecked) : DisplayTime.relative(store.newsChecked))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if store.news.isEmpty {
            emptyState(store.newsChecked == nil ? "尚未加载" : "暂无重置动态", detail: "点击右上角刷新。", icon: "arrow.counterclockwise")
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
                            HStack(spacing: 4) { Text("查看来源"); Image(systemName: "arrow.up.right") }.font(.system(size: 10, weight: .medium))
                        }.buttonStyle(.plain).foregroundStyle(Palette.teal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
            }
        }
        Text("个人可用重置次数请在 Codex 中查看。")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Link(destination: URL(string: "https://codex-resets.com")!) {
            Label("消息来源 · Codex Resets", systemImage: "arrow.up.right.square").font(.system(size: 10))
        }.foregroundStyle(.secondary)
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("设置").font(.system(size: 21, weight: .semibold)).padding(.top, 8)
            CompanionPreferences(store: store)
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $animationEnabled) { preferenceLabel("像素动画", detail: "关闭后显示静态图像") }
                    .accessibilityLabel("像素动画").accessibilityHint("关闭后显示静态图像")
                Divider()
                Toggle(isOn: $proxyEnabled) { preferenceLabel("使用本地代理", detail: "127.0.0.1:7890 · 下次刷新生效") }.disabled(store.busy)
                    .accessibilityLabel("使用本地代理").accessibilityHint("127.0.0.1:7890，下次刷新生效")
                Divider()
                Toggle(isOn: Binding(get: { loginEnabled }, set: { enabled in
                    guard !store.demo else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    } catch { store.error = "登录启动设置未完成，请在系统设置中检查登录项。" }
                })) { preferenceLabel("登录时启动", detail: "启动后显示在菜单栏") }.disabled(store.demo)
                    .accessibilityLabel("登录时启动").accessibilityHint("启动后显示在菜单栏")
            }
            .toggleStyle(.switch).controlSize(.small).padding(17).cardSurface()
            Text("后台约每 5 分钟刷新额度与重置动态，电脑唤醒后会补刷。收起面板后暂停动画。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("切换账号后需手动重启 Codex。重置动态仅供查看，不会领取或消耗重置次数。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.error ?? store.refreshError { message(error, warning: true) }
            if let notice = store.notice { message(notice, warning: false) }
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
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(store.demo ? "演示数据" : "切换账号后需重启 Codex")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("收起", action: close).font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24).padding(.vertical, 13).background(.primary.opacity(0.025))
    }

    private func message(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(text, systemImage: warning ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if !warning {
                Button { store.dismissNotice() } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 18)
                }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
            }
        }
        .foregroundStyle(warning ? Palette.coral : Palette.teal).padding(12)
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

extension View {
    func cardSurface() -> some View {
        self.background(.background.opacity(0.36), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.045), lineWidth: 0.7))
    }
}
