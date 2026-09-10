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
        let body = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": claims, "exp": 1])
        let payload = body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": tokenAccount, "id_token": "header." + payload + ".signature"]])
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
        print("\(count) menu bar checks passed.")
    }
}
