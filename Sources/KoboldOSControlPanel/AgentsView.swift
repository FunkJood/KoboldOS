import SwiftUI

// MARK: - Agent Model Config (persisted to UserDefaults)

struct AgentModelConfig: Codable, Identifiable {
    var id: String          // "instructor", "coder", "researcher", "web", "utility"
    var displayName: String
    var emoji: String
    var description: String
    var provider: String = "ollama"  // "ollama", "openai", "anthropic", "groq"
    var modelName: String   // Model name, e.g. "llama3.2" or "gpt-4o"
    var systemPrompt: String
    var temperature: Double
    var contextLength: Int
    var supportsVision: Bool = false  // enable vision (multimodal) for this agent

    static let defaults: [AgentModelConfig] = [
        AgentModelConfig(
            id: "instructor",
            displayName: "Instructor",
            emoji: "🧠",
            description: "Hauptagent — plant, delegiert und antwortet dem Nutzer",
            modelName: "",
            systemPrompt: "You are the Instructor agent. You plan tasks, delegate to sub-agents, and synthesize results for the user.",
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
            id: "researcher",
            displayName: "Researcher",
            emoji: "📚",
            description: "Recherche-Agent — sucht und analysiert Informationen",
            modelName: "",
            systemPrompt: "You are a research specialist. Find accurate information and summarize it clearly.",
            temperature: 0.5,
            contextLength: 8192,
            supportsVision: false
        ),
        AgentModelConfig(
            id: "web",
            displayName: "Web",
            emoji: "🌐",
            description: "Web-Agent — navigiert Webseiten und extrahiert Daten",
            modelName: "",
            systemPrompt: "You are a web specialist. Extract and summarize information from web pages.",
            temperature: 0.4,
            contextLength: 4096,
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
    @StateObject private var store = AgentsStore.shared
    @State private var expandedId: String? = nil

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
                    Button(action: { Task { await store.fetchOllamaModels() } }) {
                        HStack(spacing: 4) {
                            if store.isLoadingModels {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Modelle laden")
                        }
                        .font(.system(size: 14.5))
                    }
                    .buttonStyle(.bordered)
                    .help("Ollama Modelle abrufen")
                }

                // Sessions table (oben)
                sessionsTable

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

                // Tool Routing Map
                toolRoutingSection
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

    // MARK: - Tool Routing Visualization

    /// Tool routing data: which agent gets which tools and why
    private static let toolRoutingDefaults: [(tool: String, role: String, icon: String, defaultAgents: [String], reason: String)] = [
        ("shell",           "Shell",            "terminal.fill",                    ["instructor", "coder", "utility"],    "Bash/Zsh-Befehle im Terminal ausführen, Pakete installieren, Prozesse starten"),
        ("file",            "Dateisystem",      "doc.fill",                         ["instructor", "coder", "utility"],    "Dateien und Ordner lesen, erstellen, bearbeiten und durchsuchen"),
        ("browser",         "Browser",          "globe",                            ["instructor", "researcher", "web"],   "Webseiten laden, DOM parsen und Inhalte extrahieren"),
        ("http",            "Netzwerk",         "network",                          ["instructor", "researcher", "web"],   "REST-APIs aufrufen, Webhooks senden, Daten herunterladen"),
        ("calendar",        "Kalender",         "calendar",                         ["instructor", "utility"],             "Termine erstellen, Erinnerungen setzen, Kalender abfragen"),
        ("contacts",        "Kontakte",         "person.crop.circle",               ["instructor", "utility"],             "Kontakte nach Name, Nummer oder E-Mail durchsuchen"),
        ("applescript",     "AppleScript",      "applescript",                      ["instructor", "utility"],             "macOS-Apps steuern: Mail, Finder, Safari, Messages etc."),
        ("memory_save",     "Speichern",        "brain.head.profile",               ["instructor", "coder", "researcher"], "Wichtige Fakten, Entscheidungen und Kontext langfristig merken"),
        ("memory_recall",   "Abruf",            "magnifyingglass",                  ["instructor", "coder", "researcher"], "Gespeicherte Erinnerungen und Wissen semantisch abrufen"),
        ("task_manage",     "Aufgaben",         "checklist",                        ["instructor"],                        "Tasks erstellen, planen, zuweisen und als erledigt markieren"),
        ("workflow_manage", "Workflows",        "arrow.triangle.branch",            ["instructor"],                        "Automatisierungs-Pipelines erstellen und ausführen"),
        ("call_subordinate","Delegation",       "person.2.fill",                    ["instructor"],                        "Teilaufgabe an spezialisierten Sub-Agent delegieren"),
        ("delegate_parallel","Parallel",        "person.3.fill",                    ["instructor"],                        "Mehrere Sub-Agents gleichzeitig für parallele Arbeit starten"),
        ("skill_write",     "Skills",           "square.and.pencil",                ["instructor", "coder"],               "Wiederverwendbare Fähigkeiten als Code-Snippets speichern"),
        ("notify",          "Benachrichtigung", "bell.fill",                        ["instructor", "coder", "researcher"], "System-Benachrichtigungen und Push-Alerts an den User senden"),
        ("calculator",      "Rechner",          "plusminus",                        ["instructor", "coder", "utility"],    "Mathematische Berechnungen, Einheiten-Umrechnung, Formeln"),
        ("telegram_send",   "Telegram",         "paperplane.fill",                  ["instructor"],                        "Nachrichten über Telegram-Bot an Kontakte/Gruppen senden"),
        ("google_api",      "Google API",       "globe",                            ["instructor", "web"],                 "Google Suche, Maps, Drive und weitere Google-Dienste nutzen"),
        ("speak",           "Sprache",          "speaker.wave.2.fill",              ["instructor"],                        "Text als gesprochene Sprache ausgeben (Text-to-Speech)"),
        ("generate_image",  "Bildgenerator",    "photo.artframe",                   ["instructor"],                        "Bilder per Stable Diffusion aus Text-Prompts generieren"),
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

    var toolRoutingSection: some View {
        GlassCard(padding: 0, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Tool-Routing", systemImage: "arrow.triangle.swap")
                            .font(.system(size: 16.5, weight: .semibold))
                        Spacer()
                        Text("\(Self.toolRoutingDefaults.count) Tools")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text("Bestimmt, welche Tools dem AgentLoop pro Agent zur Verfügung stehen. Deaktivierte Tools werden aus dem System-Prompt entfernt und können nicht aufgerufen werden.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(14)

                Divider()

                // Header
                HStack(spacing: 12) {
                    Text("Tool")
                        .font(.system(size: 12.5, weight: .bold))
                        .frame(width: 130, alignment: .leading)
                    // Agent emoji headers
                    HStack(spacing: 4) {
                        ForEach(store.configs, id: \.id) { config in
                            Text(config.emoji)
                                .font(.system(size: 12.5))
                                .frame(width: 24)
                                .help(config.displayName)
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
                        // Icon (centered) + Role
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

                        // Agent toggle badges — click to enable/disable
                        HStack(spacing: 4) {
                            ForEach(store.configs, id: \.id) { config in
                                let enabled = isAgentEnabled(tool: item.tool, agent: config.id)
                                Button(action: { toggleAgent(tool: item.tool, agent: config.id) }) {
                                    Text(config.emoji)
                                        .font(.system(size: 14.5))
                                        .frame(width: 24, height: 24)
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

                        // Beschreibung — fills remaining space
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

    // MARK: - Sessions Table

    var sessionsTable: some View {
        GlassCard(padding: 0, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Aktive Sessions", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 16.5, weight: .semibold))
                    Spacer()
                    Text("\(viewModel.activeSessions.count) Sessions")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(14)

                Divider()

                if viewModel.activeSessions.isEmpty {
                    Text("Keine aktiven oder kürzlichen Sessions.")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(14)
                } else {
                    // Table header
                    HStack(spacing: 0) {
                        Text("Typ").frame(width: 70, alignment: .leading)
                        Text("Agent").frame(width: 80, alignment: .leading)
                        Text("Aufgabe").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Schritte").frame(width: 60, alignment: .trailing)
                        Text("Tokens").frame(width: 70, alignment: .trailing)
                        Text("Status").frame(width: 90, alignment: .trailing)
                        Text("").frame(width: 30)
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.koboldSurface.opacity(0.5))

                    ForEach(viewModel.activeSessions) { session in
                        HStack(spacing: 0) {
                            // Type badge
                            Text(session.parentAgentType.isEmpty ? "Agent" : "Sub")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(session.parentAgentType.isEmpty ? Color.koboldEmerald : Color.koboldGold)
                                .cornerRadius(4)
                                .frame(width: 70, alignment: .leading)

                            Text(session.agentType)
                                .font(.system(size: 13.5, weight: .medium))
                                .frame(width: 80, alignment: .leading)

                            Text(session.prompt)
                                .font(.system(size: 13.5))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(session.stepCount)")
                                .font(.system(size: 13.5, design: .monospaced))
                                .frame(width: 60, alignment: .trailing)

                            Text(session.tokensUsed > 0 ? "\(session.tokensUsed)" : "—")
                                .font(.system(size: 13.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .trailing)

                            sessionStatusBadge(session.status)
                                .frame(width: 90, alignment: .trailing)

                            if session.status == .running {
                                Button(action: { viewModel.killSession(session.id) }) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 14.5))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 30)
                            } else {
                                Spacer().frame(width: 30)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(session.status == .running ? Color.koboldEmerald.opacity(0.04) : Color.clear)

                        if session.id != viewModel.activeSessions.last?.id {
                            Divider().padding(.horizontal, 14)
                        }
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

    private func providerLabel(_ provider: String) -> String {
        switch provider {
        case "openai":    return "OpenAI"
        case "anthropic": return "Anthropic"
        case "groq":      return "Groq"
        default:          return "Ollama"
        }
    }

    private func suggestedModels(for provider: String) -> [String] {
        switch provider {
        case "openai":    return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o1", "o3-mini"]
        case "anthropic": return ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-20250514"]
        case "groq":      return ["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"]
        default:          return []
        }
    }

    private func modelPlaceholder(_ provider: String) -> String {
        switch provider {
        case "openai":    return "z.B. gpt-4o"
        case "anthropic": return "z.B. claude-sonnet-4-20250514"
        case "groq":      return "z.B. llama-3.3-70b-versatile"
        default:          return "z.B. llama3.2:8b"
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "openai":    return .green
        case "anthropic": return .orange
        case "groq":      return .koboldEmerald
        default:          return .gray
        }
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

                        // Provider + Model pill
                        HStack(spacing: 4) {
                            if config.provider != "ollama" {
                                Text(providerLabel(config.provider))
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(providerColor(config.provider))
                                    .cornerRadius(4)
                            }
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

                        // Provider picker
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Provider", systemImage: "cloud.fill")
                                .font(.caption.bold()).foregroundColor(.secondary)
                            Picker("", selection: $config.provider) {
                                Text("Ollama (lokal)").tag("ollama")
                                Text("OpenAI").tag("openai")
                                Text("Anthropic").tag("anthropic")
                                Text("Groq").tag("groq")
                            }
                            .pickerStyle(.segmented)

                            if config.provider != "ollama" {
                                HStack(spacing: 6) {
                                    Image(systemName: "key.fill").font(.caption2).foregroundColor(.koboldGold)
                                    Text("API-Key in Settings > API-Provider konfigurieren")
                                        .font(.caption).foregroundColor(.koboldGold)
                                }
                            }
                        }

                        Divider()

                        // Model picker (adapts to selected provider)
                        VStack(alignment: .leading, spacing: 6) {
                            Label(providerLabel(config.provider) + " Modell",
                                  systemImage: "cpu.fill")
                                .font(.caption.bold()).foregroundColor(.secondary)

                            if config.provider == "ollama" {
                                // Ollama: show locally available models
                                if ollamaModels.isEmpty {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                        Text("Keine Ollama Modelle — ist Ollama gestartet?")
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
                            } else {
                                // Cloud provider: show suggested models
                                let suggested = suggestedModels(for: config.provider)
                                Picker("", selection: $config.modelName) {
                                    Text("Standard").tag("")
                                    Divider()
                                    ForEach(suggested, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }

                            HStack {
                                Text("oder manuell:").font(.caption).foregroundColor(.secondary)
                                TextField(modelPlaceholder(config.provider), text: $config.modelName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }
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
