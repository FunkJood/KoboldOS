import SwiftUI

// MARK: - Task Schedule Preset

enum TaskSchedulePreset: String, CaseIterable, Identifiable {
    case manual       = "Manuell"
    case every5min    = "Alle 5 Minuten"
    case every15min   = "Alle 15 Minuten"
    case every30min   = "Alle 30 Minuten"
    case hourly       = "Stündlich"
    case every2h      = "Alle 2 Stunden"
    case every4h      = "Alle 4 Stunden"
    case every6h      = "Alle 6 Stunden"
    case daily8       = "Täglich 08:00"
    case daily12      = "Täglich 12:00"
    case daily18      = "Täglich 18:00"
    case daily22      = "Täglich 22:00"
    case weekdayMorning = "Werktags 09:00"
    case weekly       = "Wöchentlich (Mo)"
    case custom       = "Benutzerdefiniert"

    var id: String { rawValue }

    var cronExpression: String {
        switch self {
        case .manual:         return ""
        case .every5min:      return "*/5 * * * *"
        case .every15min:     return "*/15 * * * *"
        case .every30min:     return "*/30 * * * *"
        case .hourly:         return "0 * * * *"
        case .every2h:        return "0 */2 * * *"
        case .every4h:        return "0 */4 * * *"
        case .every6h:        return "0 */6 * * *"
        case .daily8:         return "0 8 * * *"
        case .daily12:        return "0 12 * * *"
        case .daily18:        return "0 18 * * *"
        case .daily22:        return "0 22 * * *"
        case .weekdayMorning: return "0 9 * * 1-5"
        case .weekly:         return "0 9 * * 1"
        case .custom:         return ""
        }
    }

    var icon: String {
        switch self {
        case .manual:         return "hand.tap.fill"
        case .every5min, .every15min, .every30min: return "bolt.fill"
        case .hourly, .every2h, .every4h, .every6h: return "clock.fill"
        case .daily8, .daily12, .daily18, .daily22: return "sun.max.fill"
        case .weekdayMorning: return "calendar.badge.clock"
        case .weekly:         return "calendar"
        case .custom:         return "slider.horizontal.3"
        }
    }

    static func from(cron: String) -> TaskSchedulePreset {
        allCases.first { $0.cronExpression == cron && $0 != .manual } ?? .custom
    }
}

// MARK: - ScheduledTask

struct ScheduledTask: Identifiable {
    let id: String
    var name: String
    var prompt: String
    var schedule: String
    var lastRun: String?
    var enabled: Bool

    var schedulePreset: TaskSchedulePreset { TaskSchedulePreset.from(cron: schedule) }

    var scheduleDescription: String {
        let preset = schedulePreset
        if preset == .custom || preset == .manual { return schedule.isEmpty ? "Manuell" : schedule }
        return preset.rawValue
    }
}

// MARK: - TasksView

