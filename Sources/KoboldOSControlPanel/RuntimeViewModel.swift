import SwiftUI
import Combine
@preconcurrency import UserNotifications

// MARK: - ThinkingEntry (single step inside the combined thinking window)

struct ThinkingEntry: Identifiable, Sendable {
    let id = UUID()
    let type: ThinkingEntryType
    let content: String
    let toolName: String
    let success: Bool

    enum ThinkingEntryType: String, Sendable {
        case thought, toolCall, toolResult, subAgentSpawn, subAgentResult, agentStep
    }

    var icon: String {
        switch type {
        case .thought:         return "brain"
        case .toolCall:        return "hammer.fill"
        case .toolResult:      return "checkmark.circle"
        case .subAgentSpawn:   return "person.2.fill"
        case .subAgentResult:  return "person.2.badge.gearshape"
        case .agentStep:       return "arrow.right"
        }
    }
}

// MARK: - MessageKind

enum MessageKind: Sendable {
    case user(text: String)
    case assistant(text: String)
    case toolCall(name: String, args: String)
    case toolResult(name: String, success: Bool, output: String)
    case thought(text: String)
    case agentStep(n: Int, desc: String)
    case subAgentSpawn(profile: String, task: String)
    case subAgentResult(profile: String, output: String, success: Bool)
    case thinking(entries: [ThinkingEntry])
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    let id = UUID()
    let kind: MessageKind
    let timestamp: Date
    var isCollapsed: Bool = true
    var attachments: [MediaAttachment] = []
    var confidence: Double? = nil
}

// MARK: - KoboldNotification

struct KoboldNotification: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let type: NotificationType
    let timestamp: Date

    enum NotificationType: String {
        case info, success, warning, error
    }

    var icon: String {
        switch type {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch type {
        case .info:    return .blue
        case .success: return .koboldEmerald
        case .warning: return .koboldGold
        case .error:   return .red
        }
    }
}

// MARK: - RuntimeViewModel

@MainActor
class RuntimeViewModel: ObservableObject {
    // Connection
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var safeModeActive: Bool = false
    @Published var backendConfig: BackendConfig = BackendConfig()
    @Published var daemonStatus: String = "Disconnected"

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var agentLoading: Bool = false
    @Published var activeThinkingSteps: [ThinkingEntry] = []
    private var activeStreamTask: Task<Void, Never>?
    private var saveDebounceTask: Task<Void, Never>?
    private var metricsPollingTask: Task<Void, Never>?
    var isMetricsPollingActive: Bool = false

    /// Message cap per session to prevent memory leak
    private let maxMessagesPerSession = 500

    // Notifications
    @Published var notifications: [KoboldNotification] = []
    @Published var unreadNotificationCount: Int = 0

    // Models
    @Published var loadedModels: [ModelInfo] = []
    @Published var selectedRole: ModelRole = .utility
    @Published var ollamaStatus: String = "Unknown"
    @Published var activeOllamaModel: String = ""

    // Metrics
    @Published var metrics: RuntimeMetrics = RuntimeMetrics()

    // Dashboard extras
    @Published var recentTraces: [String] = []
    @Published var taskHistory: [String] = []

    @AppStorage("kobold.port") private var storedPort: Int = 8080
    @AppStorage("kobold.authToken") private var storedToken: String = "kobold-secret"
    @AppStorage("kobold.agent.type") private var agentTypeStr: String = "general"

    var baseURL: String { "http://localhost:\(storedPort)" }
    var authToken: String { storedToken }

    /// Creates an authorized URLRequest with Bearer token
    func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !storedToken.isEmpty {
            req.setValue("Bearer \(storedToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Convenience: authorized GET data fetch
    func authorizedData(from url: URL) async throws -> (Data, URLResponse) {
        let req = authorizedRequest(url: url)
        return try await URLSession.shared.data(for: req)
    }

    // MARK: - Persistence

    private var historyURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/chat_history.json")
    }

    private var sessionsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/chat_sessions.json")
    }

