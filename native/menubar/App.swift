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
        updateStatus()
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let height = min(758, (screen?.visibleFrame.height ?? 850) - 24)
        panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 438, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = demo ? .normal : .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.title = "Codex Auth"
        let view = PanelView(store: store, close: { [weak self] in self?.closePanel() }, quit: { NSApp.terminate(nil) })
        let hosting = NSHostingView(rootView: view)
        let glass = NSGlassEffectView(frame: panel.contentView!.bounds)
        glass.style = .regular
        glass.cornerRadius = 26
        glass.contentView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor), hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        panel.contentView = glass
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.visible else { return }
                self.store.opened()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(closePanel), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
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
        let height = min(758, frame.height - 24)
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
            if event.type == .keyDown && event.keyCode == 53 { self.closePanel(); return nil }
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.statusItem.button?.window { self.closePanel() }
            return event
        }
    }

    @objc private func closePanel() {
        panel?.orderOut(nil)
        store?.visible = false
        removeMonitors()
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    private func updateStatus() {
        let account = store.active
        let remaining = account?.fiveHour?.remaining ?? account?.weekly?.remaining
        statusItem.button?.title = remaining.map { " \(Int($0.rounded()))%" } ?? ""
        let period = account?.fiveHour != nil ? "5 小时" : "每周"
        statusItem.button?.toolTip = "Codex Auth" + (remaining.map { " · \(period)剩余 \(Int($0.rounded()))%（缓存）" } ?? " · 暂无额度数据")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate(); removeMonitors(); store.runner.stop()
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
