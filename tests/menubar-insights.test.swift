import Foundation

extension MenuBarTests {
    @MainActor static func insightsChecks(at root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(_ remaining: Double, seconds: Double = 0, reset: Double = 10000) -> AccountRecord {
            AccountRecord(accountKey: "weekly", email: "weekly@example.test", alias: "", accountName: nil, plan: "pro", authMode: "chatgpt",
                          lastUsage: UsageSnapshot(primary: UsageWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil),
                            secondary: UsageWindow(usedPercent: 100 - remaining, windowMinutes: 10080, resetsAt: now.timeIntervalSince1970 + reset), planType: nil),
                          lastUsageAt: now.timeIntervalSince1970 + seconds)
        }
        let primary = account(62), other = record("other", email: "other@example.test")
        expect(StatusDisplay.remaining.text(weekly: primary.weekly) == " 62%", "status uses weekly quota even when five-hour data exists")
        expect(StatusDisplay.remaining.text(weekly: nil) == " —" && StatusDisplay.icon.text(weekly: primary.weekly).isEmpty, "missing weekly data and icon-only display are explicit")
        expect(StatusDisplay.countdown.text(weekly: primary.weekly, now: now).contains("时"), "weekly reset countdown uses the selected clock")
        var state = CompanionState()
        state.decorate(primary.id, name: "  Work  ", note: "  Main account  ")
        state.move(other.id, by: -1, records: [primary, other], active: primary.id)
        expect(state.label(primary) == "Work" && state.accounts[primary.id]?.note == "Main account", "local account names and notes trim whitespace")
        expect(state.visibleAccounts([primary, other], active: primary.id).first?.id == other.id, "account ordering is independent from active identity")
        state.accounts[primary.id]?.hidden = true
        expect(state.visibleAccounts([primary, other], active: primary.id).contains { $0.id == primary.id }, "active account stays visible even if hidden previously")
        state.accounts[other.id] = AccountDecoration(hidden: true)
        expect(state.visibleAccounts([primary, other], active: primary.id).count == 1, "hidden inactive accounts leave the panel list")
        try state.save(home: root)
        let restored = try CompanionState.read(home: root)
        expect(restored.label(primary) == "Work" && restored.order == state.order, "account organization survives restart")
        let statePermissions = try FileManager.default.attributesOfItem(atPath: CompanionState.location(home: root).path)[.posixPermissions] as? NSNumber
        expect(statePermissions?.intValue == 0o600, "private state is owner-readable only")

        state = CompanionState()
        expect(state.observe(account(65), now: now).isEmpty, "initial quota sample seeds a silent baseline")
        let low = state.observe(account(19, seconds: 1), now: now + 1)
        expect(low.first?.kind == .low, "crossing the weekly threshold queues a low-quota notification")
        expect(state.observe(account(19, seconds: 1), now: now + 1).count == 1, "undelivered notification remains retryable")
        state.acknowledge(low[0])
        expect(state.observe(account(18, seconds: 2), now: now + 2).isEmpty, "delivered low-quota alert is deduplicated")
        let critical = state.observe(account(4, seconds: 3), now: now + 3)
        expect(critical.first?.kind == .critical, "critical weekly quota escalates once")
        state.acknowledge(critical[0])
        let recovered = state.observe(account(100, seconds: 4, reset: 20000), now: now + 4)
        expect(recovered.first?.kind == .recovered, "observed quota recovery produces a recovery notification")
        expect(state.observe(account(99, seconds: 5, reset: 20000), now: now + 5).first?.kind == .recovered, "failed recovery delivery is retried on the next sample")
        state.acknowledge(recovered[0])
        try state.save(home: root); state = try CompanionState.read(home: root)
        expect(state.observe(account(98, seconds: 6, reset: 20000), now: now + 6).isEmpty, "recovery deduplication persists on disk")
        expect(state.observe(account(1, seconds: -2000), now: now).isEmpty, "out-of-order stale samples never notify")
        expect(state.history[primary.id]?.count == 7, "quota history keeps distinct timestamps and rejects older samples")
        expect(state.observe(account(3, seconds: 7, reset: 20000), now: now + 7, deliveryAllowed: false).isEmpty, "out-of-scope account notifications are suppressed")
        expect(state.observe(account(3, seconds: 7, reset: 20000), now: now + 7).isEmpty, "enabling account scope does not send historical alerts")