    init() {
        // Auto-generate auth token if not set
        if storedToken.isEmpty {
            storedToken = UUID().uuidString
        }
        loadChatHistory()
        loadSessions()
        loadProjects()
        Task { await connect() }
    }

    // MARK: - Connection

    func connect() async {
        isConnecting = true
        let ours = await checkHealthIsOurProcess()
        if ours {
            isConnected = true
            daemonStatus = "Connected"
            await loadMetrics()
            await loadModels()
            await checkOllamaStatus()
        } else {
            // Either no daemon running, or a stale daemon from another instance.
            // RuntimeManager's health monitor will handle stale-daemon restarts.
            daemonStatus = "Starting..."
            await startDaemon()
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if await checkHealthIsOurProcess() {
                    isConnected = true
                    daemonStatus = "Connected"
                    await loadMetrics()
                    await loadModels()
                    await checkOllamaStatus()
                    break
                }
            }
            if !isConnected { daemonStatus = "Failed to connect" }
        }
        isConnecting = false
    }

    /// Checks health AND verifies the responding daemon is THIS process (not an old instance).
    func checkHealthIsOurProcess() async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = json["pid"] as? Int {
                return pid == Int(ProcessInfo.processInfo.processIdentifier)
            }
            // No PID in response = old binary without this check → treat as foreign
            return false
        } catch { return false }
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func testHealth() async {
        let ok = await checkHealth()
        daemonStatus = ok ? "Connected" : "Health check failed"
    }

    func startDaemon() async { RuntimeManager.shared.startDaemon() }

    func stopDaemon() {
        RuntimeManager.shared.stopDaemon()
        isConnected = false
        daemonStatus = "Stopped"
    }

    func restartDaemon() {
        RuntimeManager.shared.stopDaemon()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await connect()
        }
    }

    // MARK: - Metrics

    func loadMetrics() async {
        guard let url = URL(string: baseURL + "/metrics") else { return }
        if let (data, _) = try? await authorizedData(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metrics = RuntimeMetrics(from: json)
        }
        // Also load recent traces
        guard let traceURL = URL(string: baseURL + "/trace") else { return }
        if let (data, _) = try? await authorizedData(from: traceURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let timeline = json["timeline"] as? [[String: Any]] {
            recentTraces = timeline.suffix(10).compactMap { entry in
                guard let event = entry["event"] as? String else { return nil }
                let detail = entry["detail"] as? String ?? ""
                return "\(event): \(String(detail.prefix(60)))"
            }
        }
    }

    func resetMetrics() {
        Task {
            if let url = URL(string: baseURL + "/metrics/reset") {
                let req = authorizedRequest(url: url, method: "POST")
                _ = try? await URLSession.shared.data(for: req)
            }
            metrics = RuntimeMetrics()
            recentTraces = []
        }
    }
    func resetSafeMode() { Task { _ = await checkHealth() } }

    // MARK: - Models

    func loadModels() async {
        guard let url = URL(string: baseURL + "/models") else { return }
        if let (data, _) = try? await authorizedData(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [String] {
            loadedModels = models.map { ModelInfo(name: $0, usageCount: 0, lastUsed: Date()) }
            if let active = json["active"] as? String { activeOllamaModel = active }
            if let status = json["ollama_status"] as? String {
                ollamaStatus = status == "running" ? "Running" : "Offline"
            }
        }
    }

    func fetchOllamaModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    func setActiveModel(_ model: String) {
        activeOllamaModel = model
        UserDefaults.standard.set(model, forKey: "kobold.ollamaModel")
        Task {
            guard let url = URL(string: baseURL + "/model/set") else { return }
            var req = authorizedRequest(url: url, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func checkOllamaStatus() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            ollamaStatus = "Not available"; return
        }
        if let (_, resp) = try? await URLSession.shared.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            ollamaStatus = "Running"
            // Don't overwrite activeOllamaModel if user already selected one via UserDefaults
            if activeOllamaModel.isEmpty,
               let saved = UserDefaults.standard.string(forKey: "kobold.ollamaModel"), !saved.isEmpty {
                activeOllamaModel = saved
            }
        } else {
            ollamaStatus = "Not running"
        }
    }

    // MARK: - Chat

    /// Send a chat message.
    /// - Parameters:
    ///   - text: Display text shown in the chat bubble (user's original input).
    ///   - agentText: Text actually sent to the agent (may include embedded file content). Defaults to `text`.
    ///   - attachments: All attachments (images shown in bubble; non-image content embedded by caller).
    func sendMessage(_ text: String, agentText: String? = nil, attachments: [MediaAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        var msg = ChatMessage(kind: .user(text: trimmed.isEmpty ? "📎" : trimmed), timestamp: Date())
        msg.attachments = attachments
        messages.append(msg)

        // Ensure this chat immediately appears in sidebar history (atomic upsert prevents duplicates)
        upsertCurrentSession()
        saveSessions()
        saveChatHistory()
        let textForAgent = (agentText ?? trimmed).trimmingCharacters(in: .whitespaces)
        // Cancel any previous stream BEFORE creating new task (not inside sendWithAgent!)
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTask = Task { await sendWithAgent(message: textForAgent.isEmpty ? "Describe the attached media." : textForAgent, attachments: attachments) }
    }

    @AppStorage("kobold.showAgentSteps") var showAgentSteps: Bool = true

    func cancelAgent() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        agentLoading = false
        activeThinkingSteps = []
        messages.append(ChatMessage(kind: .assistant(text: "⏸ Agent gestoppt."), timestamp: Date()))
        saveChatHistory()
    }

    /// Cancel all background tasks (call on view disappear / deinit)
    func cancelAllTasks() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        metricsPollingTask?.cancel()
        metricsPollingTask = nil
        agentLoading = false
        activeThinkingSteps = []
    }

    /// Start periodic metrics polling (only while dashboard is visible)
    func startMetricsPolling() {
        guard !isMetricsPollingActive else { return }
        isMetricsPollingActive = true
        metricsPollingTask?.cancel()
        metricsPollingTask = Task {
            while !Task.isCancelled && isMetricsPollingActive {
                await loadMetrics()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopMetricsPolling() {
        isMetricsPollingActive = false
        metricsPollingTask?.cancel()
        metricsPollingTask = nil
    }

    /// Trim messages to prevent memory bloat
    private func trimMessages() {
        if messages.count > maxMessagesPerSession {
            messages = Array(messages.suffix(maxMessagesPerSession))
        }
    }

    // MARK: - Notifications

    @AppStorage("kobold.pushNotifications") var pushNotificationsEnabled: Bool = true

    func addNotification(title: String, message: String, type: KoboldNotification.NotificationType = .info) {
        let n = KoboldNotification(title: title, message: message, type: type, timestamp: Date())
        notifications.insert(n, at: 0)
        unreadNotificationCount += 1
        // Cap at 50
        if notifications.count > 50 { notifications = Array(notifications.prefix(50)) }

        // Only send system push notifications when app is in background or for errors
        // Normal chat completions while app is active → no push
        if pushNotificationsEnabled {
            let appIsActive = NSApp.isActive
            let isImportant = (type == .error || type == .warning)
            if !appIsActive || isImportant {
                deliverSystemNotification(title: title, body: message, type: type)
            }
        }
    }

    /// Delivers a native macOS notification via UNUserNotificationCenter
    private func deliverSystemNotification(title: String, body: String, type: KoboldNotification.NotificationType) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            switch type {
            case .error:   content.categoryIdentifier = "KOBOLD_ERROR"
            case .warning: content.categoryIdentifier = "KOBOLD_WARNING"
            case .success: content.categoryIdentifier = "KOBOLD_SUCCESS"
            case .info:    content.categoryIdentifier = "KOBOLD_INFO"
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    func markAllNotificationsRead() { unreadNotificationCount = 0 }

    func clearNotifications() {
        notifications.removeAll()
        unreadNotificationCount = 0
    }

    func removeNotification(_ notification: KoboldNotification) {
        notifications.removeAll { $0.id == notification.id }
    }

    func sendWithAgent(message: String, attachments: [MediaAttachment] = []) async {
        agentLoading = true
        let sessionId = UUID()
        let session = ActiveAgentSession(
            id: sessionId, agentType: agentTypeStr,
            startedAt: Date(),
            prompt: String(message.prefix(100)),
            status: .running, stepCount: 0, currentTool: ""
        )
        activeSessions.insert(session, at: 0)
        if activeSessions.count > 20 { activeSessions = Array(activeSessions.prefix(20)) }

        defer {
            agentLoading = false
            if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                if activeSessions[idx].status == .running {
                    activeSessions[idx].status = .completed
                }
            }
        }

        // Collect base64 images for vision
        let imageBase64s = attachments.compactMap { $0.base64 }

        var payload: [String: Any] = [
            "message": message,
            "agent_type": agentTypeStr
        ]
        if !imageBase64s.isEmpty {
            payload["images"] = imageBase64s
        }

        // Look up per-agent config for provider/model/apiKey
        let agentConfig = AgentsStore.shared.configs.first(where: { $0.id == agentTypeStr })
        if let cfg = agentConfig {
            payload["provider"] = cfg.provider
            if !cfg.modelName.isEmpty {
                payload["model"] = cfg.modelName
            }
            payload["temperature"] = cfg.temperature
            // Resolve API key from UserDefaults for cloud providers
            if cfg.provider != "ollama" {
                let keyName = "kobold.provider.\(cfg.provider).key"
                if let key = UserDefaults.standard.string(forKey: keyName), !key.isEmpty {
                    payload["api_key"] = key
                }
            }
        }

        // If images, use non-streaming /agent endpoint
        if !imageBase64s.isEmpty {
            await sendWithAgentNonStreaming(payload: payload)
            return
        }

        // Use SSE streaming
        guard let url = URL(string: baseURL + "/agent/stream") else {
            messages.append(ChatMessage(kind: .assistant(text: "Invalid URL"), timestamp: Date()))
            return
        }

        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 300

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                messages.append(ChatMessage(kind: .assistant(text: "HTTP Error \(code)"), timestamp: Date()))
                return
            }

            var lastFinalAnswer = ""
            var lastConfidence: Double? = nil
            activeThinkingSteps = []
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.hasPrefix("data: ") {
                    let jsonStr = String(line.dropFirst(6))
                    guard let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let stepType = json["type"] as? String ?? ""
                    let content = json["content"] as? String ?? ""
                    let toolName = json["tool"] as? String ?? ""
                    let success = json["success"] as? Bool ?? true
                    if let c = json["confidence"] as? Double { lastConfidence = c }

                    switch stepType {
                    case "think":
                        activeThinkingSteps.append(ThinkingEntry(type: .thought, content: content, toolName: "", success: true))
                    case "toolCall":
                        activeThinkingSteps.append(ThinkingEntry(type: .toolCall, content: content, toolName: toolName, success: true))
                        // Update active session with current tool
                        if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                            activeSessions[idx].currentTool = toolName
                            activeSessions[idx].stepCount += 1
                        }
                    case "toolResult":
                        activeThinkingSteps.append(ThinkingEntry(type: .toolResult, content: content, toolName: toolName, success: success))
                    case "finalAnswer":
                        lastFinalAnswer = content
                        if let c = json["confidence"] as? Double { lastConfidence = c }
                    case "subAgentSpawn":
                        let profile = json["subAgent"] as? String ?? "agent"
                        activeThinkingSteps.append(ThinkingEntry(type: .subAgentSpawn, content: content, toolName: profile, success: true))
                    case "subAgentResult":
                        let profile = json["subAgent"] as? String ?? "agent"
                        activeThinkingSteps.append(ThinkingEntry(type: .subAgentResult, content: content, toolName: profile, success: success))
                    case "notify":
                        let title = json["title"] as? String ?? "Benachrichtigung"
                        addNotification(title: title, message: content, type: .info)
                    case "error":
                        messages.append(ChatMessage(kind: .assistant(text: "⚠️ \(content)"), timestamp: Date()))
                        addNotification(title: "Fehler", message: content, type: .error)
                    default:
                        break
                    }
                }
            }

            // Compact all thinking steps into a single message
            let hadToolSteps = !activeThinkingSteps.isEmpty
            if hadToolSteps && showAgentSteps {
                messages.append(ChatMessage(kind: .thinking(entries: activeThinkingSteps), timestamp: Date()))
            }
            activeThinkingSteps = []

            // Append final answer with confidence
            if !lastFinalAnswer.isEmpty {
                messages.append(ChatMessage(kind: .assistant(text: lastFinalAnswer), timestamp: Date(), confidence: lastConfidence))
                if hadToolSteps {
                    let preview = lastFinalAnswer.count > 80 ? String(lastFinalAnswer.prefix(77)) + "..." : lastFinalAnswer
                    addNotification(title: "Aufgabe erledigt", message: preview, type: .success)
                }
            }
            trimMessages()
            saveChatHistory()
            await loadMetrics()
        } catch {
            if !Task.isCancelled {
                messages.append(ChatMessage(
                    kind: .assistant(text: "Fehler: \(error.localizedDescription)"),
                    timestamp: Date()
                ))
            }
        }
    }

    /// Fallback non-streaming agent call (used for vision/image requests)
    private func sendWithAgentNonStreaming(payload: [String: Any]) async {
        guard let url = URL(string: baseURL + "/agent") else {
            messages.append(ChatMessage(kind: .assistant(text: "Invalid URL"), timestamp: Date()))
            return
        }

        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 180

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                messages.append(ChatMessage(kind: .assistant(text: "HTTP Error \(code)"), timestamp: Date()))
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let output = json["output"] as? String ?? ""
                let toolResults = json["tool_results"] as? [[String: Any]] ?? []

                if showAgentSteps {
                    for tool in toolResults {
                        let name = tool["name"] as? String ?? "tool"
                        let toolOutput = tool["output"] as? String ?? ""
                        let success = tool["success"] as? Bool ?? true
                        messages.append(ChatMessage(
                            kind: .toolResult(name: name, success: success, output: toolOutput),
                            timestamp: Date()
                        ))
                    }
                }

                messages.append(ChatMessage(kind: .assistant(text: output), timestamp: Date()))
            }
            saveChatHistory()
            await loadMetrics()
        } catch {
            messages.append(ChatMessage(
                kind: .assistant(text: "Fehler: \(error.localizedDescription)"),
                timestamp: Date()
            ))
        }
    }

    // MARK: - Persistence

    func saveChatHistory() {
        // Debounce: cancel previous pending save, schedule new one in 1s
        saveDebounceTask?.cancel()
        let msgs = messages
        let url = historyURL
        saveDebounceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }

            let simplified: [[String: Any]] = msgs.compactMap { msg in
                switch msg.kind {
                case .user(let text):
                    return ["kind": "user", "text": text, "ts": msg.timestamp.timeIntervalSince1970]
                case .assistant(let text):
                    return ["kind": "assistant", "text": text, "ts": msg.timestamp.timeIntervalSince1970]
                case .thinking(let entries):
                    let entriesData: [[String: Any]] = entries.map { e in
                        ["type": e.type.rawValue, "content": e.content, "toolName": e.toolName, "success": e.success]
                    }
                    return ["kind": "thinking", "text": "", "ts": msg.timestamp.timeIntervalSince1970, "entries": entriesData]
                default:
                    return nil
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: simplified) else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url)
            // NOTE: Session sync removed — saveSessions() is the single writer for chat_sessions.json
            // This prevents race conditions between debounced history saves and direct session saves
        }
    }

    // MARK: - Session Persistence

    func saveSessions() {
        let snapshot = sessions
        let url = sessionsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return }
        // Deduplicate by ID — keep the first occurrence (most recent)
        var seen = Set<UUID>()
        sessions = loaded.filter { seen.insert($0.id).inserted }
        // Restore last active session if messages are empty
        if messages.isEmpty, let first = sessions.first {
            currentSessionId = first.id
            messages = restoreMessages(from: first.messages)
        }
    }

    /// Atomically ensure the current session is in the sessions list (prevents duplicates from race conditions)
    private func upsertCurrentSession() {
        guard !isWorkflowChat, !messages.isEmpty else { return }
        let title = generateSessionTitle(from: messages)
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx] = ChatSession(id: currentSessionId, title: title, messages: messages)
        } else {
            sessions.insert(ChatSession(id: currentSessionId, title: title, messages: messages), at: 0)
        }
    }

    /// Restore ChatMessages from Codable, including thinking entries
    private func restoreMessages(from codables: [ChatMessageCodable]) -> [ChatMessage] {
        codables.compactMap { codable -> ChatMessage? in
            let kind: MessageKind
            switch codable.kind {
            case "user":      kind = .user(text: codable.text)
            case "assistant": kind = .assistant(text: codable.text)
            case "thinking":
                let entries = codable.thinkingEntries?.map { $0.toThinkingEntry() } ?? []
                guard !entries.isEmpty else { return nil }
                kind = .thinking(entries: entries)
            default:          return nil
            }
            return ChatMessage(kind: kind, timestamp: codable.timestamp)
        }
    }

    private func generateSessionTitle(from messages: [ChatMessage]) -> String {
        for msg in messages {
            if case .user(let text) = msg.kind, !text.isEmpty {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count <= 40 { return clean }
                return String(clean.prefix(37)) + "..."
            }
        }
        return "Gespräch"
    }

    private func syncCurrentSession() {
        guard !isWorkflowChat else { return }
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx] = ChatSession(id: currentSessionId, title: sessions[idx].title, messages: messages)
        }
    }

    func loadChatHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        messages = arr.compactMap { item in
            guard let kind = item["kind"] as? String else { return nil }
            let text = item["text"] as? String ?? ""
            let ts = Date(timeIntervalSince1970: item["ts"] as? Double ?? Date().timeIntervalSince1970)
            switch kind {
            case "user":      return ChatMessage(kind: .user(text: text), timestamp: ts)
            case "assistant": return ChatMessage(kind: .assistant(text: text), timestamp: ts)
            case "thinking":
                let entriesRaw = item["entries"] as? [[String: Any]] ?? []
                let entries: [ThinkingEntry] = entriesRaw.map { e in
                    ThinkingEntry(
                        type: ThinkingEntry.ThinkingEntryType(rawValue: e["type"] as? String ?? "thought") ?? .thought,
                        content: e["content"] as? String ?? "",
                        toolName: e["toolName"] as? String ?? "",
                        success: e["success"] as? Bool ?? true
                    )
                }
                return entries.isEmpty ? nil : ChatMessage(kind: .thinking(entries: entries), timestamp: ts)
            default:          return nil
            }
        }
    }

    func clearChatHistory() {
        // Remove current session from sidebar
        sessions.removeAll { $0.id == currentSessionId }
        // Clear messages and start fresh
        messages = []
        currentSessionId = UUID()
        saveSessions()
        try? FileManager.default.removeItem(at: historyURL)
        Task {
            guard let url = URL(string: baseURL + "/history/clear") else { return }
            let req = authorizedRequest(url: url, method: "POST")
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: - loadOllamaModels (used by SettingsView)
    func loadOllamaModels() async -> [String] {
        return await fetchOllamaModels()
    }

    // MARK: - Session Management

    @Published var sessions: [ChatSession] = []
    @Published var currentSessionId: UUID = UUID()

    // Tracks whether the current chat is a temporary workflow chat (not in sidebar history)
    @Published var isWorkflowChat: Bool = false
    @Published var workflowChatLabel: String = ""

    func newSession() {
        // Save current session before creating new one (atomic upsert prevents duplicates)
        upsertCurrentSession()
        isWorkflowChat = false
        workflowChatLabel = ""
        currentSessionId = UUID()
        messages = []
        saveSessions()
    }

    /// Opens a temporary chat for a workflow node — not saved to sidebar history.
    func openWorkflowChat(nodeName: String) {
        // Save current regular session before switching (atomic upsert prevents duplicates)
        upsertCurrentSession()
        saveSessions()
        messages = []
        currentSessionId = UUID()
        isWorkflowChat = true
        workflowChatLabel = nodeName
        NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
    }

    func switchToSession(_ session: ChatSession) {
        // Save current session before switching (atomic upsert prevents duplicates)
        upsertCurrentSession()
        isWorkflowChat = false
        workflowChatLabel = ""
        messages = restoreMessages(from: session.messages)
        currentSessionId = session.id
        saveSessions()
    }

    func deleteSession(_ session: ChatSession) {
        saveDebounceTask?.cancel()
        sessions.removeAll { $0.id == session.id }
        if session.id == currentSessionId {
            currentSessionId = UUID()
            messages = []
        }
        saveSessions()
    }

    // MARK: - Project Management (for Team/Workflow view)

    @Published var projects: [Project] = []
    @Published var selectedProjectId: UUID? = nil

    private var projectsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/projects.json")
    }

    var selectedProject: Project? {
        get { projects.first { $0.id == selectedProjectId } }
        set {
            if let p = newValue, let idx = projects.firstIndex(where: { $0.id == p.id }) {
                projects[idx] = p
            }
        }
    }

    func loadProjects() {
        guard let data = try? Data(contentsOf: projectsURL),
              let loaded = try? JSONDecoder().decode([Project].self, from: data),
              !loaded.isEmpty else {
            projects = Project.defaultProjects()
            return
        }
        projects = loaded
    }

    func saveProjects() {
        let snapshot = projects
        let url = projectsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    func newProject(name: String = "Neues Projekt") {
        let project = Project(name: name)
        projects.insert(project, at: 0)
        selectedProjectId = project.id
        saveProjects()
    }

    func deleteProject(_ project: Project) {
        // Also delete the workflow file for this project
        let workflowURL = workflowURL(for: project.id)
        try? FileManager.default.removeItem(at: workflowURL)
        projects.removeAll { $0.id == project.id }
        if selectedProjectId == project.id {
            selectedProjectId = projects.first?.id
        }
        saveProjects()
    }

    func renameProject(_ project: Project, to name: String) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].name = name
            projects[idx].updatedAt = Date()
            saveProjects()
        }
    }

    /// Returns per-project workflow storage URL
    func workflowURL(for projectId: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/workflows/\(projectId.uuidString).json")
    }

    // MARK: - Active Agent Sessions

    @Published var activeSessions: [ActiveAgentSession] = []

    func killSession(_ id: UUID) {
        activeSessions.removeAll { $0.id == id }
        activeStreamTask?.cancel()
        activeStreamTask = nil
        agentLoading = false
    }
}

