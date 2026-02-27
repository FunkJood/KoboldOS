import SwiftUI

// MARK: - Agent Model Config (persisted to UserDefaults)

struct AgentModelConfig: Codable, Identifiable {
    var id: String          // "general", "coder", "web"
    var displayName: String
    var emoji: String
    var description: String
    var provider: String = "ollama"
    var modelName: String
    var systemPrompt: String
    var temperature: Double
    var contextLength: Int
    var supportsVision: Bool = false

    static let defaults: [AgentModelConfig] = [
        AgentModelConfig(
            id: "general",
            displayName: "General",
            emoji: "🧠",
            description: "Hauptagent — orchestriert, plant, delegiert und antwortet dem Nutzer",
            modelName: "",
            systemPrompt: "You are the General agent. You plan tasks, delegate to sub-agents (coder, web), and synthesize results for the user.",
            temperature: 0.7,
            contextLength: 8192,
            supportsVision: true
        ),
        AgentModelConfig(
            id: "coder",
            displayName: "Coder",
            emoji: "💻",
            description: "Entwickler-Agent — schreibt und analysiert Code",
            modelName: "",
            systemPrompt: "You are a coding specialist. Write clean, efficient code and explain your reasoning.",
            temperature: 0.3,
            contextLength: 16384,
            supportsVision: false
        ),
        AgentModelConfig(
            id: "web",
            displayName: "Web",
            emoji: "🌐",
            description: "Web-Agent — Recherche, Web-Suche, APIs und Browser-Automatisierung",
            modelName: "",
            systemPrompt: "You are a web and research specialist. Search the web, extract information from pages, call APIs, and compile accurate research reports.",
            temperature: 0.4,
            contextLength: 8192,
            supportsVision: true
        ),
        AgentModelConfig(
            id: "utility",
            displayName: "Utility",
            emoji: "⚡",
            description: "Hilfs-Agent — schnelle Aufgaben und Tool-Ausführung",
            modelName: "",
            systemPrompt: "You are a utility agent. Execute tasks quickly and efficiently.",
            temperature: 0.5,
            contextLength: 4096,
            supportsVision: false
        ),
    ]
}

// MARK: - AgentsStore

@MainActor
class AgentsStore: ObservableObject {
    static let shared = AgentsStore()
    @Published var configs: [AgentModelConfig] = []
    @Published var ollamaModels: [String] = []
    @Published var isLoadingModels = false

    private let key = "kobold.agentConfigs"

    private init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AgentModelConfig].self, from: data) {
            // Merge saved with defaults (adds any newly introduced agents)
            var merged = AgentModelConfig.defaults
            for saved in decoded {
                if let idx = merged.firstIndex(where: { $0.id == saved.id }) {
                    merged[idx] = saved
                }
            }
            configs = merged
        } else {
            configs = AgentModelConfig.defaults
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func update(_ config: AgentModelConfig) {
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
        }
        save()
        // Sync general model to kobold.ollamaModel so all subsystems pick it up
        if config.id == "general" && !config.modelName.isEmpty {
            UserDefaults.standard.set(config.modelName, forKey: "kobold.ollamaModel")
        }
    }

    func fetchOllamaModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return }
        ollamaModels = models.compactMap { $0["name"] as? String }
    }
}

// MARK: - AgentsView

