import AppKit
import SwiftUI

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: CompanionPanel!
    private var store: AppStore!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        if demo && CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        store = AppStore(demo: demo)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusIcon()
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Codex Auth，查看额度与账号")
        }
        store.onChange = { [weak self] in self?.updateStatus() }
        if !demo {
            let notifications = QuotaNotifications()
            notifications.onOpen = { [weak self] key in
                guard let self else { return }
                if let key, self.store.accounts.contains(where: { $0.id == key }) { self.store.selectedKey = key }
                self.store.tab = 0; self.store.settings = false; self.showPanel()
            }
            store.notifications = notifications
            Task { await store.configureNotifications() }
        }
        updateStatus()
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let height = min(704, (screen?.visibleFrame.height ?? 850) - 24)
        panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 438, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = demo ? .normal : .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The native glass supplies the edge treatment. A window-server shadow
        // can outline the rectangular backing surface outside its rounded glass.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.title = "Codex Auth"
        let cornerRadius: CGFloat = 26
        let view = PanelView(store: store, close: { [weak self] in self?.closePanel() }, quit: { NSApp.terminate(nil) })
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        let hosting = NSHostingView(rootView: view)
        // The menu panel, not each page's ideal size, owns the window geometry.
        hosting.sizingOptions = []
        let glass = NSGlassEffectView(frame: panel.contentView!.bounds)
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.clipsToBounds = true
        glass.contentView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor), hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        panel.contentView = glass
        let refreshTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
                await self?.store.refreshIfNeeded()
            }
        }
        refreshTimer.tolerance = 5
        RunLoop.main.add(refreshTimer, forMode: .common)
        self.refreshTimer = refreshTimer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(closePanel), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        Task { await store.refreshIfNeeded() }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        if !demo { UserDefaults.standard.set(true, forKey: "hasLaunched") }
        if CommandLine.arguments.contains("--show") || demo || firstLaunch { showPanel() }
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            let show = menu.addItem(withTitle: "打开 Codex Auth", action: #selector(showPanel), keyEquivalent: "")
            show.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Codex Auth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        panel.isVisible ? closePanel() : showPanel()
    }

    @objc private func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        let frame = screen.visibleFrame
        let height = min(704, frame.height - 24)
        let x = min(max(frame.minX + 10, anchor.midX - 219), frame.maxX - 448)
        let y = max(frame.minY + 12, anchor.minY - height - 7)
        panel.setFrame(NSRect(x: x, y: y, width: 438, height: height), display: true)
        panel.makeKeyAndOrderFront(nil)
        store.opened()
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.panel.attachedSheet != nil { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.closePanel(); return nil }
            // Native menus and sheets own their click tracking. External clicks
            // are handled by the global monitor; keep local editors open.
            return event
        }
    }

    @objc private func closePanel() {
        panel?.orderOut(nil)
        store?.visible = false
        removeMonitors()
    }

    @objc private func systemDidWake() {
        Task { await store.refreshIfNeeded() }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    private func updateStatus() {
        let account = store.active
        let remaining = account?.weekly?.remaining
        statusItem.button?.title = store.companion.statusDisplay.text(weekly: account?.weekly)
        statusItem.button?.toolTip = "Codex Auth" + (remaining.map { " · 每周剩余 \(Int($0.rounded()))%（缓存）" } ?? " · 暂无每周额度数据")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.loginPhase != nil else { return .terminateNow }
        Task {
            await store.finishLoginForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshTimer?.invalidate(); removeMonitors(); store.stop()
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.labelColor.setFill()
            let rows = ["000000010000000", "000000010000000", "000111111111000", "001100000001100", "011000000000110", "011011000110110", "011011000110110", "011000000000110", "001100000001100", "000111111111000", "000001111100000", "000111111111000"]
            let size: CGFloat = 1.15
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "1" {
                    NSRect(x: 1 + CGFloat(column) * size, y: 16 - CGFloat(row) * size, width: size, height: size).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@main enum CodexAuthMenuBar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