// MARK: - Supporting Types

struct RuntimeMetrics {
    var toolCalls = 0
    var modelCalls = 0
    var cacheHits = 0
    var errors = 0
    var tokensTotal = 0
    var chatRequests = 0
    var uptimeSeconds = 0
    var avgLatencyMs = 0.0
    var backend = "unknown"
    var model = "—"

    init(from json: [String: Any]) {
        toolCalls     = json["tool_calls"] as? Int ?? 0
        modelCalls    = json["chat_requests"] as? Int ?? 0
        cacheHits     = json["cache_hits"] as? Int ?? 0
        errors        = json["errors"] as? Int ?? 0
        tokensTotal   = json["token_total"] as? Int ?? (json["tokens_total"] as? Int ?? 0)
        chatRequests  = json["chat_requests"] as? Int ?? 0
        uptimeSeconds = json["uptime"] as? Int ?? (json["uptime_seconds"] as? Int ?? 0)
        avgLatencyMs  = json["avg_latency_ms"] as? Double ?? 0.0
        backend       = json["backend"] as? String ?? "unknown"
        model         = json["model"] as? String ?? "—"
    }
    init() {}
}

struct ModelInfo: Identifiable {
    let id = UUID()
    let name: String
    var usageCount: Int
    var lastUsed: Date
}

