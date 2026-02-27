import Foundation
import SwiftUI
import Combine
import KoboldCore
import UserNotifications

// MARK: - Core Types

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case general, coder, web, embedding
}

public enum ChatMode: String, Codable, Sendable {
    case normal, task, workflow
}

public struct ThinkingEntry: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public enum ThinkingEntryType: String, Sendable { 
        case thought, toolCall, toolResult, subAgentSpawn, subAgentResult, agentStep 
    }
    public let type: ThinkingEntryType
    public let content: String
    public let toolName: String
    public let success: Bool
    public var icon: String {
        switch type {
        case .thought: return "brain"
        case .toolCall: return "wrench.fill"
        case .toolResult: return success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        default: return "step.forward"
        }
    }
}

public struct KoboldNotification: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var message: String
    public var timestamp = Date()
    public var navigationTarget: String? = nil
    public var sessionId: UUID? = nil
    public enum NotificationType: String, Codable, Sendable { case info, success, warning, error }
    public var type: NotificationType = .info
    public var icon: String { "bell" }
    public var color: Color { .blue }
}

// MARK: - SessionAgentState (Per-Session Isolation)

public struct SessionAgentState {
    public var isLoading: Bool = false
    public var messageQueue: [String] = []
    public var streamTask: Task<Void, Never>? = nil
    public var thinkingSteps: [ThinkingEntry] = []
    public var checklist: [String] = []
    public var lastPrompt: String? = nil
    public var wasStopped: Bool = false
    // Context Usage per Session
    public var contextPromptTokens: Int = 0
    public var contextCompletionTokens: Int = 0
    public var contextUsagePercent: Double = 0.0
    public var contextWindowSize: Int = {
        let stored = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        return stored > 0 ? stored : 32768
    }()

    public init() {}
}

// MARK: - RuntimeViewModel

@MainActor
public class RuntimeViewModel: ObservableObject {

    // MARK: - Session Isolation (Multi-Chat)

    /// Per-Session Agent State für vollständige Isolation
    private var sessionAgentStates: [UUID: SessionAgentState] = [:]

    /// Per-Session Pending Messages Buffer
    private var pendingMessages: [UUID: [ChatMessage]] = [:]

    /// Streaming Sessions Set (statt Bool für korrekte Multi-Chat Isolation)
    public private(set) var streamingSessions: Set<UUID> = []

    // MARK: - Memory Management
    /// Tracks last access time per session for offloading inactive ones
    private var sessionLastAccess: [UUID: Date] = [:]
    /// Periodic timer that offloads inactive background sessions from RAM
    private var offloadTimer: Task<Void, Never>?
    /// macOS memory pressure handler — offloads all background sessions on warning/critical
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// A2: Connectivity-Timer Referenz (war fire-and-forget → Zombie-Ursache)
    private var connectivityTask: Task<Void, Never>?
    /// A2: Shutdown-Observer Token (für sauberes removeObserver in deinit)
    private var shutdownObserver: NSObjectProtocol?

    /// Computed: Ist gerade irgendeine Session am Streamen?
    public var isStreamingToDaemon: Bool { !streamingSessions.isEmpty }

    /// Computed: Lädt der Agent in der aktuell sichtbaren Session?
    public var isAgentLoadingInCurrentChat: Bool {
        streamingSessions.contains(currentSessionId)
    }

    // UI State (aktive Session)
    // P1: Chat-only properties use didSet guard — only trigger objectWillChange when Chat tab is visible.
    // This prevents MemoryView, SettingsView, TasksView etc. from re-rendering on every message append.
    // G4: Perf-Logging Flag (Default: false, via Einstellungen aktivierbar)
    private lazy var perfLogEnabled: Bool = UserDefaults.standard.bool(forKey: "kobold.debug.perfLog")

    var messages: [ChatMessage] = [] {
        didSet {
            if currentViewTab == "chat" {
                if perfLogEnabled { kperf("objectWillChange: messages count=\(messages.count)") }
                objectWillChange.send()
            }
        }
    }
    public var agentLoading: Bool = false {
        didSet {
            if currentViewTab == "chat" {
                if perfLogEnabled { kperf("objectWillChange: agentLoading=\(agentLoading)") }
                objectWillChange.send()
            }
        }
    }
    // F1: isConnected — nur bei ECHTEM Wechsel senden (Connectivity-Timer feuert alle 5s)
    public var isConnected: Bool = false {
        didSet {
            guard oldValue != isConnected else { return }
            if perfLogEnabled { kperf("objectWillChange: isConnected=\(isConnected)") }
            objectWillChange.send()
        }
    }
    @Published public var currentViewTab: String = "chat"
    // F1: notifications — append/clear ändert immer → bleibt funktional @Published-like
    public var notifications: [KoboldNotification] = [] {
        didSet {
            if perfLogEnabled { kperf("objectWillChange: notifications count=\(notifications.count)") }
            objectWillChange.send()
        }
    }

    // Model State
    @Published public var loadedModels: [ModelInfo] = []
    @Published public var activeOllamaModel: String = ""
    @Published public var ollamaStatus: String = "Unknown"
    @Published public var daemonStatus: String = "Unknown"

    // Sessions & Projects
    @Published public var sessions: [ChatSession] = []
    @Published public var currentSessionId: UUID = UUID()
    @Published public var projects: [Project] = Project.defaultProjects()
    @Published public var selectedProjectId: UUID? = nil

    // Teams & Workflow
    @Published public var teams: [AgentTeam] = AgentTeam.defaults
    @Published public var chatMode: ChatMode = .normal
    @Published public var taskChatLabel: String = ""
    @Published public var workflowChatLabel: String = ""
    @Published public var workflowLastResponse: String? = nil
    @Published public var activeSessions: [ActiveAgentSession] = []
    @Published public var teamMessages: [UUID: [GroupMessage]] = [:]

