import SwiftUI
import AppKit
import Darwin

// MARK: - SystemMetricsMonitor

@MainActor
class SystemMetricsMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0       // 0–100 % (1-min load avg normalized per core)
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var thermalPressure: Double = 0  // 0.0–1.0
    @Published var thermalLabel: String = "Kühl"

    func update() {
        updateRAM()
        updateCPU()
        updateThermal()
        // Disk I/O on background thread to avoid Main Thread freeze
        Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path),
               let freeBytes = attrs[FileAttributeKey.systemFreeSize] as? Int64,
               let totalBytes = attrs[FileAttributeKey.systemSize] as? Int64 {
                let free = Double(freeBytes) / 1_073_741_824
                let total = Double(totalBytes) / 1_073_741_824
                await MainActor.run {
                    self.diskFreeGB = free
                    self.diskTotalGB = total
                }
            }
        }
    }

    private func updateRAM() {
        let total = ProcessInfo.processInfo.physicalMemory
        ramTotalGB = Double(total) / 1_073_741_824

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = UInt64(sysconf(_SC_PAGESIZE))
            let free = UInt64(stats.free_count + stats.inactive_count) * pageSize
            ramUsedGB = Double(total > free ? total - free : 0) / 1_073_741_824
        }
    }

    private func updateCPU() {
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        cpuUsage = min(100.0, loadavg[0] / cores * 100.0)
    }

    private func updateDisk() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            diskFreeGB = Double(freeBytes) / 1_073_741_824
            diskTotalGB = Double(totalBytes) / 1_073_741_824
        }
    }

    private func updateThermal() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:  thermalPressure = 0.15; thermalLabel = "~40°C"
        case .fair:     thermalPressure = 0.45; thermalLabel = "~60°C"
        case .serious:  thermalPressure = 0.75; thermalLabel = "~80°C"
        case .critical: thermalPressure = 1.0;  thermalLabel = "~95°C"
        @unknown default: thermalPressure = 0.0; thermalLabel = "—"
        }
    }
}

// MARK: - DashboardView
// Metriken, Status, letzte Aktivitäten, Schnellaktionen

enum MetricsPeriod: String, CaseIterable {
    case session = "Sitzung"
    case hour    = "1 Stunde"
    case day     = "24 Stunden"
    case week    = "7 Tage"
}