struct TasksView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var tasks: [ScheduledTask] = []
    @State private var isLoading = false
    @State private var showAddTask = false
    @State private var statusMsg = ""

    // Add task form state
    @State private var newName = ""
    @State private var newPrompt = ""
    @State private var newSchedulePreset: TaskSchedulePreset = .manual
    @State private var newCustomCron = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tasksHeader
                statsRow
                if isLoading {
                    GlassProgressBar(value: 0.5, label: "Lade Aufgaben...")
                        .padding(.horizontal, 4)
                } else if tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(tasks) { task in
                        TaskCard(task: task) {
                            Task { await runTask(task) }
                        } onDelete: {
                            Task { await deleteTask(task) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
        .task { await loadTasks() }
        .sheet(isPresented: $showAddTask) { addTaskSheet }
    }

    // MARK: - Header

    var tasksHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.language.tasks).font(.title2.bold())
                Text("Automatische und geplante Agent-Aufgaben — führe Aktionen nach Zeitplan aus")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !statusMsg.isEmpty {
                Text(statusMsg).font(.caption).foregroundColor(.koboldEmerald)
            }
            GlassButton(title: "Neue Aufgabe", icon: "plus", isPrimary: true) { showAddTask = true }
                .help("Erstelle eine neue automatisierte Aufgabe")
            GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                Task { await loadTasks() }
            }
        }
    }

    // MARK: - Stats Row

    var statsRow: some View {
        HStack(spacing: 12) {
            metaStat(icon: "checklist", label: "Gesamt", value: "\(tasks.count)", color: .koboldEmerald)
            metaStat(icon: "play.circle.fill", label: "Aktiv", value: "\(tasks.filter(\.enabled).count)", color: .blue)
            metaStat(icon: "pause.circle.fill", label: "Pausiert", value: "\(tasks.filter { !$0.enabled }.count)", color: .secondary)
        }
    }

    func metaStat(icon: String, label: String, value: String, color: Color) -> some View {
        GlassCard(padding: 10, cornerRadius: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text(label).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        GlassCard {
            VStack(spacing: 16) {
                Image(systemName: "checklist").font(.system(size: 40)).foregroundColor(.secondary)
                Text("Keine Aufgaben").font(.headline)
                Text("Erstelle automatische Aufgaben, die dein Agent nach Zeitplan ausführt — täglich, stündlich oder auf Knopfdruck.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                GlassButton(title: "Erste Aufgabe erstellen", icon: "plus", isPrimary: true) { showAddTask = true }
            }
            .frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: - Add Task Sheet

    var addTaskSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Neue Aufgabe").font(.title3.bold())
                    Spacer()
                    Button(action: { showAddTask = false; resetForm() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                    }.buttonStyle(.plain)
                }
                .padding(.top, 20)

                // Name
                formField(
                    title: "Aufgaben-Name",
                    hint: "Ein klarer Name für diese Aufgabe, z.B. 'Täglicher Bericht'"
                ) {
                    GlassTextField(text: $newName, placeholder: "z.B. Morgen-Briefing, System-Check...")
                }

                // Prompt
                formField(
                    title: "Prompt",
                    hint: "Was soll der Agent tun? Beschreibe die Aufgabe so genau wie möglich."
                ) {
                    TextEditor(text: $newPrompt)
                        .font(.system(size: 13))
                        .frame(minHeight: 80, maxHeight: 160)
                        .padding(8)
                        .background(Color.black.opacity(0.2)).cornerRadius(8)
                        .scrollContentBackground(.hidden)
                }

                // Schedule Picker
                formField(
                    title: "Ausführungszeitpunkt",
                    hint: "Wähle wann die Aufgabe ausgeführt wird — Manuell bedeutet nur auf Knopfdruck."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Grid of preset options
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(TaskSchedulePreset.allCases.filter { $0 != .custom }) { preset in
                                schedulePresetButton(preset)
                            }
                        }

                        // Custom cron input
                        if newSchedulePreset == .custom {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cron-Ausdruck (Minute Stunde Tag Monat Wochentag)")
                                    .font(.caption2).foregroundColor(.secondary)
                                GlassTextField(text: $newCustomCron, placeholder: "z.B. */30 * * * *")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }

                        // Preview
                        if newSchedulePreset != .manual && newSchedulePreset != .custom || !newCustomCron.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle").font(.caption2)
                                Text("Cron: \(effectiveCron)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Spacer()
                    GlassButton(title: "Abbrechen", isPrimary: false) {
                        showAddTask = false; resetForm()
                    }
                    GlassButton(title: "Erstellen", icon: "plus", isPrimary: true,
                                isDisabled: newName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await createTask() }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 480)
        .background(Color.koboldBackground)
    }

    func schedulePresetButton(_ preset: TaskSchedulePreset) -> some View {
        let isSelected = newSchedulePreset == preset
        return Button(action: { newSchedulePreset = preset }) {
            HStack(spacing: 6) {
                Image(systemName: preset.icon).font(.system(size: 11))
                Text(preset.rawValue).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(isSelected ? .koboldEmerald : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.koboldEmerald.opacity(0.2) : Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.koboldEmerald.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func formField<Content: View>(title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary)
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            content()
        }
    }

    var effectiveCron: String {
        if newSchedulePreset == .custom { return newCustomCron }
        return newSchedulePreset.cronExpression
    }

    // MARK: - Networking

    func loadTasks() async {
        isLoading = true
        defer { isLoading = false }
        guard let url = URL(string: viewModel.baseURL + "/tasks"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["tasks"] as? [[String: Any]] else { return }
        tasks = list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return ScheduledTask(
                id: item["id"] as? String ?? UUID().uuidString,
                name: name,
                prompt: item["prompt"] as? String ?? "",
                schedule: item["schedule"] as? String ?? "",
                lastRun: item["last_run"] as? String,
                enabled: item["enabled"] as? Bool ?? true
            )
        }
    }

    func createTask() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let prompt = newPrompt.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "create",
            "name": name,
            "prompt": prompt,
            "schedule": effectiveCron,
            "schedule_label": newSchedulePreset.rawValue
        ])
        _ = try? await URLSession.shared.data(for: req)
        showAddTask = false
        resetForm()
        await loadTasks()
    }

    func deleteTask(_ task: ScheduledTask) async {
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "delete", "id": task.id])
        _ = try? await URLSession.shared.data(for: req)
        tasks.removeAll { $0.id == task.id }
    }

    func runTask(_ task: ScheduledTask) async {
        statusMsg = "Starte '\(task.name)'..."
        viewModel.sendMessage(task.prompt)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        statusMsg = ""
    }

    func resetForm() {
        newName = ""; newPrompt = ""; newSchedulePreset = .manual; newCustomCron = ""
    }
}

// MARK: - TaskCard

struct TaskCard: View {
    let task: ScheduledTask
    let onRun: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                // Schedule icon
                Image(systemName: task.schedulePreset.icon)
                    .font(.system(size: 20))
                    .foregroundColor(.koboldGold)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(task.name).font(.system(size: 14, weight: .semibold))
                        GlassStatusBadge(
                            label: task.enabled ? "Aktiv" : "Pausiert",
                            color: task.enabled ? .koboldEmerald : .secondary
                        )
                        Spacer()
                    }

                    if !task.prompt.isEmpty {
                        Text(task.prompt)
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }

                    HStack(spacing: 12) {
                        // Schedule label
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.caption2)
                            Text(task.scheduleDescription)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))

                        if let lastRun = task.lastRun {
                            Text("Zuletzt: \(lastRun)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                // Actions
                VStack(spacing: 6) {
                    GlassButton(title: "Jetzt starten", icon: "play.fill", isPrimary: true) { onRun() }
                        .help("Aufgabe jetzt manuell ausführen")
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Aufgabe löschen")
                    .confirmationDialog(
                        "Aufgabe '\(task.name)' löschen?",
                        isPresented: $showDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Löschen", role: .destructive) { onDelete() }
                        Button("Abbrechen", role: .cancel) {}
                    }
                }
            }
        }
    }
}
