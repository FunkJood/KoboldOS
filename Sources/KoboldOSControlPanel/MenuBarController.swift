import AppKit
import SwiftUI
// MARK: - MenuBarController
// Manages the NSStatusItem (menu bar icon) and popover for always-on mode.

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    @Published var isMenuBarEnabled: Bool = false
    @Published var isPopoverShown: Bool = false

    @AppStorage("kobold.menuBar.enabled") private var menuBarEnabledSetting: Bool = false
    @AppStorage("kobold.menuBar.hideMainWindow") private var hideMainWindowOnClose: Bool = true

    private override init() {
        super.init()
        isMenuBarEnabled = menuBarEnabledSetting
        if isMenuBarEnabled {
            setupStatusItem()
        }
    }

    // MARK: - Enable / Disable

    func enable() {
        guard statusItem == nil else { return }
        menuBarEnabledSetting = true
        isMenuBarEnabled = true
        setupStatusItem()
        updateActivationPolicy()
    }

    func disable() {
        menuBarEnabledSetting = false
        isMenuBarEnabled = false
        teardownStatusItem()
        updateActivationPolicy()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "KoboldOS")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.animates = true

        let popoverView = MenuBarPopoverView()
            .environmentObject(RuntimeManager.shared)
        popover.contentViewController = NSHostingController(rootView: popoverView)

        self.popover = popover

        // Monitor clicks outside popover to close it
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func teardownStatusItem() {
        closePopover()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        popover = nil
    }

    // MARK: - Click Handling

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Right-Click Context Menu

    private func showContextMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let autostartItem = NSMenuItem(title: "Autostart", action: #selector(toggleAutostart(_:)), keyEquivalent: "")
        autostartItem.target = self
        autostartItem.state = LaunchAgentManager.shared.isEnabled ? .on : .off
        menu.addItem(autostartItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Beenden", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Reset menu so left-click goes back to popover
        statusItem?.menu = nil
    }

    @objc private func openSettings() {
        showMainWindow()
        NotificationCenter.default.post(name: .koboldNavigateSettings, object: nil)
    }

    @objc private func toggleAutostart(_ sender: NSMenuItem) {
        if LaunchAgentManager.shared.isEnabled {
            LaunchAgentManager.shared.disable()
        } else {
            LaunchAgentManager.shared.enable()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        isPopoverShown = true

        // Activate the app so popover gets focus
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        popover?.performClose(nil)
        isPopoverShown = false
    }

    // MARK: - Activation Policy

    func updateActivationPolicy() {
        if isMenuBarEnabled && hideMainWindowOnClose {
            // Accessory mode: no dock icon when all windows closed, only menu bar
            // But keep regular if a window is visible
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.className != "NSStatusBarWindow" }
            if hasVisibleWindow {
                NSApp.setActivationPolicy(.regular)
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Update Status Icon

    func updateStatusIcon(healthy: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = healthy ? "brain.head.profile" : "exclamationmark.triangle.fill"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "KoboldOS")
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
        // Tint via contentTintColor
        button.contentTintColor = healthy ? nil : .systemRed
    }

    // MARK: - Show Main Window

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Find or create the main window
        if let window = NSApp.windows.first(where: { $0.className != "NSStatusBarWindow" && !$0.className.contains("Popover") }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Open main window via notification
            NotificationCenter.default.post(name: .koboldShowMainWindow, object: nil)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let koboldShowMainWindow = Notification.Name("koboldShowMainWindow")
    static let koboldMenuBarSendMessage = Notification.Name("koboldMenuBarSendMessage")
    static let koboldNavigateSettings = Notification.Name("koboldNavigateSettings")
}
