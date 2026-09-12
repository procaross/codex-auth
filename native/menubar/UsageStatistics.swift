import Foundation
import CryptoKit

private enum RolloutDates {
    static let lock = NSLock()
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()
    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

struct TokenTally: Codable, Equatable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var written: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 { input + output }
    static func parse(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any], let input = object["input_tokens"] as? NSNumber,
              let output = object["output_tokens"] as? NSNumber else { return nil }
        for key in ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"] {
            if let value = object[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            }
        }
        let result = Self(input: input.int64Value, cached: (object["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0,
                          written: (object["cache_write_input_tokens"] as? NSNumber)?.int64Value ?? 0,
                          output: output.int64Value, reasoning: (object["reasoning_output_tokens"] as? NSNumber)?.int64Value ?? 0)
        guard [result.input, result.cached, result.written, result.output, result.reasoning].allSatisfy({ (0...1_000_000_000_000).contains($0) }),
              result.cached + result.written <= result.input, result.reasoning <= result.output else { return nil }
        return result
    }
    func subtracting(_ other: Self) -> Self? {
        let result = Self(input: input - other.input, cached: cached - other.cached, written: written - other.written,
                          output: output - other.output, reasoning: reasoning - other.reasoning)
        guard [result.input, result.cached, result.written, result.output, result.reasoning].allSatisfy({ $0 >= 0 }),
              result.cached + result.written <= result.input else { return nil }
        return result
    }
    mutating func add(_ other: Self) {
        input += other.input; cached += other.cached; written += other.written; output += other.output; reasoning += other.reasoning
    }
}

struct ModelCall: Codable, Identifiable {
    var id: String
    var timestamp: Double
    var session: String
    var model: String
    var provider: String
    var tokens: TokenTally
    var workspace: String? = nil
    var aggregated = false
    var date: Date { Date(timeIntervalSince1970: timestamp) }
}

struct ModelPrice {
    var input: Double
    var cached: Double
    var written: Double?
    var output: Double
    var longContext = false
    var sessionLongContext = false
}

enum APIPrices {
    static let checked = "2026-09-11"
    static let source = URL(string: "https://developers.openai.com/api/docs/pricing")!
    static let astraEstimatedModels: Set<String> = [
        "chatgpt-web/extra-high",
        "chatgpt-web/high",
        "chatgpt-web/pro"
    ]
    // Standard USD / million tokens, verified against official model pages.
    // Snapshot suffixes are matched explicitly; unknown aliases stay unpriced.
    static let models: [String: ModelPrice] = [
        "gpt-6-astra": .init(input: 10, cached: 1, written: 12.5, output: 50, longContext: true),
        "gpt-5.6-sol": .init(input: 4, cached: 0.4, written: 5, output: 20, longContext: true),
        "gpt-5.6-terra": .init(input: 2, cached: 0.2, written: 2.5, output: 12, longContext: true),
        "gpt-5.6-luna": .init(input: 0.2, cached: 0.02, written: 0.25, output: 1.2, longContext: true),
        "gpt-5.5": .init(input: 5, cached: 0.5, output: 30, longContext: true, sessionLongContext: true),
        "gpt-5.4": .init(input: 2.5, cached: 0.25, output: 15, longContext: true, sessionLongContext: true),
        "gpt-5.3-codex": .init(input: 1.75, cached: 0.175, output: 14),
        "gpt-5.2": .init(input: 1.75, cached: 0.175, output: 14)
    ]
    static func canonical(_ model: String) -> String {
        if models[model] != nil { return model }
        for base in models.keys where model.hasPrefix(base + "-") {
            let suffix = String(model.dropFirst(base.count + 1))
            if suffix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return base }
        }
        return model
    }
    static func pricingModel(_ model: String) -> String {
        astraEstimatedModels.contains(model) ? "gpt-6-astra" : canonical(model)
    }
    static func usesAstraEstimate(_ model: String) -> Bool { astraEstimatedModels.contains(model) }
    static func cost(_ call: ModelCall, longSessions: Set<String> = []) -> Double? {
        let priceModel = pricingModel(call.model)
        guard !call.aggregated, call.provider == "openai", let rate = models[priceModel],
              call.tokens.written == 0 || rate.written != nil else { return nil }
        let t = call.tokens
        let long = rate.longContext && (t.input > 272000 || (rate.sessionLongContext && longSessions.contains(call.session + "|" + priceModel)))
        let input = Double(t.input - t.cached - t.written) * rate.input + Double(t.cached) * rate.cached + Double(t.written) * (rate.written ?? 0)
        // Reasoning is already part of output_tokens; never charge it twice.
        return (input * (long ? 2 : 1) + Double(t.output) * rate.output * (long ? 1.5 : 1)) / 1_000_000
    }
}

