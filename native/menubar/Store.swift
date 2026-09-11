import AppKit
import SwiftUI

enum CommandError: Error { case missingExecutable, failed, timedOut }

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Process?

    func stop() {
        lock.lock(); let process = running; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func run(executable: URL, arguments: [String], home: URL, proxy: Bool, timeout: Double = 50, workingDirectory: URL? = nil) async throws {
        let cancellation = CommandCancellation()
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                environment["CODEX_HOME"] = home.path
                environment["NO_COLOR"] = "1"
                environment["TERM"] = "dumb"
                for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                    environment[key] = proxy ? "http://127.0.0.1:7890" : nil
                }
                environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
                environment["no_proxy"] = environment["NO_PROXY"]
                environment["NODE_USE_ENV_PROXY"] = "1"
                process.environment = environment
                do {
                    if cancellation.isCancelled { throw CancellationError() }
                    try process.run()
                    self.lock.lock(); self.running = process; self.lock.unlock()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    // This runs off the main thread; the panel stays responsive.
                    while process.isRunning && !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    let expired = process.isRunning
                    if expired {
                        process.terminate()
                        Thread.sleep(forTimeInterval: 0.25)
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    self.lock.lock(); self.running = nil; self.lock.unlock()
                    if cancellation.isCancelled { throw CancellationError() }
                    if expired { throw CommandError.timedOut }
                    if process.terminationStatus != 0 { throw CommandError.failed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
          }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var accounts: [AccountRecord] = []
    @Published var activeKey: String?
    @Published var selectedKey: String?
    @Published var subscriptions: [String: SubscriptionSnapshot] = [:]
    @Published var news: [NewsItem] = []
    @Published var newsChecked: Date?
    @Published var newsStale = true
    @Published var busy = false
    @Published var visible = false
    @Published var error: String?
    @Published var refreshError: String?
    @Published var notice: String?
    @Published var tab = 0
    @Published var settings = false
    @Published var loginPhase: AccountLoginPhase?
    let demo: Bool
    let codexHome: URL
    let runner = CommandRunner()
    var onChange: (() -> Void)?
    private var lastAttempt = Date.distantPast
    private var registryReadable = true
    private var loginTask: Task<Void, Never>?
    private let cliOverride: URL?
    private let now: () -> Date
    private var stopping = false

    init(demo: Bool = false, home: URL? = nil, cli: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.demo = demo
        self.cliOverride = cli
        self.now = now
        let customHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        codexHome = home ?? customHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        if demo { loadDemo() } else { reload() }
    }

    var selected: AccountRecord? { accounts.first { $0.id == selectedKey } }
    var active: AccountRecord? { accounts.first { $0.id == activeKey } }
    var orderedAccounts: [AccountRecord] {
        accounts.filter { $0.id == activeKey } + accounts.filter { $0.id != activeKey }
    }
    var proxyEnabled: Bool { UserDefaults.standard.object(forKey: "proxyEnabled") as? Bool ?? true }
    var executable: URL? {
        if let cliOverride { return cliOverride }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("codex-auth"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/codex-auth-fork/bin/codex-auth")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    var switchAvailable: Bool {
        guard !demo, !busy, registryReadable, let selected, selected.authMode != "apikey", selected.id != activeKey, executable != nil else { return false }
        return LocalData.switchQuery(for: selected, in: accounts) != nil
    }
    var addAvailable: Bool { !demo && !busy && registryReadable }

    func addAccount() {
        guard addAvailable else { return }
        guard let executable else { error = "未找到 codex-auth，请重新安装菜单栏应用。"; return }
        guard let codex = AccountLogin.findCodex() else {
            error = "添加账号需要官方 Codex CLI。请先安装：npm install -g @openai/codex"; return
        }
        let existing = Set(accounts.map(\.id))
        busy = true; error = nil; notice = nil; loginPhase = .waiting; settings = false; tab = 0
        loginTask = Task {
            defer { busy = false; loginPhase = nil; loginTask = nil; onChange?() }
            do {
                let key = try await AccountLogin.add(codex: codex, importer: executable, home: codexHome, proxy: proxyEnabled) {
                    self.loginPhase = .saving
                }
                reload()
                selectedKey = key
                notice = existing.contains(key) ? "已更新这个账号的登录信息。" : "账号已添加，点击「切换」即可使用。"
            } catch is CancellationError {
                notice = "已取消添加账号。"
            } catch CommandError.timedOut {
                error = loginPhase == .waiting ? "登录等待超时，请重新添加账号。" : "保存超时，请刷新检查账号列表后重试。"
            } catch {
                self.error = loginPhase == .waiting ? "登录未完成，请检查网络或代理后重试。若已有其他登录窗口，请先结束那次登录。" : "账号保存未完成，请刷新检查账号列表后重试。"
                reload()
            }
        }
    }

    func cancelLogin() {
        guard loginPhase == .waiting else { return }
        loginTask?.cancel()
    }

    func stop() {
        stopping = true
        loginTask?.cancel()
        runner.stop()
    }

    func finishLoginForQuit() async {
        // Keep the app alive until the login listener exits and its private
        // scratch directory is removed. Let an import already saving finish.
        if loginPhase == .waiting { loginTask?.cancel() }
        await loginTask?.value
    }

    func reload() {
        guard !demo else { return }
        do {
            let registry = try LocalData.registry(home: codexHome)
            accounts = registry.accounts
            registryReadable = true
            // auth.json is the selected CLI login; registry may lag behind it.
            activeKey = LocalData.metadata(at: codexHome.appendingPathComponent("auth.json"))?.key
            if !accounts.contains(where: { $0.id == selectedKey }) { selectedKey = active?.id ?? accounts.first?.id }
            subscriptions = [:]
            for account in accounts {
                subscriptions[account.id] = LocalData.subscription(for: account, home: codexHome, activeKey: activeKey)
            }
        } catch {
            registryReadable = false
            self.error = "账号文件暂时无法读取，保留上次显示。请检查文件后刷新。"
        }
        reloadNews()
        onChange?()
    }

    private func reloadNews() {
        let url = codexHome.appendingPathComponent("reset-news/state.json")
        if let data = try? LocalData.boundedData(url), let cache = try? LocalData.decoder.decode(ResetCache.self, from: data) {
            news = NewsItem.items(from: cache.status?.data)
            newsChecked = cache.checkedDate
            newsStale = cache.lastError != nil || Date().timeIntervalSince(newsChecked ?? .distantPast) > 300
        } else { newsStale = true }
    }

    func opened() {
        visible = true
        reload()
        Task { await refreshIfNeeded() }
    }

    func refreshIfNeeded() async {
        guard !demo, !busy, !stopping else { return }
        let age = now().timeIntervalSince(lastAttempt)
        // A clock adjustment must not postpone updates indefinitely. Busy ticks
        // do not advance lastAttempt, so the next idle tick can catch up.
        guard age >= 300 || age < 0 else { return }
        await refresh(automatically: true)
    }

    func refresh(automatically: Bool = false) async {
        guard !busy, !stopping else { return }
        if demo {
            busy = true
            try? await Task.sleep(for: .milliseconds(450))
            busy = false
            return
        }
        guard let executable else { refreshError = "未找到 codex-auth。请用构建脚本打包本分支的 CLI。"; return }
        busy = true; refreshError = nil; lastAttempt = now()
        // Background maintenance must not erase login/switch feedback.
        if !automatically { error = nil; notice = nil }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Refresh Codex account quota")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        defer { busy = false; onChange?() }
        var failures: [String] = []
        do {
            try await runner.run(executable: executable, arguments: ["list", "--api"], home: codexHome, proxy: proxyEnabled)
        } catch { failures.append("额度刷新失败") }
        guard !stopping, !Task.isCancelled else { return }
        reload()
        do {
            try await runner.run(executable: executable, arguments: ["resets", "--json"], home: codexHome, proxy: proxyEnabled)
        } catch { failures.append("重置消息刷新失败") }
        reloadNews()
        if !failures.isEmpty { refreshError = failures.joined(separator: "，") + "。正在显示缓存；请检查网络、代理或 Node.js。" }
    }

    func switchSelected() async {
        guard switchAvailable, let target = selected, let executable else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false; onChange?() }
        do {
            let fresh = try LocalData.registry(home: codexHome)
            guard let record = fresh.accounts.first(where: { $0.id == target.id }),
                  let query = LocalData.switchQuery(for: record, in: fresh.accounts) else {
                error = "这个账号无法唯一匹配，请先在 CLI 中设置唯一别名。"; return
            }
            try await runner.run(executable: executable, arguments: ["switch", query], home: codexHome, proxy: proxyEnabled, timeout: 15)
            reload()
            guard activeKey == target.id else { error = "未能确认账号已切换，请刷新后检查。"; return }
            notice = "登录文件已切换。请手动重启 Codex，让 App 使用这个账号。"
        } catch { self.error = "切换未完成，请刷新后检查账号状态。"; reload() }
    }

    private func loadDemo() {
        let now = Date().timeIntervalSince1970
        let json = """
        {"schema_version":3,"active_account_key":"demo::nova","accounts":[
          {"account_key":"demo::nova","email":"nova@example.test","alias":"Nova","account_name":null,"plan":"pro","auth_mode":"chatgpt","last_usage_at":\(now),"last_usage":{"primary":{"used_percent":16,"window_minutes":300,"resets_at":\(now+8040)},"secondary":{"used_percent":32,"window_minutes":10080,"resets_at":\(now+190800)}}},
          {"account_key":"demo::orbit","email":"orbit@example.test","alias":"Orbit","account_name":"Personal","plan":"plus","auth_mode":"chatgpt","last_usage_at":\(now-180),"last_usage":{"primary":{"used_percent":91,"window_minutes":300,"resets_at":\(now+2220)},"secondary":{"used_percent":76,"window_minutes":10080,"resets_at":\(now+362400)}}}
        ]}
        """
        guard let registry = try? LocalData.decoder.decode(RegistryFile.self, from: Data(json.utf8)) else { return }
        accounts = registry.accounts; activeKey = registry.activeAccountKey; selectedKey = activeKey
        subscriptions["demo::nova"] = SubscriptionSnapshot(until: Date(timeIntervalSince1970: now + 23 * 86400), checked: Date(timeIntervalSince1970: now - 7200))
        subscriptions["demo::orbit"] = SubscriptionSnapshot(until: Date(timeIntervalSince1970: now + 8 * 86400), checked: Date(timeIntervalSince1970: now - 86400))
        newsChecked = Date(); newsStale = false
        news = [NewsItem(id: "demo-news", kind: .announced, title: "备用重置次数已公告", detail: "适用范围与领取条件请查看原公告。", date: Date(timeIntervalSince1970: now - 3600), source: "https://codex-resets.com")]
    }
}
