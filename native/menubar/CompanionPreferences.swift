import SwiftUI

struct CompanionPreferences: View {
    @ObservedObject var store: AppStore
    private func preference<T>(_ key: WritableKeyPath<CompanionState, T>) -> Binding<T> {
        Binding(get: { store.companion[keyPath: key] }, set: { value in store.updatePreferences { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("菜单栏显示", selection: preference(\.statusDisplay)) {
                ForEach(StatusDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 12))
            Divider()
            Toggle("周额度系统通知", isOn: preference(\.notificationsEnabled))
                .onChange(of: store.companion.notificationsEnabled) { Task { await store.configureNotifications() } }
            if store.companion.notificationsEnabled {
                Picker("提醒阈值", selection: preference(\.lowThreshold)) {
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                Toggle("额度恢复时提醒", isOn: preference(\.recoveryEnabled))
                Toggle("包含其他可见账号", isOn: preference(\.notifyAllAccounts))
                Text("默认只提醒当前登录账号；每周期提醒一次，降至 5% 时再提醒一次。首次读取不发通知。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(store.notificationStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("测试通知") { Task { await store.testNotification() } }.buttonStyle(.glass).disabled(store.demo)
                }
                Link("打开系统通知设置", destination: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    .font(.system(size: 10))
            }
            let hidden = store.accounts.filter { store.companion.accounts[$0.id]?.hidden == true && $0.id != store.activeKey }
            if !hidden.isEmpty {
                Divider()
                Text("已隐藏账号").font(.system(size: 11, weight: .medium))
                ForEach(hidden) { account in
                    HStack {
                        Text(store.label(account)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("恢复显示") { store.hide(account, hidden: false) }.buttonStyle(.glass)
                    }.font(.system(size: 10))
                }
            }
        }.font(.system(size: 11)).toggleStyle(.switch).controlSize(.small).padding(17).cardSurface()
        .task { if let notifications = store.notifications { store.notificationStatus = await notifications.authorization() } }
    }
}

struct AccountEditor: View {
    @ObservedObject var store: AppStore
    let account: AccountRecord
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑账号").font(.system(size: 17, weight: .semibold))
            Text(account.email).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("显示名称", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("显示名称")
                .onChange(of: name) { name = String(name.prefix(40)) }
            TextField("备注", text: $note).textFieldStyle(.roundedBorder).accessibilityLabel("备注")
                .onChange(of: note) { note = String(note.prefix(160)) }
            Text("仅用于本机面板。留空名称则使用原有名称或邮箱。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { store.decorate(account, name: name, note: note); dismiss() }.keyboardShortcut(.defaultAction)
            }.buttonStyle(.glass)
        }.padding(22).frame(width: 330)
        .onAppear { name = store.companion.accounts[account.id]?.name ?? ""; note = store.note(account) }
    }
}
