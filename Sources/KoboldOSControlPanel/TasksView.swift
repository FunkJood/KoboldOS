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

// MARK: - AutomationSuggestion

struct AutomationSuggestion {
    let icon: String
    let name: String
    let prompt: String
    let schedule: String
}

// MARK: - TasksView

struct TasksView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var tasks: [ScheduledTask] = []
    @State private var isLoading = false
    // showAddTask replaced by activeSheet == .addTask
    @State private var statusMsg = ""

    // Add/Edit task form state
    @State private var newName = ""
    @State private var newPrompt = ""
    @State private var newSchedulePreset: TaskSchedulePreset = .manual
    @State private var newCustomCron = ""
    @State private var newTeamId: String? = nil
    @State private var suggestionOffset: Int = 0
    @State private var errorMsg = ""

    // New schedule mode
    @State private var scheduleMode: ScheduleMode = .once
    @State private var onceDate: Date = Date()
    @State private var repeatWeeks: Int = 0
    @State private var repeatDays: Int = 0
    @State private var repeatHours: Int = 0
    @State private var repeatMinutes: Int = 30
    @State private var useWeekdays: Bool = false
    @State private var weekdayMon = false
    @State private var weekdayTue = false
    @State private var weekdayWed = false
    @State private var weekdayThu = false
    @State private var weekdayFri = false
    @State private var weekdaySat = false
    @State private var weekdaySun = false
    @State private var repeatAtHour: Int = 9
    @State private var repeatAtMinute: Int = 0

    // Sheet management (single sheet to avoid SwiftUI multiple-sheet bugs)
    enum SheetType: Identifiable {
        case addTask, editTask
        var id: String { String(describing: self) }
    }
    @State private var activeSheet: SheetType? = nil

    // Edit mode
    @State private var editingTask: ScheduledTask? = nil

    enum ScheduleMode: String {
        case once = "Einmalig"
        case recurring = "Wiederkehrend"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tasksHeader
                statsRow
                if !errorMsg.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(errorMsg).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Erneut versuchen") { Task { await loadTasks() } }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                if isLoading {
                    GlassProgressBar(value: 0.5, label: "Lade Aufgaben...")
                        .padding(.horizontal, 4)
                } else if tasks.isEmpty && errorMsg.isEmpty {
                    emptyState
                } else {
                    ForEach(tasks) { task in
                        TaskCard(task: task, onRun: {
                            Task { await runTask(task) }
                        }, onEdit: {
                            editingTask = task
                            newName = task.name
                            newPrompt = task.prompt
                            newSchedulePreset = task.schedulePreset == .custom ? .custom : task.schedulePreset
                            newCustomCron = task.schedulePreset == .custom ? task.schedule : ""
                            activeSheet = .editTask
                        }, onDelete: {
                            Task { await deleteTask(task) }
                        }, onToggle: { enabled in
                            Task { await toggleTask(task, enabled: enabled) }
                        }, onOpenChat: {
                            viewModel.openTaskChat(taskId: task.id, taskName: task.name)
                        })
                    }
                }

            }
            .padding(24)
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .task { await loadTasks() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addTask: addTaskSheet
            case .editTask: editTaskSheet
            }
        }
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
            GlassButton(title: "Neue Aufgabe", icon: "plus", isPrimary: true) { activeSheet = .addTask }
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
            metaStat(icon: "play.circle.fill", label: "Aktiv", value: "\(tasks.filter(\.enabled).count)", color: .koboldGold)
            metaStat(icon: "pause.circle.fill", label: "Pausiert", value: "\(tasks.filter { !$0.enabled }.count)", color: .secondary)
        }
    }

    func metaStat(icon: String, label: String, value: String, color: Color) -> some View {
        GlassCard(padding: 10, cornerRadius: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 16.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(size: 18.5, weight: .bold, design: .monospaced))
                    Text(label).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Empty State

    // Rotating automation suggestions (change every 4 hours)
    private static let automationSuggestions: [[AutomationSuggestion]] = [
        [
            AutomationSuggestion(icon: "newspaper.fill", name: "Morgen-Briefing", prompt: "Fasse die wichtigsten Nachrichten des Tages zusammen", schedule: "Täglich 08:00"),
            AutomationSuggestion(icon: "externaldrive.fill", name: "Backup-Check", prompt: "Prüfe ob alle wichtigen Ordner ein aktuelles Backup haben", schedule: "Wöchentlich"),
            AutomationSuggestion(icon: "chart.bar.fill", name: "System-Report", prompt: "Erstelle einen Bericht über CPU, RAM und Speichernutzung", schedule: "Stündlich"),
        ],
        [
            AutomationSuggestion(icon: "envelope.fill", name: "Email-Zusammenfassung", prompt: "Fasse ungelesene Emails zusammen und priorisiere sie", schedule: "Alle 4 Stunden"),
            AutomationSuggestion(icon: "trash.fill", name: "Desktop aufräumen", prompt: "Sortiere Dateien auf dem Desktop nach Typ in Unterordner", schedule: "Täglich 18:00"),
            AutomationSuggestion(icon: "globe", name: "Preis-Tracker", prompt: "Prüfe ob sich der Preis auf der hinterlegten URL geändert hat", schedule: "Alle 6 Stunden"),
        ],
        [
            AutomationSuggestion(icon: "doc.text.fill", name: "Log-Bereinigung", prompt: "Lösche alte Logdateien und temporäre Dateien", schedule: "Wöchentlich"),
            AutomationSuggestion(icon: "antenna.radiowaves.left.and.right", name: "Netzwerk-Check", prompt: "Prüfe Internetgeschwindigkeit und offene Ports", schedule: "Alle 2 Stunden"),
            AutomationSuggestion(icon: "calendar", name: "Tages-Planung", prompt: "Zeige meine Termine für heute und schlage eine Tagesplanung vor", schedule: "Täglich 07:00"),
        ],
        [
            AutomationSuggestion(icon: "photo.stack.fill", name: "Screenshot-Sortierung", prompt: "Sortiere neue Screenshots vom Desktop in einen Ordner nach Datum", schedule: "Alle 4 Stunden"),
            AutomationSuggestion(icon: "arrow.triangle.2.circlepath", name: "Git Status Check", prompt: "Prüfe alle Git-Repos im Documents-Ordner auf uncommitted changes", schedule: "Täglich 12:00"),
            AutomationSuggestion(icon: "waveform", name: "Podcast-Zusammenfassung", prompt: "Lade den neuesten Podcast herunter und fasse ihn zusammen", schedule: "Täglich 22:00"),
        ],
        [
            AutomationSuggestion(icon: "cpu.fill", name: "Dependency-Check", prompt: "Prüfe ob es Updates für installierte Homebrew-Pakete gibt", schedule: "Wöchentlich"),
            AutomationSuggestion(icon: "lock.shield.fill", name: "Sicherheits-Scan", prompt: "Scanne nach ungesicherten Dateien und prüfe Firewall-Status", schedule: "Täglich 18:00"),
            AutomationSuggestion(icon: "cloud.fill", name: "Wetter-Briefing", prompt: "Erstelle einen kurzen Wetterbericht für heute und morgen", schedule: "Täglich 07:00"),
        ],
        [
            AutomationSuggestion(icon: "rectangle.stack.fill", name: "Projekt-Status", prompt: "Zeige den Status aller aktiven Projekte und offenen TODOs", schedule: "Täglich 09:00"),
            AutomationSuggestion(icon: "arrow.down.doc.fill", name: "Download-Bereinigung", prompt: "Lösche Downloads die älter als 7 Tage sind", schedule: "Wöchentlich"),
            AutomationSuggestion(icon: "text.bubble.fill", name: "Telegram-Digest", prompt: "Fasse die letzten Telegram-Nachrichten zusammen", schedule: "Alle 6 Stunden"),
        ],
    ]

    private var currentSuggestions: [AutomationSuggestion] {
        // Prefer AI-generated suggestions
        let aiSuggestions = SuggestionService.shared.taskSuggestions
        if !aiSuggestions.isEmpty {
            return aiSuggestions.map { item in
                AutomationSuggestion(
                    icon: SuggestionService.shared.iconForTask(item.name),
                    name: item.name, prompt: item.prompt, schedule: item.schedule
                )
            }
        }
        let hour = Calendar.current.component(.hour, from: Date())
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let index = (dayOfYear * 6 + hour / 4 + suggestionOffset) % Self.automationSuggestions.count
        return Self.automationSuggestions[index]
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            GlassCard {
                VStack(spacing: 16) {
                    Image(systemName: "checklist").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Keine Aufgaben").font(.headline)
                    Text("Erstelle automatische Aufgaben, die dein Agent nach Zeitplan ausführt — täglich, stündlich oder auf Knopfdruck.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    GlassButton(title: "Erste Aufgabe erstellen", icon: "plus", isPrimary: true) { activeSheet = .addTask }
                }
                .frame(maxWidth: .infinity).padding()
            }

            // Automation suggestions
            GlassCard(padding: 12, cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Automatisierungsideen").font(.system(size: 15.5, weight: .semibold)).foregroundColor(.koboldGold)
                        Spacer()
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { suggestionOffset += 1 } }) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13.5)).foregroundColor(.koboldGold)
                        }.buttonStyle(.plain).help("Neue Vorschläge laden")
                    }
                    ForEach(currentSuggestions, id: \.name) { suggestion in
                        Button(action: {
                            newName = suggestion.name
                            newPrompt = suggestion.prompt
                            activeSheet = .addTask
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.icon)
                                    .font(.system(size: 14.5))
                                    .foregroundColor(.koboldEmerald)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.name)
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(suggestion.prompt)
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(suggestion.schedule)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.koboldSurface)
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(Color.koboldEmerald.opacity(0.04))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 500)
        }
    }

    // MARK: - Add Task Sheet

    var addTaskSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Neue Aufgabe").font(.title3.bold())
                    Spacer()
                    Button(action: { activeSheet = nil; resetForm() }) {
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
                        .font(.system(size: 15.5))
                        .frame(minHeight: 80, maxHeight: 160)
                        .padding(8)
                        .background(Color.black.opacity(0.2)).cornerRadius(8)
                        .scrollContentBackground(.hidden)
                }

                // Schedule Picker — Einmalig / Wiederkehrend
                formField(
                    title: "Ausführungszeitpunkt",
                    hint: "Einmalig für eine bestimmte Zeit, oder wiederkehrend nach Intervall."
                ) {
                    schedulePickerContent
                }

                HStack(spacing: 12) {
                    Spacer()
                    GlassButton(title: "Abbrechen", isPrimary: false) {
                        activeSheet = nil; resetForm()
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
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    func schedulePresetButton(_ preset: TaskSchedulePreset) -> some View {
        let isSelected = newSchedulePreset == preset
        return Button(action: { newSchedulePreset = preset }) {
            HStack(spacing: 6) {
                Image(systemName: preset.icon).font(.system(size: 13.5))
                Text(preset.rawValue).font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
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
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundColor(.primary)
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            content()
        }
    }

    var effectiveCron: String {
        if scheduleMode == .once {
            // Einmalig: Speichere als ISO-Datum mit Prefix "once:"
            let formatter = ISO8601DateFormatter()
            return "once:\(formatter.string(from: onceDate))"
        }
        // Wiederkehrend
        if useWeekdays {
            // Bestimmte Wochentage
            var days: [String] = []
            if weekdayMon { days.append("1") }
            if weekdayTue { days.append("2") }
            if weekdayWed { days.append("3") }
            if weekdayThu { days.append("4") }
            if weekdayFri { days.append("5") }
            if weekdaySat { days.append("6") }
            if weekdaySun { days.append("0") }
            let dayStr = days.isEmpty ? "*" : days.joined(separator: ",")
            return "\(repeatAtMinute) \(repeatAtHour) * * \(dayStr)"
        }
        // Intervall-basiert (WW/TT/SS/MM)
        if repeatWeeks > 0 {
            // Wöchentliches Intervall: Cron unterstützt kein Multi-Wochen, nutze "once per Woche am Mo"
            return "\(repeatAtMinute) \(repeatAtHour) */\(repeatWeeks * 7) * *"
        }
        if repeatDays > 0 {
            return "\(repeatAtMinute) \(repeatAtHour) */\(repeatDays) * *"
        }
        if repeatHours > 0 {
            return "\(repeatAtMinute) */\(repeatHours) * * *"
        }
        if repeatMinutes > 0 {
            return "*/\(repeatMinutes) * * * *"
        }
        return ""
    }

    // MARK: - Schedule Picker UI

    @ViewBuilder
    var schedulePickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle: Einmalig / Wiederkehrend
            HStack(spacing: 0) {
                scheduleModeButton("Einmalig", icon: "clock.fill", mode: .once)
                scheduleModeButton("Wiederkehrend", icon: "repeat", mode: .recurring)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))

            if scheduleMode == .once {
                // Datum + Uhrzeit
                VStack(alignment: .leading, spacing: 8) {
                    Text("Datum und Uhrzeit").font(.system(size: 13.5, weight: .medium)).foregroundColor(.secondary)
                    DatePicker("", selection: $onceDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(maxHeight: 280)
                }
            } else {
                // Wiederkehrend: Intervall ODER Wochentage
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("An bestimmten Wochentagen", isOn: $useWeekdays)
                        .toggleStyle(.switch).tint(.koboldEmerald)
                        .font(.system(size: 14.5))

                    if useWeekdays {
                        // Wochentag-Checkboxen
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wochentage").font(.system(size: 13.5, weight: .medium)).foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                weekdayCheckbox("Mo", isOn: $weekdayMon)
                                weekdayCheckbox("Di", isOn: $weekdayTue)
                                weekdayCheckbox("Mi", isOn: $weekdayWed)
                                weekdayCheckbox("Do", isOn: $weekdayThu)
                                weekdayCheckbox("Fr", isOn: $weekdayFri)
                                weekdayCheckbox("Sa", isOn: $weekdaySat)
                                weekdayCheckbox("So", isOn: $weekdaySun)
                            }
                            // Uhrzeit
                            HStack(spacing: 8) {
                                Text("Uhrzeit:").font(.system(size: 13.5)).foregroundColor(.secondary)
                                Picker("", selection: $repeatAtHour) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d", h)).tag(h)
                                    }
                                }.pickerStyle(.menu).frame(width: 60)
                                Text(":").font(.system(size: 15.5, weight: .bold))
                                Picker("", selection: $repeatAtMinute) {
                                    ForEach([0, 15, 30, 45], id: \.self) { m in
                                        Text(String(format: "%02d", m)).tag(m)
                                    }
                                }.pickerStyle(.menu).frame(width: 60)
                            }
                        }
                    } else {
                        // Intervall-Eingabe: WW / TT / SS / MM
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wiederholung alle:").font(.system(size: 13.5, weight: .medium)).foregroundColor(.secondary)
                            HStack(spacing: 10) {
                                intervalField("WW", value: $repeatWeeks, hint: "Wochen")
                                intervalField("TT", value: $repeatDays, hint: "Tage")
                                intervalField("SS", value: $repeatHours, hint: "Stunden")
                                intervalField("MM", value: $repeatMinutes, hint: "Minuten")
                            }
                            if repeatHours > 0 || repeatDays > 0 || repeatWeeks > 0 {
                                HStack(spacing: 8) {
                                    Text("Startzeit:").font(.system(size: 13.5)).foregroundColor(.secondary)
                                    Picker("", selection: $repeatAtHour) {
                                        ForEach(0..<24, id: \.self) { h in
                                            Text(String(format: "%02d", h)).tag(h)
                                        }
                                    }.pickerStyle(.menu).frame(width: 60)
                                    Text(":").font(.system(size: 15.5, weight: .bold))
                                    Picker("", selection: $repeatAtMinute) {
                                        ForEach([0, 15, 30, 45], id: \.self) { m in
                                            Text(String(format: "%02d", m)).tag(m)
                                        }
                                    }.pickerStyle(.menu).frame(width: 60)
                                }
                            }
                        }
                    }
                }

                // Preview
                if !effectiveCron.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.caption2)
                        Text("Cron: \(effectiveCron)")
                            .font(.system(size: 12.5, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    private func scheduleModeButton(_ label: String, icon: String, mode: ScheduleMode) -> some View {
        Button(action: { scheduleMode = mode }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13.5))
                Text(label).font(.system(size: 14.5, weight: scheduleMode == mode ? .semibold : .regular))
            }
            .foregroundColor(scheduleMode == mode ? .white : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(scheduleMode == mode ? Color.koboldEmerald : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func weekdayCheckbox(_ label: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            Text(label)
                .font(.system(size: 13.5, weight: isOn.wrappedValue ? .bold : .regular))
                .foregroundColor(isOn.wrappedValue ? .white : .secondary)
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isOn.wrappedValue ? Color.koboldEmerald : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isOn.wrappedValue ? Color.koboldEmerald : Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func intervalField(_ label: String, value: Binding<Int>, hint: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 12.5, weight: .bold)).foregroundColor(.koboldEmerald)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15.5, weight: .medium, design: .monospaced))
                .frame(width: 50)
                .multilineTextAlignment(.center)
            Text(hint).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    // MARK: - Edit Task Sheet

    var editTaskSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Aufgabe bearbeiten").font(.title3.bold())
                    Spacer()
                    Button(action: { activeSheet = nil; editingTask = nil; resetForm() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                    }.buttonStyle(.plain)
                }
                .padding(.top, 20)

                formField(title: "Aufgaben-Name", hint: "Name der Aufgabe") {
                    GlassTextField(text: $newName, placeholder: "z.B. Morgen-Briefing...")
                }

                formField(title: "Prompt", hint: "Was soll der Agent tun?") {
                    TextEditor(text: $newPrompt)
                        .font(.system(size: 15.5))
                        .frame(minHeight: 80, maxHeight: 160)
                        .padding(8)
                        .background(Color.black.opacity(0.2)).cornerRadius(8)
                        .scrollContentBackground(.hidden)
                }

                formField(title: "Ausführungszeitpunkt", hint: "Zeitplan ändern") {
                    schedulePickerContent
                }

                HStack(spacing: 12) {
                    Spacer()
                    GlassButton(title: "Abbrechen", isPrimary: false) {
                        activeSheet = nil; editingTask = nil; resetForm()
                    }
                    GlassButton(title: "Speichern", icon: "checkmark", isPrimary: true,
                                isDisabled: newName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await updateTask() }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 480)
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    // MARK: - Networking

    func loadTasks() async {
        isLoading = true
        errorMsg = ""
        defer { isLoading = false }

        // Check daemon readiness first
        guard viewModel.isConnected else {
            errorMsg = "Daemon nicht verbunden. Warte auf Verbindung..."
            return
        }

        guard let url = URL(string: viewModel.baseURL + "/tasks") else {
            errorMsg = "Ungültige URL"
            return
        }

        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            guard let http = resp as? HTTPURLResponse else {
                errorMsg = "Keine HTTP-Antwort"
                return
            }
            guard http.statusCode == 200 else {
                // Tasks endpoint may not exist yet — show empty state instead of error
                if http.statusCode == 404 {
                    tasks = []
                    return
                }
                errorMsg = "HTTP-Fehler \(http.statusCode)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["tasks"] as? [[String: Any]] else {
                // Empty or malformed response — treat as empty tasks
                tasks = []
                return
            }
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
        } catch {
            errorMsg = "Verbindungsfehler: \(error.localizedDescription)"
        }
    }

    func createTask() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let prompt = newPrompt.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "create",
            "name": name,
            "prompt": prompt,
            "schedule": effectiveCron,
            "schedule_label": newSchedulePreset.rawValue
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                statusMsg = "Fehler beim Erstellen (HTTP \(http.statusCode))"
            }
        } catch {
            statusMsg = "Erstellen fehlgeschlagen"
        }
        activeSheet = nil
        resetForm()
        await loadTasks()
    }

    func updateTask() async {
        guard let task = editingTask else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update",
            "id": task.id,
            "name": name,
            "prompt": newPrompt.trimmingCharacters(in: .whitespaces),
            "schedule": effectiveCron,
            "enabled": task.enabled
        ] as [String: Any])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                statusMsg = "Fehler beim Aktualisieren (HTTP \(http.statusCode))"
            }
        } catch {
            statusMsg = "Aktualisieren fehlgeschlagen"
        }
        activeSheet = nil
        editingTask = nil
        resetForm()
        await loadTasks()
    }

    func toggleTask(_ task: ScheduledTask, enabled: Bool) async {
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update",
            "id": task.id,
            "enabled": enabled
        ] as [String: Any])
        _ = try? await URLSession.shared.data(for: req)
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].enabled = enabled
        }
    }

    func deleteTask(_ task: ScheduledTask) async {
        guard let url = URL(string: viewModel.baseURL + "/tasks") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "delete", "id": task.id])
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            statusMsg = "Löschen fehlgeschlagen"
        }
        tasks.removeAll { $0.id == task.id }
    }

    func runTask(_ task: ScheduledTask) async {
        statusMsg = "Starte '\(task.name)'..."
        viewModel.sendMessage(task.prompt)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        statusMsg = ""
    }

    func resetForm() {
        newName = ""; newPrompt = ""; newSchedulePreset = .manual; newCustomCron = ""; newTeamId = nil
    }
}

// MARK: - TaskCard

struct TaskCard: View {
    let task: ScheduledTask
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onOpenChat: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                // Schedule icon
                Image(systemName: task.schedulePreset.icon)
                    .font(.system(size: 21))
                    .foregroundColor(.koboldGold)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(task.name).font(.system(size: 16.5, weight: .semibold))
                        // Enabled/Disabled toggle
                        Toggle("", isOn: Binding(
                            get: { task.enabled },
                            set: { onToggle($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
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
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.caption2)
                            Text(task.scheduleDescription).font(.system(size: 12.5))
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
                    GlassButton(title: "Starten", icon: "play.fill", isPrimary: true) { onRun() }
                        .help("Aufgabe jetzt manuell ausführen")
                    HStack(spacing: 4) {
                        Button(action: onOpenChat) {
                            Image(systemName: "message.fill").foregroundColor(.koboldEmerald.opacity(0.8))
                        }
                        .buttonStyle(.plain).help("Task-Chat öffnen")
                        Button(action: onEdit) {
                            Image(systemName: "pencil").foregroundColor(.koboldGold.opacity(0.8))
                        }
                        .buttonStyle(.plain).help("Aufgabe bearbeiten")
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain).help("Aufgabe löschen")
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
}