enum ModelRole: String, CaseIterable {
    case instructor = "Instructor"
    case utility    = "Utility"
    case coder      = "Coder"
    case reviewer   = "Reviewer"
    case web        = "Web"
    case embedding  = "Embedding"
}

// MARK: - ChatSession

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatMessageCodable]
    var createdAt: Date

    init(id: UUID = UUID(), title: String, messages: [ChatMessage] = []) {
        self.id = id
        self.title = title.isEmpty ? "Gespräch" : title
        self.messages = messages.compactMap { ChatMessageCodable(from: $0) }
        self.createdAt = Date()
    }

    var formattedDate: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: createdAt, relativeTo: Date())
    }
}

struct ChatMessageCodable: Codable {
    var kind: String
    var text: String
    var timestamp: Date
    var thinkingEntries: [ThinkingEntryCodable]?

    init?(from msg: ChatMessage) {
        switch msg.kind {
        case .user(let t):      kind = "user";      text = t
        case .assistant(let t): kind = "assistant";  text = t
        case .thinking(let entries):
            kind = "thinking"
            text = ""
            thinkingEntries = entries.map { ThinkingEntryCodable(from: $0) }
        default: return nil
        }
        timestamp = msg.timestamp
    }
}

struct ThinkingEntryCodable: Codable {
    var type: String
    var content: String
    var toolName: String
    var success: Bool

