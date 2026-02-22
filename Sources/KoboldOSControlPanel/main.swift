import SwiftUI
import AppKit

// MARK: - Shared Navigation State (used by Commands to change tabs)

extension Notification.Name {
    static let koboldNavigate = Notification.Name("koboldNavigateTo")
    static let koboldShutdownSave = Notification.Name("koboldShutdownSave")
}

// MARK: - App Entry Point

@main
struct KoboldOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runtimeManager = RuntimeManager.shared
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var menuBarController = MenuBarController.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(runtimeManager)
                .environmentObject(l10n)
                .onAppear {
                    runtimeManager.startDaemon()
                    // Initialize menu bar if enabled
                    if menuBarController.isMenuBarEnabled {
                        menuBarController.updateActivationPolicy()
                    }
                    // Auto-check for updates on launch
                    if UserDefaults.standard.bool(forKey: "kobold.autoCheckUpdates") {
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await UpdateManager.shared.checkForUpdates()
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Replace default "New" with New Chat
            CommandGroup(replacing: .newItem) {
                Button("Neue Unterhaltung") {
                    NotificationCenter.default.post(name: .koboldNavigate,
                                                   object: SidebarTab.chat)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Navigation menu
            CommandMenu("Navigation") {
                Button("Chat") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
                }.keyboardShortcut("1", modifiers: .command)

                Button("Dashboard") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.dashboard)
                }.keyboardShortcut("2", modifiers: .command)

                Button("Gedächtnis") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.memory)
                }.keyboardShortcut("3", modifiers: .command)

                Button("Aufgaben") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.tasks)
                }.keyboardShortcut("4", modifiers: .command)

                Button("Agenten") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.agents)
                }.keyboardShortcut("5", modifiers: .command)

                Button("Workflows") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.workflows)
                }.keyboardShortcut("6", modifiers: .command)

                Divider()

                Button("Einstellungen") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.settings)
                }.keyboardShortcut(",", modifiers: .command)
            }

            // Daemon menu
            CommandMenu("Daemon") {
                Button("Daemon neu starten") {
                    RuntimeManager.shared.retryConnection()
                }
                Button("Daemon stoppen") {
                    RuntimeManager.shared.stopDaemon()
                }
                Divider()
                Button("Verlauf löschen") {
                    NotificationCenter.default.post(name: Notification.Name("koboldClearHistory"), object: nil)
                }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // NEVER quit when window closes — always minimize to menu bar / dock
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Retarget the red close button on the main window: HIDE instead of CLOSE.
        // SwiftUI's WindowGroup closes + terminates on the default close action,
        // so we intercept at the button level to prevent that entirely.
        retargetCloseButtons()
        // Also watch for new windows (sheets, etc.) so we only retarget the main one
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.retargetCloseButtons()
        }
    }

    /// Finds the main window's red close button and rewires it to hide instead of close.
    private func retargetCloseButtons() {
        for window in NSApp.windows {
            guard window.className != "NSStatusBarWindow",
                  !window.className.contains("Popover"),
                  !window.className.contains("_NSAlertPanel") else { continue }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(hideWindowInsteadOfClose(_:))
            }
        }
    }

    /// Called when the user clicks the red X: hides the window, switches to accessory mode.
    @objc func hideWindowInsteadOfClose(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // Save data before hiding
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)
        // Hide the window (keeps it alive, just invisible)
        window.orderOut(nil)
        // Switch to accessory mode (hides Dock icon, menu bar stays)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)
        RuntimeManager.shared.stopDaemon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Re-show the hidden main window
            if let window = NSApp.windows.first(where: {
                $0.className != "NSStatusBarWindow" && !$0.className.contains("Popover")
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
