import Foundation
import SwiftUI
import Combine
import KoboldCore

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
    private var streamingSessions: Set<UUID> = []

    /// Computed: Ist gerade irgendeine Session am Streamen?
    public var isStreamingToDaemon: Bool { !streamingSessions.isEmpty }

    /// Computed: Lädt der Agent in der aktuell sichtbaren Session?
    public var isAgentLoadingInCurrentChat: Bool {
        streamingSessions.contains(currentSessionId)
    }

    // UI State (aktive Session)
    @Published var messages: [ChatMessage] = []
    @Published public var agentLoading: Bool = false
    @Published public var isConnected: Bool = false
    @Published public var currentViewTab: String = "chat"
    @Published public var notifications: [KoboldNotification] = []

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

    // Topics (für Topic-Badge im Chat-Header)
    @Published public var topics: [ChatTopic] = []
    @Published public var activeTopicId: UUID? = nil

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
        // Bei App-Beendigung Sessions speichern
        NotificationCenter.default.addObserver(forName: .koboldShutdownSave, object: nil, queue: .main) { [weak self] _ in
            self?.upsertCurrentSession()
        }
        startConnectivityTimer()
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
    private func loadSessions() {
        let url = sessionsURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            print("[RuntimeViewModel] No saved sessions found — starting fresh")
            return
        }
        sessions = loaded
        // Lade Messages der letzten Session falls vorhanden
        if let last = loaded.last {
            currentSessionId = last.id
            messages = last.messages.map { $0.toChatMessage() }
            pendingMessages[last.id] = messages
        }
        print("[RuntimeViewModel] Loaded \(loaded.count) sessions from disk")
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
    
    func sendMessage(_ text: String, agentText: String? = nil, attachments: [MediaAttachment] = []) {
        let userMsg = ChatMessage(kind: .user(text: text), attachments: attachments)
        let sessionId = currentSessionId
        appendMessage(userMsg, for: sessionId)

        let messageForAgent = agentText ?? text

        // Ensure current session appears in sidebar immediately on first message
        if !sessions.contains(where: { $0.id == sessionId }) {
            upsertCurrentSession()
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
                self.agentLoading = true
                self.streamingSessions.insert(sessionId)
                self.activeThinkingSteps = []
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

            // Start 400ms flush timer for UI updates (balanced: responsive but not too frequent)
            let flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, !Task.isCancelled else { break }
                    let flush = await accumulator.takePendingFlush()
                    if !flush.steps.isEmpty || flush.contextPromptTokens != nil {
                        await MainActor.run {
                            var didChange = false
                            if !flush.steps.isEmpty {
                                var state = self.sessionAgentStates[sessionId] ?? SessionAgentState()
                                state.thinkingSteps.append(contentsOf: flush.steps)
                                // Cap thinkingSteps to prevent unbounded growth during long sub-agent runs
                                // Without this, 100+ entries cause O(n) re-renders every 400ms → UI freeze
                                if state.thinkingSteps.count > 50 {
                                    state.thinkingSteps = Array(state.thinkingSteps.suffix(40))
                                }
                                self.sessionAgentStates[sessionId] = state
                                didChange = true
                            }
                            if let pt = flush.contextPromptTokens {
                                self.updateContextUsage(
                                    for: sessionId,
                                    promptTokens: pt,
                                    completionTokens: flush.contextCompletionTokens ?? 0,
                                    windowSize: flush.contextWindowSize ?? 32000
                                )
                                didChange = true
                            }
                            // Only send objectWillChange if this session is visible (avoid re-rendering for background chats)
                            if didChange && sessionId == self.currentSessionId {
                                self.objectWillChange.send()
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

            await MainActor.run {
                var state = self.sessionAgentStates[sessionId] ?? SessionAgentState()
                state.thinkingSteps = finalResult.thinkingSteps
                self.sessionAgentStates[sessionId] = state

                if let error = finalResult.error, !error.isEmpty {
                    self.appendMessage(ChatMessage(kind: .assistant(text: "Fehler: \(error)")), for: sessionId)
                    self.addNotification(title: "Agent-Fehler", message: String(error.prefix(100)), type: .error, navigationTarget: "chat")
                } else {
                    // Persist the thinking box as a permanent chat message (orange box stays visible)
                    if !finalResult.thinkingSteps.isEmpty {
                        self.appendMessage(ChatMessage(kind: .thinking(entries: finalResult.thinkingSteps)), for: sessionId)
                    }
                    if !finalResult.finalAnswer.isEmpty {
                        self.appendMessage(ChatMessage(kind: .assistant(text: finalResult.finalAnswer)), for: sessionId)
                    }
                }

                for step in finalResult.thinkingSteps where step.type == .toolResult {
                    self.appendMessage(ChatMessage(kind: .toolResult(name: step.toolName, success: step.success, output: step.content)), for: sessionId)
                }

                for interactive in finalResult.interactiveMessages {
                    self.appendMessage(ChatMessage(kind: .interactive(text: interactive.text, options: interactive.options)), for: sessionId)
                }

                for embed in finalResult.embedMessages {
                    self.appendMessage(ChatMessage(kind: .image(path: embed.path, caption: embed.caption)), for: sessionId)
                }

                if sessionId != self.currentSessionId && !finalResult.finalAnswer.isEmpty {
                    let preview = String(finalResult.finalAnswer.prefix(80))
                    self.addNotification(title: "Chat fertig", message: preview, type: .success, navigationTarget: "chat")
                }

                if finalResult.toolStepCount >= 5 && !finalResult.finalAnswer.isEmpty {
                    self.addNotification(
                        title: "Aufgabe abgeschlossen",
                        message: "\(finalResult.toolStepCount) Schritte ausgef\u{00FC}hrt",
                        type: .success,
                        navigationTarget: "chat"
                    )
                }

                self.upsertCurrentSession()
                self.streamingSessions.remove(sessionId)
                // agentLoading is @Published — setting it auto-triggers objectWillChange (no manual send needed)
                if sessionId == self.currentSessionId {
                    self.agentLoading = false
                }
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
    private let maxMessagesPerSession = 500

    private func appendMessage(_ message: ChatMessage, for sessionId: UUID) {
        pendingMessages[sessionId, default: []].append(message)
        // Trim to prevent unbounded memory growth (keep last N messages)
        if pendingMessages[sessionId]!.count > maxMessagesPerSession {
            pendingMessages[sessionId] = Array(pendingMessages[sessionId]!.suffix(maxMessagesPerSession - 100))
        }
        if sessionId == currentSessionId {
            messages.append(message)
            if messages.count > maxMessagesPerSession {
                messages = Array(messages.suffix(maxMessagesPerSession - 100))
            }
        }
    }

    /// Synchrones Upsert der aktuellen Session (speichert echte Messages!)
    private func upsertCurrentSession() {
        // pendingMessages ist Source of Truth — sync von self.messages
        pendingMessages[currentSessionId] = messages
        let codableMessages = messages.map { $0.toCodable() }
        // Titel aus erster User-Nachricht generieren
        let title: String
        if let firstUser = messages.first(where: {
            if case .user = $0.kind { return true }; return false
        }), case .user(let t) = firstUser.kind {
            title = String(t.prefix(40))
        } else {
            title = topics.first?.name ?? "Chat"
        }
        var session = ChatSession(id: currentSessionId, title: title, messages: codableMessages)
        session.createdAt = sessions.first(where: { $0.id == currentSessionId })?.createdAt ?? Date()
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx] = session
        } else {
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
            guard !Task.isCancelled else { return }
            self?.saveSessionsWithRetry()
        }
    }

    /// Session wechseln mit korrekter Isolation
    public func switchToSession(_ sessionId: UUID) {
        guard sessionId != currentSessionId else { return }

        // 1. Aktuelle Session speichern (Messages → pendingMessages + ChatSession)
        upsertCurrentSession()

        // 2. Zu neuer Session wechseln
        currentSessionId = sessionId

        // 3. Session-Agent-State initialisieren falls nicht vorhanden
        if sessionAgentStates[sessionId] == nil {
            sessionAgentStates[sessionId] = SessionAgentState()
        }

        // 4. Messages der neuen Session laden (pendingMessages hat Vorrang, dann ChatSession)
        if let pending = pendingMessages[sessionId], !pending.isEmpty {
            messages = pending
        } else if let session = sessions.first(where: { $0.id == sessionId }), !session.messages.isEmpty {
            messages = session.messages.map { $0.toChatMessage() }
            pendingMessages[sessionId] = messages
        } else {
            messages = []
            pendingMessages[sessionId] = []
        }

        // 5. Agent Loading State für neue Session setzen
        agentLoading = streamingSessions.contains(sessionId)
        syncAgentStateToUI()
        objectWillChange.send()
    }

    /// Neue Session erstellen
    public func newSession() {
        // 1. Aktuelle Session speichern
        upsertCurrentSession()

        // 2. Neue Session-ID
        currentSessionId = UUID()

        // 3. Agent State initialisieren
        sessionAgentStates[currentSessionId] = SessionAgentState()
        pendingMessages[currentSessionId] = []

        // 4. UI aktualisieren
        messages = []
        chatMode = .normal
        topics = []
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

    // Stub-Properties für Task/Workflow Sessions
    @Published public var taskSessions: [ChatSession] = []
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

    public func newSession(topicId: UUID? = nil) {
        let session = ChatSession(id: UUID(), title: "Neuer Chat", messages: [], topicId: topicId)
        sessions.append(session)
        switchToSession(session.id)
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
        chatMode = .task
        taskChatLabel = taskName
        upsertCurrentSession()
        messages = []
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
            await MainActor.run { [weak self] in
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
        // Use async Task loop instead of Timer on main RunLoop (avoids main thread blocking)
        Task { [weak self] in
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
                self.isConnected = true
                if !wasConnected {
                    addNotification(title: "Daemon verbunden", message: "KoboldOS Daemon ist online", type: .success)
                }
            } else { self.isConnected = false }
        } catch {
            self.isConnected = false
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
    }

    public func deleteSession(_ s: ChatSession) {
        // Cancel any running stream for this session
        sessionAgentStates[s.id]?.streamTask?.cancel()
        // Remove all in-memory state
        sessions.removeAll { $0.id == s.id }
        sessionAgentStates.removeValue(forKey: s.id)
        pendingMessages.removeValue(forKey: s.id)
        streamingSessions.remove(s.id)
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
    public func addNotification(title: String, message: String, type: KoboldNotification.NotificationType = .info, navigationTarget: String? = nil) {
        let notif = KoboldNotification(title: title, message: message, navigationTarget: navigationTarget, type: type)
        notifications.insert(notif, at: 0)
        unreadNotificationCount += 1
        // Max 50 Notifications behalten
        if notifications.count > 50 {
            notifications = Array(notifications.prefix(50))
        }
    }

    public func navigateToTarget(_ target: String) {
        currentViewTab = target
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
    public var createdAt: Date = Date()
    public var hasUnread: Bool = false
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
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
    public var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: createdAt)
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
        let dir = appSupport.appendingPathComponent("KoboldOS", isDirectory: true)
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
