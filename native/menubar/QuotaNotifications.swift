import AppKit
import CryptoKit
import UserNotifications

@MainActor final class QuotaNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String?) -> Void)?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func authorization(request: Bool = false) async -> String {
        center.delegate = self
        if request { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return "已允许"
        case .denied: return "系统通知未允许"
        default: return "尚未允许通知"
        }
    }

    func send(_ alert: QuotaAlert, name: String) async -> Bool {
        let status = await center.notificationSettings()
        guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.kind == .recovered ? "每周额度已恢复" : "每周额度偏低"
        content.body = "\(name) · 每周剩余 \(Int(alert.point.remaining.rounded()))%。" +
            (alert.kind == .recovered ? "可以继续使用。" : DisplayTime.reset(alert.point.resetsAt.map(Date.init(timeIntervalSince1970:))) + "。")
        content.sound = .default
        content.userInfo = ["account": alert.account]
        let id = SHA256.hash(data: Data(alert.id.utf8)).map { String(format: "%02x", $0) }.joined()
        do { try await center.add(UNNotificationRequest(identifier: "quota-" + id, content: content, trigger: nil)); return true }
        catch { return false }
    }

    func test() async -> Bool {
        guard await authorization(request: true) == "已允许" else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Codex Auth · 通知测试"
        content.body = "周额度偏低或恢复时，会在这里提醒你。这是一条测试通知。"
        content.sound = .default
        do { try await center.add(UNNotificationRequest(identifier: "quota-test", content: content, trigger: nil)); return true }
        catch { return false }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["account"] as? String
        Task { @MainActor in self.onOpen?(key) }
        completionHandler()
    }
}
