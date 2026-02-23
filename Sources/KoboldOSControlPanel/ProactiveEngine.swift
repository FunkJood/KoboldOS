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

// MARK: - ProactiveEngine

@MainActor
class ProactiveEngine: ObservableObject {
    static let shared = ProactiveEngine()

    @Published var suggestions: [ProactiveSuggestion] = []
    @Published var rules: [ProactiveRule] = []
    @Published var goals: [GoalEntry] = []
    @Published var isChecking = false
    @Published var heartbeatStatus: String = "Idle"
    @Published var lastHeartbeat: Date? = nil
    @Published var idleTasksCompleted: Int = 0
    @AppStorage("kobold.proactive.enabled") var isEnabled: Bool = true
    @AppStorage("kobold.proactive.interval") var checkIntervalMinutes: Int = 10
    @AppStorage("kobold.proactive.morningBriefing") var morningBriefing: Bool = true
    @AppStorage("kobold.proactive.eveningSummary") var eveningSummary: Bool = true
    @AppStorage("kobold.proactive.errorAlerts") var errorAlerts: Bool = true
    @AppStorage("kobold.proactive.systemHealth") var systemHealth: Bool = true
    @AppStorage("kobold.proactive.idleTasks") var idleTasksEnabled: Bool = false

    private var checkTimer: Timer?
    private var heartbeatTimer: Timer?
    private let rulesKey = "kobold.proactive.rules"
    private let goalsKey = "kobold.proactive.goals"

    private init() {
        loadRules()
        loadGoals()
    }

    /// Call on app termination to prevent timer leak
    func cleanup() {
        checkTimer?.invalidate()
        checkTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
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
        checkTimer?.invalidate()
        heartbeatTimer?.invalidate()
        let interval = TimeInterval(max(1, checkIntervalMinutes) * 60)
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak viewModel] _ in
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.generateSuggestions(viewModel: viewModel)
            }
        }
        // Heartbeat: check every 60s if agent is idle and can do proactive work
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak viewModel] _ in
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.heartbeat(viewModel: viewModel)
            }
        }
        // Initial check after 15 seconds
        Task { [weak self, weak viewModel] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, let viewModel else { return }
            self.generateSuggestions(viewModel: viewModel)
        }
    }

    func stopPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Heartbeat (Proactive idle tasks)

    private func heartbeat(viewModel: RuntimeViewModel) {
        lastHeartbeat = Date()
        guard idleTasksEnabled, !viewModel.agentLoading else {
            heartbeatStatus = viewModel.agentLoading ? "Agent aktiv" : "Idle"
            return
        }
        heartbeatStatus = "Beobachtet..."
        // Agent is idle — check if there's proactive work to do
        let idleTasks = getIdleTasks()
        if let task = idleTasks.first {
            heartbeatStatus = "Führt aus: \(task.title)"
            // Execute idle task by sending it as a background message
            viewModel.sendMessage(task.action)
            idleTasksCompleted += 1
        }
    }

    private func getIdleTasks() -> [ProactiveSuggestion] {
        // Only return suggestions that are actionable and haven't been shown recently
        return suggestions.filter { $0.priority == .high && $0.category == .systemHealth }
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