struct AgentsView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @ObservedObject private var store = AgentsStore.shared
    @State private var expandedId: String? = nil
    @State private var toolRoutingExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agenten-Konfiguration").font(.headline)
                        Text("Modell, Temperatur, System-Prompt und Vision pro Agent")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        ollamaRestarting = true
                        Task {
                            // Restart Ollama with configured parallelism, then refresh models
                            viewModel.restartOllamaWithParallelism(workers: workerPoolSize)
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            for _ in 0..<10 {
                                await viewModel.checkOllamaStatus()
                                if viewModel.ollamaStatus == "Active" { break }
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            await store.fetchOllamaModels()
                            ollamaRestarting = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if store.isLoadingModels || ollamaRestarting {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(ollamaRestarting ? "Starte Ollama..." : "Modelle neu laden")
                        }
                        .font(.system(size: 14.5))
                    }
                    .buttonStyle(.bordered)
                    .disabled(ollamaRestarting)
                    .help("Ollama neustarten und Modelle abrufen")
                }

                // Ollama Backend Status + Worker-Pool (integriert)
                ollamaStatusBox

                ForEach($store.configs) { $config in
                    VStack(spacing: 0) {
                        AgentConfigCard(
                            config: $config,
                            ollamaModels: store.ollamaModels,
                            isExpanded: expandedId == config.id,
                            onToggle: {
                                withAnimation(.spring(response: 0.3)) {
                                    expandedId = expandedId == config.id ? nil : config.id
                                }
                            },
                            onSave: { store.update(config) }
                        )

                        // Active session banner for this agent
                        ForEach(activeSessions(for: config.id)) { session in
                            AgentActivityBanner(session: session) {
                                viewModel.killSession(session.id)
                            }
                        }
                    }
                }

                // Tool Routing Map (GlassCard wie Agent-Karten)
                toolRoutingCard
            }
            .padding(24)
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .task { await store.fetchOllamaModels() }
    }

    /// Returns active sessions matching this agent config id
    private func activeSessions(for agentId: String) -> [ActiveAgentSession] {
        viewModel.activeSessions.filter { $0.agentType == agentId && $0.status == .running }
    }

    // MARK: - Ollama Backend Status Box (ehemals in Modelle-Tab)

    @AppStorage("kobold.workerPool.size") private var workerPoolSize: Int = 4
    @State private var ollamaRestarting = false

    private var ollamaStatusBox: some View {
        GlassCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Ollama Backend", systemImage: "server.rack")
                        .font(.system(size: 16.5, weight: .semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ollamaRestarting ? Color.orange : (viewModel.ollamaStatus == "Active" ? Color.green : Color.red))
                            .frame(width: 8, height: 8)
                        Text(ollamaRestarting ? "Neustart..." : (viewModel.ollamaStatus == "Active" ? "Aktiv" : "Offline"))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(ollamaRestarting ? .orange : (viewModel.ollamaStatus == "Active" ? .green : .red))
                    }
                }
                Text("Verbindung zu Ollama auf http://localhost:11434")
                    .font(.caption2).foregroundColor(.secondary)

                if !viewModel.ollamaModels.isEmpty {
                    Text("Modelle: \(viewModel.ollamaModels.joined(separator: ", "))")
                        .font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }

                Divider().opacity(0.3)

                // Worker-Pool (integriert)
                HStack(spacing: 12) {
                    Text("Parallele Chats:")
                        .font(.system(size: 13.5, weight: .medium))
                    Stepper("\(workerPoolSize) Worker", value: $workerPoolSize, in: 1...16)
                        .font(.system(size: 13.5))
                        .frame(maxWidth: 160)
                    Spacer()
                }
                Text("Mehr Worker = mehr parallele Chats. Ollama muss mit passender Parallelität laufen.")
                    .font(.caption2).foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Button("Ollama prüfen") {
                        Task { await viewModel.checkOllamaStatus() }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button(action: {
                        ollamaRestarting = true
                        viewModel.restartOllamaWithParallelism(workers: workerPoolSize)
                        // Live-Status: Poll until Ollama is back
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            for _ in 0..<10 {
                                await viewModel.checkOllamaStatus()
                                if viewModel.ollamaStatus == "Active" { break }
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            ollamaRestarting = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if ollamaRestarting { ProgressView().scaleEffect(0.6) }
                            Text(ollamaRestarting ? "Starte neu..." : "Neu starten (\(workerPoolSize)x parallel)")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(ollamaRestarting)
                }
            }
        }
    }

    // MARK: - Tool Routing Visualization

    /// Tool routing data: which agent gets which tools and why
    private static let toolRoutingDefaults: [(tool: String, role: String, icon: String, defaultAgents: [String], reason: String)] = [
        ("shell",           "Shell",            "terminal.fill",                    ["general", "coder", "utility"],    "Bash/Zsh-Befehle im Terminal ausführen, Pakete installieren, Prozesse starten"),
        ("file",            "Dateisystem",      "doc.fill",                         ["general", "coder", "utility"],    "Dateien und Ordner lesen, erstellen, bearbeiten und durchsuchen"),
        ("browser",         "Browser",          "globe",                            ["general", "web"],                 "Webseiten laden, DOM parsen und Inhalte extrahieren"),
        ("http",            "Netzwerk",         "network",                          ["general", "web"],                 "REST-APIs aufrufen, Webhooks senden, Daten herunterladen"),
        ("calendar",        "Kalender",         "calendar",                         ["general", "utility"],             "Termine erstellen, Erinnerungen setzen, Kalender abfragen"),
        ("contacts",        "Kontakte",         "person.crop.circle",               ["general", "utility"],             "Kontakte nach Name, Nummer oder E-Mail durchsuchen"),
        ("applescript",     "AppleScript",      "applescript",                      ["general", "utility"],             "macOS-Apps steuern: Mail, Finder, Safari, Messages etc."),
        ("memory_save",     "Speichern",        "brain.head.profile",               ["general", "coder", "web"],        "Wichtige Fakten, Entscheidungen und Kontext langfristig merken"),
        ("memory_recall",   "Abruf",            "magnifyingglass",                  ["general", "coder", "web"],        "Gespeicherte Erinnerungen und Wissen semantisch abrufen"),
        ("task_manage",     "Aufgaben",         "checklist",                        ["general"],                        "Tasks erstellen, planen, zuweisen und als erledigt markieren"),
        ("workflow_manage", "Workflows",        "arrow.triangle.branch",            ["general"],                        "Automatisierungs-Pipelines erstellen und ausführen"),
        ("call_subordinate","Delegation",       "person.2.fill",                    ["general"],                        "Teilaufgabe an spezialisierten Sub-Agent delegieren"),
        ("delegate_parallel","Parallel",        "person.3.fill",                    ["general"],                        "Mehrere Sub-Agents gleichzeitig für parallele Arbeit starten"),
        ("skill_write",     "Skills",           "square.and.pencil",                ["general", "coder"],               "Wiederverwendbare Fähigkeiten als Code-Snippets speichern"),
        ("notify",          "Benachrichtigung", "bell.fill",                        ["general", "coder", "web"],        "System-Benachrichtigungen und Push-Alerts an den User senden"),
        ("calculator",      "Rechner",          "plusminus",                        ["general", "coder", "utility"],    "Mathematische Berechnungen, Einheiten-Umrechnung, Formeln"),
        ("telegram_send",   "Telegram",         "paperplane.fill",                  ["general"],                        "Nachrichten über Telegram-Bot an Kontakte/Gruppen senden"),
        ("google_api",      "Google API",       "globe",                            ["general", "web"],                 "Google Suche, Maps, Drive und weitere Google-Dienste nutzen"),
        ("speak",           "Sprache",          "speaker.wave.2.fill",              ["general"],                        "Text als gesprochene Sprache ausgeben (Text-to-Speech)"),
    ]

    /// Persisted tool routing overrides
    @AppStorage("kobold.toolRouting") private var toolRoutingData: String = ""

    private func loadToolRouting() -> [String: Set<String>] {
        guard !toolRoutingData.isEmpty,
              let data = toolRoutingData.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            var map: [String: Set<String>] = [:]
            for item in Self.toolRoutingDefaults {
                map[item.tool] = Set(item.defaultAgents)
            }
            return map
        }
        return dict.mapValues { Set($0) }
    }

    private func saveToolRouting(_ map: [String: Set<String>]) {
        let dict = map.mapValues { Array($0).sorted() }
        if let data = try? JSONEncoder().encode(dict), let str = String(data: data, encoding: .utf8) {
            toolRoutingData = str
        }
    }

    private func shortProfileName(_ id: String) -> String {
        switch id {
        case "general": return "General"
        case "coder":      return "Dev"
        case "web":        return "Web"
        case "utility":    return "Utility"
        default:           return String(id.prefix(6))
        }
    }

    private func isAgentEnabled(tool: String, agent: String) -> Bool {
        loadToolRouting()[tool]?.contains(agent) ?? Self.toolRoutingDefaults.first(where: { $0.tool == tool })?.defaultAgents.contains(agent) ?? false
    }

    private func toggleAgent(tool: String, agent: String) {
        var map = loadToolRouting()
        var agents = map[tool] ?? Set(Self.toolRoutingDefaults.first(where: { $0.tool == tool })?.defaultAgents ?? [])
        if agents.contains(agent) {
            agents.remove(agent)
        } else {
            agents.insert(agent)
        }
        map[tool] = agents
        saveToolRouting(map)
    }

    var toolRoutingCard: some View {
        GlassCard(padding: 0, cornerRadius: 14) {
            VStack(spacing: 0) {
                // Header (klickbar, wie AgentConfigCard)
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        toolRoutingExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.title2)
                            .foregroundColor(.koboldEmerald)
                            .frame(width: 36, height: 36)
                            .background(Color.koboldSurface)
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tool-Routing")
                                .font(.system(size: 16.5, weight: .semibold))
                            Text("Welche Tools stehen welchem Sub-Agenten zur Verfügung")
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.koboldEmerald)
                                .frame(width: 6, height: 6)
                            Text("\(Self.toolRoutingDefaults.count) Tools")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.koboldSurface)
                        .cornerRadius(6)

                        Image(systemName: toolRoutingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)

                // Content (eingeklappt/ausgeklappt)
                if toolRoutingExpanded {
                    Divider().padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deaktivierte Tools werden aus dem System-Prompt entfernt. General hat immer Zugriff auf alle Tools als Orchestrator.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)

                    // Table header
                    HStack(spacing: 12) {
                        Text("Tool")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(width: 130, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(store.configs, id: \.id) { config in
                                Text(shortProfileName(config.id))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 48)
                            }
                        }
                        Text("Beschreibung")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.white.opacity(0.03))

                    ForEach(Self.toolRoutingDefaults, id: \.tool) { item in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(.koboldEmerald)
                                    .frame(width: 20, alignment: .center)
                                Text(item.role)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(width: 130, alignment: .leading)

                            HStack(spacing: 4) {
                                ForEach(store.configs, id: \.id) { config in
                                    let enabled = isAgentEnabled(tool: item.tool, agent: config.id)
                                    Button(action: { toggleAgent(tool: item.tool, agent: config.id) }) {
                                        Text(config.emoji)
                                            .font(.system(size: 14.5))
                                            .frame(width: 48, height: 24)
                                            .background(RoundedRectangle(cornerRadius: 6)
                                                .fill(enabled ? Color.koboldEmerald.opacity(0.25) : Color.white.opacity(0.04)))
                                            .overlay(RoundedRectangle(cornerRadius: 6)
                                                .stroke(enabled ? Color.koboldEmerald.opacity(0.5) : Color.clear, lineWidth: 1))
                                            .saturation(enabled ? 1.0 : 0.0)
                                            .opacity(enabled ? 1.0 : 0.3)
                                    }
                                    .buttonStyle(.plain)
                                    .help(enabled ? "\(config.displayName): aktiv" : "\(config.displayName): deaktiviert")
                                }
                            }

                            Text(item.reason)
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
    }


    private func sessionStatusBadge(_ status: ActiveAgentSession.SessionStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 12.5))
                .foregroundColor(statusColor(status))
        }
    }

    private func statusColor(_ status: ActiveAgentSession.SessionStatus) -> Color {
        switch status {
        case .running:   return .koboldEmerald
        case .completed: return .secondary
        case .cancelled: return .orange
        case .error:     return .red
        }
    }
}

