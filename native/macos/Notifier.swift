import AppKit
import UserNotifications

// A tiny owned app bundle gives notifications the Codex Auth name and icon.
// It has no network client and receives only public notification text/URLs.
final class NotificationApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var finished = false

    func finish(_ payload: [String: Any], code: Int32 = 0) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(code)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        center.delegate = self
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--status"] {
            center.getNotificationSettings { settings in
                self.finish([
                    "authorization": settings.authorizationStatus.rawValue,
                    "alerts": settings.alertSetting.rawValue,
                    "bundle_id": Bundle.main.bundleIdentifier ?? "unknown"
                ])
            }
        } else if args == ["--delivered"] {
            center.getDeliveredNotifications { notices in
                self.finish(["notifications": notices.map { ["id": $0.request.identifier, "title": $0.request.content.title, "body": $0.request.content.body] }])
            }
        } else if args == ["--authorize"] {
            authorize { self.finish(["authorized": true]) }
        } else if args.count == 4 && args[0] == "--send" {
            authorize { self.send(title: args[1], body: args[2], source: args[3]) }
        } else if args.isEmpty {
            // A click may relaunch the app. Allow the notification response to
            // arrive before terminating; do not send another notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish(["opened": true]) }
        } else {
            finish(["error": "Invalid notifier arguments."], code: 2)
        }
    }

    private func authorize(_ next: @escaping () -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                self.finish(["error": error.localizedDescription], code: 1)
            } else if !granted {
                self.finish(["error": "Allow notifications for Codex Auth in System Settings > Notifications."], code: 1)
            } else {
                next()
            }
        }
    }

    private func send(title: String, body: String, source: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Let the user's system sound and Focus preferences apply.
        content.sound = .default
        if let url = URL(string: source), url.scheme == "https", url.host != nil {
            content.userInfo = ["source": url.absoluteString]
        }
        let identifier = "codex-auth-" + UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                self.finish(["error": error.localizedDescription], code: 1)
            } else {
                // Acceptance and presentation are different: report acceptance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.finish(["accepted": true, "id": identifier])
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let raw = response.notification.request.content.userInfo["source"] as? String,
           let url = URL(string: raw), url.scheme == "https", url.host != nil {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finish(["opened": true]) }
    }
}

let app = NSApplication.shared
let delegate = NotificationApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