struct UsageTotal: Identifiable {
    var id: String
    var tokens = TokenTally()
    var calls = 0
    var cost = 0.0
    var unpriced = 0
    mutating func add(_ call: ModelCall, longSessions: Set<String>) {
        tokens.add(call.tokens); calls += 1
        if let price = APIPrices.cost(call, longSessions: longSessions) { cost += price } else { unpriced += 1 }
    }
    mutating func add(_ other: UsageTotal) {
        tokens.add(other.tokens); calls += other.calls; cost += other.cost; unpriced += other.unpriced
    }
}

struct DailyUsage: Identifiable {
    let date: Date
    var total: UsageTotal
    var id: Date { date }
}

struct UsageCostTrend {
    let dailyAverage: Double
    let monthlyProjection: Double
    let changePercent: Double?
    let comparisonDays: Int?
}

private struct UsageSlice: Hashable {
    let model: String
    let workspace: String
}

private func usageWorkspace(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "其他" : trimmed
}

struct UsageStatistics {
    var calls: [ModelCall] = []
    var longSessions: Set<String> = []
    var skipped = 0
    var scannedFiles = 0
    var checkedAt: Date?
    private var dailySlices: [Date: [UsageSlice: UsageTotal]]?
    mutating func prepare(now: Date) {
        var buckets: [Date: [UsageSlice: UsageTotal]] = [:]
        let calendar = Calendar.current
        for call in calls where call.date <= now {
            let day = calendar.startOfDay(for: call.date)
            let workspace = usageWorkspace(call.workspace)
            let key = UsageSlice(model: call.model, workspace: workspace)
            var entry = buckets[day]?[key] ?? UsageTotal(id: call.model)
            entry.add(call, longSessions: longSessions)
            buckets[day, default: [:]][key] = entry
        }
        dailySlices = buckets
    }
    func summary(days: Int, now: Date = Date(), model: String? = nil, workspace: String? = nil) -> (total: UsageTotal, daily: [DailyUsage], models: [UsageTotal], workspaces: [UsageTotal]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        var total = UsageTotal(id: "all"), models: [String: UsageTotal] = [:], workspaces: [String: UsageTotal] = [:], buckets: [Date: UsageTotal] = [:]
        if let dailySlices {
          for (day, entries) in dailySlices where day >= start && day <= today {
            for (slice, entry) in entries where (model == nil || slice.model == model) && (workspace == nil || slice.workspace == workspace) {
                total.add(entry)
                var bucket = buckets[day] ?? UsageTotal(id: String(day.timeIntervalSince1970)); bucket.add(entry); buckets[day] = bucket
                var combined = models[slice.model] ?? UsageTotal(id: slice.model); combined.add(entry); models[slice.model] = combined
                var workspaceTotal = workspaces[slice.workspace] ?? UsageTotal(id: slice.workspace); workspaceTotal.add(entry); workspaces[slice.workspace] = workspaceTotal
            }
          }
        } else {
          for call in calls where call.date >= start && call.date <= now && (model == nil || call.model == model) && (workspace == nil || usageWorkspace(call.workspace) == workspace) {
            total.add(call, longSessions: longSessions)
            let day = calendar.startOfDay(for: call.date)
            var bucket = buckets[day] ?? UsageTotal(id: String(day.timeIntervalSince1970)); bucket.add(call, longSessions: longSessions); buckets[day] = bucket
            var entry = models[call.model] ?? UsageTotal(id: call.model); entry.add(call, longSessions: longSessions); models[call.model] = entry
            let workspaceName = usageWorkspace(call.workspace)
            var workspaceTotal = workspaces[workspaceName] ?? UsageTotal(id: workspaceName); workspaceTotal.add(call, longSessions: longSessions); workspaces[workspaceName] = workspaceTotal
          }
        }
        let daily = (0..<days).map { index -> DailyUsage in
            let date = calendar.date(byAdding: .day, value: index, to: start)!
            return DailyUsage(date: date, total: buckets[date] ?? UsageTotal(id: String(index)))
        }
        return (total, daily, models.values.sorted { $0.cost > $1.cost }, workspaces.values.sorted { $0.cost > $1.cost })
    }
    func costTrend(days: Int, now: Date = Date(), model: String? = nil, workspace: String? = nil) -> UsageCostTrend? {
        guard days > 0 else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return nil }
        let elapsed = now.timeIntervalSince(currentStart)
        guard elapsed >= 3600 else { return nil }
        let current = pricedTotal(from: currentStart, through: now, model: model, workspace: workspace)
        guard current.calls > 0, current.cost > 0 else { return nil }
        let elapsedDays = elapsed / 86400
        let dailyAverage = current.cost / elapsedDays
        var change: Double?, comparisonDays: Int?
        if days <= 14,
           let previousStart = calendar.date(byAdding: .day, value: -days, to: currentStart),
           let previousEnd = calendar.date(byAdding: .day, value: -days, to: now) {
            let previous = pricedTotal(from: previousStart, through: previousEnd, model: model, workspace: workspace)
            if previous.calls > 0, previous.cost > 0 {
                change = (current.cost / previous.cost - 1) * 100
                comparisonDays = days
            }
        }
        return UsageCostTrend(dailyAverage: dailyAverage,
                              monthlyProjection: dailyAverage * (365.25 / 12),
                              changePercent: change,
                              comparisonDays: comparisonDays)
    }
    private func pricedTotal(from start: Date, through end: Date, model: String?, workspace: String?) -> UsageTotal {
        var total = UsageTotal(id: "trend")
        for call in calls where call.date >= start && call.date <= end && (model == nil || call.model == model) && (workspace == nil || usageWorkspace(call.workspace) == workspace) {
            total.add(call, longSessions: longSessions)
        }
        return total
    }
}