struct DashboardView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @StateObject private var sysMonitor = SystemMetricsMonitor()
    @ObservedObject private var proactiveEngine = ProactiveEngine.shared
    @ObservedObject private var suggestionService = SuggestionService.shared
    @State private var refreshTimer: Timer? = nil
    @State private var selectedPeriod: MetricsPeriod = .session
    @AppStorage("kobold.koboldName") private var koboldName: String = "KoboldOS"
    @AppStorage("kobold.showAdvancedStats") private var showAdvancedStats: Bool = false
    @ObservedObject private var weatherManager = WeatherManager.shared
    @State private var showErrorPopover: Bool = false
    @State private var showProcessManager: Bool = false
    @State private var showWidgetPicker: Bool = false
    @AppStorage("kobold.dashboard.widgets") private var enabledWidgetsJSON: String = ""
    @State private var cachedWidgets: [DashboardWidgetId]? = nil
    @State private var lastWidgetsJSON: String = ""

    // Widget System
    enum DashboardWidgetId: String, CaseIterable, Identifiable {
        case koboldPet = "kobold_pet"
        case systemStatus = "system_status"
        case shortcuts = "shortcuts"
        case metrics = "metrics"
        case recentActivity = "recent_activity"
        case activeSessions = "active_sessions"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .koboldPet: return "Kobold-Haustier"
            case .systemStatus: return "System & Status"
            case .shortcuts: return "Schnellzugriff"
            case .metrics: return "Metriken"
            case .recentActivity: return "Letzte Aktivitäten"
            case .activeSessions: return "Aktive Sessions"
            }
        }
        var icon: String {
            switch self {
            case .koboldPet: return "hare.fill"
            case .systemStatus: return "memorychip"
            case .shortcuts: return "square.grid.2x2.fill"
            case .metrics: return "chart.bar.fill"
            case .recentActivity: return "list.bullet.clipboard"
            case .activeSessions: return "person.3.fill"
            }
        }
    }

    private var enabledWidgets: [DashboardWidgetId] {
        // Cache decoded widgets to avoid JSON decode on every SwiftUI render pass
        if enabledWidgetsJSON == lastWidgetsJSON, let cached = cachedWidgets { return cached }
        let defaults: [DashboardWidgetId] = [.koboldPet, .shortcuts, .metrics, .recentActivity]
        guard !enabledWidgetsJSON.isEmpty,
              let data = enabledWidgetsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return defaults
        }
        let result = ids.compactMap { DashboardWidgetId(rawValue: $0) }
        DispatchQueue.main.async { cachedWidgets = result; lastWidgetsJSON = enabledWidgetsJSON }
        return result
    }

    private func saveEnabledWidgets(_ widgets: [DashboardWidgetId]) {
        if let data = try? JSONEncoder().encode(widgets.map { $0.rawValue }),
           let str = String(data: data, encoding: .utf8) { enabledWidgetsJSON = str }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                welcomeSection
                HStack {
                    dashboardToolbar
                    Button(action: { showWidgetPicker = true }) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18.5)).foregroundColor(.koboldEmerald)
                    }
                    .buttonStyle(.plain).help("Widgets verwalten")
                }
                ProactiveSuggestionsBar(engine: proactiveEngine) { action in
                    viewModel.sendMessage(action)
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
                }
                ForEach(enabledWidgets) { wid in
                    widgetView(for: wid)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(
            ZStack {
                Color.koboldBackground
                LinearGradient(colors: [Color.koboldEmerald.opacity(0.02), .clear, Color.koboldGold.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .onAppear {
            Task { await viewModel.loadMetrics() }
            Task { await suggestionService.generateSuggestions() }
            sysMonitor.update()
            proactiveEngine.startPeriodicCheck(viewModel: viewModel)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in
                    await viewModel.loadMetrics()
                    sysMonitor.update()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            proactiveEngine.stopPeriodicCheck()
        }
    }

    // MARK: - Welcome Section

    private var dailyGreeting: String {
        if !suggestionService.dashboardGreeting.isEmpty {
            return suggestionService.dashboardGreeting
        }
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let greetings = [
            "Dein Kobold hat Kaffee gekocht. Na ja, fast.",
            "Der Kobold wartet schon ungeduldig auf Befehle.",
            "Heute hat dein Kobold 0 Fehler gemacht. Noch.",
            "Psst... dein Kobold hat heimlich aufgeräumt.",
            "Dein Kobold ist bereit. Die Welt noch nicht.",
            "Ein Kobold, unendliche Möglichkeiten.",
            "Dein Kobold läuft auf Hochtouren.",
            "Dein Kobold hat heute Nacht 3 Sachen gelernt. Frag lieber nicht welche.",
            "Lass uns was Cooles bauen. Oder wenigstens was Nützliches.",
            "Dein Kobold hat den Desktop aufgeräumt. Spaß — aber er könnte!",
            "Bereit für Chaos? Dein Kobold ist es.",
            "Dein digitaler Mitbewohner grüßt.",
            "Kobold-Status: Motiviert und einsatzbereit.",
            "Heute wird automatisiert, was das Zeug hält!",
            "Dein Kobold hat schon mal vorgearbeitet. Oder so getan.",
            "Noch kein Kaffee? Dein Kobold läuft auch ohne.",
            "Spoiler: Heute wird ein guter Tag.",
            "Dein Kobold hat 42 Ideen. Die meisten sind sogar gut.",
            "Willkommen zurück! Dein Kobold hat dich vermisst.",
            "Die KI ist wach, der Mensch hoffentlich auch.",
            "Plot Twist: Dein Kobold hat nichts kaputtgemacht. Diesmal.",
            "Fehlerrate heute: 0%. Noch ist der Tag jung.",
            "Dein Kobold denkt mit. Manchmal sogar voraus.",
            "Automatisierung ist die beste Art von Faulheit.",
            "Dein Kobold ist geladen und bereit zum Feuern.",
            "Was steht an? Dein Kobold hat Zeit. Unendlich viel sogar.",
            "System läuft. Kobold läuft. Du auch?",
            "Dein Kobold hat die Nacht durchgearbeitet. OK, er hat nur gewartet.",
            "Lass uns den Tag rocken! Oder zumindest organisieren.",
            "Alles unter Kontrolle. Wahrscheinlich.",
            "Dein Kobold ist so bereit, er vibriert fast.",
            "Heute im Angebot: Produktivität zum Bestpreis.",
        ]
        return greetings[dayOfYear % greetings.count]
    }

    private var dailyGreetingPrefix: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return "Gute Nacht" }
        if hour < 12 { return "Guten Morgen" }
        if hour < 17 { return "Guten Tag" }
        if hour < 21 { return "Guten Abend" }
        return "Gute Nacht"
    }

    var welcomeSection: some View {
        VStack(spacing: 6) {
            let userName = UserDefaults.standard.string(forKey: "kobold.profile.name") ?? ""
            Text("\(dailyGreetingPrefix)\(userName.isEmpty ? "!" : ", \(userName)!")")
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Color.koboldGold, Color.koboldEmerald], startPoint: .leading, endPoint: .trailing))
            Text(dailyGreeting)
                .font(.system(size: 17.5, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - System Resources (CPU / RAM / GPU)

    var systemResourcesSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "System-Ressourcen", icon: "memorychip")

                HStack(spacing: 16) {
                    // CPU
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "cpu.fill").font(.caption).foregroundColor(.koboldEmerald)
                            Text("CPU").font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.1f%%", sysMonitor.cpuUsage))
                                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                                .foregroundColor(sysMonitor.cpuUsage > 80 ? .red : .primary)
                        }
                        GlassProgressBar(
                            value: sysMonitor.cpuUsage / 100,
                            color: sysMonitor.cpuUsage > 80 ? .red : sysMonitor.cpuUsage > 60 ? .orange : .koboldEmerald
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(width: 1, height: 40)

                    // RAM
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "memorychip.fill").font(.caption).foregroundColor(.koboldEmerald)
                            Text("RAM").font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.1f / %.0f GB", sysMonitor.ramUsedGB, sysMonitor.ramTotalGB))
                                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                                .foregroundColor(sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.85 ? .red : .primary)
                        }
                        GlassProgressBar(
                            value: sysMonitor.ramTotalGB > 0 ? sysMonitor.ramUsedGB / sysMonitor.ramTotalGB : 0,
                            color: sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.85 ? .red :
                                   sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.65 ? .orange : .koboldEmerald
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(width: 1, height: 40)

                    // Disk Space
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "internaldrive.fill").font(.caption).foregroundColor(.koboldGold)
                            Text("Speicher").font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.0f / %.0f GB", sysMonitor.diskTotalGB - sysMonitor.diskFreeGB, sysMonitor.diskTotalGB))
                                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                                .foregroundColor(sysMonitor.diskFreeGB < 20 ? .red : .primary)
                        }
                        GlassProgressBar(
                            value: sysMonitor.diskTotalGB > 0 ? (sysMonitor.diskTotalGB - sysMonitor.diskFreeGB) / sysMonitor.diskTotalGB : 0,
                            color: sysMonitor.diskFreeGB < 20 ? .red : sysMonitor.diskFreeGB < 50 ? .orange : .koboldGold
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }

    // MARK: - Date & Weather Bar

    private var formattedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy"
        return f.string(from: Date())
    }

    var dateWeatherBar: some View {
        HStack {
            // Datum links
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 15.5))
                    .foregroundColor(.koboldEmerald)
                Text(formattedDate)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Wetter rechts
            HStack(spacing: 8) {
                if weatherManager.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else if let temp = weatherManager.temperature {
                    Image(systemName: weatherManager.iconName)
                        .font(.system(size: 15.5))
                        .foregroundColor(.koboldGold)
                    Text(String(format: "%.0f°C", temp))
                        .font(.system(size: 15.5, weight: .semibold))
                    if !weatherManager.cityName.isEmpty {
                        Text(weatherManager.cityName)
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Online badge
            GlassStatusBadge(
                label: viewModel.isConnected ? "Online" : "Offline",
                color: viewModel.isConnected ? .koboldEmerald : .red
            )
        }
        .padding(.horizontal, 4)
        .onAppear { weatherManager.fetchWeatherIfNeeded() }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.koboldPanel)
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color.koboldEmerald.opacity(0.04), .clear, Color.koboldGold.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.2), Color.koboldGold.opacity(0.15)], startPoint: .leading, endPoint: .trailing), lineWidth: 0.5)
            }
        )
    }

    // MARK: - Dashboard Toolbar (Period picker + actions, compact)

    var dashboardToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedPeriod) {
                ForEach(MetricsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Spacer()

            Button(action: {
                if let url = URL(string: "https://github.com/FunkJood/KoboldOS") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("GitHub")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            GlassButton(title: "Aktualisieren", icon: "arrow.clockwise.circle", isPrimary: false) {
                Task {
                    await viewModel.loadMetrics()
                    sysMonitor.update()
                }
            }

            GlassButton(title: "Zurücksetzen", icon: "arrow.clockwise", isPrimary: false) {
                Task {
                    await resetMetrics()
                }
            }
        }
    }

    // MARK: - Metrics Grid

    var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()),
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            MetricCard(
                title: "Anfragen",
                value: "\(viewModel.metrics.chatRequests)",
                subtitle: selectedPeriod.rawValue,
                icon: "bubble.left.fill",
                color: .koboldEmerald
            )
            MetricCard(
                title: "Tool-Aufrufe",
                value: "\(viewModel.metrics.toolCalls)",
                subtitle: selectedPeriod.rawValue,
                icon: "wrench.fill",
                color: .koboldGold
            )
            MetricCard(
                title: "Laufzeit",
                value: formatUptime(viewModel.metrics.uptimeSeconds),
                icon: "clock.fill",
                color: .koboldEmerald
            )
            Button(action: { if viewModel.metrics.errors > 0 { showErrorPopover.toggle() } }) {
                MetricCard(
                    title: "Fehler",
                    value: "\(viewModel.metrics.errors)",
                    icon: "exclamationmark.triangle.fill",
                    color: viewModel.metrics.errors > 0 ? .red : .secondary
                )
                .overlay(
                    viewModel.metrics.errors > 0
                    ? RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.4), lineWidth: 1)
                    : nil
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showErrorPopover, arrowEdge: .bottom) {
                ErrorListPopover(viewModel: viewModel)
            }
        }
    }

    // MARK: - Shortcut Tiles

    var shortcutTilesSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Schnellzugriff", icon: "square.grid.2x2.fill")

                LazyVGrid(columns: [
                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible())
                ], spacing: 10) {
                    shortcutTile(title: "Chat", icon: "message.fill", color: .koboldEmerald, tab: .chat)
                    shortcutTile(title: "Aufgaben", icon: "checklist", color: .koboldGold, tab: .tasks)
                    shortcutTile(title: "Gedächtnis", icon: "brain.filled.head.profile", color: .koboldEmerald, tab: .memory)
                    shortcutTile(title: "Workflows", icon: "point.3.connected.trianglepath.dotted", color: .koboldGold, tab: .workflows)
                    shortcutTile(title: "Einstellungen", icon: "gearshape.fill", color: .koboldEmerald, tab: .settings)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }

    func shortcutTile(title: String, icon: String, color: Color, tab: SidebarTab) -> some View {
        Button {
            NotificationCenter.default.post(name: .koboldNavigate, object: tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.08))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Section

    var statusSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "System-Status", icon: "antenna.radiowaves.left.and.right")

                HStack(spacing: 0) {
                    statusColumn("Daemon", value: viewModel.daemonStatus, color: viewModel.isConnected ? .koboldEmerald : .orange)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Ollama", value: viewModel.ollamaStatus, color: viewModel.ollamaStatus == "Running" ? .koboldEmerald : .red)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Modell",
                                 value: viewModel.activeOllamaModel.isEmpty ? "—" : viewModel.activeOllamaModel,
                                 color: .koboldGold)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Ø Latenz",
                                 value: String(format: "%.0f ms", viewModel.metrics.avgLatencyMs),
                                 color: viewModel.metrics.avgLatencyMs > 5000 ? .red : .koboldEmerald)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Tokens",
                                 value: formatTokens(viewModel.metrics.tokensTotal),
                                 color: .koboldGold)
                }

                if viewModel.metrics.tokensTotal > 0 {
                    GlassDivider()
                    GlassProgressBar(
                        value: min(1.0, Double(viewModel.metrics.tokensTotal) / 100_000.0),
                        label: "Token-Verbrauch (\(selectedPeriod.rawValue))",
                        color: .koboldEmerald
                    )
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }

    func statusColumn(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 15.5, weight: .semibold)).foregroundColor(color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent Activity

    var recentActivitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Letzte Aktivitäten", icon: "list.bullet.clipboard")

                if viewModel.recentTraces.isEmpty {
                    Text("Noch keine Aktivitäten in dieser Sitzung.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.recentTraces.prefix(6), id: \.self) { trace in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(traceColor(trace))
                                .frame(width: 6, height: 6)
                            Text(trace)
                                .font(.system(size: 14.5, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }

    // MARK: - Helpers

    func formatTokens(_ n: Int) -> String {
        if n > 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n > 1_000     { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }

    func formatUptime(_ s: Int) -> String {
        if s < 60    { return "\(s)s" }
        if s < 3600  { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m"
    }

    func traceColor(_ trace: String) -> Color {
        if trace.contains("error")  { return .red }
        if trace.contains("agent")  { return .koboldEmerald }
        if trace.contains("tool")   { return .koboldGold }
        return .secondary
    }

    func resetMetrics() async {
        guard let url = URL(string: viewModel.baseURL + "/metrics/reset") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(viewModel.authToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
        viewModel.metrics = RuntimeMetrics()
        viewModel.recentTraces = []
        await viewModel.loadMetrics()
    }

    // MARK: - Widget System

    @ViewBuilder
    func widgetView(for id: DashboardWidgetId) -> some View {
        switch id {
        case .koboldPet:     KoboldPetWidget(viewModel: viewModel)
        case .systemStatus:  combinedSystemSection
        case .shortcuts:     shortcutTilesSection
        case .metrics:       metricsGrid
        case .recentActivity: recentActivitySection
        case .activeSessions: activeSessionsWidget
        }
    }

    // Combined Resources + Status
    var combinedSystemSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeader(title: "System", icon: "memorychip")

                // CPU + RAM + Disk + Temp circular gauges
                HStack(spacing: 20) {
                    Spacer()
                    CircularGaugeView(
                        value: sysMonitor.cpuUsage / 100,
                        label: "CPU",
                        valueText: String(format: "%.0f%%", sysMonitor.cpuUsage),
                        color: sysMonitor.cpuUsage > 80 ? .red : sysMonitor.cpuUsage > 60 ? .orange : .koboldEmerald,
                        size: 72
                    )
                    CircularGaugeView(
                        value: sysMonitor.ramTotalGB > 0 ? sysMonitor.ramUsedGB / sysMonitor.ramTotalGB : 0,
                        label: "RAM",
                        valueText: String(format: "%.1fGB", sysMonitor.ramUsedGB),
                        color: sysMonitor.ramUsedGB / max(1, sysMonitor.ramTotalGB) > 0.85 ? .red :
                               sysMonitor.ramUsedGB / max(1, sysMonitor.ramTotalGB) > 0.65 ? .orange : .koboldEmerald,
                        size: 72
                    )
                    CircularGaugeView(
                        value: sysMonitor.diskTotalGB > 0 ? (sysMonitor.diskTotalGB - sysMonitor.diskFreeGB) / sysMonitor.diskTotalGB : 0,
                        label: "Speicher",
                        valueText: String(format: "%.0fGB", sysMonitor.diskTotalGB - sysMonitor.diskFreeGB),
                        color: sysMonitor.diskFreeGB < 20 ? .red : sysMonitor.diskFreeGB < 50 ? .orange : .koboldGold,
                        size: 72
                    )
                    CircularGaugeView(
                        value: sysMonitor.thermalPressure,
                        label: "Temperatur",
                        valueText: sysMonitor.thermalLabel,
                        color: sysMonitor.thermalPressure > 0.7 ? .red : sysMonitor.thermalPressure > 0.4 ? .orange : .koboldEmerald,
                        size: 72
                    )
                    Spacer()
                }

                GlassDivider()

                // Status columns
                HStack(spacing: 0) {
                    statusColumn("Daemon", value: viewModel.daemonStatus, color: viewModel.isConnected ? .koboldEmerald : .orange)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Ollama", value: viewModel.ollamaStatus, color: viewModel.ollamaStatus == "Running" ? .koboldEmerald : .red)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Modell", value: viewModel.activeOllamaModel.isEmpty ? "—" : viewModel.activeOllamaModel, color: .koboldGold)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Latenz", value: String(format: "%.0f ms", viewModel.metrics.avgLatencyMs), color: viewModel.metrics.avgLatencyMs > 5000 ? .red : .koboldEmerald)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Tokens", value: formatTokens(viewModel.metrics.tokensTotal), color: .koboldGold)
                }

                if viewModel.metrics.tokensTotal > 0 {
                    GlassDivider()
                    GlassProgressBar(value: min(1.0, Double(viewModel.metrics.tokensTotal) / 100_000.0), label: "Token-Verbrauch (\(selectedPeriod.rawValue))", color: .koboldEmerald)
                }

                GlassDivider()

                // Process Manager button
                Button(action: { showProcessManager = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: 14.5)).foregroundColor(.koboldEmerald)
                        Text("Prozessmanager").font(.system(size: 14.5, weight: .medium)).foregroundColor(.koboldEmerald)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12.5)).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
        .sheet(isPresented: $showProcessManager) { ProcessManagerSheet(viewModel: viewModel) }
        .sheet(isPresented: $showWidgetPicker) {
            WidgetPickerSheet(enabledWidgets: enabledWidgets) { newWidgets in saveEnabledWidgets(newWidgets) }
        }
    }

    // Active Sessions Widget
    var activeSessionsWidget: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Aktive Sessions", icon: "person.3.fill")
                if viewModel.activeSessions.isEmpty {
                    Text("Keine aktiven Sessions.").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.activeSessions.prefix(5)) { session in
                        HStack(spacing: 8) {
                            Circle().fill(session.status == .running ? Color.koboldEmerald : .secondary).frame(width: 6, height: 6)
                            Text(session.agentType.capitalized).font(.system(size: 14.5, weight: .medium))
                            Spacer()
                            Text(session.elapsed).font(.system(size: 12.5, design: .monospaced)).foregroundColor(.secondary)
                            if session.status == .running {
                                Button(action: { viewModel.killSession(session.id) }) {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14.5)).foregroundColor(.red)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
    }
}

// MARK: - ProcessManagerSheet

struct ProcessManagerSheet: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: 17.5)).foregroundColor(.koboldEmerald)
                Text("Prozessmanager").font(.system(size: 17.5, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }.padding(16)
            Divider()
            if viewModel.activeSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 35)).foregroundColor(.koboldEmerald.opacity(0.5))
                    Text("Keine aktiven Prozesse").font(.system(size: 15.5, weight: .medium)).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.activeSessions) { session in
                            HStack(spacing: 12) {
                                Circle().fill(session.status == .running ? Color.koboldEmerald : .secondary).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.agentType.capitalized).font(.system(size: 14.5, weight: .semibold))
                                    Text(session.prompt).font(.system(size: 12.5)).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(session.status.rawValue).font(.system(size: 12.5, weight: .medium)).foregroundColor(session.status == .running ? .koboldEmerald : .secondary)
                                    Text(session.elapsed).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.secondary)
                                    if session.stepCount > 0 { Text("\(session.stepCount) Schritte").font(.system(size: 11.5)).foregroundColor(.secondary) }
                                }
                                if session.status == .running {
                                    Button(action: { viewModel.killSession(session.id) }) {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 17.5)).foregroundColor(.red)
                                    }.buttonStyle(.plain).help("Prozess beenden")
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 10)
                            Divider().opacity(0.3).padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(Color.koboldPanel)
    }
}