// MARK: - AgentActivityBanner

struct AgentActivityBanner: View {
    let session: ActiveAgentSession
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.prompt)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !session.currentTool.isEmpty {
                        Label(session.currentTool, systemImage: "wrench.fill")
                            .font(.system(size: 12.5))
                            .foregroundColor(.koboldGold)
                    }
                    Label(session.elapsed, systemImage: "clock")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    Label("\(session.stepCount) Schritte", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18.5))
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
            .help("Stoppen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.koboldEmerald.opacity(0.08))
        .cornerRadius(0)
        .overlay(
            Rectangle()
                .fill(Color.koboldEmerald)
                .frame(width: 3),
            alignment: .leading
        )
    }
}

// MARK: - AgentConfigCard

struct AgentConfigCard: View {
    @Binding var config: AgentModelConfig
    let ollamaModels: [String]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSave: () -> Void

    var activeModel: String {
        config.modelName.isEmpty ? "Standard" : config.modelName
    }

    var body: some View {
        GlassCard(padding: 0, cornerRadius: 14) {
            VStack(spacing: 0) {
                // Collapsed header
                Button(action: onToggle) {
                    HStack(spacing: 12) {
                        Text(config.emoji)
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .background(Color.koboldSurface)
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.displayName)
                                .font(.system(size: 16.5, weight: .semibold))
                            Text(config.description)
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Vision badge
                        if config.supportsVision {
                            HStack(spacing: 3) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 12.5))
                                Text("Vision")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundColor(.koboldEmerald)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.koboldEmerald.opacity(0.12))
                            .cornerRadius(5)
                        }

                        // Model pill
                        HStack(spacing: 4) {
                            Circle()
                                .fill(config.modelName.isEmpty ? Color.orange : Color.koboldEmerald)
                                .frame(width: 6, height: 6)
                            Text(activeModel)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.koboldSurface)
                        .cornerRadius(6)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)

