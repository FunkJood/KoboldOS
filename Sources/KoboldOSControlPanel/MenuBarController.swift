import AppKit
import SwiftUI

// MARK: - MenuBarController (disabled — replaced with lightweight stub)
// The full NSStatusItem + NSPopover + independent MenuBarViewModel was a major freeze source:
// - Own chat system competing with main RuntimeViewModel
// - Global NSEvent monitor consuming events
// - NSPopover rendering pipeline parallel to main window
// All removed. Notification.Name extensions kept for backward compat.

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    static let shared = MenuBarController()

    @Published var isMenuBarEnabled: Bool = false
    @Published var isPopoverShown: Bool = false

    private override init() {
        super.init()
    }

    func enable() { /* no-op */ }
    func disable() { /* no-op */ }
    func updateActivationPolicy() { /* no-op */ }
    func updateStatusIcon(healthy: Bool) { /* no-op */ }
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.className != "NSStatusBarWindow" && !$0.className.contains("Popover")
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Notifications (kept for existing references)

extension Notification.Name {
    static let koboldShowMainWindow = Notification.Name("koboldShowMainWindow")
    static let koboldMenuBarSendMessage = Notification.Name("koboldMenuBarSendMessage")
    static let koboldNavigateSettings = Notification.Name("koboldNavigateSettings")
}
