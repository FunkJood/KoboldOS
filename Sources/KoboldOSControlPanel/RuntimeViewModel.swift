import SwiftUI
import Combine
import KoboldCore
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

// MARK: - AgentChecklistItem

struct AgentChecklistItem: Identifiable {
    let id: String
    let label: String
    var isCompleted: Bool = false
}

// MARK: - MessageKind

// MARK: - InteractiveOption (for yes/no or multi-choice buttons)

struct InteractiveOption: Identifiable, Sendable {
    let id: String
    let label: String
    let icon: String?
    init(id: String, label: String, icon: String? = nil) {
        self.id = id; self.label = label; self.icon = icon
    }
}

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
    case interactive(text: String, options: [InteractiveOption])
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    let id = UUID()
    let kind: MessageKind
    let timestamp: Date
    var isCollapsed: Bool = true
    var attachments: [MediaAttachment] = []
    var confidence: Double? = nil
    var interactiveAnswered: Bool = false
    var selectedOptionId: String? = nil
}

// MARK: - KoboldNotification

struct KoboldNotification: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let type: NotificationType
    let timestamp: Date
    var navigationTarget: NavigationTarget? = nil

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

// MARK: - ChatMode

enum ChatMode: String {
    case normal, task, workflow
}

// MARK: - NavigationTarget (for notification taps)

enum NavigationTarget {
    case chat(sessionId: UUID)
    case task(taskId: String)
    case workflow(projectId: UUID)
    case tab(SidebarTab)
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
    @Published var agentChecklist: [AgentChecklistItem] = []
    @Published var messageQueue: [String] = []
    /// Which chat session the agent is currently working for (nil = idle)
    @Published var activeAgentOriginSession: UUID?
    /// True only when the agent is loading AND the user is viewing the origin chat
    var isAgentLoadingInCurrentChat: Bool {
        agentLoading && activeAgentOriginSession == currentSessionId
    }
    private var activeStreamTask: Task<Void, Never>?
    private var saveDebounceTask: Task<Void, Never>?
    private var metricsPollingTask: Task<Void, Never>?
    var isMetricsPollingActive: Bool = false

    /// Message cap per session (generous — 2000 messages before trimming)
    private let maxMessagesPerSession = 2000

    // Workflow Execution
    @Published var workflowLastResponse: String? = nil

    // Context Management
    @Published var contextPromptTokens: Int = 0
    @Published var contextCompletionTokens: Int = 0
    @Published var contextUsagePercent: Double = 0.0
    @Published var contextWindowSize: Int = 150_000

    // Notifications
    @Published var notifications: [KoboldNotification] = []
    @Published var unreadNotificationCount: Int = 0

    // Teams
    @Published var teams: [AgentTeam] = AgentTeam.defaults
    @Published var teamMessages: [UUID: [GroupMessage]] = [:]

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
        var req = authorizedRequest(url: url)
        req.timeoutInterval = 5
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