// MARK: - WidgetPickerSheet

struct WidgetPickerSheet: View {
    let enabledWidgets: [DashboardView.DashboardWidgetId]
    let onSave: ([DashboardView.DashboardWidgetId]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<DashboardView.DashboardWidgetId> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dashboard-Widgets").font(.system(size: 17.5, weight: .bold))
                Spacer()
                Button("Fertig") {
                    onSave(DashboardView.DashboardWidgetId.allCases.filter { selected.contains($0) })
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(.koboldEmerald)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(DashboardView.DashboardWidgetId.allCases) { widget in
                        HStack(spacing: 12) {
                            Image(systemName: widget.icon).font(.system(size: 17.5)).foregroundColor(.koboldEmerald).frame(width: 24)
                            Text(widget.displayName).font(.system(size: 15.5, weight: .medium))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { selected.contains(widget) },
                                set: { isOn in if isOn { selected.insert(widget) } else { selected.remove(widget) } }
                            )).toggleStyle(.switch).tint(.koboldEmerald)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().opacity(0.3).padding(.horizontal, 16)
                    }
                }
            }
        }
        .frame(width: 400, height: 380)
        .background(Color.koboldPanel)
        .onAppear { selected = Set(enabledWidgets) }
    }
}

// MARK: - ErrorListPopover

