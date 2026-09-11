import Foundation

@main enum MenuBarTests {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: " + name) }
        count += 1
        print("PASS: " + name)
    }

    static func record(_ key: String, email: String, alias: String = "") -> AccountRecord {
        AccountRecord(accountKey: key, email: email, alias: alias, accountName: nil, plan: "pro", authMode: "chatgpt", lastUsage: nil, lastUsageAt: nil)
    }

    static func auth(user: String = "user", account: String = "account", tokenAccount: String = "account", date: String? = "2026-10-04T11:13:00+08:00") throws -> Data {
        var claims: [String: Any] = ["chatgpt_user_id": user, "chatgpt_account_id": account]
        if let date { claims["chatgpt_subscription_active_until"] = date }
        let body = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": claims, "email": user + "@example.test", "exp": 1])
        let payload = body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": tokenAccount, "id_token": "header." + payload + ".signature"]])
    }

    static func script(_ name: String, at root: URL, body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func loginChecks(at root: URL) async throws {
        let fm = FileManager.default
        let scratchRoot = root.appendingPathComponent("login scratch")
        func scratchIsEmpty() -> Bool { (try? fm.contentsOfDirectory(atPath: scratchRoot.path))?.isEmpty == true }
        let target = root.appendingPathComponent("target")
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: target.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        let original = try auth(user: "original")
        try original.write(to: target.appendingPathComponent("auth.json"))
        let fixture = root.appendingPathComponent("new-auth.json")
        try auth().write(to: fixture)
        let registry = root.appendingPathComponent("new-registry.json")
        try Data("{\"schema_version\":3,\"active_account_key\":\"original::account\",\"accounts\":[{\"account_key\":\"user::account\",\"email\":\"new@example.test\",\"alias\":\"\"}]}".utf8).write(to: registry)
        let login = try script("fake-login", at: root, body: """
        test "$#" -eq 3
        test "$1" = login
        test "$2" = -c
        test "$3" = 'cli_auth_credentials_store="file"'
        test "$CODEX_HOME" != \(quoted(target.path))
        test "$(/usr/bin/stat -f %Lp "$CODEX_HOME")" = 700
        test "$(pwd -P)" = "$(cd "$CODEX_HOME" && pwd -P)"
        /bin/cp \(quoted(fixture.path)) "$CODEX_HOME/auth.json"
        """)
        let marker = root.appendingPathComponent("imported")
        let importer = try script("fake-import", at: root, body: """
        test "$#" -eq 2
        test "$1" = import
        test "$CODEX_HOME" = \(quoted(target.path))
        test -f "$2"
        /bin/cp \(quoted(registry.path)) "$CODEX_HOME/accounts/registry.json"
        /usr/bin/touch \(quoted(marker.path))
        """)
        let key = try await AccountLogin.add(codex: login, importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
        expect(key == "user::account", "browser login uses private file storage and add-only import")
        let after = try Data(contentsOf: target.appendingPathComponent("auth.json"))
        expect(after == original, "adding an account preserves the active login byte for byte")
        expect(scratchIsEmpty(), "successful login removes temporary credentials")
        try fm.removeItem(at: marker)
        do {
            _ = try await AccountLogin.add(codex: URL(fileURLWithPath: "/usr/bin/false"), importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
            fatalError("accepted failed login")
        } catch { expect(!fm.fileExists(atPath: marker.path), "failed login never imports") }
        do {
            _ = try await AccountLogin.add(codex: URL(fileURLWithPath: "/usr/bin/true"), importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
            fatalError("accepted login without credentials")
        } catch { expect(!fm.fileExists(atPath: marker.path), "missing credentials never import") }
        do {
            _ = try await AccountLogin.add(codex: login, importer: URL(fileURLWithPath: "/usr/bin/false"), home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
            fatalError("accepted import failure")
        } catch { expect(true, "import failure is surfaced") }
        expect(scratchIsEmpty(), "failed flows remove temporary credentials")

        let pidFile = root.appendingPathComponent("login-pid")
        let slowLogin = try script("slow-login", at: root, body: """
        echo $$ > \(quoted(pidFile.path))
        trap '' TERM
        exec /bin/sleep 20
        """)
        let task = Task {
            try await AccountLogin.add(codex: slowLogin, importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
        }
        for _ in 0..<100 {
            if fm.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(fm.fileExists(atPath: pidFile.path), "cancellation test starts a live login process")
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        task.cancel()
        do { _ = try await task.value; fatalError("accepted cancelled login") }
        catch is CancellationError { expect(true, "cancel reaches the login operation") }
        expect(kill(pid, 0) == -1 && errno == ESRCH, "cancellation kills even a login ignoring SIGTERM")
        expect(!fm.fileExists(atPath: marker.path), "cancelled login never imports")
        expect(scratchIsEmpty(), "cancellation cleans temporary credentials")

        let beforeCancel = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AccountLogin.add(codex: login, importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, willImport: {})
        }
        do { _ = try await beforeCancel.value; fatalError("accepted pre-cancelled login") }
        catch is CancellationError { expect(true, "cancellation before launch is honored") }
        let start = Date()
        do {
            _ = try await AccountLogin.add(codex: slowLogin, importer: importer, home: target, proxy: false, temporaryRoot: scratchRoot, timeout: 0.15, willImport: {})
            fatalError("accepted login timeout")
        } catch CommandError.timedOut { expect(Date().timeIntervalSince(start) < 3, "browser login has a bounded timeout") }
        expect(scratchIsEmpty(), "timeout cleans temporary credentials")
        expect(AccountLogin.findCodex(candidates: [URL(fileURLWithPath: "/usr/bin/true")]) != nil, "native CLI discovery works")
        expect(AccountLogin.findCodex(candidates: [login]) == nil, "arbitrary shell wrappers are not launched as native login processes")
        #if arch(arm64)
        let vendor = "codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #else
        let vendor = "codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        #endif
        let package = root.appendingPathComponent("npm/@openai/codex")
        let native = package.appendingPathComponent("node_modules/@openai/" + vendor)
        try fm.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: native)
        expect(AccountLogin.findCodex(candidates: [package.appendingPathComponent("bin/codex.js")]) == native, "npm launcher resolves to its native child")
    }

    static func importIntegration(at root: URL, executable: URL) async throws {
        let fm = FileManager.default
        let target = root.appendingPathComponent("integration")
        try fm.createDirectory(at: target.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        try Data("{\"schema_version\":3,\"api\":{\"usage\":false,\"account\":false},\"accounts\":[]}".utf8)
            .write(to: target.appendingPathComponent("accounts/registry.json"))
        let oldAuth = root.appendingPathComponent("integration-old.json")
        let newAuth = root.appendingPathComponent("integration-new.json")
        try auth(user: "original").write(to: oldAuth)
        try auth(user: "new").write(to: newAuth)
        let runner = CommandRunner()
        try await runner.run(executable: executable, arguments: ["import", oldAuth.path, "--alias", "Original"], home: target, proxy: false)
        try await runner.run(executable: executable, arguments: ["switch", "original@example.test"], home: target, proxy: false)
        let before = try Data(contentsOf: target.appendingPathComponent("auth.json"))
        let login = try script("integration-login", at: root, body: "/bin/cp " + quoted(newAuth.path) + " \"$CODEX_HOME/auth.json\"")
        let added = try await AccountLogin.add(codex: login, importer: executable, home: target, proxy: false, temporaryRoot: root, willImport: {})
        let registry = try LocalData.registry(home: target)
        expect(added == "new::account" && registry.accounts.count == 2, "real CLI saves the newly authorized account")
        let after = try Data(contentsOf: target.appendingPathComponent("auth.json"))
        expect(before == after && registry.activeAccountKey == "original::account", "real CLI import preserves active credentials and active registry identity")
        expect(registry.accounts.first(where: { $0.id == "original::account" })?.alias == "Original", "real CLI import preserves the existing account alias")
        _ = try await AccountLogin.add(codex: login, importer: executable, home: target, proxy: false, temporaryRoot: root, willImport: {})
        let duplicate = try LocalData.registry(home: target)
        expect(duplicate.accounts.count == 2, "authorizing an existing account updates it without duplication")
        let firstHome = root.appendingPathComponent("first-account")
        try fm.createDirectory(at: firstHome, withIntermediateDirectories: true)
        _ = try await AccountLogin.add(codex: login, importer: executable, home: firstHome, proxy: false, temporaryRoot: root, willImport: {})
        let first = try LocalData.registry(home: firstHome)
        expect(first.accounts.count == 1 && first.activeAccountKey == nil && !fm.fileExists(atPath: firstHome.appendingPathComponent("auth.json").path), "first account is saved without silently activating a login")
    }

    @MainActor static func backgroundRefreshChecks(at root: URL) async throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("background-home")
        try fm.createDirectory(at: home.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        try auth().write(to: home.appendingPathComponent("auth.json"))
        let fixture = root.appendingPathComponent("background-registry.json")
        try Data("""
        {"schema_version":3,"accounts":[{"account_key":"user::account","email":"user@example.test","alias":"","auth_mode":"chatgpt","last_usage":{"primary":{"used_percent":27,"window_minutes":300}},"last_usage_at":1800000000}]}
        """.utf8).write(to: fixture)
        let cli = try script("background-cli", at: root, body: """
        printf '%s\\n' "$1" >> "$CODEX_HOME/calls"
        if [ -e "$CODEX_HOME/fail" ]; then exit 1; fi
        if [ "$1" = list ]; then
          /bin/cp \(quoted(fixture.path)) "$CODEX_HOME/accounts/registry.json"
        fi
        /bin/sleep 0.1
        """)
        func calls() -> [String] {
            ((try? String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        var clock = Date(timeIntervalSince1970: 1800000000)
        let store = AppStore(home: home, cli: cli, now: { clock })
        var statusUpdates = 0
        store.onChange = { statusUpdates += 1 }
        store.notice = "Switch completed; restart reminder"
        store.error = "Unrelated account action feedback"
        await store.refreshIfNeeded()
        expect(calls() == ["list", "resets"], "hidden startup refresh fetches both quota and reset news")
        expect(!store.visible && store.active?.fiveHour?.remaining == 73 && statusUpdates > 0, "background refresh updates menu data without opening the panel")
        expect(store.notice != nil && store.error != nil, "automatic refresh preserves account action feedback")
        clock += 299
        await store.refreshIfNeeded()
        expect(calls().count == 2, "fresh cache suppresses duplicate opening and wake refreshes")
        clock += 1
        store.busy = true
        await store.refreshIfNeeded()
        expect(calls().count == 2, "login or switching defers a due background refresh")
        store.busy = false
        await store.refreshIfNeeded()
        expect(calls().count == 4, "next idle check catches up without losing the due refresh")
        clock += 300
        let first = Task { await store.refreshIfNeeded() }
        for _ in 0..<50 {
            if store.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        expect(store.busy, "overlap test observes an in-flight refresh")
        await store.refreshIfNeeded()
        await first.value
        expect(calls().count == 6 && !store.busy, "simultaneous timer and wake checks share one refresh")
        let failure = home.appendingPathComponent("fail")
        try Data().write(to: failure)
        clock += 300
        await store.refreshIfNeeded()
        expect(store.refreshError != nil && store.active?.fiveHour?.remaining == 73, "background API failure keeps cached quota and reports failure")
        await store.refreshIfNeeded()
        expect(calls().count == 8, "failed refresh is throttled rather than retried continuously")
        try fm.removeItem(at: failure)
        clock += 300
        await store.refreshIfNeeded()
        expect(calls().count == 10 && store.refreshError == nil && store.error != nil, "scheduled recovery clears only the refresh error")
        clock += 3600
        await store.refreshIfNeeded()
        expect(calls().count == 12 && !store.visible, "wake after a long gap catches up while the panel stays hidden")
        clock -= 7200
        await store.refreshIfNeeded()
        expect(calls().count == 14, "backward clock adjustment cannot suspend refreshing")
        await store.refresh()
        expect(calls().count == 16 && store.notice == nil && store.error == nil, "manual refresh bypasses interval and clears action feedback")
        let demo = AppStore(demo: true, home: home, cli: cli, now: { clock })
        await demo.refreshIfNeeded()
        expect(calls().count == 16 && !demo.visible, "demo never starts automatic CLI requests")
        store.stop()
        clock += 300
        await store.refreshIfNeeded()
        expect(calls().count == 16, "shutdown prevents queued background checks from starting commands")
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-auth-menubar-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let weekly = UsageWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: 1)
        let onlyWeekly = UsageSnapshot(primary: weekly, secondary: nil, planType: "pro")
        expect(onlyWeekly.window(minutes: 300) == nil, "weekly-only primary never becomes five-hour usage")
        expect(onlyWeekly.window(minutes: 10080)?.remaining == 1, "weekly-only primary maps to weekly usage")
        let unknownDuration = UsageWindow(usedPercent: 16, windowMinutes: nil, resetsAt: nil)
        expect(UsageSnapshot(primary: unknownDuration, secondary: nil, planType: nil).window(minutes: 300)?.remaining == 84, "legacy unknown duration has a positional fallback")
        expect(UsageWindow(usedPercent: 110, windowMinutes: nil, resetsAt: nil).remaining == 0, "quota is clamped")

        expect(LocalData.snapshotFilename("../escape").contains("/") == false, "snapshot path cannot escape accounts directory")
        expect(LocalData.snapshotFilename("user::account") == "dXNlcjo6YWNjb3VudA.auth.json", "snapshot filename matches Zig base64url encoding")
        expect(LocalData.snapshotFilename("valid-id_1") == "valid-id_1.auth.json", "legacy safe filenames preserved")
        let metadata = LocalData.authMetadata(try auth())
        expect(metadata?.key == "user::account", "JWT identity decoded")
        expect(metadata?.subscription.until == LocalData.date("2026-10-04T03:13:00Z"), "subscription date preserves timezone")
        let mismatched = try auth(tokenAccount: "other")
        expect(LocalData.authMetadata(mismatched) == nil, "token and claim account mismatch rejected")
        let noDate = try auth(date: nil)
        expect(LocalData.authMetadata(noDate)?.subscription.until == nil, "JWT exp is never a subscription date")
        expect(LocalData.authMetadata(Data("not json".utf8)) == nil, "malformed auth ignored")
        var apiAuth = try JSONSerialization.jsonObject(with: auth()) as! [String: Any]
        apiAuth["OPENAI_API_KEY"] = "synthetic-api-key"
        let apiAuthData = try JSONSerialization.data(withJSONObject: apiAuth)
        expect(LocalData.authMetadata(apiAuthData) == nil, "API key takes precedence over leftover ChatGPT tokens")
        try auth(user: "other").write(to: root.appendingPathComponent("auth.json"))
        expect(LocalData.subscription(for: record("user::account", email: "a@example.test"), home: root, activeKey: "user::account") == nil, "concurrent switch cannot attach another identity's subscription")

        let a = record("a", email: "same@example.test", alias: "work")
        let b = record("b", email: "same@example.test")
        expect(LocalData.switchQuery(for: a, in: [a, b]) == "work", "duplicate email resolves through unique alias")
        expect(LocalData.switchQuery(for: b, in: [a, b]) == nil, "ambiguous account cannot switch")
        expect(LocalData.switchQuery(for: record("x", email: "--api"), in: [record("x", email: "--api")]) == nil, "queries cannot inject flags")
        expect(LocalData.switchQuery(for: a, in: [a, record("c", email: "SAME@EXAMPLE.TEST", alias: "WORK")]) == nil, "query uniqueness matches CLI case-insensitive semantics")

        let empty = try LocalData.registry(home: root)
        expect(empty.accounts.isEmpty, "first launch without a registry is an empty state")
        let registryURL = root.appendingPathComponent("accounts/registry.json")
        try Data("{\"schema_version\":99,\"accounts\":[]}".utf8).write(to: registryURL)
        do { _ = try LocalData.registry(home: root); fatalError("accepted unsupported registry") }
        catch { expect(true, "unsupported registry is rejected") }
        try Data("broken".utf8).write(to: registryURL)
        do { _ = try LocalData.registry(home: root); fatalError("accepted malformed registry") }
        catch { expect(true, "malformed registry is an error, not an empty account list") }
        do { _ = try LocalData.boundedData(registryURL, limit: 2); fatalError("accepted oversized file") }
        catch { expect(true, "local reads are bounded") }

        let expired = ResetForecast(level: "strong", resetChancePercent: 90, observedAt: "2020-01-01T00:00:00Z", expiresAt: "2020-01-02T00:00:00Z", source: nil)
        expect(NewsItem.items(from: ResetData(latestReset: nil, scheduledReset: nil, activeWatch: expired)).isEmpty, "expired forecasts are hidden")
        let plan = ResetReport(id: "1", resetType: "regular", announcedAt: "2020-01-01T00:00:00Z", scheduledFor: "2020-01-02T00:00:00Z", source: nil)
        expect(NewsItem.items(from: ResetData(latestReset: nil, scheduledReset: plan, activeWatch: nil)).first?.kind == .planned, "passed scheduled date does not imply execution")
        expect(NewsItem(id: "x", kind: .announced, title: "", detail: "", date: nil, source: "file:///tmp/private").url == nil, "source links cannot open local files")
        expect(NewsItem(id: "x", kind: .announced, title: "", detail: "", date: nil, source: "https://user:secret@example.test").url == nil, "source links cannot include credentials")

        let runner = CommandRunner()
        try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], home: root, proxy: false)
        expect(true, "CLI success completes asynchronously")
        do {
            try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], home: root, proxy: false)
            fatalError("accepted CLI failure")
        } catch { expect(true, "CLI failure is surfaced") }
        let start = Date()
        do {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], home: root, proxy: false, timeout: 0.1)
            fatalError("accepted stalled CLI")
        } catch { expect(Date().timeIntervalSince(start) < 3, "stalled CLI terminates within deadline") }
        try await loginChecks(at: root)
        try await backgroundRefreshChecks(at: root)
        try await insightsChecks(at: root)
        if let importer = ProcessInfo.processInfo.environment["CODEX_AUTH_TEST_IMPORTER"] {
            try await importIntegration(at: root, executable: URL(fileURLWithPath: importer))
        }
        print("\(count) menu bar checks passed.")
    }
}
