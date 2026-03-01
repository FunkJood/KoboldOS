import SwiftUI
import AppKit
import KoboldCore

// MARK: - Shared Navigation State (used by Commands to change tabs)

extension Notification.Name {
    static let koboldNavigate = Notification.Name("koboldNavigateTo")
    static let koboldNavigateSettings = Notification.Name("koboldNavigateSettings")
    static let koboldShowMainWindow = Notification.Name("koboldShowMainWindow")
    static let koboldShutdownSave = Notification.Name("koboldShutdownSave")
    static let koboldWorkflowChanged = Notification.Name("koboldWorkflowChanged")
    static let koboldProjectsChanged = Notification.Name("koboldProjectsChanged")
    static let koboldWorkflowRun = Notification.Name("koboldWorkflowRun")
    static let koboldLateStartup = Notification.Name("koboldLateStartup")
    static let koboldScheduledTaskFired = Notification.Name("koboldScheduledTaskFired")
    static let koboldToolApprovalRequest = Notification.Name("koboldToolApprovalRequest")
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
                    // Daemon wird bereits in AppDelegate.applicationDidFinishLaunching gestartet
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

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // App läuft im Hintergrund weiter (Punkt am Dock-Icon bleibt)
    }

    // Held for process lifetime — prevents App Nap and requests high scheduler priority.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Globale Permission-Defaults registrieren.
        UserDefaults.standard.register(defaults: [
            "kobold.autonomyLevel": 2,
            "kobold.perm.shell": true,
            "kobold.perm.fileWrite": true,
            "kobold.perm.createFiles": true,
            "kobold.perm.deleteFiles": false,
            "kobold.perm.network": true,
            "kobold.perm.confirmAdmin": true,
            "kobold.perm.modifyMemory": true,
            "kobold.perm.notifications": true,
            "kobold.perm.calendar": true,
            "kobold.perm.contacts": false,
            "kobold.perm.mail": false,
            "kobold.perm.playwright": false,
            "kobold.perm.screenControl": false,
            "kobold.perm.selfCheck": false,
            "kobold.perm.installPkgs": false,
            "kobold.shell.powerTier": true,
            "kobold.shell.normalTier": true,
        ])

        // Disable App Nap for LLM inference performance.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .latencyCritical,
            ],
            reason: "KoboldOS Agent Inference — requires full CPU access"
        )
        print("[AppDelegate] High-performance activity token acquired")

        // G6: Cross-Module Logging-Callbacks setzen (KoboldCore → KoboldOSControlPanel)
        AgentLoop.onToolLog = { msg in ktool(msg) }
        AgentLoop.onBuildLog = { msg in kbuild(msg) }

        // Start daemon
        RuntimeManager.shared.startDaemon()
        print("[AppDelegate] Daemon start triggered")

        // Auto-start Telegram bot if configured
        let telegramToken = UserDefaults.standard.string(forKey: "kobold.telegram.token") ?? ""
        if !telegramToken.isEmpty {
            let chatIdStr = UserDefaults.standard.string(forKey: "kobold.telegram.chatId") ?? ""
            let groupIdsStr = UserDefaults.standard.string(forKey: "kobold.telegram.groupIds") ?? ""
            let ids = SettingsView.parseTelegramIds(chatId: chatIdStr, groupIds: groupIdsStr)
            TelegramBot.shared.start(token: telegramToken, allowedChatIds: ids)
            print("[AppDelegate] Telegram bot auto-started (allowed IDs: \(ids))")
        }

        // Auto-start WebApp server if configured
        if UserDefaults.standard.bool(forKey: "kobold.webapp.autostart") &&
           UserDefaults.standard.bool(forKey: "kobold.webapp.enabled") {
            let wPort = UserDefaults.standard.integer(forKey: "kobold.webapp.port")
            let wUser = UserDefaults.standard.string(forKey: "kobold.webapp.username") ?? "admin"
            let wPass = UserDefaults.standard.string(forKey: "kobold.webapp.password") ?? ""
            if !wPass.isEmpty {
                let dPort = UserDefaults.standard.integer(forKey: "kobold.port")
                let dToken = RuntimeManager.shared.authToken
                WebAppServer.shared.start(
                    port: wPort == 0 ? 8090 : wPort,
                    daemonPort: dPort == 0 ? 8080 : dPort,
                    daemonToken: dToken,
                    username: wUser,
                    password: wPass
                )
                print("[AppDelegate] WebApp auto-started on port \(wPort == 0 ? 8090 : wPort)")
            }
        }

        // Initialize TTS Manager
        _ = TTSManager.shared

        // Post late startup notification for background tasks
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            NotificationCenter.default.post(name: .koboldLateStartup, object: nil)
        }

        // Doppelklick auf Titelleiste = Fenster maximieren/wiederherstellen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let window = NSApplication.shared.windows.first else { return }
            let titleBarGesture = NSClickGestureRecognizer(target: self, action: #selector(self.handleTitleBarDoubleClick(_:)))
            titleBarGesture.numberOfClicksRequired = 2
            // Geste auf die gesamte contentView legen — aber nur obere 38px reagieren (siehe Action)
            window.contentView?.addGestureRecognizer(titleBarGesture)
            print("[AppDelegate] Title bar double-click gesture installed")
        }
    }

    @MainActor @objc private func handleTitleBarDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let window = view.window else { return }
        let loc = gesture.location(in: view)
        // macOS: Ursprung unten-links, y steigt nach oben → obere 38px = nahe bounds.maxY
        guard loc.y >= view.bounds.height - 38 else { return }
        window.zoom(nil)
    }

    /// Dock-Icon geklickt → Fenster wieder öffnen falls geschlossen/minimiert.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Kein sichtbares Fenster → erstes Fenster wieder zeigen
            if let window = sender.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A4: Shutdown-Reihenfolge: Save → Cleanup → Token freigeben
        // 1. RuntimeViewModel reagiert auf diese Notification: save + cleanup
        NotificationCenter.default.post(name: .koboldShutdownSave, object: nil)

        // A3: Telegram-Bot stoppen (Polling-Task läuft sonst ewig)
        TelegramBot.shared.stop()

        // 3. Proactive + Runtime cleanup
        ProactiveEngine.shared.cleanup()
        RuntimeManager.shared.cleanup()

        // A1: Activity Token freigeben (macOS hielt Prozess wegen beginActivity() am Leben)
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            print("[AppDelegate] Activity token released")
        }
    }
}
