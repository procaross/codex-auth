import AppKit
import SwiftUI

enum CommandError: Error { case missingExecutable, failed, timedOut }

final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Process?

    func stop() {
        lock.lock(); let process = running; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func run(executable: URL, arguments: [String], home: URL, proxy: Bool, timeout: Double = 50) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
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
                    try process.run()
                    self.lock.lock(); self.running = process; self.lock.unlock()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    // This runs off the main thread; the panel stays responsive.
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    let expired = process.isRunning
                    if expired {
                        process.terminate()
                        Thread.sleep(forTimeInterval: 0.25)
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    self.lock.lock(); self.running = nil; self.lock.unlock()
                    if expired { throw CommandError.timedOut }
                    if process.terminationStatus != 0 { throw CommandError.failed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
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
    @Published var notice: String?
    @Published var tab = 0
    @Published var settings = false
    let demo: Bool
    let codexHome: URL
    let runner = CommandRunner()
    var onChange: (() -> Void)?
    private var lastAttempt = Date.distantPast
    private var registryReadable = true

    init(demo: Bool = false) {
        self.demo = demo
        let customHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        codexHome = customHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
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
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("codex-auth"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/codex-auth-fork/bin/codex-auth")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    var switchAvailable: Bool {
        guard !demo, !busy, registryReadable, let selected, selected.authMode != "apikey", selected.id != activeKey, executable != nil else { return false }
        return LocalData.switchQuery(for: selected, in: accounts) != nil
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
        if Date().timeIntervalSince(lastAttempt) > 300 { Task { await refresh() } }
    }

    func refresh() async {
        guard !busy else { return }
        if demo {
            busy = true
            try? await Task.sleep(for: .milliseconds(450))
            busy = false
            return
        }
        guard let executable else { error = "未找到 codex-auth。请用构建脚本打包本分支的 CLI。"; return }
        busy = true; error = nil; notice = nil; lastAttempt = Date()
        defer { busy = false; onChange?() }
        var failures: [String] = []
        do {
            try await runner.run(executable: executable, arguments: ["list", "--api"], home: codexHome, proxy: proxyEnabled)
        } catch { failures.append("额度刷新失败") }
        reload()
        do {
            try await runner.run(executable: executable, arguments: ["resets", "--json"], home: codexHome, proxy: proxyEnabled)
        } catch { failures.append("重置消息刷新失败") }
        reloadNews()
        if !failures.isEmpty { error = failures.joined(separator: "，") + "。正在显示缓存；请检查网络、代理或 Node.js。" }
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