        state.history[primary.id] = [
            QuotaPoint(timestamp: now.timeIntervalSince1970 - 12 * 3600, remaining: 80, resetsAt: now.timeIntervalSince1970 + 2 * 86400),
            QuotaPoint(timestamp: now.timeIntervalSince1970 - 6 * 3600, remaining: 70, resetsAt: now.timeIntervalSince1970 + 2 * 86400),
            QuotaPoint(timestamp: now.timeIntervalSince1970, remaining: 60, resetsAt: now.timeIntervalSince1970 + 2 * 86400)
        ]
        let riskProjection = state.quotaProjection(for: account(60, reset: 2 * 86400), now: now)
        expect(riskProjection != nil && abs(riskProjection!.burnPerDay - 40) < 0.001 && !riskProjection!.survivesReset,
               "quota projection uses recent same-cycle burn rate and flags depletion before reset")
        state.history[primary.id] = [
            QuotaPoint(timestamp: now.timeIntervalSince1970 - 12 * 3600, remaining: 92, resetsAt: now.timeIntervalSince1970 + 2 * 86400),
            QuotaPoint(timestamp: now.timeIntervalSince1970, remaining: 90, resetsAt: now.timeIntervalSince1970 + 2 * 86400)
        ]
        let safeProjection = state.quotaProjection(for: account(90, reset: 2 * 86400), now: now)
        expect(safeProjection?.survivesReset == true, "quota projection reports when current burn rate survives the reset")
        expect(state.quotaProjection(for: account(90, seconds: -3600, reset: 2 * 86400), now: now) == nil,
               "stale quota samples are never projected")

        state = CompanionState()
        expect(state.observe(account(80, seconds: -12 * 3600, reset: 2 * 86400), now: now - 12 * 3600).isEmpty,
               "forecast notifications establish a baseline before alerting")
        let forecast = state.observe(account(60, reset: 2 * 86400), now: now)
        expect(forecast.first?.kind == .forecast && forecast.first?.projection?.survivesReset == false,
               "forecast notification warns once when depletion precedes reset")
        state.acknowledge(forecast[0])
        expect(state.observe(account(60, reset: 2 * 86400), now: now).isEmpty,
               "forecast notification is deduplicated for the reset cycle")