struct ErrorListPopover: View {
    @ObservedObject var viewModel: RuntimeViewModel

    private var errorNotifications: [KoboldNotification] {
        viewModel.notifications.filter { $0.type == .error || $0.type == .warning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15.5))
                    .foregroundColor(.red)
                Text("Fehler-Log")
                    .font(.system(size: 15.5, weight: .semibold))
                Spacer()
                Text("\(viewModel.metrics.errors) Fehler")
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if errorNotifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 25))
                        .foregroundColor(.koboldEmerald.opacity(0.5))
                    Text("Keine Fehlerdetails verfügbar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Fehler werden ab dieser Sitzung protokolliert.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(errorNotifications) { notif in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: notif.icon)
                                    .font(.system(size: 15.5))
                                    .foregroundColor(notif.color)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(notif.title)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(notif.message)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                    Text(notif.timestamp, style: .relative)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 380)
        .background(Color.koboldPanel)
    }
}

// MARK: - Kobold Pet Widget (ASCII Tamagotchi)

struct KoboldPetWidget: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @State private var animFrame = 0
    @State private var mood: KoboldMood = .idle
    @State private var speechBubble: String = ""
    @State private var showSpeech = false
    @State private var interactionCount = 0
    @State private var lastFedTime: Date = .distantPast
    @State private var lastPlayTime: Date = .distantPast
    @AppStorage("kobold.pet.happiness") private var happiness: Int = 70
    @AppStorage("kobold.pet.energy") private var energy: Int = 80
    @AppStorage("kobold.pet.xp") private var xp: Int = 0
    @AppStorage("kobold.koboldName") private var koboldName: String = "KoboldOS"

    enum KoboldMood: String {
        case idle, happy, working, sleeping, hungry, excited, thinking
    }

    // ASCII Art Frames für verschiedene Stimmungen
    private var asciiFrames: [String] {
        switch mood {
        case .idle:
            return animFrame % 2 == 0 ? [idleFrame1] : [idleFrame2]
        case .happy:
            return [happyFrame]
        case .working:
            return animFrame % 2 == 0 ? [workFrame1] : [workFrame2]
        case .sleeping:
            return [sleepFrame]
        case .hungry:
            return [hungryFrame]
        case .excited:
            return [excitedFrame]
        case .thinking:
            return animFrame % 2 == 0 ? [thinkFrame1] : [thinkFrame2]
        }
    }

    private var idleFrame1: String { """
       ╭─────╮
       │ ◉ ◉ │
       │  ▽  │
       ╰──┬──╯
        ╭─┴─╮
        │   │
       ╱│   │╲
      ╱ ╰───╯ ╲
        │   │
       ═╧═ ═╧═
    """ }
    private var idleFrame2: String { """
       ╭─────╮
       │ ◉ ◉ │
       │  ▽  │
       ╰──┬──╯
        ╭─┴─╮
        │   │
       ╱│   │╲
      ╱ ╰───╯ ╲
        │   │
      ═╧═   ═╧═
    """ }
    private var happyFrame: String { """
       ╭─────╮
       │ ◠ ◠ │
       │  ◡  │
       ╰──┬──╯
      ╱╭──┴──╮╲
     ╱ │  ♥  │ ╲
       │     │
       ╰─────╯
        │   │
       ═╧═ ═╧═
    """ }
    private var workFrame1: String { """
       ╭─────╮
       │ ◉ ◉ │
       │  ─  │
       ╰──┬──╯
        ╭─┴─╮ ⚡
        │ ⌨ │╱
       ╱│   │
      ╱ ╰───╯
        │   │
       ═╧═ ═╧═
    """ }
    private var workFrame2: String { """
       ╭─────╮
       │ ◉ ◉ │
       │  ─  │
       ╰──┬──╯
     ⚡╭──┴──╮
       ╲│ ⌨ │
        │   │╲
        ╰───╯ ╲
        │   │
       ═╧═ ═╧═
    """ }
    private var sleepFrame: String { """
       ╭─────╮  z
       │ ─ ─ │ z
       │  ω  │z
       ╰──┬──╯
        ╭─┴─╮
        │   │
        │   │
        ╰───╯
        │   │
       ═╧═ ═╧═
    """ }
    private var hungryFrame: String { """
       ╭─────╮
       │ ◉ ◉ │
       │  △  │
       ╰──┬──╯
        ╭─┴─╮
        │   │
        │ … │
        ╰───╯
        │   │
       ═╧═ ═╧═
    """ }
    private var excitedFrame: String { """
     ✨╭─────╮✨
       │ ★ ★ │
       │  ◡  │
       ╰──┬──╯
      ╱╭──┴──╮╲
     ╱ │  !  │ ╲
       │     │
       ╰─────╯
       ╱│   │╲
      ═╧═   ═╧═
    """ }
    private var thinkFrame1: String { """
       ╭─────╮ 💭
       │ ◉ ◉ │
       │  ─  │
       ╰──┬──╯
        ╭─┴─╮
        │ ? │
        │   │
        ╰───╯
        │   │
       ═╧═ ═╧═
    """ }
    private var thinkFrame2: String { """
       ╭─────╮💭
       │ ◉ ◉ │ .
       │  ─  │
       ╰──┬──╯
        ╭─┴─╮
        │ ! │
        │   │
        ╰───╯
        │   │
       ═╧═ ═╧═
    """ }

    private var level: Int { min(99, xp / 100 + 1) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "hare.fill").foregroundColor(.koboldEmerald).font(.system(size: 14))
                Text(koboldName).font(.system(size: 14, weight: .semibold))
                Text("Lv.\(level)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.koboldGold)
                Spacer()
                Text("\(xp) XP").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider().opacity(0.2)

            HStack(alignment: .top, spacing: 16) {
                // ASCII Kobold
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                            .frame(width: 160, height: 150)

                        Text(asciiFrames.first ?? idleFrame1)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                            .lineSpacing(-2)
                    }

                    // Speech Bubble
                    if showSpeech {
                        Text(speechBubble)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(Color.koboldSurface)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.koboldEmerald.opacity(0.3)))
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                // Stats + Buttons
                VStack(alignment: .leading, spacing: 10) {
                    // Stimmung
                    HStack(spacing: 6) {
                        Text(moodEmoji).font(.system(size: 16))
                        Text(moodLabel).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }

                    // Happiness Bar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("Glück").font(.system(size: 10)).foregroundColor(.secondary); Spacer(); Text("\(happiness)%").font(.system(size: 10, design: .monospaced)) }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(happiness > 50 ? Color.koboldEmerald : Color.orange).frame(width: geo.size.width * CGFloat(happiness) / 100, height: 6)
                            }
                        }.frame(height: 6)
                    }

                    // Energy Bar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("Energie").font(.system(size: 10)).foregroundColor(.secondary); Spacer(); Text("\(energy)%").font(.system(size: 10, design: .monospaced)) }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 6)
                                RoundedRectangle(cornerRadius: 3).fill(energy > 30 ? Color.blue : Color.red).frame(width: geo.size.width * CGFloat(energy) / 100, height: 6)
                            }
                        }.frame(height: 6)
                    }

                    // Action Buttons
                    HStack(spacing: 8) {
                        petButton(icon: "hand.wave.fill", label: "Streicheln") { petKobold() }
                        petButton(icon: "cup.and.saucer.fill", label: "Füttern") { feedKobold() }
                        petButton(icon: "gamecontroller.fill", label: "Spielen") { playWithKobold() }
                    }
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.koboldSurface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.koboldEmerald.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
        )
        .onAppear { updateMood() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { animFrame += 1 }
            // Langsamer Decay
            if animFrame % 30 == 0 { // Alle 60 Sekunden
                happiness = max(0, happiness - 1)
                energy = max(0, energy - 1)
                updateMood()
            }
        }
        // Reagiert auf Agent-Aktivität
        .onChange(of: viewModel.agentLoading) {
            if viewModel.agentLoading {
                mood = .working
                energy = max(0, energy - 2)
                xp += 5
            } else {
                updateMood()
                xp += 10
            }
        }
    }

    private func petButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(.system(size: 9))
            }
            .foregroundColor(.koboldEmerald)
            .frame(width: 54, height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.koboldEmerald.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func petKobold() {
        interactionCount += 1
        happiness = min(100, happiness + 5)
        xp += 2
        withAnimation { mood = .happy }
        speak(["Hehe, das kitzelt!", "Danke! ♥", "Mehr davon!", "*schnurr*", "Das mag ich!"].randomElement()!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updateMood() }
    }

    private func feedKobold() {
        guard Date().timeIntervalSince(lastFedTime) > 30 else {
            speak("Ich bin noch satt...")
            return
        }
        lastFedTime = Date()
        energy = min(100, energy + 20)
        happiness = min(100, happiness + 3)
        xp += 3
        withAnimation { mood = .excited }
        speak(["Lecker! 🍕", "Nom nom nom!", "Danke für den Snack!", "Endlich Essen!", "*mampf*"].randomElement()!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updateMood() }
    }

    private func playWithKobold() {
        guard Date().timeIntervalSince(lastPlayTime) > 15 else {
            speak("Lass mich kurz verschnaufen...")
            return
        }
        lastPlayTime = Date()
        happiness = min(100, happiness + 10)
        energy = max(0, energy - 10)
        xp += 5
        withAnimation { mood = .excited }
        speak(["Juhu! 🎮", "Lass uns was Cooles machen!", "Ich liebe Spiele!", "Yeah! Noch eine Runde!", "Das macht Spaß!"].randomElement()!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updateMood() }
    }

    private func speak(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            speechBubble = text
            showSpeech = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { showSpeech = false }
        }
    }

    private func updateMood() {
        if energy < 15 { mood = .sleeping }
        else if happiness < 20 { mood = .hungry }
        else if viewModel.agentLoading { mood = .working }
        else if happiness > 80 { mood = .happy }
        else { mood = .idle }
    }

    private var moodEmoji: String {
        switch mood {
        case .idle: return "😐"
        case .happy: return "😊"
        case .working: return "⚡"
        case .sleeping: return "😴"
        case .hungry: return "😿"
        case .excited: return "🎉"
        case .thinking: return "🤔"
        }
    }

    private var moodLabel: String {
        switch mood {
        case .idle: return "Entspannt"
        case .happy: return "Glücklich"
        case .working: return "Arbeitet..."
        case .sleeping: return "Schläft"
        case .hungry: return "Hungrig"
        case .excited: return "Aufgeregt!"
        case .thinking: return "Denkt nach..."
        }
    }
}