struct RolloutCursor: Codable {
    var discardingLine = false
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var modified: Double = 0
    var inode: UInt64 = 0
    var model = "未知模型"
    var provider = "unknown"
    var workspace = "其他"
    var session = ""
    var turn = ""
    var started: Double = 0
    var previous: TokenTally?
    var calls: [ModelCall] = []
    var largestInputs: [String: Int64] = [:]
    var skipped = 0

    mutating func consume(_ data: Data, since cutoff: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { skipped += 1; return }
        if type == "session_meta" {
            provider = payload["model_provider"] as? String ?? "unknown"
            session = Self.digest(payload["id"] as? String ?? payload["session_id"] as? String ?? session)
            started = RolloutDates.parse(payload["timestamp"])?.timeIntervalSince1970 ?? 0
            if let cwd = payload["cwd"] as? String { workspace = Self.workspaceLabel(cwd) }
        } else if type == "turn_context" {
            model = payload["model"] as? String ?? "未知模型"
            turn = payload["turn_id"] as? String ?? ""
        } else if type == "event_msg", payload["type"] as? String == "token_count" {
            guard let info = payload["info"] as? [String: Any] else { return }
            guard let date = RolloutDates.parse(object["timestamp"]), let cumulative = TokenTally.parse(info["total_token_usage"]) else { skipped += 1; return }
            defer { previous = cumulative }
            if previous == cumulative { return }
            let last = TokenTally.parse(info["last_token_usage"])
            let delta = previous.flatMap { cumulative.subtracting($0) }
            // The first counter may include forked or resumed history. A reset
            // can also lower cumulative counters. Count only the supplied last
            // call in either case, never all inherited cumulative usage.
            guard let tokens = delta ?? last, tokens.total > 0 else { return }
            let canonical = APIPrices.canonical(model)
            largestInputs[canonical] = max(largestInputs[canonical] ?? 0, last?.input ?? tokens.input)
            guard date >= cutoff, date.timeIntervalSince1970 >= started else { return }
            let fingerprint = "\(object["timestamp"] ?? "")|\(turn.isEmpty ? session : turn)|\(model)|\(provider)|\(tokens.input)|\(tokens.cached)|\(tokens.written)|\(tokens.output)"
            calls.append(ModelCall(id: Self.digest(fingerprint), timestamp: date.timeIntervalSince1970, session: session,
                                   model: model, provider: provider, tokens: tokens, workspace: workspace,
                                   aggregated: last == nil || (delta != nil && delta != last)))
        }
    }
    static func workspaceLabel(_ path: String) -> String {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "其他" }
        let name = URL(fileURLWithPath: cleaned).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "其他" : String(name.prefix(64))
    }
    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct UsageIndex: Codable {
    var version = 2
    var files: [String: RolloutCursor] = [:]
}