    // Agent State (für ChatView ThinkingPanel) - wird aus sessionAgentStates gelesen
    public var activeThinkingSteps: [ThinkingEntry] {
        get { sessionAgentStates[currentSessionId]?.thinkingSteps ?? [] }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].thinkingSteps = newValue }
    }
    public var agentChecklist: [String] {
        get { sessionAgentStates[currentSessionId]?.checklist ?? [] }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].checklist = newValue }
    }
    public var messageQueue: [String] {
        get { sessionAgentStates[currentSessionId]?.messageQueue ?? [] }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].messageQueue = newValue }
    }
    public var agentWasStopped: Bool {
        get { sessionAgentStates[currentSessionId]?.wasStopped ?? false }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].wasStopped = newValue }
    }
    public var lastAgentPrompt: String? {
        get { sessionAgentStates[currentSessionId]?.lastPrompt }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].lastPrompt = newValue }
    }
    /// E2: Cached newestThinkingId — statt O(n) Suche bei jedem Render
    public var newestThinkingId: UUID? = nil

    // Context Usage (für Context Bar) - per Session
    public var contextPromptTokens: Int {
        get { sessionAgentStates[currentSessionId]?.contextPromptTokens ?? 0 }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].contextPromptTokens = newValue }
    }
    public var contextCompletionTokens: Int {
        get { sessionAgentStates[currentSessionId]?.contextCompletionTokens ?? 0 }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].contextCompletionTokens = newValue }
    }
    public var contextUsagePercent: Double {
        get { sessionAgentStates[currentSessionId]?.contextUsagePercent ?? 0.0 }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].contextUsagePercent = newValue }
    }
    public var contextWindowSize: Int {
        get { sessionAgentStates[currentSessionId]?.contextWindowSize ?? 32000 }
        set { sessionAgentStates[currentSessionId, default: SessionAgentState()].contextWindowSize = newValue }
    }

    // Topics (für Topic-Badge im Chat-Header) — P1: only notify when chat visible
    public var topics: [ChatTopic] = [] {
        didSet { if currentViewTab == "chat" { objectWillChange.send() } }
    }
    public var activeTopicId: UUID? = nil {
        didSet { if currentViewTab == "chat" { objectWillChange.send() } }
    }

    @AppStorage("kobold.port") private var storedPort: Int = 8080
    @AppStorage("kobold.authToken") private var storedToken: String = "kobold-secret"
    @AppStorage("kobold.safeModeActive") private var _safeModeActive: Bool = false

    public var authToken: String { storedToken }
    public var baseURL: String { "http://localhost:\(storedPort)" }
    private var cancellables = Set<AnyCancellable>()

    // Metrics
    @Published public var metrics: RuntimeMetrics = RuntimeMetrics()
    @Published public var unreadNotificationCount: Int = 0

    // Safe Mode Status
    public var safeModeActive: Bool { _safeModeActive }

    public init() {
        // Globale Standardwerte registrieren — stellt sicher, dass Permissions
        // SOFORT korrekte Defaults haben, auch wenn Settings nie geöffnet wurde.
        // @AppStorage-Defaults greifen NUR in SwiftUI-Views, nicht in Tools!
        UserDefaults.standard.register(defaults: [
            // Autonomie-Level: 2 = Normal (Shell+File erlaubt)
            "kobold.autonomyLevel": 2,
            // Kern-Berechtigungen (default: erlaubt)
            "kobold.perm.shell": true,
            "kobold.perm.fileWrite": true,
            "kobold.perm.createFiles": true,
            "kobold.perm.network": true,
            "kobold.perm.confirmAdmin": true,
            "kobold.perm.modifyMemory": true,
            "kobold.perm.notifications": true,
            "kobold.perm.calendar": true,
            // Kern-Berechtigungen (default: deaktiviert — sensibel)
            "kobold.perm.deleteFiles": false,
            "kobold.perm.playwright": false,
            "kobold.perm.screenControl": false,
            "kobold.perm.selfCheck": false,
            "kobold.perm.installPkgs": false,
            "kobold.perm.contacts": false,
            "kobold.perm.mail": false,
            // Shell-Tier Defaults
            "kobold.shell.powerTier": true,
            "kobold.shell.normalTier": true,
            // Worker Pool
            "kobold.workerPool.size": 4,
            // Context Window
            "kobold.context.windowSize": 32768,
            // Port + Token
            "kobold.port": 8080,
            "kobold.authToken": "kobold-secret",
            // Embedding
            "kobold.embedding.model": "nomic-embed-text",
            // TTS Defaults
            "kobold.tts.rate": 0.5,
            "kobold.tts.volume": 0.8,
            "kobold.tts.voice": "de-DE",
            // Proactive Engine
            "kobold.proactive.quietStart": 22,
            "kobold.proactive.quietEnd": 7,
        ])

        // Sessions von Disk laden (falls vorhanden)
        loadSessions()
        // Initiale Session anlegen
        sessionAgentStates[currentSessionId] = SessionAgentState()
        sessionLastAccess[currentSessionId] = Date()
        // A2/A4: Bei App-Beendigung: speichern → sofort auf Disk → cleanup
        // queue: .main garantiert Main-Thread → MainActor.assumeIsolated ist sicher
        shutdownObserver = NotificationCenter.default.addObserver(forName: .koboldShutdownSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.upsertCurrentSession()
                self.saveSessionsWithRetry()  // Sofort speichern (nicht debounced)
                self.cleanup()
            }
        }
        startConnectivityTimer()
        // Memory Management: Offload inactive sessions + handle system memory pressure
        startSessionOffloadTimer()
        setupMemoryPressureHandler()
        // Notification-Berechtigung anfordern (für Task-Benachrichtigungen)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Ollama + Embedding bei Start prüfen (nach kurzem Delay für Startup)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s warten bis Ollama bereit
            await self?.checkOllamaStatus()
            await self?.checkEmbeddingStatus()
            // Set correct default model from AgentsStore on all workers
            if let generalModel = AgentsStore.shared.configs.first(where: { $0.id == "general" })?.modelName,
               !generalModel.isEmpty {
                await LLMRunner.shared.setModel(generalModel)
                UserDefaults.standard.set(generalModel, forKey: "kobold.ollamaModel")
                print("[RuntimeViewModel] Set default Ollama model to general agent: \(generalModel)")
            }
        }
    }

    /// Sessions von Disk laden (~/Library/Application Support/KoboldOS/sessions.json)
    /// Startet immer mit leerem Chat für Stabilität — alte Sessions bleiben in der Sidebar verfügbar.
    private func loadSessions() {
        let url = sessionsURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            print("[RuntimeViewModel] No saved sessions found — starting fresh")
            return
        }
        sessions = loaded
        // Fresh start: Neuer leerer Chat statt letzte Session laden
        // Alte Sessions bleiben in der Sidebar und können jederzeit gewechselt werden
        // Das verhindert, dass ein langer Chat-Verlauf beim Start die UI belastet
        print("[RuntimeViewModel] Loaded \(loaded.count) sessions from disk — starting fresh chat")
    }
    
    // MARK: - API Helpers
    
    public func loadMetrics() async {
        // Placeholder
    }
    
    public func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(storedToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }
    
    public func authorizedData(from url: URL) async throws -> (Data, URLResponse) {
        let req = authorizedRequest(url: url)
        return try await URLSession.shared.data(for: req)
    }

    // MARK: - Messaging
    
    func sendMessage(_ text: String, targetSessionId: UUID? = nil, agentText: String? = nil, attachments: [MediaAttachment] = []) {
        let userMsg = ChatMessage(kind: .user(text: text), attachments: attachments)
        let sessionId = targetSessionId ?? currentSessionId
        appendMessage(userMsg, for: sessionId)

        let messageForAgent = agentText ?? text
        let isBackgroundSession = (sessionId != currentSessionId)

        // Ensure session appears in sidebar immediately on first message
        if !sessions.contains(where: { $0.id == sessionId }) {
            if isBackgroundSession {
                debouncedSave()
            } else {
                upsertCurrentSession()
            }
        }

        // Nutzerverhalten für personalisierte Vorschläge tracken
        SuggestionService.shared.recordUserActivity(message: text)

        // Save the prompt for resume
        sessionAgentStates[sessionId, default: SessionAgentState()].lastPrompt = messageForAgent

        // Cancel any existing stream task for this session
        sessionAgentStates[sessionId]?.streamTask?.cancel()

        let streamTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                if !isBackgroundSession {
                    self.agentLoading = true
                    self.activeThinkingSteps = []
                }
                self.streamingSessions.insert(sessionId)
            }

            let accumulator = SSEAccumulator()

            // Build SSE request to /agent/stream
            let url = URL(string: "\(self.baseURL)/agent/stream")!
            var req = self.authorizedRequest(url: url, method: "POST")
            req.timeoutInterval = 300

            // Build conversation history for context
            let history: [[String: String]] = await MainActor.run {
                self.conversationHistory(for: sessionId, limit: 30)
                    .compactMap { msg in
                        switch msg.kind {
                        case .user(let t): return ["role": "user", "content": t]
                        case .assistant(let t): return ["role": "assistant", "content": t]
                        default: return nil
                        }
                    }
            }

            // Read model config from AgentsStore (user configures per-agent model in Settings → Agenten)
            let agentConfig = await MainActor.run { AgentsStore.shared.configs.first(where: { $0.id == "general" }) }
            let modelName = agentConfig?.modelName ?? ""
            let temperature = agentConfig?.temperature ?? 0.7

            var body: [String: Any] = [
                "message": messageForAgent,
                "agent_type": "general",
                "provider": "ollama",
                "model": modelName,
                "temperature": temperature
            ]
            if !history.isEmpty { body["conversation_history"] = history }
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                await MainActor.run {
                    self.appendMessage(ChatMessage(kind: .assistant(text: "Fehler beim Erstellen der Anfrage")), for: sessionId)
                    self.agentLoading = false
                    self.streamingSessions.remove(sessionId)
                }
                return
            }
            req.httpBody = bodyData

            // Use delegate-based SSE stream for guaranteed real-time delivery.
            // URLSession.bytes(for:) can buffer data with raw HTTP servers on macOS.
            print("[SSE-Client] Connecting to \(url) (delegate mode)...")
            let lines = self.sseLines(for: req)

            // Start 1.5s flush timer for UI updates (user-requested: stability over responsiveness)
            // SSEAccumulator still collects events in real-time, but UI only refreshes every 1.5s
            // P2: Flush interval 2.0s (was 1.5s) — fewer re-renders per second
            let flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, !Task.isCancelled else { break }
                    let flush = await accumulator.takePendingFlush()
                    if !flush.steps.isEmpty || flush.contextPromptTokens != nil {
                        await MainActor.run {
                            if !flush.steps.isEmpty {
                                var state = self.sessionAgentStates[sessionId] ?? SessionAgentState()
                                state.thinkingSteps.append(contentsOf: flush.steps)
                                // Cap thinkingSteps to prevent unbounded growth during long sub-agent runs
                                if state.thinkingSteps.count > 50 {
                                    state.thinkingSteps = Array(state.thinkingSteps.suffix(40))
                                }
                                self.sessionAgentStates[sessionId] = state
                            }
                            if let pt = flush.contextPromptTokens {
                                self.updateContextUsage(
                                    for: sessionId,
                                    promptTokens: pt,
                                    completionTokens: flush.contextCompletionTokens ?? 0,
                                    windowSize: flush.contextWindowSize ?? 32000
                                )
                            }
                            // P2: No manual objectWillChange.send() — P1 didSet handles granular notification
                            // sessionAgentStates mutation + syncAgentStateToUI will trigger needed UI updates
                            if sessionId == self.currentSessionId {
                                self.syncAgentStateToUI()
                            }
                        }
                    }
                }
            }

            // Parse SSE lines from delegate-based stream
            var currentEvent = ""
            var lineCount = 0
            var eventCount = 0
            var httpOK = false

            for await line in lines {
                if Task.isCancelled { break }

                // First line from delegate: HTTP status
                if line.hasPrefix("__HTTP_STATUS__:") {
                    let code = Int(line.dropFirst(16)) ?? 0
                    print("[SSE-Client] HTTP \(code)")
                    DaemonLog.shared.add("SSE HTTP \(code)", category: .network)
                    if code != 200 {
                        await MainActor.run {
                            self.appendMessage(ChatMessage(kind: .assistant(text: "Daemon-Fehler (HTTP \(code))")), for: sessionId)
                            self.agentLoading = false
                            self.streamingSessions.remove(sessionId)
                        }
                        flushTask.cancel()
                        return
                    }
                    httpOK = true
                    continue
                }
                guard httpOK else { continue }

                lineCount += 1
                if lineCount <= 5 || lineCount % 50 == 0 {
                    let preview = line.count > 80 ? String(line.prefix(77)) + "..." : line
                    print("[SSE-Client] Line \(lineCount): \(preview)")
                }

                if line.hasPrefix("data: ") {
                    currentEvent = String(line.dropFirst(6))
                } else if line.hasPrefix("event: done") || (line.isEmpty && !currentEvent.isEmpty) {
                    if !currentEvent.isEmpty && currentEvent != "{}" {
                        eventCount += 1
                        await accumulator.processEvent(currentEvent)
                    }
                    currentEvent = ""
                }
            }

            print("[SSE-Client] Stream ended: \(lineCount) lines, \(eventCount) events")
            DaemonLog.shared.add("SSE fertig: \(eventCount) Events", category: .network)
            flushTask.cancel()

            guard httpOK else {
                await MainActor.run {
                    self.appendMessage(ChatMessage(kind: .assistant(text: "Keine Verbindung zum Daemon")), for: sessionId)
                    self.agentLoading = false
                    self.streamingSessions.remove(sessionId)
                }
                return
            }

            // Get final result
            await accumulator.markDone()
            let finalResult = await accumulator.takeFinalResult()

            // P8: SINGLE MainActor.run block statt 5 separate Chunks mit 50ms Pausen.
            // Vorher: 5 objectWillChange-Trigger in 150ms → 5 Full Re-Renders.
            // Jetzt: 1 Block → 1 Re-Render am Ende.
            await MainActor.run {
                // 1. Agent state
                var state = self.sessionAgentStates[sessionId] ?? SessionAgentState()
                state.thinkingSteps = finalResult.thinkingSteps
                self.sessionAgentStates[sessionId] = state

                // 2. Error or thinking box
                if let error = finalResult.error, !error.isEmpty {
                    self.appendMessage(ChatMessage(kind: .assistant(text: "Fehler: \(error)")), for: sessionId)
                    self.addNotification(title: "Agent-Fehler", message: String(error.prefix(100)), type: .error, navigationTarget: "chat")
                } else if !finalResult.thinkingSteps.isEmpty {
                    self.appendMessage(ChatMessage(kind: .thinking(entries: finalResult.thinkingSteps)), for: sessionId)
                }

                // 3. Final answer
                if !finalResult.finalAnswer.isEmpty && finalResult.error == nil {
                    self.appendMessage(ChatMessage(kind: .assistant(text: finalResult.finalAnswer)), for: sessionId)
                }

                // 4. Interactive + embed messages
                for interactive in finalResult.interactiveMessages {
                    self.appendMessage(ChatMessage(kind: .interactive(text: interactive.text, options: interactive.options)), for: sessionId)
                }
                for embed in finalResult.embedMessages {
                    self.appendMessage(ChatMessage(kind: .image(path: embed.path, caption: embed.caption)), for: sessionId)
                }

                // 5. Notifications + finalize
                let taskSession = self.sessions.first(where: { $0.id == sessionId })
                let isTask = taskSession?.taskId != nil
                if sessionId != self.currentSessionId && !finalResult.finalAnswer.isEmpty {
                    let prefix = isTask ? "Task fertig" : "Chat fertig"
                    let preview = String(finalResult.finalAnswer.prefix(80))
                    self.addNotification(title: prefix, message: preview, type: .success, sessionId: sessionId)
                }
                if isTask && !finalResult.finalAnswer.isEmpty {
                    // macOS System-Notification für Task-Ergebnis
                    self.postSystemNotification(
                        title: "Task abgeschlossen",
                        body: String(finalResult.finalAnswer.prefix(120)),
                        sessionId: sessionId
                    )
                } else if finalResult.toolStepCount >= 5 && !finalResult.finalAnswer.isEmpty {
                    self.addNotification(
                        title: "Aufgabe abgeschlossen",
                        message: "\(finalResult.toolStepCount) Schritte ausgef\u{00FC}hrt",
                        type: .success,
                        sessionId: sessionId
                    )
                }
                if sessionId == self.currentSessionId {
                    self.upsertCurrentSession()
                    self.agentLoading = false
                } else {
                    self.debouncedSave()
                }
                self.streamingSessions.remove(sessionId)
            }
        }

        sessionAgentStates[sessionId, default: SessionAgentState()].streamTask = streamTask
    }
    
    public func sendWorkflowMessage(_ text: String, modelOverride: String? = nil, agentOverride: String? = nil) {
        Task {
            workflowLastResponse = "Processing..."
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            workflowLastResponse = "Workflow abgeschlossen."
        }
    }
    
    // MARK: - Compress Context (visible in chat as tool-call)

    public func appendCompressMessage(for sessionId: UUID) {
        appendMessage(ChatMessage(kind: .toolCall(name: "context_compress", args: "Kontext wird komprimiert...")), for: sessionId)
    }

    public func appendCompressResult(remaining: Int, for sessionId: UUID) {
        if remaining >= 0 {
            appendMessage(ChatMessage(kind: .toolResult(name: "context_compress", success: true, output: "Kontext komprimiert. \(remaining) Nachrichten verbleiben.")), for: sessionId)
        } else {
            appendMessage(ChatMessage(kind: .toolResult(name: "context_compress", success: false, output: "Komprimierung fehlgeschlagen — Daemon nicht erreichbar.")), for: sessionId)
        }
    }

    /// Compact visible chat messages: keep last N, replace older with summary marker
    public func compactVisibleMessages(for sessionId: UUID, keepLast: Int = 20) {
        guard sessionId == currentSessionId else { return }
        guard messages.count > keepLast + 5 else { return } // Only compact if significantly over limit
        let oldCount = messages.count
        let kept = Array(messages.suffix(keepLast))
        let removedCount = oldCount - keepLast
        let summaryMsg = ChatMessage(kind: .thought(text: "[\(removedCount) ältere Nachrichten komprimiert — Kontext im Agent-Gedächtnis gespeichert]"))
        messages = [summaryMsg] + kept
        pendingMessages[sessionId] = messages
        upsertCurrentSession()
    }

    // MARK: - Session & Project Management

    public func loadProjects() {
        self.projects = Project.defaultProjects()
    }

    public func newProject() {
        let p = Project(id: UUID(), name: "Neues Projekt")
        projects.append(p)
        selectedProjectId = p.id
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }

    public func workflowURL(for id: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/workflows/\(id.uuidString).json")
    }

    public var sessionsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/sessions.json")
    }

    public var teamMessagesDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/teams")
    }

    // MARK: - Multi-Chat Session Isolation

    /// Append a message to the correct session (routes to pendingMessages for background sessions)
    private let maxMessagesPerSession = 200

    private func appendMessage(_ message: ChatMessage, for sessionId: UUID) {
        sessionLastAccess[sessionId] = Date()
        pendingMessages[sessionId, default: []].append(message)
        // Trim to prevent unbounded memory growth (keep last N messages)
        if pendingMessages[sessionId]!.count > maxMessagesPerSession {
            pendingMessages[sessionId] = Array(pendingMessages[sessionId]!.suffix(maxMessagesPerSession - 100))
        }
        if sessionId == currentSessionId {
            messages.append(message)
            // E2: newestThinkingId O(1) statt O(n) Suche in ChatView
            if case .thinking = message.kind { newestThinkingId = message.id }
            if messages.count > maxMessagesPerSession {
                messages = Array(messages.suffix(maxMessagesPerSession - 100))
            }
        }
    }

    /// P8: Leichtgewichtiges Upsert — NUR Titel/Timestamp für Sidebar.
    /// toCodable-Konvertierung passiert erst im debouncedSave (alle 3s statt bei jedem append).
    private func upsertCurrentSession() {
        // pendingMessages ist Source of Truth — sync von self.messages
        pendingMessages[currentSessionId] = messages
        // Titel aus erster User-Nachricht generieren
        let title: String
        if let firstUser = messages.first(where: {
            if case .user = $0.kind { return true }; return false
        }), case .user(let t) = firstUser.kind {
            title = String(t.prefix(40))
        } else {
            title = topics.first?.name ?? "Chat"
        }
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx].title = title
            // P8: sessions[idx].messages wird im debouncedSave aktualisiert — NICHT hier
        } else {
            var session = ChatSession(id: currentSessionId, title: title, messages: [])
            session.createdAt = Date()
            sessions.append(session)
        }
        // Debounced disk save — don't write on every single message
        debouncedSave()
    }

    private var saveDebounceTask: Task<Void, Never>?

    private func debouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s debounce
            guard !Task.isCancelled, let self else { return }
            // P8: toCodable-Konvertierung nur hier (alle 3s) statt bei jedem appendMessage
            for (sid, pending) in self.pendingMessages where !pending.isEmpty {
                if let idx = self.sessions.firstIndex(where: { $0.id == sid }) {
                    self.sessions[idx].messages = pending.map { $0.toCodable() }
                }
            }
            self.saveSessionsWithRetry()
        }
    }

    /// Session wechseln mit korrekter Isolation
    public func switchToSession(_ sessionId: UUID) {
        guard sessionId != currentSessionId else { return }

        // 1. Aktuelle Session speichern (Messages → pendingMessages + ChatSession)
        upsertCurrentSession()

        // 2. Zu neuer Session wechseln
        currentSessionId = sessionId
        sessionLastAccess[sessionId] = Date()

        // 3. Session-Agent-State initialisieren falls nicht vorhanden
        if sessionAgentStates[sessionId] == nil {
            sessionAgentStates[sessionId] = SessionAgentState()
        }

        // 4. Messages der neuen Session laden (pendingMessages hat Vorrang, dann ChatSession)
        //    Falls Session offloaded war (pendingMessages leer), lädt aus sessions[].messages
        //    WICHTIG: Nur letzte 50 Messages sofort laden — der Rest ist via "Mehr laden" erreichbar
        //    Das verhindert UI-Freeze beim Öffnen langer alter Chats
        if let pending = pendingMessages[sessionId], !pending.isEmpty {
            messages = pending.count > 50 ? Array(pending.suffix(50)) : pending
            // Volle Messages bleiben in pendingMessages für conversationHistory
        } else if let session = sessions.first(where: { $0.id == sessionId }), !session.messages.isEmpty {
            let allMessages = session.messages.map { $0.toChatMessage() }
            pendingMessages[sessionId] = allMessages
            messages = allMessages.count > 50 ? Array(allMessages.suffix(50)) : allMessages
        } else {
            messages = []
            pendingMessages[sessionId] = []
        }

        // 5. ChatMode basierend auf Session-Typ setzen
        if let session = sessions.first(where: { $0.id == sessionId }), session.taskId != nil {
            chatMode = .task
            taskChatLabel = session.title.hasPrefix("Task: ") ? String(session.title.dropFirst(6)) : session.title
        } else if chatMode == .task {
            chatMode = .normal
            taskChatLabel = ""
        }

        // 6. Agent Loading State für neue Session setzen
        agentLoading = streamingSessions.contains(sessionId)
        syncAgentStateToUI()
        objectWillChange.send()
    }

    /// Neue Session erstellen
    public func newSession() {
        // 1. Aktuelle Session speichern
        upsertCurrentSession()

        // 2. ChatSession erstellen und in sessions einfügen (damit Sidebar sofort zeigt)
        let session = ChatSession(id: UUID(), title: "Neuer Chat", messages: [])
        sessions.insert(session, at: 0)

        // 3. Zur neuen Session wechseln
        currentSessionId = session.id
        sessionAgentStates[currentSessionId] = SessionAgentState()
        pendingMessages[currentSessionId] = []
        sessionLastAccess[currentSessionId] = Date()

        // 4. UI aktualisieren (topics NICHT clearen — das sind die Sidebar-Themenordner!)
        messages = []
        chatMode = .normal
        activeTopicId = nil
    }

    /// Zur Session gehörende Messages laden
    public func loadMessages(for sessionId: UUID) {
        if let pending = pendingMessages[sessionId], !pending.isEmpty {
            messages = pending
        } else if let session = sessions.first(where: { $0.id == sessionId }), !session.messages.isEmpty {
            messages = session.messages.map { $0.toChatMessage() }
            pendingMessages[sessionId] = messages
        } else {
            messages = []
            pendingMessages[sessionId] = []
        }
    }

    /// Session aus streamingSessions entfernen (wenn fertig)
    public func finishStreaming(for sessionId: UUID) {
        streamingSessions.remove(sessionId)
        if sessionId == currentSessionId { agentLoading = false }
    }

    /// Session als streamend markieren
    public func startStreaming(for sessionId: UUID) {
        streamingSessions.insert(sessionId)
        if sessionId == currentSessionId { agentLoading = true }
    }

    // Convenience: switchToSession mit ChatSession statt UUID
    public func switchToSession(_ session: ChatSession) {
        switchToSession(session.id)
    }

    // Task Sessions: Alle Sessions mit taskId (gefiltert aus sessions)
    public var taskSessions: [ChatSession] {
        sessions.filter { $0.taskId != nil }.sorted { $0.createdAt > $1.createdAt }
    }
    @Published public var workflowSessions: [ChatSession] = []

    @Published public var workflowDefinitions: [WorkflowDef] = []

    public func loadWorkflowDefinitions() {
        // Workflow-Definitionen laden (Stub)
    }

    public func toggleTopicExpanded(_ topic: ChatTopic) {
        if let idx = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[idx].isExpanded.toggle()
        }
    }

    public func deleteTopic(_ topic: ChatTopic) {
        topics.removeAll { $0.id == topic.id }
    }

    public func updateTopic(_ topic: ChatTopic) {
        if let idx = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[idx] = topic
        }
    }

    public func assignSessionToTopic(sessionId: UUID, topicId: UUID?) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].topicId = topicId
        }
    }

    public func deleteWorkflowDefinition(_ def: WorkflowDef) {
        workflowDefinitions.removeAll { $0.id == def.id }
    }

    public func createTopic(name: String, color: String) {
        let topic = ChatTopic(name: name, color: color)
        topics.append(topic)
    }

    public func newSession(topicId: UUID) {
        upsertCurrentSession()
        let session = ChatSession(id: UUID(), title: "Neuer Chat", messages: [], topicId: topicId)
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        sessionAgentStates[currentSessionId] = SessionAgentState()
        pendingMessages[currentSessionId] = []
        sessionLastAccess[currentSessionId] = Date()
        messages = []
        chatMode = .normal
        activeTopicId = topicId
    }

    public func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
    }

    public func openWorkflowChat(nodeName: String) {
        chatMode = .workflow
        workflowChatLabel = nodeName
        upsertCurrentSession()
        messages = []
    }

    public func openTaskChat(taskId: String, taskName: String) {
        // 1. Aktuelle Session speichern
        upsertCurrentSession()

        // 2. Existierende Task-Session suchen oder neue erstellen
        if let existing = sessions.first(where: { $0.taskId == taskId }) {
            // Task-Session existiert → dahin wechseln
            switchToSession(existing.id)
        } else {
            // Neue Task-Session erstellen
            let session = ChatSession(
                id: UUID(),
                title: "Task: \(taskName)",
                messages: [],
                taskId: taskId
            )
            sessions.insert(session, at: 0)
            currentSessionId = session.id
            sessionAgentStates[currentSessionId] = SessionAgentState()
            pendingMessages[currentSessionId] = []
            sessionLastAccess[currentSessionId] = Date()
            messages = []
        }

        // 3. Chat-Mode setzen
        chatMode = .task
        taskChatLabel = taskName

        // 4. Zum Chat-Tab navigieren
        NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
    }

    // MARK: - Ollama Controls

    @Published public var embeddingAvailable: Bool = false
    @Published public var ollamaModels: [String] = []

    public func checkOllamaStatus() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            self.ollamaStatus = "Offline"
            return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                self.ollamaStatus = "Offline"
                return
            }
            self.ollamaStatus = "Active"
            // Modellliste aus Response parsen
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                self.ollamaModels = models.compactMap { $0["name"] as? String }
                self.loadedModels = models.compactMap { m -> ModelInfo? in
                    guard let name = m["name"] as? String else { return nil }
                    return ModelInfo(name: name, backendType: "ollama", capabilities: ["chat"])
                }
            }
        } catch {
            self.ollamaStatus = "Offline"
        }
    }

    public func checkEmbeddingStatus() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            self.embeddingAvailable = false
            return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: req)
            let embModel = UserDefaults.standard.string(forKey: "kobold.embedding.model") ?? "nomic-embed-text"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                self.embeddingAvailable = models.contains { ($0["name"] as? String)?.hasPrefix(embModel) == true }
            }
        } catch {
            self.embeddingAvailable = false
        }
    }

    public func loadModels() async {
        await checkOllamaStatus()
    }

    public func setActiveModel(_ name: String) { self.activeOllamaModel = name }

    public func restartOllamaWithParallelism(workers: Int) {
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "ollama"]
            try? proc.run()
            proc.waitUntilExit()

            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s warten

            let env: [String: String] = [
                "OLLAMA_NUM_PARALLEL": "\(workers)",
                "OLLAMA_MAX_LOADED_MODELS": "\(workers)",
                "OLLAMA_NUM_THREADS": "\(ProcessInfo.processInfo.activeProcessorCount)",
                "OLLAMA_FLASH_ATTENTION": "1",
                "OLLAMA_NUM_GPU": "999"
            ]

            let ollamaProc = Process()
            // Pfad-Fallback
            let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
            let ollamaPath = paths.first { FileManager.default.fileExists(atPath: $0) } ?? paths[0]
            ollamaProc.executableURL = URL(fileURLWithPath: ollamaPath)
            ollamaProc.arguments = ["serve"]
            ollamaProc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            try? ollamaProc.run()

            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s warten
            _ = await MainActor.run { [weak self] in
                Task { await self?.checkOllamaStatus() }
            }
        }
    }

    // Für SettingsView
    public func loadOllamaModels() async -> [String] {
        await checkOllamaStatus()
        return ollamaModels
    }

    // MARK: - Connectivity
    
    private func startConnectivityTimer() {
        // A2: Referenz speichern (war fire-and-forget → konnte nie gecancelt werden → Zombie)
        connectivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { break }
                await self.checkConnectivity()
            }
        }
    }
    
    private func checkConnectivity() async {
        guard let url = URL(string: "\(baseURL)/health") else { return }
        let wasConnected = isConnected
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4 // Nie > 5s (Timer-Intervall) → kein Aufstauen
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                // P5: Nur mutieren wenn sich der Wert ÄNDERT (vermeidet unnötiges objectWillChange)
                if !self.isConnected { self.isConnected = true }
                if !wasConnected {
                    addNotification(title: "Daemon verbunden", message: "KoboldOS Daemon ist online", type: .success)
                }
            } else { if self.isConnected { self.isConnected = false } }
        } catch {
            if self.isConnected { self.isConnected = false }
            if wasConnected {
                addNotification(title: "Daemon offline", message: "Verbindung zum Daemon verloren", type: .warning)
            }
        }
    }
    
    public func removeNotification(_ notif: KoboldNotification) {
        notifications.removeAll { $0.id == notif.id }
        unreadNotificationCount = max(0, unreadNotificationCount - 1)
    }

    public func clearChatHistory() {
        messages = []
        pendingMessages[currentSessionId] = []
        sessionAgentStates[currentSessionId]?.thinkingSteps = []
        sessionAgentStates[currentSessionId]?.messageQueue = []
        sessionAgentStates[currentSessionId]?.checklist = []
        // B3: Reset session metadata in sidebar
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx].title = "Neuer Chat"
            sessions[idx].messages = []
            sessions[idx].createdAt = Date()
        }
        topics = []
        activeTopicId = nil
        debouncedSave()
    }

    public func deleteSession(_ s: ChatSession) {
        // Cancel any running stream for this session
        sessionAgentStates[s.id]?.streamTask?.cancel()
        // Remove ALL in-memory state (complete cleanup)
        sessions.removeAll { $0.id == s.id }
        sessionAgentStates.removeValue(forKey: s.id)
        pendingMessages.removeValue(forKey: s.id)
        streamingSessions.remove(s.id)
        sessionLastAccess.removeValue(forKey: s.id)
        // If we deleted the currently displayed session → create fresh session
        if s.id == currentSessionId {
            currentSessionId = UUID()
            sessionAgentStates[currentSessionId] = SessionAgentState()
            pendingMessages[currentSessionId] = []
            messages = []
            chatMode = .normal
            topics = []
            activeTopicId = nil
            agentLoading = false
        }
        // Persist deletion to disk
        saveSessionsWithRetry()
    }

    public func markAllNotificationsRead() {}

    public func cancelAgent() {
        sessionAgentStates[currentSessionId]?.wasStopped = true
        streamingSessions.remove(currentSessionId)
        agentLoading = false
        print("Agent cancellation requested for session \(currentSessionId)")
    }

    public func killSession(_ sessionId: UUID) {
        print("Session termination requested for \(sessionId)")
        activeSessions.removeAll { $0.id == sessionId }
        sessionAgentStates.removeValue(forKey: sessionId)
        pendingMessages.removeValue(forKey: sessionId)
        streamingSessions.remove(sessionId)
        sessionLastAccess.removeValue(forKey: sessionId)
    }

    // MARK: - Memory Management (Background Session Offloading)

    /// Starts a periodic timer that offloads inactive background sessions from RAM.
    /// Sessions not accessed for >2 minutes get their pendingMessages cleared.
    /// switchToSession() automatically reloads from sessions[].messages on next access.
    private func startSessionOffloadTimer() {
        offloadTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // Check every 60s
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.offloadInactiveSessions()
                }
            }
        }
    }

    /// Offloads pendingMessages for sessions inactive > 2 minutes.
    /// The data remains available via sessions[].messages (CodableMessage on disk).
    private func offloadInactiveSessions() {
        let now = Date()
        let inactivityThreshold: TimeInterval = 120 // 2 min
        var offloadedCount = 0

        for (sessionId, lastAccess) in sessionLastAccess {
            // Skip: current session, streaming sessions, already empty
            guard sessionId != currentSessionId,
                  !streamingSessions.contains(sessionId),
                  now.timeIntervalSince(lastAccess) > inactivityThreshold,
                  let pending = pendingMessages[sessionId],
                  !pending.isEmpty else { continue }

            // Sync latest messages to sessions array before clearing
            let codableMessages = pending.map { $0.toCodable() }
            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].messages = codableMessages
            }

            // Clear from RAM — switchToSession will reload from sessions[].messages
            let count = pending.count
            pendingMessages.removeValue(forKey: sessionId)

            // Also clear thinking steps for dormant sessions
            sessionAgentStates[sessionId]?.thinkingSteps = []

            offloadedCount += 1
            print("[MemoryManager] Offloaded session \(sessionId.uuidString.prefix(8)) — freed \(count) messages from RAM")
        }

        if offloadedCount > 0 {
            // Persist to disk so the offloaded data is safe
            debouncedSave()
        }
    }

    /// Registers a macOS memory pressure handler.
    /// On .warning or .critical: immediately offloads ALL background sessions.
    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
        print("[MemoryManager] Memory pressure handler registered")
    }

    /// Emergency offload: clears ALL background session data from RAM immediately.
    private func handleMemoryPressure() {
        print("[MemoryManager] Memory pressure detected — emergency offload of background sessions")
        var freed = 0

        for sessionId in pendingMessages.keys {
            guard sessionId != currentSessionId,
                  !streamingSessions.contains(sessionId) else { continue }

            // Sync to sessions array
            if let pending = pendingMessages[sessionId], !pending.isEmpty {
                let codableMessages = pending.map { $0.toCodable() }
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                    sessions[idx].messages = codableMessages
                }
            }
            pendingMessages.removeValue(forKey: sessionId)
            freed += 1
        }

        // Clear thinking steps for all non-active, non-streaming sessions
        for sessionId in sessionAgentStates.keys {
            guard sessionId != currentSessionId,
                  !streamingSessions.contains(sessionId) else { continue }
            sessionAgentStates[sessionId]?.thinkingSteps = []
            sessionAgentStates[sessionId]?.messageQueue = []
        }

        if freed > 0 {
            saveSessionsWithRetry()
            print("[MemoryManager] Emergency offloaded \(freed) background sessions")
        }
    }

    // MARK: - Message Queue (Per-Session)

    public func clearMessageQueue() {
        sessionAgentStates[currentSessionId]?.messageQueue = []
        print("Message queue cleared for session \(currentSessionId)")
    }

    public func sendNextQueued() {
        guard let next = sessionAgentStates[currentSessionId]?.messageQueue.first else { return }
        sessionAgentStates[currentSessionId]?.messageQueue.removeFirst()
        sendMessage(next)
        print("Sent next queued message: \(next)")
    }

    // MARK: - Agent Control (Per-Session)

    public func resumeAgent() {
        guard let prompt = sessionAgentStates[currentSessionId]?.lastPrompt else { return }
        sessionAgentStates[currentSessionId]?.wasStopped = false
        sendMessage(prompt)
        print("Agent resumed with last prompt")
    }

    public func clearNotifications() {
        notifications.removeAll()
        unreadNotificationCount = 0
    }

    /// Fügt eine In-App Benachrichtigung hinzu
    public func addNotification(title: String, message: String, type: KoboldNotification.NotificationType = .info, navigationTarget: String? = nil, sessionId: UUID? = nil) {
        var notif = KoboldNotification(title: title, message: message, navigationTarget: navigationTarget, type: type)
        notif.sessionId = sessionId
        // P6: append statt insert(at:0) — O(1) statt O(n) Array-Shuffle
        notifications.append(notif)
        unreadNotificationCount += 1
        // Max 50 Notifications behalten
        if notifications.count > 50 {
            notifications = Array(notifications.prefix(50))
        }
    }

    public func navigateToTarget(_ target: String) {
        currentViewTab = target
    }

    // MARK: - Task Execution (Scheduled + Idle)

    /// Task im Hintergrund ausführen — erstellt Task-Session, sendet Message dorthin.
    /// navigate=true → wechselt UI zur Task-Session (für Cron-Tasks).
    /// navigate=false → läuft unsichtbar, Notification wenn fertig (für Idle-Tasks).
    public func executeTask(taskId: String, taskName: String, prompt: String, navigate: Bool) {
        // 1. Task-Session finden oder erstellen
        let sessionId: UUID
        if let existing = sessions.first(where: { $0.taskId == taskId }) {
            sessionId = existing.id
        } else {
            let session = ChatSession(id: UUID(), title: "Task: \(taskName)", messages: [], taskId: taskId)
            sessions.insert(session, at: 0)
            sessionId = session.id
            sessionAgentStates[sessionId] = SessionAgentState()
            pendingMessages[sessionId] = []
            sessionLastAccess[sessionId] = Date()
        }

        if navigate {
            // Aktuelle Session speichern, zur Task-Session wechseln
            upsertCurrentSession()
            currentSessionId = sessionId
            messages = pendingMessages[sessionId] ?? []
            chatMode = .task
            taskChatLabel = taskName
            objectWillChange.send()
            // Zum Chat-Tab navigieren
            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
            // Nachricht in aktuelle (= Task) Session senden
            sendMessage(prompt)
        } else {
            // Hintergrund: Nachricht in Task-Session senden ohne UI zu stören
            sendMessage(prompt, targetSessionId: sessionId)
        }
    }

    /// macOS System-Notification (Banner oben rechts) + Klick navigiert zur Session
    func postSystemNotification(title: String, body: String, sessionId: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sid = sessionId {
            content.userInfo = ["sessionId": sid.uuidString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Navigiere zur Task-Session (z.B. wenn Notification geklickt wird)
    public func navigateToTaskSession(_ sessionId: UUID) {
        switchToSession(sessionId)
        NotificationCenter.default.post(
            name: Notification.Name("koboldNavigateToSession"),
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    public func answerInteractive(messageId: UUID, optionId: String, optionLabel: String) {
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].interactiveAnswered = true
            messages[idx].selectedOptionId = optionId
            sendMessage(optionLabel)
        }
    }

    // MARK: - Agent State Sync (für UI Updates)

    /// Synchronisiert Agent State zur UI (liest IMMER aus sessionAgentStates[currentSessionId])
    public func syncAgentStateToUI() {
        let state = sessionAgentStates[currentSessionId] ?? SessionAgentState()
        agentLoading = state.isLoading
        // Published properties werden automatisch aktualisiert durch computed properties
        print("Synced agent state for session \(currentSessionId): loading=\(state.isLoading), steps=\(state.thinkingSteps.count)")
    }

    // MARK: - Conversation History (Per-Session Isolation)

    /// Conversation History für eine Session laden (korrekte Isolation!)
    func conversationHistory(for sessionId: UUID, limit: Int = 30) -> [ChatMessage] {
        if sessionId == currentSessionId {
            return Array(messages.suffix(limit))
        } else {
            // Background Session: aus pendingMessages laden (dort sind die echten Messages)
            return Array((pendingMessages[sessionId] ?? []).suffix(limit))
        }
    }

    // MARK: - Delegate-based SSE Stream

    /// Creates an AsyncStream of SSE lines using URLSessionDataDelegate for reliable real-time delivery.
    /// URLSession.bytes(for:) can buffer entire responses with raw HTTP servers on macOS.
    /// The delegate's didReceive(data:) fires on every TCP packet — guaranteed incremental delivery.
    /// First yielded value is "__HTTP_STATUS__:CODE" with the HTTP status code.
    private func sseLines(for request: URLRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            let delegate = SSEStreamDelegate(continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    // MARK: - Context Usage Updates

    /// Context Usage für Session aktualisieren
    public func updateContextUsage(for sessionId: UUID, promptTokens: Int, completionTokens: Int, windowSize: Int) {
        var state = sessionAgentStates[sessionId] ?? SessionAgentState()
        state.contextPromptTokens = promptTokens
        state.contextCompletionTokens = completionTokens
        state.contextWindowSize = windowSize
        state.contextUsagePercent = Double(promptTokens + completionTokens) / Double(windowSize)
        sessionAgentStates[sessionId] = state

        // UI update wenn aktuelle Session
        if sessionId == currentSessionId {
            contextPromptTokens = promptTokens
            contextCompletionTokens = completionTokens
            contextUsagePercent = state.contextUsagePercent
            contextWindowSize = windowSize
        }
    }

    // MARK: - Cleanup & Deinit (A2: Zombie-Prozess verhindern)

    /// Stoppt alle Background-Tasks und löst Referenzen.
    /// Wird beim App-Beenden via .koboldShutdownSave Notification aufgerufen.
    public func cleanup() {
        connectivityTask?.cancel()
        connectivityTask = nil
        offloadTimer?.cancel()
        offloadTimer = nil
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        // Alle laufenden SSE-Streams stoppen
        for (_, state) in sessionAgentStates {
            state.streamTask?.cancel()
        }
        // NotificationCenter Observer entfernen (nicht in deinit möglich — NSObjectProtocol nicht Sendable)
        if let obs = shutdownObserver {
            NotificationCenter.default.removeObserver(obs)
            shutdownObserver = nil
        }
        print("[RuntimeViewModel] Cleanup complete — all background tasks cancelled")
    }

    deinit {
        // cleanup() ist @MainActor-isoliert → inline Task-Cancellation in nonisolated deinit.
        // Task.cancel() und DispatchSource.cancel() sind thread-safe.
        // shutdownObserver wird in cleanup() entfernt (NSObjectProtocol ist nicht Sendable).
        connectivityTask?.cancel()
        offloadTimer?.cancel()
        saveDebounceTask?.cancel()
        memoryPressureSource?.cancel()
    }
}

// MARK: - Supporting Models

public struct RuntimeMetrics: Codable, Sendable {
    public var chatRequests: Int = 0
    public var toolCalls: Int = 0
    public var errors: Int = 0
    public var tokensTotal: Int = 0
    public var uptimeSeconds: Int = 0
    public var cacheHits: Int = 0
    public var avgLatencyMs: Double = 0
    public init() {}
}

public struct WorkflowDef: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String
}

public struct InteractiveOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: String
    public let icon: String?
    
    public init(id: String = UUID().uuidString, label: String, value: String, icon: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.icon = icon
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let kind: MessageKind
    let timestamp: Date
    let attachments: [MediaAttachment]
    let confidence: Double?
    var interactiveAnswered: Bool = false
    var selectedOptionId: String? = nil

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    enum MessageKind: Equatable, Sendable {
        case user(text: String)
        case assistant(text: String)
        case thinking(entries: [ThinkingEntry])
        case toolCall(name: String, args: String)
        case toolResult(name: String, success: Bool, output: String)
        case thought(text: String)
        case agentStep(n: Int, desc: String)
        case subAgentSpawn(profile: String, task: String)
        case subAgentResult(profile: String, output: String, success: Bool)
        case interactive(text: String, options: [InteractiveOption])
        case image(path: String, caption: String)
    }

    init(kind: MessageKind, timestamp: Date = Date(), attachments: [MediaAttachment] = [], confidence: Double? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.attachments = attachments
        self.confidence = confidence
    }
}

public struct ChatSession: Identifiable, Codable, Sendable {
    public let id: UUID; public var title: String; public var messages: [ChatMessageCodable]
    public var topicId: UUID? = nil
    public var taskId: String? = nil
    public var createdAt: Date = Date()
    public var hasUnread: Bool = false
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    public var formattedDate: String {
        ChatSession.dateFormatter.string(from: createdAt)
    }
}

public struct ChatMessageCodable: Codable, Sendable {
    public let timestamp: Date; public let kind: String; public let text: String; public let thinkingEntries: [ThinkingEntryCodable]?
}

public struct ThinkingEntryCodable: Codable, Sendable {
    public let type: String; public let content: String; public let toolName: String; public let success: Bool
}

// MARK: - ChatMessage ↔ ChatMessageCodable Conversion

extension ChatMessage {
    func toCodable() -> ChatMessageCodable {
        let kindStr: String
        let text: String
        switch kind {
        case .user(let t): kindStr = "user"; text = t
        case .assistant(let t): kindStr = "assistant"; text = t
        case .toolCall(let name, let args): kindStr = "toolCall"; text = "\(name): \(args)"
        case .toolResult(let name, let success, let output): kindStr = "toolResult"; text = "\(name) [\(success ? "ok" : "err")]: \(output)"
        case .thought(let t): kindStr = "thought"; text = t
        case .thinking(let entries): kindStr = "thinking"; text = entries.map { $0.content }.joined(separator: "\n")
        case .agentStep(let n, let desc): kindStr = "agentStep"; text = "Step \(n): \(desc)"
        case .subAgentSpawn(let profile, let task): kindStr = "subAgentSpawn"; text = "\(profile): \(task)"
        case .subAgentResult(let profile, let output, _): kindStr = "subAgentResult"; text = "\(profile): \(output)"
        case .interactive(let t, _): kindStr = "interactive"; text = t
        case .image(let path, let caption): kindStr = "image"; text = "\(path)|\(caption)"
        }
        return ChatMessageCodable(timestamp: timestamp, kind: kindStr, text: text, thinkingEntries: nil)
    }
}

extension ChatMessageCodable {
    func toChatMessage() -> ChatMessage {
        let msgKind: ChatMessage.MessageKind
        switch kind {
        case "user": msgKind = .user(text: text)
        case "assistant": msgKind = .assistant(text: text)
        case "thought": msgKind = .thought(text: text)
        case "toolCall":
            let parts = text.components(separatedBy: ": ")
            msgKind = .toolCall(name: parts.first ?? "", args: parts.dropFirst().joined(separator: ": "))
        case "toolResult":
            let parts = text.components(separatedBy: ": ")
            let name = parts.first ?? ""
            let output = parts.dropFirst().joined(separator: ": ")
            msgKind = .toolResult(name: name, success: !text.contains("[err]"), output: output)
        case "image":
            let parts = text.components(separatedBy: "|")
            msgKind = .image(path: parts.first ?? "", caption: parts.dropFirst().joined(separator: "|"))
        default: msgKind = .assistant(text: text)
        }
        return ChatMessage(kind: msgKind, timestamp: timestamp)
    }
}

public struct Project: Identifiable, Codable, Sendable {
    public let id: UUID; public var name: String; public var createdAt: Date = Date()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    public var formattedDate: String {
        Project.dateFormatter.string(from: createdAt)
    }
    public static func defaultProjects() -> [Project] { [Project(id: UUID(), name: "Standard-Projekt")] }
}

public struct AgentTeam: Identifiable, Codable, Sendable {
    public let id: UUID; public var name: String; public var icon: String; public var agents: [TeamAgent]; public var description: String; public var goals: [String]
    @MainActor public static let defaults: [AgentTeam] = [
        AgentTeam(id: UUID(), name: "Recherche-Team", icon: "magnifyingglass", agents: [], description: "Web-Recherche", goals: ["Fakten finden"]),
        AgentTeam(id: UUID(), name: "Code-Team", icon: "chevron.left.forwardslash.chevron.right", agents: [], description: "Entwicklung", goals: ["Bugs fixen"])
    ]
}

public struct TeamAgent: Identifiable, Codable, Sendable {
    public let id: UUID; public var name: String; public var role: String; public var instructions: String; public var profile: String; public var isActive: Bool
    public init(id: UUID = UUID(), name: String, role: String, instructions: String, profile: String, isActive: Bool = true) {
        self.id = id; self.name = name; self.role = role; self.instructions = instructions; self.profile = profile; self.isActive = isActive
    }
}

// MARK: - Active Agent Session (für AgentsView)
public struct ActiveAgentSession: Identifiable, Sendable {
    public let id = UUID()
    public let agentType: String
    public let parentAgentType: String // Added
    public let status: SessionStatus
    public let modelName: String
    public let startTime: Date
    public var progress: Double = 0.0
    public let prompt: String // Added
    public var elapsed: String { "00:00" }
    public var stepCount: Int = 0
    public var currentTool: String = ""
    public var tokensUsed: Int = 0

    public enum SessionStatus: String, Sendable {
        case running, completed, cancelled, error
    }

    public init(agentType: String, modelName: String, parentAgentType: String = "", prompt: String = "") {
        self.agentType = agentType
        self.modelName = modelName
        self.parentAgentType = parentAgentType
        self.status = .running
        self.startTime = Date()
        self.prompt = prompt
    }
}

public struct GroupMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let sender: String
    public let content: String
    public let timestamp: Date
}

public struct ModelInfo: Sendable, Codable, Identifiable {
    public var id: String { name }
    public let name: String; public let backendType: String; public let capabilities: [String]
    public var usageCount: Int = 0
    public var lastUsed: Date = Date()
}

// MARK: - ChatTopic (für Topic-Badge im Chat-Header)
public struct ChatTopic: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var color: String  // HEX color code
    public var isExpanded: Bool = true
    public var projectPath: String = ""
    public var instructions: String = ""
    public var createdAt: Date = Date()
    public var useOwnMemory: Bool = false

    public var displayPath: String {
        projectPath.isEmpty ? "Kein Pfad" : (projectPath as NSString).lastPathComponent
    }

    public var swiftUIColor: Color {
        Color(hex: color) ?? .secondary
    }

    public init(id: UUID = UUID(), name: String, color: String = "#888888", isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.color = color
        self.isExpanded = isExpanded
    }

    public static let defaultColors: [String] = [
        "#4ECDC4", "#FFD93D", "#FF6B6B", "#A0E7E5", "#B8B8FF",
        "#FFABAB", "#95E1D3", "#F38181", "#888888"
    ]
}

// MARK: - Color Hex Helper
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - SSEStreamDelegate (delegate-based SSE for reliable real-time delivery)
// URLSession.bytes(for:) can buffer data with raw HTTP servers on macOS.
// This delegate receives data incrementally via didReceive(data:) — each TCP packet triggers it.

private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private var buffer = Data()
    /// D1: Weak reference to owning URLSession — für invalidateAndCancel() in didComplete
    weak var owningSession: URLSession?

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[SSE-Delegate] HTTP \(code)")
        continuation.yield("__HTTP_STATUS__:\(code)")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Extract complete lines (delimited by 0x0A = \n)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[buffer.index(after: idx)...])
            // Strip trailing \r
            let cleaned: Data
            if lineData.last == 0x0D {
                cleaned = lineData.dropLast()
            } else {
                cleaned = Data(lineData)
            }
            let line = String(data: cleaned, encoding: .utf8) ?? ""
            continuation.yield(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("[SSE-Delegate] Connection error: \(error.localizedDescription)")
        }
        // Flush remaining buffer
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            continuation.yield(line)
        }
        continuation.finish()
        // D1: Bricht den URLSession → Delegate → Continuation Reference Cycle
        session.invalidateAndCancel()
    }
}

