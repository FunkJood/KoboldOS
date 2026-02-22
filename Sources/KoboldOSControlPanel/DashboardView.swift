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

    func update() {
        updateRAM()
        updateCPU()
        updateDisk()
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
    @StateObject private var proactiveEngine = ProactiveEngine.shared
    @State private var refreshTimer: Timer? = nil
    @State private var selectedPeriod: MetricsPeriod = .session
    @AppStorage("kobold.koboldName") private var koboldName: String = "KoboldOS"
    @AppStorage("kobold.showAdvancedStats") private var showAdvancedStats: Bool = false
    @State private var showErrorPopover: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dashboardHeader
                ProactiveSuggestionsBar(engine: proactiveEngine) { action in
                    viewModel.sendMessage(action)
                    NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
                }
                systemResourcesSection
                shortcutTilesSection
                statusSection
                metricsGrid
                recentActivitySection
                quickActionsSection
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
        .onAppear {
            Task { await viewModel.loadMetrics() }
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
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
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
                            Image(systemName: "memorychip.fill").font(.caption).foregroundColor(.blue)
                            Text("RAM").font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.1f / %.0f GB", sysMonitor.ramUsedGB, sysMonitor.ramTotalGB))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.85 ? .red : .primary)
                        }
                        GlassProgressBar(
                            value: sysMonitor.ramTotalGB > 0 ? sysMonitor.ramUsedGB / sysMonitor.ramTotalGB : 0,
                            color: sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.85 ? .red :
                                   sysMonitor.ramUsedGB / sysMonitor.ramTotalGB > 0.65 ? .orange : .blue
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
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
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
    }

    // MARK: - Header

    var dashboardHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard").font(.title2.bold())
                Text(koboldName).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            // Period picker
            Picker("", selection: $selectedPeriod) {
                ForEach(MetricsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

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

            GlassButton(title: "Zurücksetzen", icon: "arrow.clockwise", isPrimary: false) {
                Task {
                    await resetMetrics()
                }
            }

            GlassStatusBadge(
                label: viewModel.isConnected ? "Online" : "Offline",
                color: viewModel.isConnected ? .koboldEmerald : .red
            )
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
                color: .blue
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
                    shortcutTile(title: "Aufgaben", icon: "checklist", color: .blue, tab: .tasks)
                    shortcutTile(title: "Gedächtnis", icon: "brain.filled.head.profile", color: .purple, tab: .memory)
                    shortcutTile(title: "Workflows", icon: "point.3.connected.trianglepath.dotted", color: .koboldGold, tab: .workflows)
                    shortcutTile(title: "Agenten", icon: "person.3.fill", color: .orange, tab: .agents)
                }
            }
        }
    }

    func shortcutTile(title: String, icon: String, color: Color, tab: SidebarTab) -> some View {
        Button {
            NotificationCenter.default.post(name: .koboldNavigate, object: tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
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
                                 color: viewModel.metrics.avgLatencyMs > 5000 ? .red : .blue)
                    Divider().frame(width: 1, height: 40).padding(.horizontal, 12)
                    statusColumn("Tokens",
                                 value: formatTokens(viewModel.metrics.tokensTotal),
                                 color: .purple)
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
    }

    func statusColumn(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundColor(color).lineLimit(1)
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
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    // MARK: - Quick Actions

    var quickActionsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Schnellaktionen", icon: "bolt.fill")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    GlassButton(title: "Daemon neu starten", icon: "arrow.clockwise", isPrimary: false) {
                        viewModel.restartDaemon()
                    }
                    GlassButton(title: "Metriken aktualisieren", icon: "arrow.clockwise.circle", isPrimary: false) {
                        Task { await viewModel.loadMetrics() }
                    }
                    GlassButton(title: "Ollama prüfen", icon: "server.rack", isPrimary: false) {
                        Task { await viewModel.checkOllamaStatus() }
                    }
                    GlassButton(title: "Verlauf leeren", icon: "trash", isDestructive: true) {
                        viewModel.clearChatHistory()
                    }
                }
            }
        }
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
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                Text("Fehler-Log")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(viewModel.metrics.errors) Fehler")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if errorNotifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.koboldEmerald.opacity(0.5))
                    Text("Keine Fehlerdetails verfügbar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Fehler werden ab dieser Sitzung protokolliert.")
                        .font(.system(size: 10))
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
                                    .font(.system(size: 13))
                                    .foregroundColor(notif.color)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(notif.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(notif.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                    Text(notif.timestamp, style: .relative)
                                        .font(.system(size: 9))
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
