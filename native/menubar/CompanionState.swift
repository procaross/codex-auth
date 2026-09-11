import Foundation

enum StatusDisplay: String, Codable, CaseIterable {
    case remaining, countdown, icon
    var title: String { switch self { case .remaining: return "每周剩余"; case .countdown: return "重置倒计时"; case .icon: return "仅图标" } }
    func text(weekly: UsageWindow?, now: Date = Date()) -> String {
        switch self {
        case .icon: return ""
        case .remaining: return weekly.map { " \(Int($0.remaining.rounded()))%" } ?? " —"
        case .countdown:
            guard let reset = weekly?.resetDate else { return " —" }
            let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
            if minutes <= 0 { return " 待刷新" }
            if minutes >= 1440 { return " \(minutes / 1440)天\(minutes % 1440 / 60)时" }
            if minutes >= 60 { return " \(minutes / 60)时\(minutes % 60)分" }
            return " \(minutes)分"
        }
    }
}

struct AccountDecoration: Codable {
    var name = ""
    var note = ""
    var hidden = false
}

struct QuotaPoint: Codable, Identifiable {
    var timestamp: Double
    var remaining: Double
    var resetsAt: Double?
    var id: Double { timestamp }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var cycle: String { resetsAt.map { String(Int($0)) } ?? "unknown" }
}

struct AlertLedger: Codable {
    var previous: QuotaPoint
    var warnedLevel: Int
    var recoveredCycle: String?
    var pendingRecovery: QuotaPoint?
}

struct QuotaAlert: Identifiable {
    enum Kind { case low, critical, recovered }
    let account: String
    let point: QuotaPoint
    let kind: Kind
    var id: String { account + ":" + point.cycle + ":" + String(describing: kind) }
}

struct CompanionState: Codable {
    var version = 1
    var accounts: [String: AccountDecoration] = [:]
    var order: [String] = []
    var statusDisplay: StatusDisplay = .remaining
    var notificationsEnabled = true
    var notifyAllAccounts = false
    var recoveryEnabled = true
    var lowThreshold = 20
    var history: [String: [QuotaPoint]] = [:]
    var alertLedger: [String: AlertLedger] = [:]

    static func location(home: URL) -> URL { home.appendingPathComponent("menubar/state.json") }
    static func read(home: URL) throws -> Self {
        let url = location(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: LocalData.boundedData(url, limit: 32 * 1024 * 1024))
        guard value.version == 1, (1...50).contains(value.lowThreshold) else { throw ModelError.unsupportedRegistry }
        return value
    }
    func save(home: URL) throws {
        try PrivateJSON.write(self, to: Self.location(home: home))
    }
    mutating func pruneHistory(now: Date) {
        history = history.compactMapValues { points in
            let recent = points.filter { now.timeIntervalSince($0.date) <= 31 * 86400 }
            return recent.isEmpty ? nil : recent
        }
    }
    func label(_ account: AccountRecord) -> String {
        let name = accounts[account.id]?.name ?? ""
        return name.isEmpty ? account.label : name
    }
    func visibleAccounts(_ records: [AccountRecord], active: String?) -> [AccountRecord] {
        let positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return records.enumerated().filter { $0.element.id == active || accounts[$0.element.id]?.hidden != true }
            .sorted { (positions[$0.element.id] ?? (order.count + $0.offset)) < (positions[$1.element.id] ?? (order.count + $1.offset)) }
            .map(\.element)
    }
    mutating func decorate(_ key: String, name: String, note: String) {
        var value = accounts[key] ?? AccountDecoration()
        value.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        value.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        accounts[key] = value
    }
    mutating func move(_ key: String, by delta: Int, records: [AccountRecord], active: String?) {
        var ids = visibleAccounts(records, active: active).map(\.id)
        guard let from = ids.firstIndex(of: key) else { return }
        let to = min(max(0, from + delta), ids.count - 1)
        ids.swapAt(from, to); order = ids
    }
    mutating func observe(_ account: AccountRecord, now: Date, deliveryAllowed: Bool = true) -> [QuotaAlert] {
        guard let weekly = account.weekly, let stamp = account.lastUsageAt,
              stamp.isFinite, stamp <= now.timeIntervalSince1970 + 60, weekly.usedPercent.isFinite else { return [] }
        let point = QuotaPoint(timestamp: stamp, remaining: weekly.remaining, resetsAt: weekly.resetsAt)
        let level = point.remaining <= Double(min(5, lowThreshold)) ? 2 : point.remaining <= Double(lowThreshold) ? 1 : 0
        var points = history[account.id] ?? []
        if points.last.map({ stamp > $0.timestamp }) ?? true {
            points.append(point)
            points.removeAll { now.timeIntervalSince($0.date) > 31 * 86400 }
            history[account.id] = Array(points.suffix(10000))
        }
        guard notificationsEnabled, deliveryAllowed, var ledger = alertLedger[account.id] else {
            alertLedger[account.id] = AlertLedger(previous: point, warnedLevel: level)
            return [] // Initial snapshots establish a baseline, not an alert burst.
        }
        guard stamp >= ledger.previous.timestamp else { return [] }
        let previous = ledger.previous
        if point.cycle != previous.cycle { ledger.warnedLevel = 0 }
        if recoveryEnabled, ledger.recoveredCycle != point.cycle,
           previous.remaining <= Double(lowThreshold), point.remaining > Double(lowThreshold + 5) {
            ledger.pendingRecovery = point
        }
        if !recoveryEnabled || point.remaining <= Double(lowThreshold) || ledger.pendingRecovery?.cycle != point.cycle {
            ledger.pendingRecovery = nil
        }
        ledger.previous = point
        alertLedger[account.id] = ledger
        guard now.timeIntervalSince(point.date) <= 900 else { return [] }
        if let pending = ledger.pendingRecovery, now.timeIntervalSince(pending.date) <= 900 {
            return [QuotaAlert(account: account.id, point: point, kind: .recovered)]
        }
        if level > ledger.warnedLevel {
            return [QuotaAlert(account: account.id, point: point, kind: level == 2 ? .critical : .low)]
        }
        return []
    }
    mutating func acknowledge(_ alert: QuotaAlert) {
        guard var ledger = alertLedger[alert.account] else { return }
        switch alert.kind {
        case .low: ledger.warnedLevel = max(1, ledger.warnedLevel)
        case .critical: ledger.warnedLevel = 2
        case .recovered: ledger.recoveredCycle = alert.point.cycle; ledger.pendingRecovery = nil
        }
        alertLedger[alert.account] = ledger
    }
}

enum PrivateJSON {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