// MARK: - DaemonLog (persistent log system for Security tab)

public final class DaemonLog: ObservableObject, @unchecked Sendable {
    public static let shared = DaemonLog()

    public enum Category: String, CaseIterable, Sendable {
        case agent = "Agent"
        case tool = "Tool"
        case network = "Netzwerk"
        case error = "Fehler"
        case system = "System"
    }

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let category: Category
        public var icon: String {
            switch category {
            case .agent: return "brain"
            case .tool: return "wrench.fill"
            case .network: return "network"
            case .error: return "exclamationmark.triangle.fill"
            case .system: return "gearshape"
            }
        }
    }

    @Published public var entries: [Entry] = []
    private let maxEntries = 2000
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "kobold.daemonlog", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KoboldOS/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("daemon.log")
        loadFromDisk()
    }

    /// Batched log entries waiting to be flushed to UI (prevents DispatchQueue.main.async per entry)
    private var pendingLogEntries: [Entry] = []
    private var logFlushScheduled = false

    public func add(_ message: String, category: Category = .system) {
        let entry = Entry(timestamp: Date(), message: message, category: category)
        // Batch log entries — flush to UI max every 500ms to prevent MainActor flood
        pendingLogEntries.append(entry)
        if !logFlushScheduled {
            logFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.entries.append(contentsOf: self.pendingLogEntries)
                self.pendingLogEntries.removeAll()
                self.logFlushScheduled = false
                if self.entries.count > self.maxEntries {
                    self.entries = Array(self.entries.suffix(self.maxEntries / 2))
                }
            }
        }
        // Persist to disk
        queue.async { [weak self] in
            guard let self else { return }
            let line = "[\(Self.fmt.string(from: entry.timestamp))] [\(category.rawValue)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: self.logFileURL)
                }
            }
        }
    }

    public func clear() {
        DispatchQueue.main.async { self.entries = [] }
        queue.async { try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8) }
    }

    public var logFilePath: String { logFileURL.path }

    private func loadFromDisk() {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(500)
        var loaded: [Entry] = []
        for line in lines {
            // Parse: [2026-02-27 12:00:00] [Agent] message
            let cat: Category = Category.allCases.first { line.contains("[\($0.rawValue)]") } ?? .system
            let msg = line.replacingOccurrences(of: "\\[.*?\\] \\[.*?\\] ", with: "", options: .regularExpression)
            loaded.append(Entry(timestamp: Date(), message: msg, category: cat))
        }
        entries = loaded
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