actor UsageScanner {
    private var index = UsageIndex()
    private var loadedHome: URL?

    func scan(home: URL, now: Date = Date(), progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> UsageStatistics {
        let cache = home.appendingPathComponent("menubar/usage-index.json")
        if loadedHome != home {
            if let data = try? LocalData.boundedData(cache, limit: 96 * 1024 * 1024), let saved = try? JSONDecoder().decode(UsageIndex.self, from: data), saved.version == 2 {
                index = saved
            } else { index = UsageIndex() }
            loadedHome = home
        }
        let cutoff = now.addingTimeInterval(-31 * 86400)
        let files = try Self.rolloutFiles(home: home)
        let paths = Set(files.map(\.path))
        index.files = index.files.filter { paths.contains($0.key) }
        var unreadable = 0
        for (number, file) in files.enumerated() {
            try Task.checkCancellation()
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var cursor = index.files[file.path] ?? RolloutCursor()
                if size < cursor.offset || (cursor.inode != 0 && inode != cursor.inode) || (size == cursor.size && modified != cursor.modified) {
                    cursor = RolloutCursor()
                }
                if cursor.size != size || cursor.modified != modified {
                    try Self.read(file, cursor: &cursor, size: size, cutoff: cutoff)
                }
                cursor.size = size; cursor.modified = modified; cursor.inode = inode
                cursor.calls.removeAll { $0.date < cutoff }
                index.files[file.path] = cursor
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
            if number % 12 == 0 { await progress(number + 1, files.count) }
        }
        try Task.checkCancellation()
        try PrivateJSON.write(index, to: cache)
        var seen: Set<String> = [], result = UsageStatistics()
        for file in index.files.values {
            result.skipped += file.skipped
            for (model, input) in file.largestInputs where input > 272000 { result.longSessions.insert(file.session + "|" + model) }
            for call in file.calls where seen.insert(call.id).inserted { result.calls.append(call) }
        }
        result.calls.sort { $0.timestamp < $1.timestamp }
        result.scannedFiles = files.count; result.skipped += unreadable; result.checkedAt = now
        result.prepare(now: now)
        await progress(files.count, files.count)
        return result
    }

    private static func rolloutFiles(home: URL) throws -> [URL] {
        var files: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true && values.isSymbolicLink != true { files.append(url) }
            }
        }
        return files
    }

    private static func read(_ file: URL, cursor: inout RolloutCursor, size: UInt64, cutoff: Date) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        var position = cursor.offset, line = Data(), discard = cursor.discardingLine
        while position < size {
            try Task.checkCancellation()
            // A large rollout can run for seconds without an actor suspension.
            // Drain Foundation's temporary Data/JSON/formatter objects per chunk.
            let consumed = try autoreleasepool { () throws -> Bool in
            let chunk = try handle.read(upToCount: Int(min(256 * 1024, size - position))) ?? Data()
            if chunk.isEmpty { return false }
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 10) {
                if !discard { line.append(chunk[start..<end]) }
                if !discard && Self.relevant(line) { cursor.consume(line, since: cutoff) }
                cursor.offset = position + UInt64(end - chunk.startIndex + 1)
                line.removeAll(keepingCapacity: true); discard = false
                start = chunk.index(after: end)
            }
            if !discard { line.append(chunk[start...]) }
            // Tool outputs can be multi-gigabyte lines. Never retain them or
            // session prose in the index, and keep memory bounded while scanning.
            if line.count > 8 * 1024 * 1024 {
                if Self.relevant(line) { cursor.skipped += 1 }
                line.removeAll(keepingCapacity: false); discard = true
            }
            position += UInt64(chunk.count)
            return true
            }
            if !consumed { break }
        }
        cursor.discardingLine = discard
        if discard { cursor.offset = position }
        // An unfinished final line is retried from the last complete offset.
    }
    private static func relevant(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        return ["session_meta", "turn_context", "token_count"].contains { prefix.contains("\"" + $0 + "\"") }
    }
}
