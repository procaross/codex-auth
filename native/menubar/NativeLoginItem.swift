import Foundation
import ServiceManagement
import Darwin

enum NativeLoginItem {
    static func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        return service.status
    }

    /// Runs inside the installed app bundle so the login item belongs to the app.
    /// No AppDelegate, account refresh, or second menu-bar instance is started.
    static func commandLine(_ arguments: [String]) -> Int32? {
        guard arguments.contains("--login-item") else { return nil }
        guard arguments.count == 3, arguments[1] == "--login-item",
              ["status", "enable", "disable"].contains(arguments[2]) else {
            FileHandle.standardError.write(Data("Usage: <app executable> --login-item status|enable|disable\n".utf8))
            return 64
        }
        let action = arguments[2]
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundle.pathExtension == "app" else {
            FileHandle.standardError.write(Data("Run this command from an installed application bundle.\n".utf8))
            return 1
        }
        if action != "status" {
            let parent = bundle.deletingLastPathComponent().standardizedFileURL
            let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").resolvingSymlinksInPath()
            guard parent == URL(fileURLWithPath: "/Applications", isDirectory: true) || parent == userApplications else {
                FileHandle.standardError.write(Data("Install the app in /Applications or ~/Applications before changing its login item.\n".utf8))
                return 1
            }
        }
        var failure: NSError?
        if action != "status" {
            do { _ = try setEnabled(action == "enable") }
            catch { failure = error as NSError }
        }
        let status = SMAppService.mainApp.status
        var report: [String: Any] = [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "path": bundle.path,
            "status": name(status),
            "enabled": status == .enabled,
            "requiresApproval": status == .requiresApproval
        ]
        if let failure { report["error"] = "Login item operation failed (\(failure.domain), code \(failure.code))." }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
        if failure != nil { return 1 }
        if action == "enable" && status != .enabled { return 2 }
        if action == "disable" && status != .notRegistered { return 2 }
        return 0
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
