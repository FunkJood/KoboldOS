import SwiftUI

// MARK: - ProactiveSuggestion

struct ProactiveSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let message: String
    let action: String  // prompt to send to agent
    let priority: Priority
    let category: Category

    enum Priority: Int, Comparable {
        case low = 0, medium = 1, high = 2
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Category: String {
        case timeOfDay = "Tageszeit"
        case systemHealth = "System"
        case errorRecovery = "Fehler"
        case idle = "Leerlauf"
        case custom = "Benutzerdefiniert"
    }
}

// MARK: - ProactiveRule (user-configurable)

struct ProactiveRule: Identifiable, Codable {
    let id: String
    var name: String
    var triggerType: TriggerType
    var triggerValue: String  // time string "08:00", keyword, etc.
    var prompt: String        // what to suggest
    var enabled: Bool

    enum TriggerType: String, Codable, CaseIterable {
        case timeOfDay = "Uhrzeit"
        case keyword = "Stichwort"
        case idle = "Leerlauf"
        case startup = "Start"
    }

    /// No hardcoded defaults — user creates all rules via UI
    static let defaults: [ProactiveRule] = []
}

// MARK: - GoalEntry (user-defined long-term goals influencing agent autonomy)

struct GoalEntry: Identifiable, Codable {
    var id: String
    var text: String
    var isActive: Bool
    var priority: GoalPriority
    var category: GoalCategory

    init(id: String = UUID().uuidString, text: String, isActive: Bool = true, priority: GoalPriority = .medium, category: GoalCategory = .custom) {
        self.id = id; self.text = text; self.isActive = isActive; self.priority = priority; self.category = category
    }

    enum GoalPriority: String, Codable, CaseIterable {
        case high = "Hoch"
        case medium = "Mittel"
        case low = "Niedrig"

        var rawInt: Int {
            switch self { case .low: return 0; case .medium: return 1; case .high: return 2 }
        }
    }

    enum GoalCategory: String, Codable, CaseIterable {
        case system = "System"
        case productivity = "Produktivität"
        case personal = "Persönlich"
        case custom = "Benutzerdefiniert"
    }
}

// MARK: - IdleTask (user-defined tasks executed when user is inactive)

struct IdleTask: Identifiable, Codable {
    var id: String
    var name: String
    var prompt: String
    var enabled: Bool
    var priority: GoalEntry.GoalPriority
    var lastRun: Date?
    var runCount: Int
    var cooldownMinutes: Int  // min time between runs of this task

    init(id: String = UUID().uuidString, name: String, prompt: String, enabled: Bool = true,
         priority: GoalEntry.GoalPriority = .medium, cooldownMinutes: Int = 60) {
        self.id = id; self.name = name; self.prompt = prompt; self.enabled = enabled
        self.priority = priority; self.lastRun = nil; self.runCount = 0; self.cooldownMinutes = cooldownMinutes
    }

    /// No hardcoded examples — user creates all idle tasks via UI
    static let examples: [IdleTask] = []
}

// MARK: - ProactiveEngine

@MainActor
class ProactiveEngine: ObservableObject {
    static let shared = ProactiveEngine()

    @Published var suggestions: [ProactiveSuggestion] = []
    @Published var rules: [ProactiveRule] = []
    @Published var goals: [GoalEntry] = []
    @Published var idleTasks: [IdleTask] = []
    @Published var isChecking = false
    @Published var heartbeatStatus: String = "Idle"
    @Published var lastHeartbeat: Date? = nil
    @Published var idleTasksCompleted: Int = 0
    @Published var heartbeatLog: [HeartbeatLogEntry] = []

    // General
    @AppStorage("kobold.proactive.enabled") var isEnabled: Bool = true
    @AppStorage("kobold.proactive.interval") var checkIntervalMinutes: Int = 10
    @AppStorage("kobold.proactive.morningBriefing") var morningBriefing: Bool = true
    @AppStorage("kobold.proactive.eveningSummary") var eveningSummary: Bool = true
    @AppStorage("kobold.proactive.errorAlerts") var errorAlerts: Bool = true
    @AppStorage("kobold.proactive.systemHealth") var systemHealth: Bool = true