        let token = TokenTally(input: 100000, cached: 50000, written: 10000, output: 1000, reasoning: 800)
        var call = ModelCall(id: "test", timestamp: now.timeIntervalSince1970, session: "session", model: "gpt-6-astra", provider: "openai", tokens: token)
        expect(abs(APIPrices.cost(call)! - 0.625) < 0.000001, "cost separates uncached, cached and cache-write input without double-charging reasoning")
        let webToken = TokenTally(input: 100000, cached: 50000, output: 1000)
        var webStats = UsageStatistics()
        webStats.calls = ["chatgpt-web/extra-high", "chatgpt-web/high", "chatgpt-web/pro"].enumerated().map { index, model in
            ModelCall(id: "web-\(index)", timestamp: now.timeIntervalSince1970, session: "web", model: model, provider: "openai", tokens: webToken)
        }
        webStats.prepare(now: now)
        let webSummary = webStats.summary(days: 1, now: now)
        expect(webSummary.total.unpriced == 0 && abs(webSummary.total.cost - 1.8) < 0.000001, "chatgpt-web tiers use Astra rates in the total")
        expect(webSummary.daily.count == 1 && abs(webSummary.daily[0].total.cost - 1.8) < 0.000001, "chatgpt-web Astra estimates feed the daily cost chart")
        expect(Set(webSummary.models.map(\.id)) == APIPrices.astraEstimatedModels && webSummary.models.allSatisfy { abs($0.cost - 0.6) < 0.000001 }, "chatgpt-web model names stay distinct while model costs use Astra rates")
        var workspaceStats = UsageStatistics()
        workspaceStats.calls = [
            ModelCall(id: "workspace-a", timestamp: now.timeIntervalSince1970, session: "a", model: "gpt-6-astra", provider: "openai", tokens: TokenTally(input: 100000), workspace: "codex-auth"),
            ModelCall(id: "workspace-b", timestamp: now.timeIntervalSince1970, session: "b", model: "gpt-6-astra", provider: "openai", tokens: TokenTally(input: 50000), workspace: "desktop")
        ]
        workspaceStats.prepare(now: now)
        let workspaceSummary = workspaceStats.summary(days: 1, now: now)
        expect(workspaceSummary.workspaces.map(\.id) == ["codex-auth", "desktop"], "workspace attribution groups local usage by session cwd")
        expect(workspaceStats.summary(days: 1, now: now, workspace: "desktop").total.tokens.input == 50000,
               "workspace selection filters usage without rescanning rollout files")
        var trendStats = UsageStatistics()
        let calendar = Calendar.current
        let trendToday = calendar.startOfDay(for: now)
        let trendNow = trendToday.addingTimeInterval(12 * 3600)
        for offset in -13...0 {
            let stamp = calendar.date(byAdding: .day, value: offset, to: trendToday)!.addingTimeInterval(3600)
            let input: Int64 = offset >= -6 ? 100000 : 50000
            trendStats.calls.append(ModelCall(id: "trend-\(offset)", timestamp: stamp.timeIntervalSince1970, session: "trend", model: "gpt-6-astra", provider: "openai", tokens: TokenTally(input: input)))
        }
        trendStats.prepare(now: trendNow)
        let trend = trendStats.costTrend(days: 7, now: trendNow)
        expect(trend != nil && abs(trend!.dailyAverage - (7.0 / 6.5)) < 0.000001 && abs(trend!.changePercent! - 100) < 0.000001,
               "cost trend extrapolates from elapsed time and compares the prior aligned window")
        expect(trendStats.costTrend(days: 30, now: trendNow)?.changePercent == nil,
               "30-day cost trend avoids comparison beyond retained local history")
        call.tokens = TokenTally(input: 272001, output: 1000)
        expect(abs(APIPrices.cost(call)! - 5.51502) < 0.000001, "long input applies official full-request multipliers")
        call.model = "gpt-5.5"; call.tokens = TokenTally(input: 100000, output: 1000)
        expect(abs(APIPrices.cost(call, longSessions: ["session|gpt-5.5"])! - 1.045) < 0.000001, "legacy long-context pricing applies to its full session")
        call.model = "unpublished-model"
        expect(APIPrices.cost(call) == nil, "unknown model prices remain unpriced")
        call.model = "gpt-6-astra"; call.provider = "custom"
        expect(APIPrices.cost(call) == nil, "custom providers are not billed using OpenAI prices")
        call.provider = "openai"; call.aggregated = true
        expect(APIPrices.cost(call) == nil, "counter gaps cannot be priced as a single long-context request")
        expect(TokenTally.parse(["input_tokens": true, "output_tokens": 2]) == nil && TokenTally.parse(["input_tokens": 1.5, "output_tokens": 2]) == nil, "malformed boolean and fractional token counts are rejected")

