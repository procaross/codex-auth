import Foundation

@main enum PanelDismissalTests {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func main() {
        let icon = CGRect(x: 950, y: 880, width: 58, height: 24)
        let panel = CGRect(x: 750, y: 150, width: 438, height: 704)
        func dismiss(_ point: CGPoint, sheet: Bool = false, iconFrame: CGRect? = icon) -> Bool {
            PanelDismissal.shouldDismiss(at: point, statusItemFrame: iconFrame,
                                         panelFrame: panel, hasAttachedSheet: sheet)
        }
        // Reproduce a menu-bar mouse-down observed globally before the button's mouse-up.
        var visible = false
        for click in 1...6 {
            if visible && dismiss(CGPoint(x: 975, y: 892)) { visible = false }
            visible.toggle()
            check(visible == (click % 2 == 1), "status click \(click) must toggle exactly once")
        }
        check(!dismiss(CGPoint(x: 1003, y: 892)), "quota/count text is part of the status button")
        check(!dismiss(CGPoint(x: 751, y: 151)), "panel controls must remain interactive")
        check(dismiss(CGPoint(x: 500, y: 400)), "outside click must dismiss")
        check(dismiss(CGPoint(x: 1030, y: 892)), "another menu-bar icon must dismiss")
        check(!dismiss(CGPoint(x: 500, y: 400), sheet: true), "sheet owns click tracking")
        check(!dismiss(CGPoint(x: 975, y: 892)), "right-button mouse-down must leave context-menu handling to the icon")
        check(dismiss(CGPoint(x: 500, y: 400), iconFrame: nil), "missing status window still allows outside dismissal")
        let otherScreenIcon = CGRect(x: -1850, y: -40, width: 60, height: 24)
        check(!dismiss(CGPoint(x: -1830, y: -30), iconFrame: otherScreenIcon), "negative screen origins must work")
        check(dismiss(CGPoint(x: 975, y: 892), iconFrame: otherScreenIcon), "use the current screen's anchor after moving displays")
        print("Panel dismissal: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