    private var taskSessionsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/task_sessions.json")
    }

    private var workflowSessionsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/workflow_sessions.json")
    }

    init() {
        // Ensure auth token is explicitly written to UserDefaults (not just @AppStorage default)
        if UserDefaults.standard.string(forKey: "kobold.authToken") == nil {
            storedToken = "kobold-secret"
        } else if storedToken.isEmpty {
            storedToken = UUID().uuidString
        }
        loadTopics()
        loadSessions()
        loadTaskSessions()
        loadWorkflowSessions()
        loadWorkflowDefinitions()
        loadProjects()

        // Migrate: if chat_history.json has unsaved messages, archive them as a session
        loadChatHistory()
        if !messages.isEmpty {
            // Only archive if this session isn't already in the sessions list
            if !sessions.contains(where: { $0.id == currentSessionId }) {
                upsertCurrentSession()
                saveSessions()
            }
            // Clear for fresh start
            currentSessionId = UUID()
            messages = []
            // Remove stale history file so it doesn't re-archive next launch
            try? FileManager.default.removeItem(at: historyURL)
        }

        Task { await connect() }
        startTaskScheduler()

        // Listen for shutdown save notification
        NotificationCenter.default.addObserver(
            forName: .koboldShutdownSave,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performShutdownSave()
            }
        }

        // Listen for agent-created projects/workflows (reload from disk)
        NotificationCenter.default.addObserver(
            forName: .koboldProjectsChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadProjects()
            }
        }
    }

    // MARK: - Connection

    func connect() async {
        isConnecting = true
        // Daemon is started by AppDelegate.applicationDidFinishLaunching.
        // Wait for it to become healthy (up to 25 attempts = ~8s).
        daemonStatus = "Connecting..."
        for attempt in 0..<25 {
            if await checkHealthIsOurProcess() {
                isConnected = true
                daemonStatus = "Connected"
                async let m: () = loadMetrics()
                async let o: () = loadModels()
                async let s: () = checkOllamaStatus()
                _ = await (m, o, s)
                isConnecting = false
                return
            }
            // First few attempts: short delay (daemon might be ready quickly)
            let delay: UInt64 = attempt < 5 ? 200_000_000 : 400_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
        // Last resort: try starting daemon again (might have failed silently)
        await startDaemon()
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await checkHealthIsOurProcess() {
                isConnected = true
                daemonStatus = "Connected"
                async let m: () = loadMetrics()
                async let o: () = loadModels()
                async let s: () = checkOllamaStatus()
                _ = await (m, o, s)
                break
            }
        }
        if !isConnected { daemonStatus = "Failed to connect" }
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
    func answerInteractive(messageId: UUID, optionId: String, optionLabel: String) {
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].interactiveAnswered = true
            messages[idx].selectedOptionId = optionId
        }
        sendMessage(optionLabel)
    }

    func sendMessage(_ text: String, agentText: String? = nil, attachments: [MediaAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        var msg = ChatMessage(kind: .user(text: trimmed.isEmpty ? "📎" : trimmed), timestamp: Date())
        msg.attachments = attachments
        messages.append(msg)
        SoundManager.shared.play(.send)

        // Ensure this chat immediately appears in sidebar history (atomic upsert prevents duplicates)
        upsertCurrentSession()
        saveSessions()
        saveChatHistory()
        let textForAgent = (agentText ?? trimmed).trimmingCharacters(in: .whitespaces)

        // Queue message if agent is busy instead of interrupting
        if agentLoading {
            messageQueue.append(textForAgent.isEmpty ? "Describe the attached media." : textForAgent)
            return
        }

        // Cancel any previous stream BEFORE creating new task (not inside sendWithAgent!)
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTask = Task { await sendWithAgent(message: textForAgent.isEmpty ? "Describe the attached media." : textForAgent, attachments: attachments) }
    }

    /// Send a message with optional per-node model/agent overrides (used by workflow execution)
    func sendWorkflowMessage(_ text: String, modelOverride: String? = nil, agentOverride: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(kind: .user(text: trimmed), timestamp: Date()))
        upsertCurrentSession()
        saveSessions()
        saveChatHistory()
        activeStreamTask?.cancel()
        activeStreamTask = nil
        activeStreamTask = Task {
            // Temporarily override agent type and model
            let origAgent = agentTypeStr
            let origModel = activeOllamaModel
            if let ao = agentOverride, !ao.isEmpty { agentTypeStr = ao }
            if let mo = modelOverride, !mo.isEmpty { activeOllamaModel = mo }
            await sendWithAgent(message: trimmed)
            // Restore
            agentTypeStr = origAgent
            activeOllamaModel = origModel
        }
    }

    @AppStorage("kobold.showAgentSteps") var showAgentSteps: Bool = true

    func cancelAgent() {
        let originSession = activeAgentOriginSession ?? currentSessionId
        activeStreamTask?.cancel()
        activeStreamTask = nil
        agentLoading = false
        activeAgentOriginSession = nil
        activeThinkingSteps = []
        appendToSession(ChatMessage(kind: .assistant(text: "⏸ Agent gestoppt."), timestamp: Date()), originSession: originSession)
        if currentSessionId == originSession {
            saveChatHistory()
        }
        saveSessions()
        saveTaskSessions()
        saveWorkflowSessions()
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

    @AppStorage("kobold.notificationChannel") private var notificationChannel: String = "gui"

    func addNotification(title: String, message: String, type: KoboldNotification.NotificationType = .info, target: NavigationTarget? = nil) {
        let n = KoboldNotification(title: title, message: message, type: type, timestamp: Date(), navigationTarget: target)
        notifications.insert(n, at: 0)
        unreadNotificationCount += 1
        // Cap at 50
        if notifications.count > 50 { notifications = Array(notifications.prefix(50)) }

        // System push (macOS notification center)
        if pushNotificationsEnabled {
            let appIsActive = NSApp.isActive
            let isImportant = (type == .error || type == .warning)
            if !appIsActive || isImportant {
                deliverSystemNotification(title: title, body: message, type: type)
            }
        }

        // Telegram channel: send notifications when configured
        let channel = notificationChannel
        if channel == "telegram" || channel == "both" {
            let icon: String
            switch type {
            case .info: icon = "ℹ️"
            case .success: icon = "✅"
            case .warning: icon = "⚠️"
            case .error: icon = "❌"
            }
            let text = "\(icon) *\(title)*\n\(message)"
            Task.detached { TelegramBot.shared.sendNotification(text) }
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

    /// Navigate to the target of a notification (e.g. a specific chat, task, or workflow)
    func navigateToTarget(_ target: NavigationTarget) {
        switch target {
        case .chat(let sessionId):
            // Find the session in any array and switch to it
            if let session = sessions.first(where: { $0.id == sessionId }) {
                switchToSession(session)
            } else if let session = taskSessions.first(where: { $0.id == sessionId }) {
                switchToSession(session)
            } else if let session = workflowSessions.first(where: { $0.id == sessionId }) {
                switchToSession(session)
            }
            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
        case .task(let taskId):
            openTaskChat(taskId: taskId, taskName: taskId)
            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.tasks)
        case .workflow(let projectId):
            selectedProjectId = projectId
            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.workflows)
        case .tab(let tab):
            NotificationCenter.default.post(name: .koboldNavigate, object: tab)
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

    /// Append a message to the correct session, even if the user has switched away.
    /// If the origin session is currently displayed, append to `messages` (live UI).
    /// Otherwise, append to the session array directly (debounced save).
    /// All paths enforce maxMessagesPerSession to prevent unbounded RAM growth.
    private func appendToSession(_ msg: ChatMessage, originSession: UUID) {
        if currentSessionId == originSession {
            messages.append(msg)
            if messages.count > maxMessagesPerSession + 50 {
                messages = Array(messages.suffix(maxMessagesPerSession))
            }
        } else {
            guard let codable = ChatMessageCodable(from: msg) else { return }
            if let idx = sessions.firstIndex(where: { $0.id == originSession }) {
                sessions[idx].messages.append(codable)
                sessions[idx].hasUnread = true
                if sessions[idx].messages.count > maxMessagesPerSession {
                    sessions[idx].messages = Array(sessions[idx].messages.suffix(maxMessagesPerSession))
                }
            } else if let idx = taskSessions.firstIndex(where: { $0.id == originSession }) {
                taskSessions[idx].messages.append(codable)
                taskSessions[idx].hasUnread = true
                if taskSessions[idx].messages.count > maxMessagesPerSession {
                    taskSessions[idx].messages = Array(taskSessions[idx].messages.suffix(maxMessagesPerSession))
                }
            } else if let idx = workflowSessions.firstIndex(where: { $0.id == originSession }) {
                workflowSessions[idx].messages.append(codable)
                workflowSessions[idx].hasUnread = true
                if workflowSessions[idx].messages.count > maxMessagesPerSession {
                    workflowSessions[idx].messages = Array(workflowSessions[idx].messages.suffix(maxMessagesPerSession))
                }
            }
            // Debounced save — NOT per message (prevents disk I/O storms)
            debouncedSaveAllSessions()
        }
    }

    // MARK: - Debounced Session Persistence (prevents I/O storms during agent runs)

    private var sessionSaveDebounceTask: Task<Void, Never>?

    /// Save all session arrays at most once every 3 seconds (coalesces rapid writes)
    func debouncedSaveAllSessions() {
        sessionSaveDebounceTask?.cancel()
        sessionSaveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled else { return }
            saveSessions()
            saveTaskSessions()
            saveWorkflowSessions()
        }
    }

    /// Detect if a final answer is a simple yes/no question → show interactive buttons
    static func isYesNoQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = ["soll ich", "möchtest du", "willst du", "darf ich", "shall i", "should i", "do you want", "ist das ok", "einverstanden"]
        guard triggers.contains(where: { lower.contains($0) }) else { return false }
        return lower.hasSuffix("?") || lower.contains("?")
    }

    /// Extract file paths from text and create MediaAttachments for detected media files
    static func extractMediaAttachments(from text: String) -> [MediaAttachment] {
        var attachments: [MediaAttachment] = []
        // Match absolute paths and ~/paths with common media extensions
        let pattern = #"(?:~|/)[^\s\"\'\)\]<>]+\.(?:png|jpg|jpeg|gif|webp|heic|bmp|tiff|svg|mp3|wav|m4a|aac|flac|ogg|opus|mp4|mov|avi|mkv|webm|pdf)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var path = String(text[matchRange])
            // Expand ~
            if path.hasPrefix("~") {
                path = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            attachments.append(MediaAttachment(url: url))
        }
        return attachments
    }

    func sendWithAgent(message: String, attachments: [MediaAttachment] = []) async {
        agentLoading = true
        let originChatSession = currentSessionId
        activeAgentOriginSession = originChatSession
        let sessionId = UUID()
        let session = ActiveAgentSession(
            id: sessionId, agentType: agentTypeStr,
            startedAt: Date(),
            prompt: String(message.prefix(100)),
            status: .running, stepCount: 0, currentTool: ""
        )
        // Keep completed/error sessions visible for 60s, then auto-remove
        activeSessions.insert(session, at: 0)
        if activeSessions.count > 20 { activeSessions = Array(activeSessions.prefix(20)) }

        defer {
            agentLoading = false
            activeAgentOriginSession = nil
            // Auto-clear checklist after 2s if all completed
            if !agentChecklist.isEmpty && agentChecklist.allSatisfy(\.isCompleted) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.easeInOut(duration: 0.3)) { agentChecklist = [] }
                }
            }
            if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                if activeSessions[idx].status == .running {
                    activeSessions[idx].status = .completed
                }
            }
            // Auto-remove completed sessions after 60 seconds
            let sid = sessionId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                activeSessions.removeAll { $0.id == sid && $0.status != .running }
            }
            // Process message queue
            if !messageQueue.isEmpty {
                let nextMsg = messageQueue.removeFirst()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s pause
                    activeStreamTask = Task { await sendWithAgent(message: nextMsg) }
                }
            }
        }

        let imageBase64s = attachments.compactMap { $0.base64 }

        var payload: [String: Any] = [
            "message": message,
            "agent_type": agentTypeStr
        ]
        if !imageBase64s.isEmpty {
            payload["images"] = imageBase64s
        }

        let agentConfig = AgentsStore.shared.configs.first(where: { $0.id == agentTypeStr })
        if let cfg = agentConfig {
            payload["provider"] = cfg.provider
            if !cfg.modelName.isEmpty { payload["model"] = cfg.modelName }
            payload["temperature"] = cfg.temperature
            if cfg.provider != "ollama" {
                let keyName = "kobold.provider.\(cfg.provider).key"
                if let key = UserDefaults.standard.string(forKey: keyName), !key.isEmpty {
                    payload["api_key"] = key
                }
            }
        }

        if !imageBase64s.isEmpty {
            await sendWithAgentNonStreaming(payload: payload, originSession: originChatSession)
            return
        }

        guard let url = URL(string: baseURL + "/agent/stream") else {
            appendToSession(ChatMessage(kind: .assistant(text: "Invalid URL"), timestamp: Date()), originSession: originChatSession)
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
                appendToSession(ChatMessage(kind: .assistant(text: "HTTP Error \(code)"), timestamp: Date()), originSession: originChatSession)
                SoundManager.shared.play(chatMode == .workflow ? .workflowFail : .error)
                return
            }

            // ── FIX: Batched UI updates — SSE stream parsed inline but UI only updated every 300ms ──
            // JSON parsing happens on Main Actor (required by URLSession.bytes),
            // but @Published vars are ONLY touched in coalesced 300ms batches to prevent render thrashing.

            var lastFinalAnswer = ""
            var lastConfidence: Double? = nil
            var pendingSteps: [ThinkingEntry] = []
            var lastUIFlush = DispatchTime.now()
            let uiFlushInterval: UInt64 = 300_000_000  // 300ms between UI updates (was 50ms!)
            var toolStepCount = 0
            activeThinkingSteps = []

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }

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
                    pendingSteps.append(ThinkingEntry(type: .thought, content: String(content.prefix(2000)), toolName: "", success: true))
                case "toolCall":
                    pendingSteps.append(ThinkingEntry(type: .toolCall, content: String(content.prefix(2000)), toolName: toolName, success: true))
                    toolStepCount += 1
                case "toolResult":
                    let truncated = content.count > 8000 ? String(content.prefix(7997)) + "..." : content
                    pendingSteps.append(ThinkingEntry(type: .toolResult, content: truncated, toolName: toolName, success: success))
                case "finalAnswer":
                    lastFinalAnswer = content
                    if let c = json["confidence"] as? Double { lastConfidence = c }
                case "subAgentSpawn":
                    let profile = json["subAgent"] as? String ?? "agent"
                    pendingSteps.append(ThinkingEntry(type: .subAgentSpawn, content: String(content.prefix(1000)), toolName: profile, success: true))
                case "subAgentResult":
                    let profile = json["subAgent"] as? String ?? "agent"
                    let truncated = content.count > 4000 ? String(content.prefix(3997)) + "..." : content
                    pendingSteps.append(ThinkingEntry(type: .subAgentResult, content: truncated, toolName: profile, success: success))
                case "context_info":
                    if let promptT = json["prompt_tokens"] as? Int { self.contextPromptTokens = promptT }
                    if let compT = json["completion_tokens"] as? Int { self.contextCompletionTokens = compT }
                    if let pct = json["usage_percent"] as? Double { self.contextUsagePercent = pct }
                    if let ws = json["context_window"] as? Int { self.contextWindowSize = ws }
                case "error":
                    appendToSession(ChatMessage(kind: .assistant(text: "⚠️ \(content)"), timestamp: Date()), originSession: originChatSession)
                    if chatMode == .workflow {
                        SoundManager.shared.play(.workflowFail)
                        addNotification(title: "Workflow fehlgeschlagen", message: String(content.prefix(100)), type: .error, target: .chat(sessionId: originChatSession))
                    } else if chatMode == .task {
                        SoundManager.shared.play(.workflowFail)
                        addNotification(title: "Aufgabe fehlgeschlagen", message: String(content.prefix(100)), type: .error, target: .chat(sessionId: originChatSession))
                    } else {
                        addNotification(title: "Fehler", message: content, type: .error)
                    }
                case "checklist_set":
                    if let items = json["items"] as? [String] {
                        agentChecklist = items.enumerated().map { (i, label) in
                            AgentChecklistItem(id: "step_\(i)", label: label)
                        }
                    }
                case "checklist_check":
                    if let index = json["index"] as? Int, index < agentChecklist.count {
                        agentChecklist[index].isCompleted = true
                    }
                case "checklist_clear":
                    agentChecklist = []
                case "interactive":
                    let options: [InteractiveOption]
                    if let optArray = json["options"] as? [[String: Any]] {
                        options = optArray.compactMap { opt in
                            guard let id = opt["id"] as? String, let label = opt["label"] as? String else { return nil }
                            return InteractiveOption(id: id, label: label, icon: opt["icon"] as? String)
                        }
                    } else {
                        options = [
                            InteractiveOption(id: "yes", label: "Ja", icon: "checkmark"),
                            InteractiveOption(id: "no", label: "Nein", icon: "xmark")
                        ]
                    }
                    if !pendingSteps.isEmpty {
                        activeThinkingSteps.append(contentsOf: pendingSteps)
                        pendingSteps.removeAll()
                    }
                    appendToSession(
                        ChatMessage(kind: .interactive(text: content, options: options), timestamp: Date()),
                        originSession: originChatSession
                    )
                case "embed":
                    // Agent embeds media (image/file path) into chat
                    if let path = json["path"] as? String, let fileUrl = URL(string: "file://\(path)") ?? URL(fileURLWithPath: path) as URL? {
                        var embedMsg = ChatMessage(kind: .assistant(text: content.isEmpty ? "📎 \(fileUrl.lastPathComponent)" : content), timestamp: Date())
                        embedMsg.attachments = [MediaAttachment(url: fileUrl)]
                        appendToSession(embedMsg, originSession: originChatSession)
                    }
                default:
                    break
                }

                // Hard cap pending buffer (generous — 500 steps before trimming)
                if pendingSteps.count > 500 {
                    pendingSteps = Array(pendingSteps.suffix(400))
                }

                // ── COALESCED UI UPDATE every 300ms (not per-step!) ──
                let now = DispatchTime.now()
                if !pendingSteps.isEmpty && (now.uptimeNanoseconds - lastUIFlush.uptimeNanoseconds) > uiFlushInterval {
                    activeThinkingSteps.append(contentsOf: pendingSteps)
                    pendingSteps.removeAll()
                    lastUIFlush = now
                    // Hard cap UI array (generous — keeps last 800 of 1000)
                    if activeThinkingSteps.count > 1000 {
                        activeThinkingSteps = Array(activeThinkingSteps.suffix(800))
                    }
                    // Update session info (coalesced, not per-step)
                    if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                        activeSessions[idx].stepCount = toolStepCount
                    }
                }
            }

            // Flush remaining
            if !pendingSteps.isEmpty {
                activeThinkingSteps.append(contentsOf: pendingSteps)
                if activeThinkingSteps.count > 1000 {
                    activeThinkingSteps = Array(activeThinkingSteps.suffix(800))
                }
            }

            // Play sounds once (not per-step!) — workflow-aware
            if toolStepCount > 0 {
                SoundManager.shared.play(chatMode == .workflow ? .workflowStep : .toolCall)
            }

            // Compact thinking steps into single message
            let hadToolSteps = !activeThinkingSteps.isEmpty
            if hadToolSteps && showAgentSteps {
                appendToSession(ChatMessage(kind: .thinking(entries: activeThinkingSteps), timestamp: Date()), originSession: originChatSession)
            }
            activeThinkingSteps = []

            // Final answer
            if !lastFinalAnswer.isEmpty {
                // Auto-detect yes/no questions → show interactive buttons
                if Self.isYesNoQuestion(lastFinalAnswer) {
                    appendToSession(
                        ChatMessage(kind: .interactive(text: lastFinalAnswer, options: [
                            InteractiveOption(id: "yes", label: "Ja", icon: "checkmark"),
                            InteractiveOption(id: "no", label: "Nein", icon: "xmark")
                        ]), timestamp: Date(), confidence: lastConfidence),
                        originSession: originChatSession
                    )
                } else {
                    var msg = ChatMessage(kind: .assistant(text: lastFinalAnswer), timestamp: Date(), confidence: lastConfidence)
                    let autoEmbed = UserDefaults.standard.bool(forKey: "kobold.chat.autoEmbed")
                    if autoEmbed { msg.attachments = Self.extractMediaAttachments(from: lastFinalAnswer) }
                    appendToSession(msg, originSession: originChatSession)
                }
                SoundManager.shared.play(chatMode == .workflow ? .workflowDone : .success)
                let preview = lastFinalAnswer.count > 80 ? String(lastFinalAnswer.prefix(77)) + "..." : lastFinalAnswer
                if chatMode == .workflow {
                    addNotification(
                        title: "Workflow abgeschlossen",
                        message: preview,
                        type: .success,
                        target: .chat(sessionId: originChatSession)
                    )
                } else if chatMode == .task {
                    addNotification(
                        title: "Aufgabe abgeschlossen",
                        message: preview,
                        type: .success,
                        target: .chat(sessionId: originChatSession)
                    )
                } else if toolStepCount >= 3 {
                    addNotification(title: "Aufgabe erledigt", message: preview, type: .success, target: .chat(sessionId: originChatSession))
                }
            } // end if !lastFinalAnswer.isEmpty

            // Persist once at end (NOT per-step!)
            if currentSessionId == originChatSession {
                trimMessages()
                upsertCurrentSession()
                saveChatHistory()
            }
            debouncedSaveAllSessions()
        } catch {
            if !Task.isCancelled {
                appendToSession(ChatMessage(
                    kind: .assistant(text: "Fehler: \(error.localizedDescription)"),
                    timestamp: Date()
                ), originSession: originChatSession)
            }
        }
    }

    /// Fallback non-streaming agent call (used for vision/image requests)
    private func sendWithAgentNonStreaming(payload: [String: Any], originSession: UUID) async {
        guard let url = URL(string: baseURL + "/agent") else {
            appendToSession(ChatMessage(kind: .assistant(text: "Invalid URL"), timestamp: Date()), originSession: originSession)
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
                appendToSession(ChatMessage(kind: .assistant(text: "HTTP Error \(code)"), timestamp: Date()), originSession: originSession)
                SoundManager.shared.play(.error)
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
                        appendToSession(ChatMessage(
                            kind: .toolResult(name: name, success: success, output: toolOutput),
                            timestamp: Date()
                        ), originSession: originSession)
                    }
                }

                appendToSession(ChatMessage(kind: .assistant(text: output), timestamp: Date()), originSession: originSession)
            }
            // Persist session arrays (appendToSession already wrote to correct array)
            if currentSessionId == originSession {
                saveChatHistory()
            }
            saveSessions()
            saveTaskSessions()
            saveWorkflowSessions()
            Task { await loadMetrics() }  // fire-and-forget, don't block UI
        } catch {
            appendToSession(ChatMessage(
                kind: .assistant(text: "Fehler: \(error.localizedDescription)"),
                timestamp: Date()
            ), originSession: originSession)
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
            // Deduplicate off main thread
            var seen = Set<UUID>()
            let deduped = snapshot.filter { seen.insert($0.id).inserted }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(deduped) {
                try? data.write(to: url)
            }
        }
    }

    func saveTaskSessions() {
        let snapshot = taskSessions
        let url = taskSessionsURL
        Task.detached(priority: .utility) {
            var seen = Set<UUID>()
            let deduped = snapshot.filter { seen.insert($0.id).inserted }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(deduped) {
                try? data.write(to: url)
            }
        }
    }

    func saveWorkflowSessions() {
        let snapshot = workflowSessions
        let url = workflowSessionsURL
        Task.detached(priority: .utility) {
            var seen = Set<UUID>()
            let deduped = snapshot.filter { seen.insert($0.id).inserted }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(deduped) {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Team Persistence & Execution

    private var teamsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/teams.json")
    }

    private var teamMessagesDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/team_messages")
    }

    func loadTeams() {
        guard let data = try? Data(contentsOf: teamsURL),
              let loaded = try? JSONDecoder().decode([AgentTeam].self, from: data) else { return }
        teams = loaded
    }

    func saveTeams() {
        let snapshot = teams
        let url = teamsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    func loadTeamMessages(for teamId: UUID) {
        let url = teamMessagesDir.appendingPathComponent("\(teamId.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([GroupMessage].self, from: data) else { return }
        teamMessages[teamId] = loaded
    }

    func saveTeamMessages(for teamId: UUID) {
        guard let msgs = teamMessages[teamId] else { return }
        let snapshot = msgs
        let url = teamMessagesDir.appendingPathComponent("\(teamId.uuidString).json")
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    /// Send a single message to the daemon for one team agent (non-streaming, for parallel execution)
    func sendTeamAgentMessage(prompt: String, profile: String) async -> String {
        guard let url = URL(string: baseURL + "/agent") else { return "URL-Fehler" }

        let provider = UserDefaults.standard.string(forKey: "kobold.provider") ?? "ollama"
        let model = UserDefaults.standard.string(forKey: "kobold.model.\(profile)") ?? UserDefaults.standard.string(forKey: "kobold.model") ?? "llama3.2"
        let apiKey = UserDefaults.standard.string(forKey: "kobold.provider.\(provider).key") ?? ""

        let payload: [String: Any] = [
            "message": prompt,
            "agent_type": profile,
            "provider": provider,
            "model": model,
            "api_key": apiKey,
            "temperature": 0.7
        ]

        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 300

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return "HTTP-Fehler \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["output"] as? String ?? json["response"] as? String ?? String(data: data, encoding: .utf8) ?? "Keine Antwort"
            }
            return String(data: data, encoding: .utf8) ?? "Keine Antwort"
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    func loadSessions() {
        let url = sessionsURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            guard !loaded.isEmpty else { return }
            sessions = loaded
            if messages.isEmpty, let first = loaded.first {
                currentSessionId = first.id
                messages = restoreMessages(from: first.messages)
            }
        }
    }

    func loadTaskSessions() {
        let url = taskSessionsURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            if !loaded.isEmpty { taskSessions = loaded }
        }
    }

    func loadWorkflowSessions() {
        let url = workflowSessionsURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            if !loaded.isEmpty { workflowSessions = loaded }
        }
    }

    /// Atomically ensure the current session is in the correct sessions list based on chatMode.
    /// PERF: Only converts new messages to Codable (incremental update, not full rebuild).
    private func upsertCurrentSession() {
        guard !messages.isEmpty else { return }
        let codables = messages.compactMap { ChatMessageCodable(from: $0) }
        let title: String
        switch chatMode {
        case .normal:
            title = generateSessionTitle(from: messages)
            if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                sessions[idx].title = title
                sessions[idx].messages = codables
                if let tid = activeTopicId { sessions[idx].topicId = tid }
            } else {
                var session = ChatSession(id: currentSessionId, title: title, messages: [], topicId: activeTopicId)
                session.messages = codables
                sessions.insert(session, at: 0)
            }
        case .task:
            title = taskChatLabel.isEmpty ? generateSessionTitle(from: messages) : taskChatLabel
            if let idx = taskSessions.firstIndex(where: { $0.id == currentSessionId }) {
                taskSessions[idx].title = title
                taskSessions[idx].messages = codables
            } else {
                var session = ChatSession(id: currentSessionId, title: title, messages: [], linkedId: taskChatId)
                session.messages = codables
                taskSessions.insert(session, at: 0)
            }
        case .workflow:
            title = workflowChatLabel.isEmpty ? generateSessionTitle(from: messages) : workflowChatLabel
            if let idx = workflowSessions.firstIndex(where: { $0.id == currentSessionId }) {
                workflowSessions[idx].title = title
                workflowSessions[idx].messages = codables
            } else {
                var session = ChatSession(id: currentSessionId, title: title, messages: [])
                session.messages = codables
                workflowSessions.insert(session, at: 0)
            }
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
        switch chatMode {
        case .normal:
            if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                sessions[idx] = ChatSession(id: currentSessionId, title: sessions[idx].title, messages: messages)
            }
        case .task:
            if let idx = taskSessions.firstIndex(where: { $0.id == currentSessionId }) {
                taskSessions[idx] = ChatSession(id: currentSessionId, title: taskSessions[idx].title, messages: messages)
            }
        case .workflow:
            if let idx = workflowSessions.firstIndex(where: { $0.id == currentSessionId }) {
                workflowSessions[idx] = ChatSession(id: currentSessionId, title: workflowSessions[idx].title, messages: messages)
            }
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

    // Chat mode: determines which session array is active
    @Published var chatMode: ChatMode = .normal
    @Published var workflowChatLabel: String = ""

    // Task-Chat context
    @Published var taskChatId: String = ""
    @Published var taskChatLabel: String = ""

    // Strictly separated session arrays
    @Published var taskSessions: [ChatSession] = []      // Persisted in task_sessions.json
    @Published var workflowSessions: [ChatSession] = []  // Persisted in workflow_sessions.json
    @Published var workflowDefinitions: [WorkflowDefinition] = []  // From workflows.json (agent-created)

    private var workflowDefsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/workflows.json")
    }

    func loadWorkflowDefinitions() {
        guard let data = try? Data(contentsOf: workflowDefsURL),
              let defs = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) else {
            return
        }
        workflowDefinitions = defs
    }

    private func saveWorkflowDefinitionsSync() {
        if let data = try? JSONEncoder().encode(workflowDefinitions) {
            try? data.write(to: workflowDefsURL, options: .atomic)
        }
    }

    func deleteWorkflowDefinition(_ def: WorkflowDefinition) {
        workflowDefinitions.removeAll { $0.id == def.id }
        saveWorkflowDefinitionsSync()
    }

    // MARK: - Topic Management (AgentZero-style project folders)

    @Published var topics: [ChatTopic] = []
    @Published var activeTopicId: UUID? = nil  // Topic assigned to current chat

    private var topicsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/chat_topics.json")
    }

    func loadTopics() {
        guard let data = try? Data(contentsOf: topicsURL),
              let loaded = try? JSONDecoder().decode([ChatTopic].self, from: data) else { return }
        topics = loaded
    }

    func saveTopics() {
        let dir = topicsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(topics) {
            try? data.write(to: topicsURL, options: .atomic)
        }
    }

    func createTopic(name: String, color: String = "#34d399") {
        let topic = ChatTopic(name: name, color: color)
        topics.insert(topic, at: 0)
        saveTopics()
    }

    func deleteTopic(_ topic: ChatTopic) {
        // Unlink all sessions from this topic
        for i in sessions.indices where sessions[i].topicId == topic.id {
            sessions[i].topicId = nil
        }
        topics.removeAll { $0.id == topic.id }
        saveTopics()
        saveSessions()
    }

    func renameTopic(_ topic: ChatTopic, newName: String) {
        guard let idx = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        topics[idx].name = newName
        saveTopics()
    }

    func updateTopicColor(_ topic: ChatTopic, color: String) {
        guard let idx = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        topics[idx].color = color
        saveTopics()
    }

    func updateTopic(_ updated: ChatTopic) {
        guard let idx = topics.firstIndex(where: { $0.id == updated.id }) else { return }
        topics[idx] = updated
        saveTopics()
    }

    func toggleTopicExpanded(_ topic: ChatTopic) {
        guard let idx = topics.firstIndex(where: { $0.id == topic.id }) else { return }
        topics[idx].isExpanded.toggle()
        saveTopics()
    }

    func assignSessionToTopic(sessionId: UUID, topicId: UUID?) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].topicId = topicId
            saveSessions()
        }
        // Update active topic if current session
        if sessionId == currentSessionId {
            activeTopicId = topicId
        }
    }

    func topicForSession(_ session: ChatSession) -> ChatTopic? {
        guard let tid = session.topicId else { return nil }
        return topics.first { $0.id == tid }
    }

    /// Get topic-specific instructions for the current session (injected into system prompt)
    func activeTopicInstructions() -> String? {
        guard let tid = activeTopicId,
              let topic = topics.first(where: { $0.id == tid }),
              !topic.instructions.isEmpty else { return nil }
        return topic.instructions
    }

    func newSession(topicId: UUID? = nil) {
        // Save current session before creating new one (atomic upsert prevents duplicates)
        upsertCurrentSession()
        saveSessions()
        chatMode = .normal
        workflowChatLabel = ""
        taskChatId = ""
        taskChatLabel = ""
        currentSessionId = UUID()
        messages = []
        activeTopicId = topicId
        saveChatHistory()
    }

    /// Opens a workflow chat for a node — persisted in workflowSessions.
    func openWorkflowChat(nodeName: String) {
        // Save current session before switching (atomic upsert prevents duplicates)
        upsertCurrentSession()
        saveSessions()
        chatMode = .workflow
        workflowChatLabel = nodeName
        // Load existing workflow session if available
        if let existing = workflowSessions.first(where: { $0.title == nodeName }) {
            messages = restoreMessages(from: existing.messages)
            currentSessionId = existing.id
        } else {
            messages = []
            currentSessionId = UUID()
        }
        NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
    }

    /// Opens a task chat — persisted in taskSessions.
    func openTaskChat(taskId: String, taskName: String) {
        upsertCurrentSession()
        saveSessions()
        chatMode = .task
        taskChatId = taskId
        taskChatLabel = taskName
        // Load existing task session if available
        if let existing = taskSessions.first(where: { $0.linkedId == taskId }) {
            messages = restoreMessages(from: existing.messages)
            currentSessionId = existing.id
        } else {
            messages = []
            currentSessionId = UUID()
        }
        NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.chat)
    }

    func switchToSession(_ session: ChatSession) {
        // Save current session before switching (debounced, not blocking)
        upsertCurrentSession()
        debouncedSaveAllSessions()

        // Detect which type this session belongs to
        if taskSessions.contains(where: { $0.id == session.id }) {
            chatMode = .task
            taskChatId = session.linkedId ?? ""
            taskChatLabel = session.title
        } else if workflowSessions.contains(where: { $0.id == session.id }) {
            chatMode = .workflow
            workflowChatLabel = session.title
        } else {
            chatMode = .normal
            workflowChatLabel = ""
            taskChatId = ""
            taskChatLabel = ""
        }

        // Switch to new session — clear unread marker + set active topic
        currentSessionId = session.id
        activeTopicId = session.topicId
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].hasUnread = false
        } else if let idx = taskSessions.firstIndex(where: { $0.id == session.id }) {
            taskSessions[idx].hasUnread = false
        } else if let idx = workflowSessions.firstIndex(where: { $0.id == session.id }) {
            workflowSessions[idx].hasUnread = false
        }

        // Clear UI first (instant response), then restore messages
        // This prevents SwiftUI from trying to diff a huge old array against a huge new array
        messages = []
        activeThinkingSteps = []

        // Restore on next run loop tick so the UI can clear first
        let codables = session.messages
        DispatchQueue.main.async { [weak self] in
            self?.messages = self?.restoreMessages(from: codables) ?? []
        }

        // Sync chat_history.json (debounced)
        saveChatHistory()
    }

    func deleteSession(_ session: ChatSession) {
        saveDebounceTask?.cancel()
        // Remove from the correct array
        if taskSessions.contains(where: { $0.id == session.id }) {
            taskSessions.removeAll { $0.id == session.id }
            saveTaskSessions()
        } else if workflowSessions.contains(where: { $0.id == session.id }) {
            workflowSessions.removeAll { $0.id == session.id }
            saveWorkflowSessions()
        } else {
            sessions.removeAll { $0.id == session.id }
        }
        if session.id == currentSessionId {
            chatMode = .normal
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
        let url = projectsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First launch — use defaults
            projects = Project.defaultProjects()
            saveProjects()
            return
        }
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let loaded = try? JSONDecoder().decode([Project].self, from: data) else {
            // File exists but empty or corrupt — keep current state (don't overwrite with defaults)
            return
        }
        projects = loaded
    }

    func saveProjects() {
        let url = projectsURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: url, options: .atomic)
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

    // MARK: - Task Scheduler

    private var taskSchedulerTimer: Task<Void, Never>?

    func startTaskScheduler() {
        taskSchedulerTimer?.cancel()
        taskSchedulerTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // Every 60 seconds
                guard !Task.isCancelled else { break }
                await checkScheduledTasks()
            }
        }
    }

    func stopTaskScheduler() {
        taskSchedulerTimer?.cancel()
        taskSchedulerTimer = nil
    }

    private func checkScheduledTasks() async {
        guard isConnected else { return }
        guard let url = URL(string: baseURL + "/tasks") else { return }
        guard let (data, resp) = try? await authorizedData(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["tasks"] as? [[String: Any]] else { return }

        let now = Date()
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let hour = cal.component(.hour, from: now)
        let dayOfMonth = cal.component(.day, from: now)
        let month = cal.component(.month, from: now)
        let weekday = cal.component(.weekday, from: now) // 1=Sun, 2=Mon...
        let isoWeekday = weekday == 1 ? 7 : weekday - 1 // 1=Mon...7=Sun

        for item in list {
            guard let enabled = item["enabled"] as? Bool, enabled,
                  let schedule = item["schedule"] as? String, !schedule.isEmpty,
                  let taskId = item["id"] as? String,
                  let name = item["name"] as? String,
                  let prompt = item["prompt"] as? String, !prompt.isEmpty else { continue }

            if cronMatches(schedule, minute: minute, hour: hour, day: dayOfMonth, month: month, weekday: isoWeekday) {
                // Execute the task
                openTaskChat(taskId: taskId, taskName: name)
                sendMessage(prompt)
                addNotification(title: "Task gestartet", message: name, type: .info, target: .task(taskId: taskId))
                // Update last_run via backend
                if let updateURL = URL(string: baseURL + "/tasks") {
                    var req = authorizedRequest(url: updateURL, method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "action": "update", "id": taskId, "last_run": ISO8601DateFormatter().string(from: now)
                    ])
                    _ = try? await URLSession.shared.data(for: req)
                }
                break // Only run one task per check cycle to avoid flooding
            }
        }
    }

    /// Simple cron matcher: supports */N, N, N-M, * for each of 5 fields
    private func cronMatches(_ cron: String, minute: Int, hour: Int, day: Int, month: Int, weekday: Int) -> Bool {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return false }
        return fieldMatches(parts[0], value: minute) &&
               fieldMatches(parts[1], value: hour) &&
               fieldMatches(parts[2], value: day) &&
               fieldMatches(parts[3], value: month) &&
               fieldMatches(parts[4], value: weekday)
    }

    private func fieldMatches(_ field: String, value: Int) -> Bool {
        if field == "*" { return true }
        if field.hasPrefix("*/"), let step = Int(field.dropFirst(2)) {
            return step > 0 && value % step == 0
        }
        if field.contains("-") {
            let range = field.split(separator: "-").compactMap { Int($0) }
            if range.count == 2 { return value >= range[0] && value <= range[1] }
        }
        if field.contains(",") {
            let values = field.split(separator: ",").compactMap { Int($0) }
            return values.contains(value)
        }
        if let exact = Int(field) { return value == exact }
        return false
    }

    // MARK: - Shutdown Save

    /// Saves all important data synchronously before app terminates.
    func performShutdownSave() {
        // 1. Save chat history immediately (bypass debounce)
        saveDebounceTask?.cancel()
        let msgs = messages
        let url = historyURL
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
        if let data = try? JSONSerialization.data(withJSONObject: simplified) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        // 2. Archive current chat into session before saving
        upsertCurrentSession()

        // 3. Save all 3 session arrays (deduped + atomic)
        var seen = Set<UUID>()
        let deduped = sessions.filter { seen.insert($0.id).inserted }
        if let data = try? JSONEncoder().encode(deduped) {
            let dir = sessionsURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: sessionsURL, options: .atomic)
        }
        var seenTask = Set<UUID>()
        let dedupedTask = taskSessions.filter { seenTask.insert($0.id).inserted }
        if let data = try? JSONEncoder().encode(dedupedTask) {
            try? data.write(to: taskSessionsURL, options: .atomic)
        }
        var seenWf = Set<UUID>()
        let dedupedWf = workflowSessions.filter { seenWf.insert($0.id).inserted }
        if let data = try? JSONEncoder().encode(dedupedWf) {
            try? data.write(to: workflowSessionsURL, options: .atomic)
        }

        // 4. Save projects + workflow definitions
        saveProjects()
        saveWorkflowDefinitionsSync()

        // 4. Flush CoreMemory via daemon (fire-and-forget, no blocking)
        let port = storedPort
        let token = storedToken
        if let flushURL = URL(string: "http://localhost:\(port)/memory/flush") {
            var req = URLRequest(url: flushURL)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 2
            URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        }

        UserDefaults.standard.synchronize()
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

