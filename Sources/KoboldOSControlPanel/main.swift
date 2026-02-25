import SwiftUI
import AppKit
import KoboldCore

// MARK: - Shared Navigation State (used by Commands to change tabs)

extension Notification.Name {
    static let koboldNavigate = Notification.Name("koboldNavigateTo")
    static let koboldShutdownSave = Notification.Name("koboldShutdownSave")
    static let koboldWorkflowChanged = Notification.Name("koboldWorkflowChanged")
    static let koboldProjectsChanged = Notification.Name("koboldProjectsChanged")
    static let koboldWorkflowRun = Notification.Name("koboldWorkflowRun")
}

// MARK: - App Entry Point

@main
struct KoboldOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runtimeManager = RuntimeManager.shared
    @StateObject private var l10n = LocalizationManager.shared
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(runtimeManager)
                .environmentObject(l10n)
                .onAppear {
                    runtimeManager.startDaemon()
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

                Button("Workflows") {
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.workflows)
                }.keyboardShortcut("5", modifiers: .command)

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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // NEVER quit when window closes — always minimize to menu bar / dock
        return false
    }

    // Held for process lifetime — prevents App Nap and requests high scheduler priority.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request maximum CPU access: disable App Nap, set latency-critical scheduling.
        // This allows macOS to schedule KoboldOS on multiple CPU cores at high priority
        // instead of throttling it when the window is not in the foreground.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep, // high QoS, allows idle sleep
                .latencyCritical,                      // lowest scheduler latency
                .automaticTerminationDisabled,          // don't auto-terminate
                .suddenTerminationDisabled,             // don't sudden-terminate
            ],
            reason: "KoboldOS Agent Inference — requires full CPU access"
        )
        print("[AppDelegate] High-performance activity token acquired")

        // CRITICAL: Start daemon IMMEDIATELY on launch — don't wait for onAppear
        RuntimeManager.shared.startDaemon()
        print("[AppDelegate] Daemon start triggered")

        // Auto-start Telegram bot if configured
        let telegramToken = UserDefaults.standard.string(forKey: "kobold.telegram.token") ?? ""
        if !telegramToken.isEmpty {
            let chatId = Int64(UserDefaults.standard.string(forKey: "kobold.telegram.chatId") ?? "") ?? 0
            TelegramBot.shared.start(token: telegramToken, allowedChatId: chatId)
            print("[AppDelegate] Telegram bot auto-started")
        }

        // Initialize TTS Manager (listens for speak notifications from agent)
        _ = TTSManager.shared

        // Re-embed any memories that don't have a vector yet (incremental, background)
        Task.detached(priority: .background) {
            // Brief delay so the UI is fully up before we start embedding
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let store = MemoryStore()
            // Allow actor-isolated loadFromDisk() Task to finish
            try? await Task.sleep(nanoseconds: 500_000_000)
            let entries = await store.allEntries()
            await EmbeddingStore.shared.reembedMissing(entries: entries)
        }

        // Set window delegate on main window once it appears (handles close → hide)
        DispatchQueue.main.async { [weak self] in
            if let window = NSApp.windows.first(where: {
                $0.className != "NSStatusBarWindow" && !$0.className.contains("Popover")
            }) {
                window.delegate = self
            }
        }
    }

    // MARK: - NSWindowDelegate — intercept close to hide instead

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Save data before hiding
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)
        // Hide the window (keeps it alive, just invisible)
        sender.orderOut(nil)
        // Switch to accessory mode (hides Dock icon, menu bar stays)
        NSApp.setActivationPolicy(.accessory)
        return false  // Prevent actual window close
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)
        ProactiveEngine.shared.cleanup()
        RuntimeManager.shared.cleanup()
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
