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

    static let defaults: [ProactiveRule] = [
        ProactiveRule(id: "morning", name: "Morgen-Briefing", triggerType: .timeOfDay, triggerValue: "08:00",
                      prompt: "Gib mir eine Zusammenfassung meiner heutigen Termine und offenen Aufgaben.", enabled: true),
        ProactiveRule(id: "evening", name: "Tagesabschluss", triggerType: .timeOfDay, triggerValue: "17:00",
                      prompt: "Fasse zusammen was heute erledigt wurde und was morgen ansteht.", enabled: true),
        ProactiveRule(id: "startup", name: "Start-Tipp", triggerType: .startup, triggerValue: "",
                      prompt: "Was kann ich alles für dich tun? Zeig mir deine Fähigkeiten.", enabled: true),
    ]
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

    static let examples: [IdleTask] = [
        // Konkrete Aufgaben
        IdleTask(name: "Brew Updates prüfen", prompt: "Prüfe ob Homebrew-Pakete veraltet sind und zeig mir eine Zusammenfassung.", priority: .low, cooldownMinutes: 1440),
        IdleTask(name: "Downloads aufräumen", prompt: "Schau in meinen Downloads-Ordner und schlage vor welche Dateien gelöscht werden können (älter als 30 Tage, doppelt, temporär).", priority: .medium, cooldownMinutes: 1440),
        IdleTask(name: "Speicherplatz checken", prompt: "Prüfe den verfügbaren Speicherplatz und warne mich wenn weniger als 10GB frei sind.", priority: .high, cooldownMinutes: 360),
        // Vage Richtungen / Explorativ
        IdleTask(name: "Verbesserungen finden", prompt: "Schau dich um und finde etwas auf meinem System das man verbessern, optimieren oder aufräumen könnte. Sei kreativ — Performance, Organisation, Sicherheit, alles ist fair game.", priority: .medium, cooldownMinutes: 720),
        IdleTask(name: "Sicherheit im Blick", prompt: "Halte Ausschau nach potenziellen Sicherheitsproblemen auf meinem System — veraltete Software, offene Ports, unsichere Berechtigungen, verdächtige Prozesse. Berichte was dir auffällt.", priority: .high, cooldownMinutes: 1440),
        IdleTask(name: "Neues entdecken", prompt: "Recherchiere etwas Interessantes — neue Tools, Technologien oder Tipps die für mich nützlich sein könnten. Basiere das auf meiner bisherigen Nutzung und meinen Projekten.", priority: .low, cooldownMinutes: 2880),
        IdleTask(name: "Projekte checken", prompt: "Schau in meine Projekte und Repos. Gibt es uncommitted Changes, veraltete Dependencies, TODOs im Code oder andere Dinge die Aufmerksamkeit brauchen? Fass zusammen was du findest.", priority: .medium, cooldownMinutes: 720),
    ]
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

    // Idle Tasks
    @AppStorage("kobold.proactive.idleTasks") var idleTasksEnabled: Bool = false
    @AppStorage("kobold.proactive.idle.minIdleMinutes") var idleMinIdleMinutes: Int = 5
    @AppStorage("kobold.proactive.idle.maxPerHour") var idleMaxPerHour: Int = 3
    @AppStorage("kobold.proactive.idle.allowShell") var idleAllowShell: Bool = false
    @AppStorage("kobold.proactive.idle.allowNetwork") var idleAllowNetwork: Bool = false
    @AppStorage("kobold.proactive.idle.allowFileWrite") var idleAllowFileWrite: Bool = false
    @AppStorage("kobold.proactive.idle.onlyHighPriority") var idleOnlyHighPriority: Bool = true
    @AppStorage("kobold.proactive.idle.categories") var idleCategoriesRaw: String = "system,error"
    @AppStorage("kobold.proactive.idle.quietHoursStart") var idleQuietHoursStart: Int = 22
    @AppStorage("kobold.proactive.idle.quietHoursEnd") var idleQuietHoursEnd: Int = 7
    @AppStorage("kobold.proactive.idle.quietHoursEnabled") var idleQuietHoursEnabled: Bool = false
    @AppStorage("kobold.proactive.idle.notifyOnExecution") var idleNotifyOnExecution: Bool = true
    @AppStorage("kobold.proactive.idle.pauseOnUserActivity") var idlePauseOnUserActivity: Bool = true

    var lastUserActivity: Date = Date()
    private var idleExecutionsThisHour: Int = 0
    private var lastHourReset: Date = Date()

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
        loadRules()
        loadGoals()
        loadIdleTasks()
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
            // Merge with defaults (add new defaults that don't exist yet)
            var merged = ProactiveRule.defaults
            for saved in saved {
                if let idx = merged.firstIndex(where: { $0.id == saved.id }) {
                    merged[idx] = saved
                } else {
                    merged.append(saved)
                }
            }
            rules = merged
        } else {
            rules = ProactiveRule.defaults
        }
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
        guard isEnabled else { return }
        checkTask?.cancel()
        heartbeatTask?.cancel()
        let interval = UInt64(max(1, checkIntervalMinutes)) * 60_000_000_000
        checkTask = Task { [weak self, weak viewModel] in
            // Initial check after 15 seconds
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if let self, let viewModel, !Task.isCancelled {
                await MainActor.run { self.generateSuggestions(viewModel: viewModel) }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, let viewModel else { break }
                await MainActor.run { self.generateSuggestions(viewModel: viewModel) }
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

        // Reset hourly counter
        let now = Date()
        if now.timeIntervalSince(lastHourReset) > 3600 {
            idleExecutionsThisHour = 0
            lastHourReset = now
        }

        // Agent busy?
        guard !viewModel.agentLoading else {
            heartbeatStatus = "Agent aktiv"
            addHeartbeatLog(status: "Agent aktiv", action: nil)
            return
        }

        // Idle tasks disabled?
        guard idleTasksEnabled else {
            heartbeatStatus = "Idle"
            addHeartbeatLog(status: "Idle (Tasks deaktiviert)", action: nil)
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
                return
            }
        }

        // Pause on user activity?
        if idlePauseOnUserActivity {
            let idleMinutes = now.timeIntervalSince(lastUserActivity) / 60.0
            if idleMinutes < Double(idleMinIdleMinutes) {
                heartbeatStatus = "User aktiv"
                addHeartbeatLog(status: "User aktiv (Idle: \(Int(idleMinutes))m < \(idleMinIdleMinutes)m)", action: nil)
                return
            }
        }

        // Rate limit
        if idleExecutionsThisHour >= idleMaxPerHour {
            heartbeatStatus = "Limit erreicht (\(idleMaxPerHour)/h)"
            addHeartbeatLog(status: "Stunden-Limit erreicht", action: nil)
            return
        }

        heartbeatStatus = "Beobachtet..."

        // 1. Try user-defined idle tasks first (have priority)
        if let userTask = getNextUserIdleTask() {
            heartbeatStatus = "Führt aus: \(userTask.name)"
            addHeartbeatLog(status: "Idle-Aufgabe", action: userTask.name)
            viewModel.executeTask(taskId: "idle-\(userTask.id)", taskName: userTask.name, prompt: userTask.prompt, navigate: false)
            markIdleTaskRun(userTask.id)
            idleTasksCompleted += 1
            idleExecutionsThisHour += 1
            return
        }

        // 2. Fallback to auto-generated suggestions
        let autoTasks = getAutoIdleTasks()
        if let task = autoTasks.first {
            heartbeatStatus = "Führt aus: \(task.title)"
            addHeartbeatLog(status: "Auto-Aufgabe", action: task.title)
            viewModel.executeTask(taskId: "auto-\(task.id)", taskName: task.title, prompt: task.action, navigate: false)
            idleTasksCompleted += 1
            idleExecutionsThisHour += 1
        } else {
            heartbeatStatus = "Keine Aufgaben"
            addHeartbeatLog(status: "Keine passenden Aufgaben", action: nil)
        }
    }

    private func addHeartbeatLog(status: String, action: String?) {
        heartbeatLog.insert(HeartbeatLogEntry(timestamp: Date(), status: status, action: action), at: 0)
        if heartbeatLog.count > heartbeatLogRetention {
            heartbeatLog = Array(heartbeatLog.prefix(heartbeatLogRetention))
        }
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
        if systemHealth && viewModel.ollamaStatus != "Running" {
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