    init(from entry: ThinkingEntry) {
        type = entry.type.rawValue
        content = entry.content
        toolName = entry.toolName
        success = entry.success
    }

    func toThinkingEntry() -> ThinkingEntry {
        ThinkingEntry(
            type: ThinkingEntry.ThinkingEntryType(rawValue: type) ?? .thought,
            content: content,
            toolName: toolName,
            success: success
        )
    }
}

// MARK: - ActiveAgentSession (for Sessions tab)

struct ActiveAgentSession: Identifiable {
    let id: UUID
    let agentType: String  // matches AgentModelConfig.id ("instructor", "coder", etc.)
    let startedAt: Date
    let prompt: String
    var status: SessionStatus
    var stepCount: Int
    var currentTool: String
    var tokensUsed: Int = 0
    var parentAgentType: String = ""  // non-empty if this is a sub-agent session

    enum SessionStatus: String {
        case running = "Läuft"
        case completed = "Abgeschlossen"
        case cancelled = "Abgebrochen"
        case error = "Fehler"
    }

    var elapsed: String {
        let secs = Int(Date().timeIntervalSince(startedAt))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

// MARK: - Project (Team/Workflow) — Codable for persistence

struct Project: Identifiable, Codable {
    var id: UUID
    var name: String
    var description: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String = "Neues Projekt",
         description: String = "") {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var formattedDate: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: updatedAt, relativeTo: Date())
    }

    static func defaultProjects() -> [Project] {
        [
            Project(name: "Coding Workflow", description: "Instructor → Coder → Reviewer"),
            Project(name: "Research Pipeline", description: "Instructor → Researcher → Web"),
        ]
    }
}