        let home = root.appendingPathComponent("usage-fixture"), sessionDir = home.appendingPathComponent("sessions"), archiveDir = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent("fixture.jsonl")
        func line(_ type: String, _ payload: [String: Any], seconds: Double = 0) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": (now + seconds).ISO8601Format(), "payload": payload], options: .sortedKeys)
            data.append(10); return data
        }
        func usage(_ input: Int, seconds: Double) throws -> Data {
            let tally: [String: Int] = ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": input / 100]
            return try line("event_msg", ["type": "token_count", "info": ["total_token_usage": tally, "last_token_usage": ["input_tokens": 10000, "cached_input_tokens": 5000, "output_tokens": 100]]], seconds: seconds)
        }
        var fixture = try line("session_meta", ["id": "synthetic-session", "timestamp": now.ISO8601Format(), "model_provider": "openai", "cwd": "/tmp/projects/codex-auth"])
        fixture.append(try line("turn_context", ["model": "gpt-6-astra", "turn_id": "turn-1"]))
        fixture.append(try usage(10000, seconds: 0)); fixture.append(try usage(10000, seconds: 0))
        try fixture.write(to: file)
        let scanner = UsageScanner()
        var result = try await scanner.scan(home: home, now: now + 10)
        expect(result.calls.count == 1 && result.calls[0].tokens.input == 10000, "duplicate cumulative events count only once")
        expect(result.calls[0].workspace == "codex-auth", "session cwd is reduced to a local workspace label")
        let unchanged = try await scanner.scan(home: home, now: now + 10)
        expect(unchanged.calls.count == 1, "unchanged files reuse their cursor without duplication")
        let append = try usage(20000, seconds: 1)
        var handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: append.dropLast()); try handle.close()
        result = try await scanner.scan(home: home, now: now + 10)
        expect(result.calls.count == 1, "an unfinished JSON line is not consumed early")
        handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        result = try await UsageScanner().scan(home: home, now: now + 10)
        expect(result.calls.count == 2 && result.summary(days: 1, now: now + 10).total.tokens.input == 20000, "persisted cursor resumes an appended partial line exactly once")
        try FileManager.default.copyItem(at: file, to: archiveDir.appendingPathComponent("copy.jsonl"))
        result = try await scanner.scan(home: home, now: now + 10)
        expect(result.calls.count == 2, "session and archived copies are deduplicated globally")
        let cached = try Data(contentsOf: home.appendingPathComponent("menubar/usage-index.json"))
        expect(!String(decoding: cached, as: UTF8.self).contains("synthetic-session"), "cache hashes session identity and omits source content")
        try FileManager.default.removeItem(at: archiveDir.appendingPathComponent("copy.jsonl"))
        try fixture.write(to: file)
        result = try await scanner.scan(home: home, now: now + 10)
        expect(result.calls.count == 1, "truncated logs reset their cursor instead of keeping stale totals")
        var cursor = RolloutCursor()
        cursor.consume(try line("session_meta", ["id": "fork", "timestamp": (now + 3).ISO8601Format(), "model_provider": "openai"]), since: now - 100)
        cursor.consume(try line("turn_context", ["model": "gpt-6-astra", "turn_id": "inherited"]), since: now - 100)
        cursor.consume(try usage(10000, seconds: 0), since: now - 100)
        cursor.consume(try usage(20000, seconds: 4), since: now - 100)
        expect(cursor.calls.count == 1 && cursor.calls[0].tokens.input == 10000, "forks exclude inherited calls before session creation")
        cursor.consume(try usage(10000, seconds: 5), since: now - 100)
        expect(cursor.calls.count == 2, "cumulative counter resets use last-call usage")
        let summary = result.summary(days: 7, now: now + 10)
        expect(summary.daily.count == 7 && summary.total.calls == 1, "chart includes empty local-calendar days and correct totals")
        let oversized = Data(repeating: 120, count: 9 * 1024 * 1024)
        handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: oversized); try handle.close()
        _ = try await scanner.scan(home: home, now: now + 10)
        handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.write(contentsOf: append); try handle.close()
        result = try await UsageScanner().scan(home: home, now: now + 10)
        expect(result.calls.count == 2, "oversized unfinished tool output stays bounded and resumes at the next record")
        let cacheURL = home.appendingPathComponent("menubar/usage-index.json")
        let indexPermissions = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber
        expect(indexPermissions?.intValue == 0o600, "usage index permissions keep local statistics private")
        let linkedHome = root.appendingPathComponent("linked-usage")
        try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome.appendingPathComponent("sessions"), withDestinationURL: sessionDir)
        let linked = try await UsageScanner().scan(home: linkedHome, now: now + 10)
        expect(linked.calls.count == result.calls.count, "relocated session roots can be indexed through a directory symlink")
        var raw = UsageStatistics(); raw.calls = result.calls; raw.longSessions = result.longSessions
        expect(abs(raw.summary(days: 7, now: now + 10).total.cost - result.summary(days: 7, now: now + 10).total.cost) < 0.000001, "precomputed chart buckets preserve token pricing totals")
        let storeHome = root.appendingPathComponent("state-restart")
        var persisted = CompanionState()
        _ = persisted.observe(account(65), now: now)
        let restartAlert = persisted.observe(account(19, seconds: 1), now: now + 1)[0]
        persisted.acknowledge(restartAlert)
        try persisted.save(home: storeHome)
        let store = AppStore(home: storeHome, now: { now + 2 })
        store.updatePreferences { $0.statusDisplay = .icon }
        expect(store.companion.alertLedger[primary.id]?.warnedLevel == 1, "restart and menu display preferences preserve delivered alert state")
        store.stop()
        state.pruneHistory(now: now + 32 * 86400)
        expect(state.history.isEmpty, "old quota history expires even without a new account sample")
    }
}
