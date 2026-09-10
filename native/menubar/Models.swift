import Foundation

struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Double?
    var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct UsageSnapshot: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let planType: String?

    // Some plans return a weekly primary window and no secondary window.
    // Never relabel a known weekly window as a five-hour allowance.
    func window(minutes: Int) -> UsageWindow? {
        let windows = [primary, secondary].compactMap { $0 }
        if let exact = windows.first(where: { $0.windowMinutes == minutes }) { return exact }
        let fallback = minutes == 300 ? primary : secondary
        return fallback?.windowMinutes == nil ? fallback : nil
    }
}

struct AccountRecord: Decodable, Identifiable {
    let accountKey: String
    let email: String
    let alias: String
    let accountName: String?
    let plan: String?
    let authMode: String?
    let lastUsage: UsageSnapshot?
    let lastUsageAt: Double?
    var id: String { accountKey }
    var label: String { alias.isEmpty ? email : alias }
    var planLabel: String {
        if authMode == "apikey" { return "API Key" }
        switch lastUsage?.planType ?? plan ?? "" {
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "plus": return "Plus"
        case "team", "business": return "Business"
        case "free": return "Free"
        case "edu": return "Edu"
        case "enterprise": return "Enterprise"
        default: return "未知套餐"
        }
    }
    var updatedAt: Date? { lastUsageAt.map(Date.init(timeIntervalSince1970:)) }
    var fiveHour: UsageWindow? { lastUsage?.window(minutes: 300) }
    var weekly: UsageWindow? { lastUsage?.window(minutes: 10080) }
}

struct RegistryFile: Decodable {
    let schemaVersion: Int
    let activeAccountKey: String?
    let accounts: [AccountRecord]
}

struct SubscriptionSnapshot {
    let until: Date?
    let checked: Date?
}

enum ModelError: Error { case unsupportedRegistry, oversizedFile }

enum LocalData {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func boundedData(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ModelError.oversizedFile }
        return data
    }

    static func registry(home: URL) throws -> RegistryFile {
        let url = home.appendingPathComponent("accounts/registry.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            return RegistryFile(schemaVersion: 3, activeAccountKey: nil, accounts: [])
        }
        let registry = try decoder.decode(RegistryFile.self, from: boundedData(url))
        guard (2...3).contains(registry.schemaVersion) else { throw ModelError.unsupportedRegistry }
        // Duplicate identities would make selection and SwiftUI identity ambiguous.
        guard Set(registry.accounts.map(\.id)).count == registry.accounts.count else {
            throw ModelError.unsupportedRegistry
        }
        return registry
    }

    static func snapshotFilename(_ key: String) -> String {
        let safe = !key.isEmpty && key != "." && key != ".." && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (safe ? key : encoded) + ".auth.json"
    }

    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func authMetadata(_ data: Data) -> (key: String, subscription: SubscriptionSnapshot)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty { return nil }
        guard let tokens = root["tokens"] as? [String: Any],
              let jwt = tokens["id_token"] as? String,
              let tokenAccount = tokens["account_id"] as? String else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, !account.isEmpty,
              account == tokenAccount,
              let user = (auth["chatgpt_user_id"] ?? auth["user_id"]) as? String, !user.isEmpty else { return nil }
        return (user + "::" + account, SubscriptionSnapshot(
            until: date(auth["chatgpt_subscription_active_until"]),
            checked: date(auth["chatgpt_subscription_last_checked"])))
    }

    static func metadata(at url: URL) -> (key: String, subscription: SubscriptionSnapshot)? {
        guard let data = try? boundedData(url, limit: 512 * 1024) else { return nil }
        return authMetadata(data)
    }

    static func subscription(for record: AccountRecord, home: URL, activeKey: String?) -> SubscriptionSnapshot? {
        guard record.authMode != "apikey" else { return nil }
        let path = record.id == activeKey ? home.appendingPathComponent("auth.json") :
            home.appendingPathComponent("accounts/" + snapshotFilename(record.id))
        guard let metadata = metadata(at: path), metadata.key == record.id else { return nil }
        return metadata.subscription
    }

    // The CLI accepts substring queries, not registry keys or row numbers.
    // Only offer a query proven to resolve to this single identity. If another
    // process adds a duplicate afterwards, the CLI gets EOF at its selection
    // prompt and cannot accidentally choose the first account.
    static func switchQuery(for record: AccountRecord, in accounts: [AccountRecord]) -> String? {
        for query in [record.email, record.alias, record.accountName ?? ""] where !query.isEmpty && !query.hasPrefix("-") {
            let needle = asciiLower(query)
            let matches = accounts.filter { candidate in
                [candidate.email, candidate.alias, candidate.accountName ?? ""].contains {
                    asciiLower($0).contains(needle)
                }
            }
            if matches.count == 1 && matches[0].id == record.id { return query }
        }
        return nil
    }

    private static func asciiLower(_ value: String) -> String {
        String(decoding: value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

struct NewsSource: Decodable { let url: String? }
struct ResetReport: Decodable {
    let id: String
    let resetType: String
    let announcedAt: String
    let scheduledFor: String?
    let source: NewsSource?
}
struct ResetForecast: Decodable {
    let level: String
    let resetChancePercent: Double?
    let observedAt: String
    let expiresAt: String
    let source: NewsSource?
}
struct ResetData: Decodable {
    let latestReset: ResetReport?
    let scheduledReset: ResetReport?
    let activeWatch: ResetForecast?
}
struct ResetEnvelope: Decodable { let data: ResetData? }
struct ResetCache: Decodable {
    let status: ResetEnvelope?
    let checkedAt: Double?
    let lastError: String?
    var checkedDate: Date? { checkedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct NewsItem: Identifiable {
    enum Kind { case announced, planned, forecast }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let date: Date?
    let source: String?
    var url: URL? {
        guard let source, let url = URL(string: source), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func items(from data: ResetData?, now: Date = Date()) -> [NewsItem] {
        guard let data else { return [] }
        var items: [NewsItem] = []
        if let plan = data.scheduledReset {
            items.append(NewsItem(id: "plan:" + plan.id, kind: .planned,
                title: plan.resetType == "banked" ? "备用重置发放计划" : "额度重置计划",
                detail: "计划尚未确认执行，以后续公告为准。", date: LocalData.date(plan.scheduledFor), source: plan.source?.url))
        }
        if let latest = data.latestReset {
            items.append(NewsItem(id: "latest:" + latest.id, kind: .announced,
                title: latest.resetType == "banked" ? "备用重置次数已公告" : "额度重置已公告",
                detail: "适用范围与领取条件请查看原公告。", date: LocalData.date(latest.announcedAt), source: latest.source?.url))
        }
        if let watch = data.activeWatch, let expires = LocalData.date(watch.expiresAt), expires > now {
            let chance = watch.resetChancePercent.map { "预测概率 \(Int(min(100, max(0, $0))))%，" } ?? ""
            items.append(NewsItem(id: "forecast:" + watch.observedAt, kind: .forecast,
                title: "AI 重置预测 · 未确认", detail: chance + "不是官方重置公告。",
                date: LocalData.date(watch.observedAt), source: watch.source?.url))
        }
        return items
    }
}

enum DisplayTime {
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "尚未更新" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "重置时间未知" }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "窗口已结束，待刷新" }
        if minutes >= 1440 { return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }
    static func full(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
