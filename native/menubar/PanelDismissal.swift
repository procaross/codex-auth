import CoreGraphics

/// Classifies an observed mouse-down in global Cocoa screen coordinates.
/// The status button owns the matching mouse-up and toggles the panel itself.
enum PanelDismissal {
    static func shouldDismiss(at point: CGPoint, statusItemFrame: CGRect?, panelFrame: CGRect,
                              hasAttachedSheet: Bool) -> Bool {
        guard !hasAttachedSheet else { return false }
        if let statusItemFrame, statusItemFrame.contains(point) { return false }
        return !panelFrame.contains(point)
    }
}