    // Heartbeat
    @AppStorage("kobold.proactive.heartbeat.enabled") var heartbeatEnabled: Bool = true
    @AppStorage("kobold.proactive.heartbeat.intervalSec") var heartbeatIntervalSec: Int = 60
    @AppStorage("kobold.proactive.heartbeat.showInDashboard") var heartbeatShowInDashboard: Bool = true
    @AppStorage("kobold.proactive.heartbeat.logRetention") var heartbeatLogRetention: Int = 50
    @AppStorage("kobold.proactive.heartbeat.notify") var heartbeatNotify: Bool = true

    // Idle Tasks
    @AppStorage("kobold.proactive.idleTasks") var idleTasksEnabled: Bool = true
    @AppStorage("kobold.proactive.idle.minIdleMinutes") var idleMinIdleMinutes: Int = 3
    @AppStorage("kobold.proactive.idle.maxPerHour") var idleMaxPerHour: Int = 5
    @AppStorage("kobold.proactive.idle.allowShell") var idleAllowShell: Bool = false
    @AppStorage("kobold.proactive.idle.allowNetwork") var idleAllowNetwork: Bool = false
    @AppStorage("kobold.proactive.idle.allowFileWrite") var idleAllowFileWrite: Bool = false
    @AppStorage("kobold.proactive.idle.onlyHighPriority") var idleOnlyHighPriority: Bool = false
    @AppStorage("kobold.proactive.idle.categories") var idleCategoriesRaw: String = "system,error,idle,custom"
    @AppStorage("kobold.proactive.idle.quietHoursStart") var idleQuietHoursStart: Int = 22
    @AppStorage("kobold.proactive.idle.quietHoursEnd") var idleQuietHoursEnd: Int = 7
    @AppStorage("kobold.proactive.idle.quietHoursEnabled") var idleQuietHoursEnabled: Bool = false
    @AppStorage("kobold.proactive.idle.notifyOnExecution") var idleNotifyOnExecution: Bool = true
    @AppStorage("kobold.proactive.idle.pauseOnUserActivity") var idlePauseOnUserActivity: Bool = true
    @AppStorage("kobold.proactive.idle.telegramMinPriority") var telegramMinPriority: String = "high"  // "high", "medium", "low", "off"

    var lastUserActivity: Date = .distantPast  // Start as "long idle" so first heartbeat can fire
    private var idleExecutionsThisHour: Int = 0
    private var lastHourReset: Date = Date()
    private var lastAutoTaskExecution: Date = .distantPast

    private var checkTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let rulesKey = "kobold.proactive.rules"
    private let goalsKey = "kobold.proactive.goals"
    private let idleTasksKey = "kobold.proactive.idleTasksList"