                // Expanded detail
                if isExpanded {
                    Divider().padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 16) {

                        // Model picker (Ollama-only)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Ollama Modell", systemImage: "cpu.fill")
                                .font(.caption.bold()).foregroundColor(.secondary)

                            if ollamaModels.isEmpty {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                    Text("Keine Ollama Modelle geladen — klicke oben 'Modelle laden'")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            } else {
                                Picker("", selection: $config.modelName) {
                                    Text("Standard (globales Modell)").tag("")
                                    Divider()
                                    ForEach(ollamaModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }

                            HStack {
                                Text("oder manuell:").font(.caption).foregroundColor(.secondary)
                                TextField("z.B. llama3:latest", text: $config.modelName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            Text("Leer = globales Standard-Modell wird verwendet")
                                .font(.caption2).foregroundColor(.secondary)
                        }

                        Divider()

                        // Temperature + Context
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Temperatur: \(String(format: "%.1f", config.temperature))",
                                      systemImage: "thermometer.medium")
                                    .font(.caption.bold()).foregroundColor(.secondary)
                                Slider(value: $config.temperature, in: 0...1, step: 0.1)
                                    .frame(maxWidth: 180)
                                    .tint(.koboldEmerald)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Kontextlänge", systemImage: "text.justify")
                                    .font(.caption.bold()).foregroundColor(.secondary)
                                Picker("", selection: $config.contextLength) {
                                    Text("4K").tag(4096)
                                    Text("8K").tag(8192)
                                    Text("16K").tag(16384)
                                    Text("32K").tag(32768)
                                    Text("128K").tag(131072)
                                    Text("256K").tag(262144)
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 280)
                            }
                        }

                        Divider()

                        // Vision toggle
                        HStack(spacing: 10) {
                            Image(systemName: "eye.fill")
                                .foregroundColor(config.supportsVision ? .koboldEmerald : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Vision / Multimodal")
                                    .font(.system(size: 15.5, weight: .medium))
                                Text("Aktiviert Bildanalyse — nutze ein Vision-Modell wie llava oder llama3.2-vision.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $config.supportsVision)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(.koboldEmerald)
                        }

                        Divider()

                        // System Prompt
                        VStack(alignment: .leading, spacing: 6) {
                            Label("System-Prompt", systemImage: "text.quote")
                                .font(.caption.bold()).foregroundColor(.secondary)
                            TextEditor(text: $config.systemPrompt)
                                .font(.system(size: 13.5))
                                .frame(minHeight: 60, maxHeight: 120)
                                .padding(6)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(8)
                                .scrollContentBackground(.hidden)
                        }

                        // Save button
                        HStack {
                            Spacer()
                            GlassButton(title: "Speichern", icon: "checkmark", isPrimary: true) {
                                onSave()
                                onToggle()
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}
