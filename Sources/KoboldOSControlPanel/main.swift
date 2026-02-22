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
        // Intercept window close button: hide instead of close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { notif in
            guard let window = notif.object as? NSWindow,
                  window.className != "NSStatusBarWindow",
                  !window.className.contains("Popover"),
                  !window.className.contains("Sheet") else { return }
            // Hide the window and switch to accessory mode (menu bar only)
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Notify all observers to save data before shutdown
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)
        RuntimeManager.shared.stopDaemon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Restore regular activation policy when app becomes active
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking dock icon or menu bar: show main window
        if !flag {
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: {
                    $0.className != "NSStatusBarWindow" && !$0.className.contains("Popover")
                }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        return true
    }
}