    struct HeartbeatLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let status: String
        let action: String?
    }

    private init() {
        migrateDefaults()
        loadRules()
        loadGoals()
        loadIdleTasks()
    }

    /// One-time migration: Fix broken defaults from versions < 0.3.6
    private func migrateDefaults() {
        let key = "kobold.proactive.migrated_v036"
        if !UserDefaults.standard.bool(forKey: key) {
            print("[ProactiveEngine] Migrating defaults to v0.3.6")
            UserDefaults.standard.set(true, forKey: "kobold.proactive.heartbeat.notify")
            UserDefaults.standard.set(false, forKey: "kobold.proactive.idle.onlyHighPriority")
            UserDefaults.standard.set("system,error,idle,custom", forKey: "kobold.proactive.idle.categories")
            UserDefaults.standard.set(5, forKey: "kobold.proactive.idle.maxPerHour")
            UserDefaults.standard.set(true, forKey: key)
            UserDefaults.standard.removeObject(forKey: idleTasksKey)
        }
        // v2: The critical switches — enabled + idleTasks MUST be on for the system to work.
        // Previous migration missed "kobold.proactive.enabled" entirely, and idleTasks kept resetting.
        let key2 = "kobold.proactive.migrated_v036_v2"
        if !UserDefaults.standard.bool(forKey: key2) {
            print("[ProactiveEngine] Migration v2: Enabling proactive engine + idle tasks")
            UserDefaults.standard.set(true, forKey: "kobold.proactive.enabled")
            UserDefaults.standard.set(true, forKey: "kobold.proactive.idleTasks")
            UserDefaults.standard.set(true, forKey: "kobold.proactive.heartbeat.enabled")
            UserDefaults.standard.set(true, forKey: key2)
        }
    }

    /// Call on app termination to prevent task leak
    func cleanup() {
        checkTask?.cancel()
        checkTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Rules Persistence

    func loadRules() {
        if let data = UserDefaults.standard.data(forKey: rulesKey),
           let saved = try? JSONDecoder().decode([ProactiveRule].self, from: data) {
            rules = saved
        }
        // No auto-populate — user creates rules via UI
    }

    func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: rulesKey)
        }
    }

    func addRule(_ rule: ProactiveRule) {
        rules.append(rule)
        saveRules()
    }

    func updateRule(_ rule: ProactiveRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        }
        saveRules()
    }

    func deleteRule(_ id: String) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    // MARK: - Goals Persistence

    func loadGoals() {
        if let data = UserDefaults.standard.data(forKey: goalsKey),
           let saved = try? JSONDecoder().decode([GoalEntry].self, from: data) {
            goals = saved
        }
    }

    func saveGoals() {
        if let data = try? JSONEncoder().encode(goals) {
            UserDefaults.standard.set(data, forKey: goalsKey)
        }
    }

    func addGoal(_ goal: GoalEntry) {
        goals.append(goal)
        saveGoals()
    }

    func deleteGoal(_ id: String) {
        goals.removeAll { $0.id == id }
        saveGoals()
    }

    // MARK: - Idle Tasks Persistence

    func loadIdleTasks() {
        if let data = UserDefaults.standard.data(forKey: idleTasksKey),
           let saved = try? JSONDecoder().decode([IdleTask].self, from: data) {
            idleTasks = saved
        }
        // No auto-populate — user creates idle tasks via UI
    }

    func saveIdleTasks() {
        if let data = try? JSONEncoder().encode(idleTasks) {
            UserDefaults.standard.set(data, forKey: idleTasksKey)
        }
    }

    func addIdleTask(_ task: IdleTask) {
        idleTasks.append(task)
        saveIdleTasks()
    }

    func deleteIdleTask(_ id: String) {
        idleTasks.removeAll { $0.id == id }
        saveIdleTasks()
    }

    func markIdleTaskRun(_ id: String) {
        if let idx = idleTasks.firstIndex(where: { $0.id == id }) {
            idleTasks[idx].lastRun = Date()
            idleTasks[idx].runCount += 1
            saveIdleTasks()
        }
    }

    /// Active goals formatted for agent system prompt injection
    var activeGoalsPromptSection: String {
        let active = goals.filter { $0.isActive }
        guard !active.isEmpty else { return "" }
        let list = active.map { "- [\($0.priority.rawValue)] \($0.text)" }.joined(separator: "\n")
        return """

        ## Langfristige Ziele (vom Nutzer definiert)
        Arbeite proaktiv auf diese Ziele hin. Schlage relevante Aktionen vor wenn passend.
        \(list)
        """
    }

    // MARK: - Timer Control

    func startPeriodicCheck(viewModel: RuntimeViewModel) {
        guard isEnabled else {
            print("[ProactiveEngine] DISABLED — not starting timers")
            return
        }
        let taskCount = idleTasks.filter(\.enabled).count
        print("[ProactiveEngine] ✅ Starting | interval=\(checkIntervalMinutes)m | heartbeat=\(heartbeatIntervalSec)s | idleTasks=\(idleTasksEnabled) (\(taskCount) tasks) | notify=\(heartbeatNotify) | onlyHigh=\(idleOnlyHighPriority) | minIdle=\(idleMinIdleMinutes)m")
        checkTask?.cancel()
        heartbeatTask?.cancel()
        let interval = UInt64(max(1, checkIntervalMinutes)) * 60_000_000_000
        checkTask = Task { [weak self, weak viewModel] in
            // Initial check after 15 seconds
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if let self, let viewModel, !Task.isCancelled {
                // F2: generateSuggestions ist leichtgewichtig genug für MainActor,
                // aber nur ausführen wenn UI nicht aktiv rendert (viewModel nicht loading)
                await MainActor.run {
                    guard !viewModel.agentLoading else { return }
                    self.generateSuggestions(viewModel: viewModel)
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, let viewModel else { break }
                await MainActor.run {
                    guard !viewModel.agentLoading else { return }
                    self.generateSuggestions(viewModel: viewModel)
                }
            }
        }
        if heartbeatEnabled {
            let hbNanos = UInt64(max(10, heartbeatIntervalSec)) * 1_000_000_000
            heartbeatTask = Task { [weak self, weak viewModel] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: hbNanos)
                    guard !Task.isCancelled, let self, let viewModel else { break }
                    await MainActor.run { self.heartbeat(viewModel: viewModel) }
                }
            }
        }
    }

    func stopPeriodicCheck() {
        checkTask?.cancel()
        checkTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func restartHeartbeat(viewModel: RuntimeViewModel) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard heartbeatEnabled, isEnabled else { return }
        let hbNanos = UInt64(max(10, heartbeatIntervalSec)) * 1_000_000_000
        heartbeatTask = Task { [weak self, weak viewModel] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: hbNanos)
                guard !Task.isCancelled, let self, let viewModel else { break }
                await MainActor.run { self.heartbeat(viewModel: viewModel) }
            }
        }
    }

    /// Record user interaction to track idle time
    func recordUserActivity() {
        lastUserActivity = Date()
    }

    // MARK: - Heartbeat (Proactive idle tasks)

    private func heartbeat(viewModel: RuntimeViewModel) {
        lastHeartbeat = Date()
        let now = Date()
        let idleMinutes = now.timeIntervalSince(lastUserActivity) / 60.0

        print("[ProactiveEngine] ♥ Heartbeat | idle=\(Int(idleMinutes))m | tasksEnabled=\(idleTasksEnabled) | onlyHigh=\(idleOnlyHighPriority) | notify=\(heartbeatNotify) | agentBusy=\(viewModel.agentLoading) | execs=\(idleExecutionsThisHour)/\(idleMaxPerHour)")

        // Reset hourly counter
        if now.timeIntervalSince(lastHourReset) > 3600 {
            idleExecutionsThisHour = 0
            lastHourReset = now
        }

        // Agent or Ollama busy?
        guard !viewModel.agentLoading && !viewModel.isOllamaBusy else {
            let reason = viewModel.isOllamaBusy ? "Ollama beschäftigt" : "Agent aktiv"
            heartbeatStatus = reason
            addHeartbeatLog(status: reason, action: nil)
            print("[ProactiveEngine] ⏸ Blocked: \(reason)")
            return
        }

        // Idle tasks disabled?
        guard idleTasksEnabled else {
            heartbeatStatus = "Idle"
            addHeartbeatLog(status: "Idle (Tasks deaktiviert)", action: nil)
            print("[ProactiveEngine] ⏸ idleTasksEnabled=false → skipping")
            return
        }

        // Quiet hours check
        if idleQuietHoursEnabled {
            let hour = Calendar.current.component(.hour, from: now)
            let inQuiet: Bool
            if idleQuietHoursStart > idleQuietHoursEnd {
                inQuiet = hour >= idleQuietHoursStart || hour < idleQuietHoursEnd
            } else {
                inQuiet = hour >= idleQuietHoursStart && hour < idleQuietHoursEnd
            }
            if inQuiet {
                heartbeatStatus = "Ruhezeit"
                addHeartbeatLog(status: "Ruhezeit (\(idleQuietHoursStart):00–\(idleQuietHoursEnd):00)", action: nil)
                print("[ProactiveEngine] ⏸ Quiet hours")
                return
            }
        }

        // Pause on user activity?
        if idlePauseOnUserActivity && idleMinutes < Double(idleMinIdleMinutes) {
            heartbeatStatus = "User aktiv"
            addHeartbeatLog(status: "User aktiv (Idle: \(Int(idleMinutes))m < \(idleMinIdleMinutes)m)", action: nil)
            print("[ProactiveEngine] ⏸ User active (\(Int(idleMinutes))m < \(idleMinIdleMinutes)m)")
            return
        }

        // Rate limit
        if idleExecutionsThisHour >= idleMaxPerHour {
            heartbeatStatus = "Limit erreicht (\(idleMaxPerHour)/h)"
            addHeartbeatLog(status: "Stunden-Limit erreicht", action: nil)
            print("[ProactiveEngine] ⏸ Rate limit reached (\(idleExecutionsThisHour)/\(idleMaxPerHour))")
            return
        }

        heartbeatStatus = "Beobachtet..."

        // 1. Try user-defined idle tasks first
        let availableTasks = idleTasks.filter { $0.enabled }
        let readyTasks = availableTasks.filter { task in
            if idleOnlyHighPriority && task.priority != .high { return false }
            if let lastRun = task.lastRun {
                let cooldownSec = Double(task.cooldownMinutes) * 60
                if now.timeIntervalSince(lastRun) < cooldownSec { return false }
            }
            return true
        }
        print("[ProactiveEngine] 📋 Tasks: \(idleTasks.count) total, \(availableTasks.count) enabled, \(readyTasks.count) ready (cooldown OK)")

        let permPrefix = idlePermissionPrefix()

        if let userTask = readyTasks.first {
            heartbeatStatus = "Führt aus: \(userTask.name)"
            addHeartbeatLog(status: "Idle-Aufgabe", action: userTask.name)
            print("[ProactiveEngine] ▶ EXECUTING idle task: \(userTask.name)")
            viewModel.executeTask(taskId: "idle-tasks", taskName: "Idle-Aufgaben", prompt: permPrefix + userTask.prompt, navigate: true, source: "idle")
            markIdleTaskRun(userTask.id)
            idleTasksCompleted += 1
            idleExecutionsThisHour += 1
            notify(viewModel: viewModel, title: "Idle-Task gestartet", message: userTask.name, type: .success, target: "tasks", priority: userTask.priority, forceSystem: idleNotifyOnExecution)
            return
        }

        // 2. Fallback to auto-generated suggestions (mit 30-min Cooldown)
        let autoCooldownOk = now.timeIntervalSince(lastAutoTaskExecution) > 1800
        let autoTasks = getAutoIdleTasks()
        print("[ProactiveEngine] 📋 Auto-tasks available: \(autoTasks.count), cooldownOk=\(autoCooldownOk)")
        if autoCooldownOk, let task = autoTasks.first {
            heartbeatStatus = "Führt aus: \(task.title)"
            addHeartbeatLog(status: "Auto-Aufgabe", action: task.title)
            print("[ProactiveEngine] ▶ EXECUTING auto task: \(task.title)")
            viewModel.executeTask(taskId: "idle-tasks", taskName: "Idle-Aufgaben", prompt: permPrefix + task.action, navigate: true, source: "idle")
            idleTasksCompleted += 1
            idleExecutionsThisHour += 1
            lastAutoTaskExecution = now
            let autoPrio: GoalEntry.GoalPriority = task.priority == .high ? .high : task.priority == .medium ? .medium : .low
            notify(viewModel: viewModel, title: "Auto-Task gestartet", message: task.title, type: .success, target: "tasks", priority: autoPrio, forceSystem: idleNotifyOnExecution)
        } else {
            heartbeatStatus = "Keine Aufgaben"
            addHeartbeatLog(status: "Keine passenden Aufgaben", action: nil)
            print("[ProactiveEngine] ⏸ No tasks ready (all on cooldown or filtered)")
        }
    }

    /// Unified notification helper — sends in-app, macOS system, and optionally Telegram notification
    private func notify(viewModel: RuntimeViewModel, title: String, message: String, type: KoboldNotification.NotificationType, target: String, priority: GoalEntry.GoalPriority = .medium, forceSystem: Bool = false) {
        guard heartbeatNotify || forceSystem else { return }
        viewModel.addNotification(title: title, message: message, type: type, navigationTarget: target)
        viewModel.postSystemNotification(title: "KoboldOS — \(title)", body: message)

        // Telegram senden wenn Priorität hoch genug
        if telegramMinPriority != "off" {
            let minLevel: Int
            switch telegramMinPriority {
            case "low": minLevel = 0
            case "medium": minLevel = 1
            case "high": minLevel = 2
            default: minLevel = 99  // off
            }
            if priority.rawInt >= minLevel {
                TelegramBot.shared.sendNotification("🤖 \(title): \(message)")
            }
        }
    }

    private func addHeartbeatLog(status: String, action: String?) {
        heartbeatLog.insert(HeartbeatLogEntry(timestamp: Date(), status: status, action: action), at: 0)
        if heartbeatLog.count > heartbeatLogRetention {
            heartbeatLog = Array(heartbeatLog.prefix(heartbeatLogRetention))
        }
    }

    /// Build permission restrictions string for idle task prompts
    private func idlePermissionPrefix() -> String {
        var restrictions: [String] = [
            "KEINE Telefonate/Anrufe (phone_call Tool VERBOTEN)",
            "KEINE selbständige Fehlerbewertung oder Selbstkritik — nur die Aufgabe ausführen"
        ]
        if !idleAllowShell { restrictions.append("KEIN Shell/Terminal") }
        if !idleAllowNetwork { restrictions.append("KEIN Netzwerk/Browser/HTTP") }
        if !idleAllowFileWrite { restrictions.append("KEINE Dateien schreiben/löschen") }
        return "[IDLE-TASK EINSCHRÄNKUNGEN: \(restrictions.joined(separator: ", ")). Nutze nur erlaubte Tools.]\n\n"
    }

    /// Next user-defined idle task that is ready to run (respects cooldown)
    private func getNextUserIdleTask() -> IdleTask? {
        let now = Date()
        return idleTasks.first { task in
            guard task.enabled else { return false }
            if idleOnlyHighPriority && task.priority != .high { return false }
            // Cooldown check
            if let lastRun = task.lastRun {
                let cooldownSec = Double(task.cooldownMinutes) * 60
                if now.timeIntervalSince(lastRun) < cooldownSec { return false }
            }
            return true
        }
    }

    /// Auto-generated suggestions filtered for idle execution
    private func getAutoIdleTasks() -> [ProactiveSuggestion] {
        let allowedCategories = Set(idleCategoriesRaw.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })

        return suggestions.filter { s in
            if idleOnlyHighPriority && s.priority != .high { return false }
            let catKey: String
            switch s.category {
            case .systemHealth: catKey = "system"
            case .errorRecovery: catKey = "error"
            case .timeOfDay: catKey = "time"
            case .idle: catKey = "idle"
            case .custom: catKey = "custom"
            }
            return allowedCategories.contains(catKey)
        }
    }

    func clearHeartbeatLog() {
        heartbeatLog.removeAll()
    }

    // MARK: - Generate Suggestions

    func generateSuggestions(viewModel: RuntimeViewModel) {
        guard isEnabled else { suggestions = []; return }
        isChecking = true
        defer { isChecking = false }

        var newSuggestions: [ProactiveSuggestion] = []
        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())

        // 1. Time-based (configurable)
        if morningBriefing && hour >= 8 && hour <= 9 && weekday >= 2 && weekday <= 6 {
            newSuggestions.append(ProactiveSuggestion(
                icon: "sun.max.fill", title: "Guten Morgen!",
                message: "Soll ich dir eine Zusammenfassung deiner Aufgaben und Termine für heute geben?",
                action: "Gib mir eine Zusammenfassung meiner heutigen Termine und offenen Aufgaben.",
                priority: .high, category: .timeOfDay
            ))
        }

        if eveningSummary && hour >= 17 && hour <= 18 {
            newSuggestions.append(ProactiveSuggestion(
                icon: "sunset.fill", title: "Tagesabschluss",
                message: "Soll ich zusammenfassen was heute erledigt wurde?",
                action: "Fasse zusammen was heute erledigt wurde und was morgen ansteht.",
                priority: .medium, category: .timeOfDay
            ))
        }

        // 2. Error recovery (configurable)
        if errorAlerts && !viewModel.messages.isEmpty {
            let lastMessages = viewModel.messages.suffix(5)
            let hasErrors = lastMessages.contains { msg in
                if case .assistant(let text) = msg.kind {
                    return text.contains("Fehler") || text.contains("Error")
                }
                return false
            }
            if hasErrors {
                newSuggestions.append(ProactiveSuggestion(
                    icon: "wrench.and.screwdriver.fill", title: "Fehler aufgetreten",
                    message: "Es gab kürzlich Fehler. Soll ich eine Diagnose durchführen?",
                    action: "Analysiere die letzten Fehler und schlage Lösungen vor.",
                    priority: .high, category: .errorRecovery
                ))
            }
        }

        // 3. System health (configurable)
        if systemHealth && viewModel.ollamaStatus == "Offline" {
            newSuggestions.append(ProactiveSuggestion(
                icon: "exclamationmark.triangle.fill", title: "Ollama nicht aktiv",
                message: "Ollama scheint nicht zu laufen. Soll ich es starten?",
                action: "Starte Ollama mit: brew services start ollama",
                priority: .high, category: .systemHealth
            ))
        }

        // 4. Custom rules
        for rule in rules where rule.enabled {
            switch rule.triggerType {
            case .timeOfDay:
                let parts = rule.triggerValue.split(separator: ":").compactMap { Int($0) }
                let minute = Calendar.current.component(.minute, from: Date())
                if parts.count == 2 && hour == parts[0] && minute >= parts[1] && minute < parts[1] + max(1, checkIntervalMinutes) {
                    newSuggestions.append(ProactiveSuggestion(
                        icon: "clock.fill", title: rule.name, message: rule.prompt,
                        action: rule.prompt, priority: .medium, category: .custom
                    ))
                }
            case .startup:
                if viewModel.messages.isEmpty {
                    newSuggestions.append(ProactiveSuggestion(
                        icon: "lightbulb.fill", title: rule.name, message: rule.prompt,
                        action: rule.prompt, priority: .low, category: .idle
                    ))
                }
            case .keyword, .idle:
                break // future expansion
            }
        }

        suggestions = newSuggestions.sorted { $0.priority > $1.priority }
    }

    func dismissSuggestion(_ suggestion: ProactiveSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
    }
}

// MARK: - ProactiveSuggestionsBar (for Dashboard)

struct ProactiveSuggestionsBar: View {
    @ObservedObject var engine: ProactiveEngine
    let onAction: (String) -> Void

    var body: some View {
        if !engine.suggestions.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Vorschläge", systemImage: "lightbulb.fill")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.koboldGold)
                        Spacer()
                        Text("\(engine.suggestions.count)")
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    ForEach(engine.suggestions.prefix(3)) { suggestion in
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 16.5))
                                .foregroundColor(.koboldEmerald)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(suggestion.title)
                                        .font(.system(size: 14.5, weight: .semibold))
                                    Text(suggestion.category.rawValue)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.white.opacity(0.06)))
                                }
                                Text(suggestion.message)
                                    .font(.system(size: 13.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Button(action: { onAction(suggestion.action) }) {
                                Text("Los")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(.koboldEmerald)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.koboldEmerald.opacity(0.15)))
                            }
                            .buttonStyle(.plain)

                            Button(action: { engine.dismissSuggestion(suggestion) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.koboldSurface))
                    }
                }
            }
        }
    }
}