// MARK: - ChatTopic (AgentZero-style project/folder for chats)

struct ChatTopic: Identifiable, Codable {
    var id: UUID
    var name: String
    var color: String          // Hex color, e.g. "#7b2cbf"
    var instructions: String   // Topic-specific system instructions injected into agent prompt
    var projectPath: String    // Local folder path for this topic (e.g. ~/Projects/MyApp)
    var useOwnMemory: Bool     // true = isolated memory, false = global
    var isExpanded: Bool       // Sidebar disclosure state
    var createdAt: Date

    init(id: UUID = UUID(), name: String, color: String = "#34d399",
         instructions: String = "", projectPath: String = "", useOwnMemory: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.instructions = instructions
        self.projectPath = projectPath
        self.useOwnMemory = useOwnMemory
        self.isExpanded = true
        self.createdAt = Date()
    }

    var swiftUIColor: Color {
        color.isEmpty ? .koboldEmerald : Color(hex: color)
    }

    /// Display-friendly path (~ for home dir)
    var displayPath: String {
        guard !projectPath.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return projectPath.hasPrefix(home) ? projectPath.replacingOccurrences(of: home, with: "~") : projectPath
    }

    static let defaultColors: [String] = [
        "#34d399", "#60a5fa", "#a78bfa", "#f472b6", "#fbbf24",
        "#fb923c", "#f87171", "#2dd4bf", "#818cf8", "#c084fc"
    ]
}

// MARK: - ChatSession

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatMessageCodable]
    var createdAt: Date
    var linkedId: String?  // Links to task ID or workflow node name
    var hasUnread: Bool = false
    var topicId: UUID?     // Links to ChatTopic (nil = ungrouped)

    init(id: UUID = UUID(), title: String, messages: [ChatMessage] = [], linkedId: String? = nil, topicId: UUID? = nil) {
        self.id = id
        self.title = title.isEmpty ? "Gespräch" : title
        self.messages = messages.compactMap { ChatMessageCodable(from: $0) }
        self.createdAt = Date()
        self.linkedId = linkedId
        self.hasUnread = false
        self.topicId = topicId
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

