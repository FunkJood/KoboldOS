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
    case image(path: String, caption: String)
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

// MARK: - SessionAgentState (per-session isolation)

/// Each chat session gets its own agent state — no cross-session interference.
/// This is the key to scalability: Tasks, Workflows, Teams, and Chats all run independently.
@MainActor
final class SessionAgentState {
    let sessionId: UUID
    var isLoading: Bool = false
    var messageQueue: [String] = []
    var streamTask: Task<Void, Never>?
    var thinkingSteps: [ThinkingEntry] = []
    var checklist: [AgentChecklistItem] = []
    var lastPrompt: String?
    var wasStopped: Bool = false

    // Per-session context window info — not global to prevent cross-session overwriting
    var contextPromptTokens: Int = 0
    var contextCompletionTokens: Int = 0
    var contextUsagePercent: Double = 0.0
    var contextWindowSize: Int

    init(sessionId: UUID) {
        self.sessionId = sessionId
        let stored = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        self.contextWindowSize = stored > 0 ? stored : 32768
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        messageQueue.removeAll()
        thinkingSteps = []
        wasStopped = true
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

    // Chat — live UI state for CURRENT session only
    @Published var messages: [ChatMessage] = []
    // De-@Published: written every 500ms during streaming → manual objectWillChange
    var activeThinkingSteps: [ThinkingEntry] = []
    var agentChecklist: [AgentChecklistItem] = []

    // MARK: Per-Session Agent States (scalable isolation)
    /// Dictionary of per-session agent states — each session has independent agent execution
    private var sessionAgentStates: [UUID: SessionAgentState] = [:]

    // De-@Published: written in syncAgentStateToUI → manual objectWillChange
    var agentLoading: Bool = false
    var messageQueue: [String] = []
    var activeAgentOriginSession: UUID?

    /// Aktueller View-Tab für Kontext-Awareness (gesetzt von MainView)
    @Published var currentViewTab: String = "chat"
    /// Aktueller Sub-Tab im Apps-View
    @Published var currentAppSubTab: String = "apps"
    /// True only when the agent is loading AND the user is viewing the origin chat
    var isAgentLoadingInCurrentChat: Bool {
        let state = sessionAgentStates[currentSessionId]
        return state?.isLoading ?? false
    }
    /// Returns true if ANY session has an active agent
    var isAnyAgentLoading: Bool {
        sessionAgentStates.values.contains { $0.isLoading }
    }
    private var activeStreamTask: Task<Void, Never>?
    private var saveDebounceTask: Task<Void, Never>?
    private var metricsPollingTask: Task<Void, Never>?
    var isMetricsPollingActive: Bool = false
    /// Set of session IDs currently streaming to the daemon.
    /// Using a Set instead of a Bool allows multiple sessions to stream concurrently
    /// without incorrectly clearing the flag when only one of them finishes.
    private var streamingSessions: Set<UUID> = []
    /// True while ANY SSE stream is active (used for metrics/health guards)
    var isStreamingToDaemon: Bool { !streamingSessions.isEmpty }

    // Notification observer tokens for cleanup (nonisolated for deinit access)
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    /// Message cap per session (effectively unlimited)
    private let maxMessagesPerSession = 10000
    /// Generation counter to prevent stale session switches from overwriting messages
    private var sessionSwitchGeneration: Int = 0

    /// Rate-limit Ja/Nein buttons — only every 5th eligible message shows interactive buttons
    private var messagesSinceLastInteractive: Int = 0
    private let interactiveInterval = 5

    // MARK: - Message Batching (reduces objectWillChange during streaming)
    /// Per-session message buffer — each session buffers independently.
    /// Flushed in one batch at stream end (no objectWillChange storms).
    private var pendingMessages: [UUID: [ChatMessage]] = [:]
    private var messageFlushTask: Task<Void, Never>?

    // De-@Published: written in syncAgentStateToUI → manual objectWillChange
    var lastAgentPrompt: String? = nil
    var agentWasStopped: Bool = false

    // MARK: Per-Session Agent State Helpers

    /// Get or create agent state for a session
    func agentState(for sessionId: UUID) -> SessionAgentState {
        if let existing = sessionAgentStates[sessionId] {
            return existing
        }
        let state = SessionAgentState(sessionId: sessionId)
        sessionAgentStates[sessionId] = state
        return state
    }

    /// Sync published properties from current session's agent state (call after session switch or state change)
    /// Optimized: only assigns @Published properties if value actually changed, to prevent unnecessary SwiftUI redraws
    func syncAgentStateToUI() {
        let state = sessionAgentStates[currentSessionId]
        let newLoading = state?.isLoading ?? false
        let newOrigin: UUID? = state?.isLoading == true ? currentSessionId : nil
        let newStopped = state?.wasStopped ?? false
        let newPrompt = state?.lastPrompt

        if agentLoading != newLoading { agentLoading = newLoading }
        if activeAgentOriginSession != newOrigin { activeAgentOriginSession = newOrigin }
        if agentWasStopped != newStopped { agentWasStopped = newStopped }
        if lastAgentPrompt != newPrompt { lastAgentPrompt = newPrompt }
        // Arrays: only assign when count differs to avoid unnecessary objectWillChange
        let newQueue = state?.messageQueue ?? []
        if newQueue.count != messageQueue.count { messageQueue = newQueue }
        let newSteps = state?.thinkingSteps ?? []
        if newSteps.count != activeThinkingSteps.count { activeThinkingSteps = newSteps }
        let newChecklist = state?.checklist ?? []
        if newChecklist.count != agentChecklist.count { agentChecklist = newChecklist }
        // Per-session context info — only show data for the currently viewed session
        let newPT = state?.contextPromptTokens ?? 0
        let newCT = state?.contextCompletionTokens ?? 0
        let newPct = state?.contextUsagePercent ?? 0.0
        let fallbackCtx = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        let newWS = state?.contextWindowSize ?? (fallbackCtx > 0 ? fallbackCtx : 32768)
        if contextPromptTokens != newPT { contextPromptTokens = newPT }
        if contextCompletionTokens != newCT { contextCompletionTokens = newCT }
        if contextUsagePercent != newPct { contextUsagePercent = newPct }
        if contextWindowSize != newWS { contextWindowSize = newWS }
        // Manual notification for de-@Published properties (ONE per call, not 7)
        objectWillChange.send()
    }

    /// Cleanup stale agent states (sessions that no longer exist)
    func pruneAgentStates() {
        let allSessionIds = Set(sessions.map(\.id) + taskSessions.map(\.id) + workflowSessions.map(\.id))
        let staleIds = sessionAgentStates.keys.filter { !allSessionIds.contains($0) && !($0 == currentSessionId) }
        for id in staleIds {
            let state = sessionAgentStates[id]
            if state?.isLoading != true {
                sessionAgentStates.removeValue(forKey: id)
                klog("pruneAgentStates: removed stale state for \(id)")
            }
        }
    }

    // Workflow Execution
    @Published var workflowLastResponse: String? = nil

    // Context Management — de-@Published: written every 500ms in SSE polling
    var contextPromptTokens: Int = 0
    var contextCompletionTokens: Int = 0
    var contextUsagePercent: Double = 0.0
    var contextWindowSize: Int = {
        let stored = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        return stored > 0 ? stored : 32768
    }()

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

    /// Dedicated URLSession for SSE streaming — no caching, no buffering
    private lazy var sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

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

    var sessionsURL: URL {
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
        kcrit("RuntimeViewModel.init START")
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
        klog("RuntimeViewModel.init: sessions loaded")

        // Load heavier data async to avoid blocking Main Thread at startup
        Task { @MainActor in
            loadWorkflowDefinitions()
            loadProjects()
            loadChatHistory()
            if !messages.isEmpty {
                if !sessions.contains(where: { $0.id == currentSessionId }) {
                    upsertCurrentSession()
                    saveSessions()
                }
                currentSessionId = UUID()
                messages = []
                try? FileManager.default.removeItem(at: historyURL)
            }
        }

        Task { await connect() }
        startTaskScheduler()

        // Listen for shutdown save notification
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .koboldShutdownSave,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performShutdownSave()
            }
        })

        // Listen for agent-created projects/workflows (reload from disk)
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .koboldProjectsChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadProjects()
            }
        })

        // Listen for checklist events from ChecklistTool
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldChecklist"),
            object: nil, queue: .main
        ) { [weak self] notif in
            let action = notif.userInfo?["action"] as? String ?? ""
            let items = notif.userInfo?["items"] as? [String]
            let index = notif.userInfo?["index"] as? Int
            MainActor.assumeIsolated {
                guard let self = self else { return }
                switch action {
                case "set":
                    if let items = items {
                        self.agentChecklist = items.enumerated().map { (i, label) in
                            AgentChecklistItem(id: "step_\(i)", label: label)
                        }
                    }
                case "check":
                    if let index = index, index >= 0, index < self.agentChecklist.count {
                        self.agentChecklist[index].isCompleted = true
                    }
                case "clear":
                    self.agentChecklist = []
                default:
                    break
                }
                self.objectWillChange.send()
            }
        })

        // Listen for app terminal tool actions (Phase 3)
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldAppTerminalAction"),
            object: nil, queue: .main
        ) { notif in
            let action = notif.userInfo?["action"] as? String ?? ""
            let sessionIdStr = notif.userInfo?["session_id"] as? String ?? ""
            let resultId = notif.userInfo?["result_id"] as? String ?? ""
            let command = notif.userInfo?["command"] as? String ?? ""
            let linesStr = notif.userInfo?["lines"] as? String ?? "50"
            let sessionId = UUID(uuidString: sessionIdStr)

            MainActor.assumeIsolated {
                let manager = SharedTerminalManager.shared

                switch action {
                case "send_command":
                    let result = manager.sendCommand(command, sessionId: sessionId)
                    AgentCursorState.shared.show(at: CGPoint(x: 200, y: 50), label: "Terminal: \(command.prefix(30))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let output = manager.readOutput(sessionId: sessionId, lastN: 30)
                        Task {
                            await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "\(result)\n---\nOutput:\n\(output)")
                        }
                    }

                case "read_output":
                    let lines = Int(linesStr) ?? 50
                    let output = manager.readOutput(sessionId: sessionId, lastN: lines)
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: output) }

                case "snapshot":
                    let snapshot = manager.getSnapshot(sessionId: sessionId)
                    let json = snapshot.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: json) }

                case "new_session":
                    let newId = manager.newSession()
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "Neue Session: \(newId.uuidString)") }

                case "close_session":
                    if let sid = sessionId {
                        manager.closeSession(sid)
                    }
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "Session geschlossen") }

                case "list_sessions":
                    let list = manager.sessions.map { "[\($0.id.uuidString)] \($0.title) \($0.isRunning ? "running" : "stopped")" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: list.isEmpty ? "Keine Sessions" : list) }

                default:
                    break
                }
            }
        })

        // Listen for app browser tool actions (Phase 3)
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldAppBrowserAction"),
            object: nil, queue: .main
        ) { notif in
            let action = notif.userInfo?["action"] as? String ?? ""
            let tabIdStr = notif.userInfo?["tab_id"] as? String ?? ""
            let resultId = notif.userInfo?["result_id"] as? String ?? ""
            let url = notif.userInfo?["url"] as? String ?? ""
            let selector = notif.userInfo?["selector"] as? String ?? ""
            let text = notif.userInfo?["text"] as? String ?? ""
            let js = notif.userInfo?["js"] as? String ?? ""
            let tabId = UUID(uuidString: tabIdStr)

            MainActor.assumeIsolated {
                let manager = SharedBrowserManager.shared

                switch action {
                case "navigate":
                    let result = manager.navigate(url: url, tabId: tabId)
                    AgentCursorState.shared.show(at: CGPoint(x: 300, y: 30), label: "Navigiere: \(url.prefix(40))")
                    let json = result.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: json) }

                case "read_page":
                    manager.readPage(tabId: tabId) { pageText in
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: pageText) }
                    }

                case "click":
                    manager.click(selector: selector, tabId: tabId) { clickResult, point in
                        if let p = point {
                            // Offset für Browser-View (Tab-Bar ~40px + Toolbar ~40px)
                            let adjusted = CGPoint(x: p.x + 12, y: p.y + 90)
                            DispatchQueue.main.async {
                                AgentCursorState.shared.click(at: adjusted)
                            }
                        }
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: clickResult) }
                    }

                case "type":
                    manager.type(selector: selector, text: text, tabId: tabId) { typeResult, point in
                        if let p = point {
                            let adjusted = CGPoint(x: p.x + 12, y: p.y + 90)
                            DispatchQueue.main.async {
                                AgentCursorState.shared.show(at: adjusted, label: "Tippe: \(text.prefix(20))")
                            }
                        }
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: typeResult) }
                    }

                case "inspect":
                    manager.inspect(tabId: tabId) { inspectResult in
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: inspectResult) }
                    }

                case "execute_js":
                    manager.executeJS(js, tabId: tabId) { jsResult in
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: jsResult) }
                    }

                case "screenshot":
                    manager.screenshot(tabId: tabId) { path in
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: path) }
                    }

                case "new_tab":
                    let newId = manager.newTab(url: url)
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "Neuer Tab: \(newId.uuidString)") }

                case "close_tab":
                    if let tid = tabId {
                        manager.closeTab(tid)
                    }
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "Tab geschlossen") }

                case "list_tabs":
                    let list = manager.tabs.map { "[\($0.id.uuidString)] \($0.title) — \($0.urlString)" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: list.isEmpty ? "Keine Tabs" : list) }

                case "snapshot":
                    let snapshot = manager.getSnapshot(tabId: tabId)
                    let json = snapshot.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: json) }

                case "dismiss_popup":
                    manager.dismissPopup(tabId: tabId) { dismissResult in
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: dismissResult) }
                    }

                case "wait_for_load":
                    Task {
                        let loaded = await manager.waitForLoad(tabId: tabId, timeout: 12)
                        let tab = manager.tab(for: tabId) ?? manager.activeTab
                        let status = loaded ? "Seite geladen" : "Timeout (Seite lädt noch)"
                        let url = tab?.urlString ?? ""
                        let title = tab?.title ?? ""
                        await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "\(status)\nURL: \(url)\nTitel: \(title)")
                    }

                case "submit_form":
                    guard let wv = (manager.tab(for: tabId) ?? manager.activeTab)?.webView else {
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "[Kein Browser-Tab aktiv]") }
                        break
                    }
                    let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
                    let formJs = """
                    (() => {
                        const el = document.querySelector('\(escaped)');
                        if (!el) return 'element not found';
                        const form = el.closest('form');
                        if (form) {
                            form.dispatchEvent(new Event('submit', {bubbles:true}));
                            const submit = form.querySelector('[type=submit], button:not([type])');
                            if (submit) submit.click();
                            else form.submit();
                            return 'form submitted';
                        } else {
                            // Kein Form: Enter-Key simulieren
                            el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, bubbles:true}));
                            el.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter', code:'Enter', keyCode:13, bubbles:true}));
                            el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', keyCode:13, bubbles:true}));
                            return 'enter key sent (no form found)';
                        }
                    })()
                    """
                    wv.evaluateJavaScript(formJs) { result, error in
                        let msg = (result as? String) ?? error?.localizedDescription ?? "submitted"
                        Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: msg) }
                    }

                default:
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "[Unbekannte Browser-Aktion: \(action)]") }
                }
            }
        })

        // Listen for self-awareness queries from SelfAwarenessTool
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldSelfAwareness"),
            object: nil, queue: .main
        ) { [weak self] notif in
            let action = notif.userInfo?["action"] as? String ?? ""
            let resultId = notif.userInfo?["result_id"] as? String ?? ""

            MainActor.assumeIsolated {
                guard let self = self else { return }

                switch action {
                case "get_notifications":
                    let list = self.notifications.prefix(10).map { "[\($0.type.rawValue)] \($0.title): \($0.message)" }.joined(separator: "\n")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: list.isEmpty ? "Keine Benachrichtigungen" : list) }

                case "get_sessions":
                    UserDefaults.standard.set(self.sessions.count, forKey: "kobold.stats.sessionCount")
                    UserDefaults.standard.set(self.taskSessions.count, forKey: "kobold.stats.taskSessionCount")
                    UserDefaults.standard.set(self.workflowSessions.count, forKey: "kobold.stats.workflowSessionCount")
                    Task { await AppToolResultWaiter.shared.deliverResult(id: resultId, result: "Sessions aktualisiert") }

                default:
                    break
                }
            }
        })

        // Track settings changes for agent awareness
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldSettingChanged"),
            object: nil, queue: .main
        ) { notif in
            let key = notif.userInfo?["key"] as? String ?? ""
            let value = notif.userInfo?["value"] as? String ?? ""
            let by = notif.userInfo?["by"] as? String ?? "user"

            // Append to recent changes log
            var changes = UserDefaults.standard.stringArray(forKey: "kobold.recentChanges") ?? []
            let entry = "[\(by)] \(key) = \(value)"
            changes.append(entry)
            if changes.count > 20 { changes = Array(changes.suffix(20)) }
            UserDefaults.standard.set(changes, forKey: "kobold.recentChanges")
        })
    }

    deinit {
        // Remove all notification observers to prevent leaks
        let tokens = observerTokens
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Mini-Chat (Phase 5)

    private var miniChatTask: Task<Void, Never>?

    func sendFromMiniChat(_ message: String, onResponse: @escaping @Sendable (String) -> Void) {
        let contextMessage = "[Mini-Chat / Apps-Tab] \(message)"
        let previousCount = messages.count
        sendMessage(contextMessage)

        // Cancel any previous mini-chat watcher
        miniChatTask?.cancel()

        // Watch for assistant response — poll every 1s, max 15s, cancellable + OFF MainActor
        miniChatTask = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self = self else { return }
                if self.messages.count > previousCount {
                    for msg in self.messages.suffix(from: previousCount) {
                        if case .assistant(let text) = msg.kind {
                            let truncated = text.count > 200 ? String(text.prefix(200)) + "..." : text
                            onResponse(truncated)
                            return
                        }
                    }
                }
            }
            onResponse("Timeout — keine Antwort erhalten.")
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
        guard !isStreamingToDaemon else { return isConnected } // Don't hit daemon during SSE
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
        // Skip metrics during agent streaming — daemon is an actor, concurrent HTTP requests
        // cause actor-queue starvation and make the SSE stream hang
        if agentLoading || isStreamingToDaemon { return }
        guard let url = URL(string: baseURL + "/metrics") else { return }
        if let (data, _) = try? await authorizedData(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let newMetrics = RuntimeMetrics(from: json)
            if newMetrics != metrics { metrics = newMetrics }
        }
        // Also load recent traces
        guard let traceURL = URL(string: baseURL + "/trace") else { return }
        if let (data, _) = try? await authorizedData(from: traceURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let timeline = json["timeline"] as? [[String: Any]] {
            let newTraces = timeline.suffix(10).compactMap { entry -> String? in
                guard let event = entry["event"] as? String else { return nil }
                let detail = entry["detail"] as? String ?? ""
                return "\(event): \(String(detail.prefix(60)))"
            }
            if newTraces != recentTraces { recentTraces = newTraces }
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
        guard !isStreamingToDaemon else { return }
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

    // MARK: - Ollama Parallel Processing

    /// Restart Ollama with full performance flags:
    /// - OLLAMA_NUM_PARALLEL: concurrent requests (= worker pool size)
    /// - OLLAMA_MAX_LOADED_MODELS: models kept hot in (V)RAM
    /// - OLLAMA_NUM_THREADS: CPU inference threads (all physical cores by default)
    /// - OLLAMA_FLASH_ATTENTION: enable Flash Attention (faster, less memory)
    /// - OLLAMA_NUM_GPU: GPU layers to offload to Metal (999 = all, Apple Silicon)
    func restartOllamaWithParallelism(workers: Int) {
        let n = max(1, min(workers, 16))
        // Use all physical CPU cores for inference threads
        let cpuCores = ProcessInfo.processInfo.processorCount
        ollamaStatus = "Restarting…"
        Task.detached(priority: .userInitiated) {
            // Step 1: Kill existing Ollama
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-x", "ollama"]
            try? kill.run()
            kill.waitUntilExit()
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s grace period

            func buildEnv(_ base: [String: String], parallel: Int, threads: Int) -> [String: String] {
                var env = base
                env["OLLAMA_NUM_PARALLEL"] = "\(parallel)"
                env["OLLAMA_MAX_LOADED_MODELS"] = "\(parallel)"
                env["OLLAMA_NUM_THREADS"] = "\(threads)"
                env["OLLAMA_FLASH_ATTENTION"] = "1"
                env["OLLAMA_NUM_GPU"] = "999"  // offload all layers to Metal/GPU
                return env
            }

            // Step 2: Start Ollama with performance flags
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
            serve.arguments = ["serve"]
            serve.environment = buildEnv(ProcessInfo.processInfo.environment, parallel: n, threads: cpuCores)
            do {
                try serve.run()
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s startup
                await MainActor.run { [weak self] in
                    self?.ollamaStatus = "Running (×\(n), \(cpuCores)T, GPU)"
                    Task { await self?.loadModels() }
                }
            } catch {
                // Fallback: Homebrew arm64 path
                let serve2 = Process()
                serve2.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
                serve2.arguments = ["serve"]
                serve2.environment = buildEnv(ProcessInfo.processInfo.environment, parallel: n, threads: cpuCores)
                try? serve2.run()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { [weak self] in
                    self?.ollamaStatus = "Running (×\(n), \(cpuCores)T, GPU)"
                    Task { await self?.loadModels() }
                }
            }
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
        let sessionId = currentSessionId
        let state = agentState(for: sessionId)
        kcrit("sendMessage START: \"\(String(trimmed.prefix(60)))\" session=\(sessionId) isLoading=\(state.isLoading) queueSize=\(state.messageQueue.count)")
        state.wasStopped = false
        var msg = ChatMessage(kind: .user(text: trimmed.isEmpty ? "📎" : trimmed), timestamp: Date())
        msg.attachments = attachments
        messages.append(msg)
        SoundManager.shared.play(.send)

        upsertCurrentSessionAsync()
        saveSessions()
        saveChatHistory()
        let textForAgent = (agentText ?? trimmed).trimmingCharacters(in: .whitespaces)
        let agentMsg = textForAgent.isEmpty ? "Describe the attached media." : textForAgent

        if state.isLoading {
            kcrit("sendMessage QUEUED (agent busy) session=\(sessionId) queueSize=\(state.messageQueue.count + 1)")
            state.messageQueue.append(agentMsg)
            syncAgentStateToUI()
            return
        }

        state.streamTask?.cancel()
        state.streamTask = nil
        klog("sendMessage → creating sendWithAgent Task for session=\(sessionId)")
        state.streamTask = Task { await sendWithAgent(message: agentMsg, attachments: attachments, forSession: sessionId) }
        syncAgentStateToUI()
    }

    /// Send a message with optional per-node model/agent overrides (used by workflow execution)
    func sendWorkflowMessage(_ text: String, modelOverride: String? = nil, agentOverride: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let sessionId = currentSessionId
        let state = agentState(for: sessionId)
        messages.append(ChatMessage(kind: .user(text: trimmed), timestamp: Date()))
        upsertCurrentSessionAsync()
        saveSessions()
        saveChatHistory()
        state.streamTask?.cancel()
        state.streamTask = nil
        state.streamTask = Task {
            // Temporarily override agent type and model
            let origAgent = self.agentTypeStr
            let origModel = self.activeOllamaModel
            if let ao = agentOverride, !ao.isEmpty { self.agentTypeStr = ao }
            if let mo = modelOverride, !mo.isEmpty { self.activeOllamaModel = mo }
            defer { self.agentTypeStr = origAgent; self.activeOllamaModel = origModel }
            await self.sendWithAgent(message: trimmed, forSession: sessionId)
        }
        syncAgentStateToUI()
    }

    @AppStorage("kobold.showAgentSteps") var showAgentSteps: Bool = true

    func cancelAgent() {
        let sessionId = currentSessionId
        let state = agentState(for: sessionId)
        kcrit("cancelAgent: session=\(sessionId) wasLoading=\(state.isLoading) queueSize=\(state.messageQueue.count)")
        flushPendingMessages(for: sessionId)
        streamingSessions.remove(sessionId)
        state.cancel()
        appendToSession(ChatMessage(kind: .assistant(text: "⏸ Agent gestoppt."), timestamp: Date()), originSession: sessionId)
        if currentSessionId == sessionId {
            saveChatHistory()
        }
        syncAgentStateToUI()
        saveSessions()
        saveTaskSessions()
        saveWorkflowSessions()
    }

    /// Processes the next queued message for a specific session — fully isolated
    private func processMessageQueue(forSession sessionId: UUID) {
        let state = agentState(for: sessionId)
        guard !state.messageQueue.isEmpty, !state.isLoading else {
            klog("processMessageQueue[\(sessionId.uuidString.prefix(8))]: skip (empty=\(state.messageQueue.isEmpty) loading=\(state.isLoading))")
            return
        }
        let nextMsg = state.messageQueue.removeFirst()
        kcrit("processMessageQueue[\(sessionId.uuidString.prefix(8))]: processing \"\(String(nextMsg.prefix(40)))\" remaining=\(state.messageQueue.count)")
        state.streamTask?.cancel()
        state.streamTask = nil
        state.isLoading = true
        state.streamTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard !Task.isCancelled else {
                state.isLoading = false
                self.syncAgentStateToUI()
                return
            }
            await self.sendWithAgent(message: nextMsg, forSession: sessionId)
        }
        syncAgentStateToUI()
    }

    /// Baut View-Kontext für automatische Kontexterkennung
    func buildViewContext() -> String {
        switch currentViewTab {
        case "applications":
            var ctx = "User ist im Apps-Tab"
            switch currentAppSubTab {
            case "terminal":
                let snapshot = SharedTerminalManager.shared.getSnapshot()
                let output = snapshot["last_output"] ?? ""
                ctx += " → Terminal. Letzte Zeilen:\n\(String(output.suffix(500)))"
                ctx += "\nNutze app_terminal um Terminal-Befehle auszuführen."
            case "browser":
                let snap = SharedBrowserManager.shared.getSnapshot()
                ctx += " → Browser. URL: \(snap["url"] ?? "leer"), Titel: \(snap["title"] ?? "leer")"
                ctx += "\nNutze app_browser um mit der Webseite zu interagieren."
            default:
                ctx += " → \(currentAppSubTab)"
            }
            return ctx
        case "tasks":
            return "User ist im Tasks-Tab"
        case "workflows":
            return "User ist im Workflows-Tab"
        case "teams":
            return "User ist im Teams-Tab"
        case "dashboard":
            return "" // Dashboard braucht keinen extra Kontext
        default:
            return "" // Chat = Standard, kein Kontext nötig
        }
    }

    /// Resume agent with last prompt after stop
    func resumeAgent() {
        let sessionId = currentSessionId
        let state = agentState(for: sessionId)
        guard let prompt = state.lastPrompt, !prompt.isEmpty else { return }
        state.wasStopped = false
        state.streamTask?.cancel()
        state.streamTask = nil
        appendToSession(ChatMessage(kind: .user(text: "▶ Weiter: \(String(prompt.prefix(80)))…"), timestamp: Date()), originSession: sessionId)
        state.streamTask = Task { await sendWithAgent(message: prompt, forSession: sessionId) }
        syncAgentStateToUI()
    }

    /// Send next queued message immediately (cancels current agent)
    func sendNextQueued() {
        let state = agentState(for: currentSessionId)
        guard !state.messageQueue.isEmpty else { return }
        let nextMsg = state.messageQueue.removeFirst()
        cancelAgent()
        sendMessage(nextMsg)
    }

    /// Clear entire message queue for current session
    func clearMessageQueue() {
        let state = agentState(for: currentSessionId)
        state.messageQueue.removeAll()
        syncAgentStateToUI()
    }

    /// Cancel all background tasks (call on view disappear / deinit)
    func cancelAllTasks() {
        // Cancel ALL session agent states
        for (_, state) in sessionAgentStates {
            state.streamTask?.cancel()
            state.streamTask = nil
            state.isLoading = false
            state.thinkingSteps = []
        }
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        metricsPollingTask?.cancel()
        metricsPollingTask = nil
        syncAgentStateToUI()
    }

    /// Start periodic metrics polling (only while dashboard is visible)
    func startMetricsPolling() {
        guard !isMetricsPollingActive else { return }
        isMetricsPollingActive = true
        metricsPollingTask?.cancel()
        metricsPollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self, await self.isMetricsPollingActive else { break }
                await self.loadMetrics()
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
    /// If the origin session is currently displayed AND agent is streaming, messages are
    /// buffered and flushed every 300ms as a single batch (1 objectWillChange instead of 50+).
    /// User messages and session switches bypass the buffer for instant feedback.
    /// All paths enforce maxMessagesPerSession to prevent unbounded RAM growth.
    private func appendToSession(_ msg: ChatMessage, originSession: UUID) {
        // Current session — live UI path
        if currentSessionId == originSession {
            // User messages bypass buffer for instant feedback
            let isUserMsg: Bool
            if case .user = msg.kind { isUserMsg = true } else { isUserMsg = false }
            let isStreaming = sessionAgentStates[originSession]?.isLoading ?? false

            if isStreaming && !isUserMsg {
                // Buffer during streaming — keyed by session for full isolation
                pendingMessages[originSession, default: []].append(msg)
                scheduleMessageFlush()
            } else {
                // Not streaming or user message — flush this session's buffer then append immediately
                flushPendingMessages(for: originSession)
                messages.append(msg)
                if messages.count > maxMessagesPerSession + 50 {
                    messages = Array(messages.suffix(maxMessagesPerSession))
                }
            }
            return
        }
        // Session is not currently viewed - append to the correct session array
        guard let codable = ChatMessageCodable(from: msg) else {
            kcrit("appendToSession: failed to create CodableMessage for session \(originSession)")
            return
        }
        var found = false
        if let idx = sessions.firstIndex(where: { $0.id == originSession }) {
            sessions[idx].messages.append(codable)
            sessions[idx].hasUnread = true
            if sessions[idx].messages.count > maxMessagesPerSession {
                sessions[idx].messages = Array(sessions[idx].messages.suffix(maxMessagesPerSession))
            }
            found = true
        } else if let idx = taskSessions.firstIndex(where: { $0.id == originSession }) {
            taskSessions[idx].messages.append(codable)
            taskSessions[idx].hasUnread = true
            if taskSessions[idx].messages.count > maxMessagesPerSession {
                taskSessions[idx].messages = Array(taskSessions[idx].messages.suffix(maxMessagesPerSession))
            }
            found = true
        } else if let idx = workflowSessions.firstIndex(where: { $0.id == originSession }) {
            workflowSessions[idx].messages.append(codable)
            workflowSessions[idx].hasUnread = true
            if workflowSessions[idx].messages.count > maxMessagesPerSession {
                workflowSessions[idx].messages = Array(workflowSessions[idx].messages.suffix(maxMessagesPerSession))
            }
            found = true
        }
        if !found {
            // Session not found in any array — create it to prevent message loss
            kcrit("appendToSession: session \(originSession) NOT FOUND in any array! Creating fallback session.")
            var fallbackSession = ChatSession(id: originSession, title: "Wiederhergestellt", messages: [])
            fallbackSession.messages = [codable]
            sessions.insert(fallbackSession, at: 0)
        }
        // Debounced save — NOT per message (prevents disk I/O storms)
        debouncedSaveAllSessions()
    }

    /// During streaming: messages stay in buffer until streaming completes.
    /// No periodic flushes during streaming — the ThinkingPanel provides live feedback.
    /// This eliminates objectWillChange storms on the messages array.
    private func scheduleMessageFlush() {
        // NO-OP during streaming — messages flush on completion via flushPendingMessages()
        // in sendWithAgent's defer block. User messages bypass buffer anyway.
    }

    /// Flush buffered messages for a specific session to the live `messages` array.
    /// Only has visible effect when that session is currently displayed.
    func flushPendingMessages(for sessionId: UUID? = nil) {
        messageFlushTask?.cancel()
        messageFlushTask = nil
        let targetId = sessionId ?? currentSessionId
        guard var buffer = pendingMessages[targetId], !buffer.isEmpty else { return }
        pendingMessages.removeValue(forKey: targetId)
        // Only write to live messages when this is the currently visible session
        guard targetId == currentSessionId else {
            // Session not visible — persist buffered messages directly to session array
            for msg in buffer {
                guard let codable = ChatMessageCodable(from: msg) else { continue }
                if let idx = sessions.firstIndex(where: { $0.id == targetId }) {
                    sessions[idx].messages.append(codable)
                } else if let idx = taskSessions.firstIndex(where: { $0.id == targetId }) {
                    taskSessions[idx].messages.append(codable)
                } else if let idx = workflowSessions.firstIndex(where: { $0.id == targetId }) {
                    workflowSessions[idx].messages.append(codable)
                }
            }
            return
        }
        messages.append(contentsOf: buffer)
        buffer.removeAll()
        if messages.count > maxMessagesPerSession + 50 {
            messages = Array(messages.suffix(maxMessagesPerSession))
        }
    }

    /// Flush ALL pending session buffers — call on session switch to prevent message loss.
    func flushAllPendingMessages() {
        let ids = Array(pendingMessages.keys)
        for id in ids { flushPendingMessages(for: id) }
    }

    // MARK: - Debounced Session Persistence (prevents I/O storms during agent runs)

    private var sessionSaveDebounceTask: Task<Void, Never>?

    /// Save all session arrays at most once every 3 seconds (coalesces rapid writes)
    /// Debounce timer runs detached to avoid blocking MainActor; actual save dispatches back.
    func debouncedSaveAllSessions() {
        sessionSaveDebounceTask?.cancel()
        sessionSaveDebounceTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, let self = self else { return }
            await MainActor.run {
                klog("debouncedSave: writing sessions=\(self.sessions.count) tasks=\(self.taskSessions.count) workflows=\(self.workflowSessions.count)")
                self.saveSessions()
                self.saveTaskSessions()
                self.saveWorkflowSessions()
                self.pruneAgentStates()
            }
        }
    }

    /// Returns the conversation history for any session — active or background.
    /// Active session: reads from live `messages` (fast, always current).
    /// Background session: reads from the persisted session array (correct isolation).
    /// Each message is capped at 2000 chars to prevent payload bloat.
    private func conversationHistory(for sessionId: UUID, limit: Int = 30) -> [[String: String]] {
        func cap(_ t: String) -> String { t.count > 2000 ? String(t.prefix(2000)) + "\n…[gekürzt]" : t }

        if sessionId == currentSessionId {
            // Fast path: use live messages array
            return messages.suffix(limit).compactMap { msg -> [String: String]? in
                switch msg.kind {
                case .user(let t):      return ["role": "user",      "content": cap(t)]
                case .assistant(let t): return ["role": "assistant", "content": cap(t)]
                default: return nil
                }
            }
        }
        // Background path: read from persisted session array
        let codables: [ChatMessageCodable]
        if let s = sessions.first(where: { $0.id == sessionId }) {
            codables = s.messages
        } else if let s = taskSessions.first(where: { $0.id == sessionId }) {
            codables = s.messages
        } else if let s = workflowSessions.first(where: { $0.id == sessionId }) {
            codables = s.messages
        } else {
            return []
        }
        return codables.suffix(limit).compactMap { c -> [String: String]? in
            switch c.kind {
            case "user":      return ["role": "user",      "content": cap(c.text)]
            case "assistant": return ["role": "assistant", "content": cap(c.text)]
            default: return nil
            }
        }
    }

    /// Check if interactive buttons should be shown (rate-limited: only every 5th eligible message)
    func shouldShowInteractive(_ text: String) -> Bool {
        messagesSinceLastInteractive += 1
        guard Self.isYesNoQuestion(text) else { return false }
        guard messagesSinceLastInteractive >= interactiveInterval else { return false }
        messagesSinceLastInteractive = 0
        return true
    }

    /// Detect if a final answer is a clear, direct yes/no question → show interactive buttons.
    /// Only triggers when the text is SHORT and ends with a direct question — avoids polluting
    /// longer explanations or multi-paragraph answers with unnecessary Ja/Nein buttons.
    static func isYesNoQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Must end with a question mark
        guard trimmed.hasSuffix("?") else { return false }
        // Must be short — a direct question, not a long explanation that happens to ask something
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count <= 3, trimmed.count < 300 else { return false }
        // The last line must contain the actual trigger
        let lastLine = (lines.last ?? trimmed).lowercased()
        let triggers = ["soll ich", "möchtest du", "willst du", "darf ich", "shall i", "should i", "do you want", "ist das ok", "einverstanden"]
        guard triggers.contains(where: { lastLine.contains($0) }) else { return false }
        // Must NOT contain code blocks, lists, or long explanations (signs it's not a simple question)
        let hasCodeOrList = trimmed.contains("```") || trimmed.contains("- ") || trimmed.contains("1.")
        return !hasCodeOrList
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

    func sendWithAgent(message: String, attachments: [MediaAttachment] = [], forSession originChatSession: UUID? = nil) async {
        let originChatSession = originChatSession ?? currentSessionId
        let state = agentState(for: originChatSession)
        kcrit("sendWithAgent START: \"\(String(message.prefix(60)))\" chatMode=\(chatMode) session=\(originChatSession)")
        state.isLoading = true
        state.wasStopped = false
        state.lastPrompt = message
        syncAgentStateToUI()

        let activeSessionId = UUID()  // Tracking ID for ActiveAgentSession (not chat session)
        let session = ActiveAgentSession(
            id: activeSessionId, agentType: agentTypeStr,
            startedAt: Date(),
            prompt: String(message.prefix(100)),
            status: .running, stepCount: 0, currentTool: ""
        )
        activeSessions.insert(session, at: 0)
        if activeSessions.count > 20 { activeSessions = Array(activeSessions.prefix(20)) }

        defer {
            // Auto-clear checklist after 2s if all completed
            let stateChecklist = state.checklist
            if !stateChecklist.isEmpty && stateChecklist.allSatisfy(\.isCompleted) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    let s = self.agentState(for: originChatSession)
                    withAnimation(.easeInOut(duration: 0.3)) { s.checklist = [] }
                    self.syncAgentStateToUI()
                }
            }
            if let idx = activeSessions.firstIndex(where: { $0.id == activeSessionId }) {
                if activeSessions[idx].status == .running {
                    activeSessions[idx].status = .completed
                }
            }
            // Auto-remove completed sessions after 60 seconds
            let sid = activeSessionId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self.activeSessions.removeAll { $0.id == sid && $0.status != .running }
                self.objectWillChange.send()
            }
            // Flush this session's buffered messages before clearing loading state
            flushPendingMessages(for: originChatSession)
            // ALWAYS clear agent state, then process this session's queue
            kcrit("sendWithAgent DEFER[\(originChatSession.uuidString.prefix(8))]: clearing state, queueSize=\(state.messageQueue.count)")
            state.isLoading = false
            syncAgentStateToUI()
            processMessageQueue(forSession: originChatSession)
        }

        let imageBase64s = attachments.compactMap { $0.base64 }

        // Kontext-Awareness: Agent weiß wo der User gerade ist
        let viewContext = buildViewContext()
        let enrichedMessage = viewContext.isEmpty ? message : "\(message)\n\n---\n[Kontext: \(viewContext)]"

        // Build conversation history for the CORRECT session — not just the currently visible one.
        // conversationHistory(for:) reads from live messages for active sessions,
        // or from the persisted session array for background sessions. This is the key
        // to multi-chat isolation: each background agent gets its own correct context.
        let sessionHistory = conversationHistory(for: originChatSession)

        var payload: [String: Any] = [
            "message": enrichedMessage,
            "agent_type": agentTypeStr,
            "conversation_history": sessionHistory
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

        // ── SSE STREAMING: Background parsing + timer-based UI updates ──
        // SSE reading + JSON parsing runs 100% off MainActor via SSEAccumulator.
        // A timer polls the accumulator every 500ms for lightweight UI updates.
        // MainActor is NEVER blocked by JSON parsing, even for large payloads.

        do {
            kcrit("sendWithAgent → SSE request to \(baseURL)/agent/stream")
            streamingSessions.insert(originChatSession)

            state.thinkingSteps = []
            if currentSessionId == originChatSession { activeThinkingSteps = [] }

            let capturedReq = req
            let capturedSSESession = sseSession
            let accumulator = SSEAccumulator()

            // ── BACKGROUND: Read SSE + parse JSON completely off MainActor ──
            let parseTask = Task.detached(priority: .userInitiated) {
                do {
                    let (bytes, resp) = try await capturedSSESession.bytes(for: capturedReq)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        await accumulator.setError("HTTP Error \(code)")
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard !jsonStr.isEmpty else { continue }
                        // JSON parsing happens HERE — off MainActor!
                        await accumulator.processEvent(jsonStr)
                    }
                } catch {
                    if !Task.isCancelled {
                        await accumulator.setError(error.localizedDescription)
                    }
                }
                await accumulator.markDone()
            }

            // ── MAINACTOR: Poll accumulator every 500ms for lightweight UI updates ──
            // De-@Published properties: ONE objectWillChange per 500ms cycle (not 6+)
            var isStreamDone = false
            var pollCycle = 0
            while !isStreamDone && !Task.isCancelled {
                // Sleep 500ms — MainActor is FREE during this
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { parseTask.cancel(); break }
                pollCycle += 1

                // Check if stream is done
                isStreamDone = await accumulator.isDone

                // Take pending flush (small struct, fast actor call)
                let pendingCount = await accumulator.pendingStepCount
                // Log every 4th cycle (~2s) for debugging freezes
                if pollCycle % 4 == 0 {
                    kcrit("SSE poll #\(pollCycle): done=\(isStreamDone) pending=\(pendingCount)")
                }
                if pendingCount > 0 {
                    let flush = await accumulator.takePendingFlush()
                    // Minimal MainActor work: append steps, update UI
                    state.thinkingSteps.append(contentsOf: flush.steps)
                    if state.thinkingSteps.count > 1000 {
                        state.thinkingSteps = Array(state.thinkingSteps.suffix(800))
                    }
                    if currentSessionId == originChatSession {
                        let displaySteps = state.thinkingSteps.count > 30
                            ? Array(state.thinkingSteps.suffix(30))
                            : state.thinkingSteps
                        activeThinkingSteps = displaySteps
                    }
                    if let idx = activeSessions.firstIndex(where: { $0.id == activeSessionId }),
                       activeSessions[idx].stepCount != flush.toolStepCount {
                        activeSessions[idx].stepCount = flush.toolStepCount
                    }
                    // Context info — stored per-session to prevent cross-session overwriting.
                    // syncAgentStateToUI() will pull these into the ViewModel when this session is active.
                    if let pt = flush.contextPromptTokens { state.contextPromptTokens = pt }
                    if let ct = flush.contextCompletionTokens { state.contextCompletionTokens = ct }
                    if let pct = flush.contextUsagePercent { state.contextUsagePercent = pct }
                    if let ws = flush.contextWindowSize { state.contextWindowSize = ws }
                    // ONE objectWillChange for all de-@Published writes in this cycle
                    objectWillChange.send()
                    // Notifications (after UI update)
                    for text in flush.thoughtNotifications {
                        NotificationCenter.default.post(name: Notification.Name("koboldAgentThought"), object: nil, userInfo: ["text": text])
                    }
                    for text in flush.toolNotifications {
                        NotificationCenter.default.post(name: Notification.Name("koboldAgentThought"), object: nil, userInfo: ["text": text, "type": "tool"])
                    }
                }
            }

            // ── Stream done: apply final results on MainActor ──
            streamingSessions.remove(originChatSession) // Release this session's stream lock
            parseTask.cancel() // Ensure cleanup
            let sseResult = await accumulator.takeFinalResult()

            // Apply checklist actions
            for (action, items, index) in sseResult.checklistActions {
                switch action {
                case "set":
                    if let items = items {
                        state.checklist = items.enumerated().map { (i, label) in AgentChecklistItem(id: "step_\(i)", label: label) }
                        if currentSessionId == originChatSession { agentChecklist = state.checklist }
                    }
                case "check":
                    if let index = index, index >= 0, index < state.checklist.count {
                        state.checklist[index].isCompleted = true
                        if currentSessionId == originChatSession { agentChecklist = state.checklist }
                    }
                case "clear":
                    state.checklist = []
                    if currentSessionId == originChatSession { agentChecklist = [] }
                default: break
                }
            }

            // Apply error
            if let errorMsg = sseResult.error {
                appendToSession(ChatMessage(kind: .assistant(text: "⚠️ \(errorMsg)"), timestamp: Date()), originSession: originChatSession)
                if chatMode == .workflow {
                    SoundManager.shared.play(.workflowFail)
                    addNotification(title: "Workflow fehlgeschlagen", message: String(errorMsg.prefix(100)), type: .error, target: .chat(sessionId: originChatSession))
                } else if chatMode == .task {
                    SoundManager.shared.play(.workflowFail)
                    addNotification(title: "Aufgabe fehlgeschlagen", message: String(errorMsg.prefix(100)), type: .error, target: .chat(sessionId: originChatSession))
                } else {
                    addNotification(title: "Fehler", message: errorMsg, type: .error)
                }
            }

            // Apply interactive messages
            for (text, options) in sseResult.interactiveMessages {
                appendToSession(ChatMessage(kind: .interactive(text: text, options: options), timestamp: Date()), originSession: originChatSession)
            }

            // Apply embed messages
            for (path, caption) in sseResult.embedMessages {
                if let fileUrl = URL(string: "file://\(path)") ?? URL(fileURLWithPath: path) as URL? {
                    var embedMsg = ChatMessage(kind: .assistant(text: caption.isEmpty ? "📎 \(fileUrl.lastPathComponent)" : caption), timestamp: Date())
                    embedMsg.attachments = [MediaAttachment(url: fileUrl)]
                    appendToSession(embedMsg, originSession: originChatSession)
                }
            }

            // Play sounds once
            if sseResult.toolStepCount > 0 {
                SoundManager.shared.play(chatMode == .workflow ? .workflowStep : .toolCall)
            }

            // Compact thinking steps into single message
            let hadToolSteps = !state.thinkingSteps.isEmpty
            if hadToolSteps && showAgentSteps {
                appendToSession(ChatMessage(kind: .thinking(entries: state.thinkingSteps), timestamp: Date()), originSession: originChatSession)
            }
            state.thinkingSteps = []
            if currentSessionId == originChatSession { activeThinkingSteps = [] }

            // Final answer
            if !sseResult.finalAnswer.isEmpty {
                if shouldShowInteractive(sseResult.finalAnswer) {
                    appendToSession(
                        ChatMessage(kind: .interactive(text: sseResult.finalAnswer, options: [
                            InteractiveOption(id: "yes", label: "Ja", icon: "checkmark"),
                            InteractiveOption(id: "no", label: "Nein", icon: "xmark")
                        ]), timestamp: Date(), confidence: sseResult.confidence),
                        originSession: originChatSession
                    )
                } else {
                    var msg = ChatMessage(kind: .assistant(text: sseResult.finalAnswer), timestamp: Date(), confidence: sseResult.confidence)
                    let autoEmbed = UserDefaults.standard.bool(forKey: "kobold.chat.autoEmbed")
                    if autoEmbed { msg.attachments = Self.extractMediaAttachments(from: sseResult.finalAnswer) }
                    appendToSession(msg, originSession: originChatSession)
                }
                SoundManager.shared.play(chatMode == .workflow ? .workflowDone : .success)
                let preview = sseResult.finalAnswer.count > 80 ? String(sseResult.finalAnswer.prefix(77)) + "..." : sseResult.finalAnswer
                if chatMode == .workflow {
                    addNotification(title: "Workflow abgeschlossen", message: preview, type: .success, target: .chat(sessionId: originChatSession))
                } else if chatMode == .task {
                    addNotification(title: "Aufgabe abgeschlossen", message: preview, type: .success, target: .chat(sessionId: originChatSession))
                } else if sseResult.toolStepCount >= 3 {
                    addNotification(title: "Aufgabe erledigt", message: preview, type: .success, target: .chat(sessionId: originChatSession))
                }
            }

            // Persist once at end
            kcrit("sendWithAgent SSE DONE: finalAnswer=\(!sseResult.finalAnswer.isEmpty) toolSteps=\(sseResult.toolStepCount)")
            if currentSessionId == originChatSession {
                trimMessages()
                upsertCurrentSessionAsync()
                saveChatHistory()
            }
            debouncedSaveAllSessions()
        } catch {
            streamingSessions.remove(originChatSession)
            kcrit("sendWithAgent ERROR: \(error.localizedDescription) cancelled=\(Task.isCancelled)")
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
        streamingSessions.insert(originSession)
        defer { streamingSessions.remove(originSession) }
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
        saveDebounceTask = Task.detached(priority: .userInitiated) {
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
        Task.detached(priority: .userInitiated) {
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
        Task.detached(priority: .userInitiated) {
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
        Task.detached(priority: .userInitiated) {
            var seen = Set<UUID>()
            let deduped = snapshot.filter { seen.insert($0.id).inserted }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(deduped) {
                try? data.write(to: url)
            }
        }
    }

    func loadSessions() {
        let url = sessionsURL
        klog("loadSessions: loading from \(url.lastPathComponent)")
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            guard !loaded.isEmpty else {
                klog("loadSessions: no sessions found")
                return
            }
            klog("loadSessions: loaded \(loaded.count) sessions")
            self.sessions = loaded
            if self.messages.isEmpty, let first = loaded.first {
                self.currentSessionId = first.id
                self.messages = self.restoreMessages(from: first.messages)
                klog("loadSessions: restored \(self.messages.count) msgs from first session")
            }
        }
    }

    func loadTaskSessions() {
        let url = taskSessionsURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            if !loaded.isEmpty { self.taskSessions = loaded }
        }
    }

    func loadWorkflowSessions() {
        let url = workflowSessionsURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [ChatSession]() }
                var seen = Set<UUID>()
                return loaded.filter { seen.insert($0.id).inserted }
            }.value
            if !loaded.isEmpty { self.workflowSessions = loaded }
        }
    }

    /// Async version for session switching — conversion runs off MainActor
    private func upsertCurrentSessionAsync() {
        guard !messages.isEmpty else { return }
        let msgs = messages
        let mode = chatMode
        let sessionId = currentSessionId
        let topicId = activeTopicId
        let taskId = taskChatId
        let taskLabel = taskChatLabel
        let wfLabel = workflowChatLabel
        Task { @MainActor in
            let codables = await Task.detached(priority: .userInitiated) {
                return msgs.compactMap { ChatMessageCodable(from: $0) }
            }.value
            self.applyUpsert(codables: codables, mode: mode, sessionId: sessionId, topicId: topicId, taskId: taskId, taskLabel: taskLabel, wfLabel: wfLabel, messages: msgs)
        }
    }

    /// Atomically ensure the current session is in the correct sessions list based on chatMode.
    private func upsertCurrentSession() {
        guard !messages.isEmpty else { return }
        let codables = messages.compactMap { ChatMessageCodable(from: $0) }
        applyUpsert(codables: codables, mode: chatMode, sessionId: currentSessionId,
                    topicId: activeTopicId, taskId: taskChatId, taskLabel: taskChatLabel,
                    wfLabel: workflowChatLabel, messages: messages)
    }

    /// Shared upsert logic used by both sync and async paths
    private func applyUpsert(codables: [ChatMessageCodable], mode: ChatMode, sessionId: UUID,
                             topicId: UUID?, taskId: String, taskLabel: String,
                             wfLabel: String, messages: [ChatMessage]) {
        let title: String
        switch mode {
        case .normal:
            title = generateSessionTitle(from: messages)
            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].title = title
                sessions[idx].messages = codables
                if let tid = topicId { sessions[idx].topicId = tid }
            } else {
                var session = ChatSession(id: sessionId, title: title, messages: [], topicId: topicId)
                session.messages = codables
                sessions.insert(session, at: 0)
            }
        case .task:
            title = taskLabel.isEmpty ? generateSessionTitle(from: messages) : taskLabel
            if let idx = taskSessions.firstIndex(where: { $0.id == sessionId }) {
                taskSessions[idx].title = title
                taskSessions[idx].messages = codables
            } else {
                var session = ChatSession(id: sessionId, title: title, messages: [], linkedId: taskId)
                session.messages = codables
                taskSessions.insert(session, at: 0)
            }
        case .workflow:
            title = wfLabel.isEmpty ? generateSessionTitle(from: messages) : wfLabel
            if let idx = workflowSessions.firstIndex(where: { $0.id == sessionId }) {
                workflowSessions[idx].title = title
                workflowSessions[idx].messages = codables
            } else {
                var session = ChatSession(id: sessionId, title: title, messages: [])
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
        let url = historyURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [ChatMessage] in
                guard let data = try? Data(contentsOf: url),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
                return arr.compactMap { item -> ChatMessage? in
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
            }.value
            if !loaded.isEmpty {
                self.messages = loaded
                klog("loadChatHistory: restored \(loaded.count) messages")
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
        let url = workflowDefsURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) else { return [WorkflowDefinition]() }
                return loaded
            }.value
            if !loaded.isEmpty { self.workflowDefinitions = loaded }
        }
    }

    private func saveWorkflowDefinitionsSync() {
        let snapshot = workflowDefinitions
        let url = workflowDefsURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
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
        let url = topicsURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let loaded = try? JSONDecoder().decode([ChatTopic].self, from: data) else { return [ChatTopic]() }
                return loaded
            }.value
            if !loaded.isEmpty { self.topics = loaded }
        }
    }

    func saveTopics() {
        let snapshot = topics
        let url = topicsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
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
        ksession("NEW prev=\(currentSessionId.uuidString.prefix(8))", currentSessionId,
                 ["sessionsCount": sessions.count, "taskCount": taskSessions.count, "workflowCount": workflowSessions.count])
        // Synchronous upsert — must finish before messages = [] to avoid losing last message
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
        // Save current session before switching (async to avoid blocking MainActor)
        upsertCurrentSessionAsync()
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
        upsertCurrentSessionAsync()
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
        // Guard: Keine Aktion wenn bereits aktive Session geklickt wird
        guard session.id != currentSessionId else { return }
        ksession("SWITCH from=\(currentSessionId.uuidString.prefix(8)) to=\(session.id.uuidString.prefix(8))", session.id,
                 ["msgCount": session.messages.count, "title": String(session.title.prefix(30))])
        // Flush ALL session buffers before switching — no message loss
        flushAllPendingMessages()
        // SYNCHRONOUS upsert: must complete before messages = [] to avoid losing the last message.
        // The async variant has a race: messages=[] can happen before the task writes to sessions[].
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
        messages = []
        syncAgentStateToUI()

        // Restore messages OFF Main Actor (conversion can be slow for 500+ messages)
        sessionSwitchGeneration += 1
        let expectedGeneration = sessionSwitchGeneration
        let targetSessionId = session.id
        let codables = session.messages
        Task {
            // Heavy conversion off MainActor
            let restored = await Task.detached(priority: .userInitiated) { () -> [ChatMessage] in
                return codables.compactMap { codable -> ChatMessage? in
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
            }.value
            // Apply on MainActor only if still viewing this session
            await MainActor.run {
                guard self.sessionSwitchGeneration == expectedGeneration,
                      self.currentSessionId == targetSessionId else { return }
                self.messages = restored
                klog("switchToSession: restored \(restored.count) messages for \(targetSessionId.uuidString.prefix(8))")
            }
        }

        saveChatHistory()
    }

    func deleteSession(_ session: ChatSession) {
        ksession("DELETE", session.id, ["title": session.title, "msgCount": session.messages.count])
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
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            projects = Project.defaultProjects()
            saveProjects()
            return
        }
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      !data.isEmpty,
                      let loaded = try? JSONDecoder().decode([Project].self, from: data) else { return [Project]() }
                return loaded
            }.value
            if !loaded.isEmpty { self.projects = loaded }
        }
    }

    func saveProjects() {
        let snapshot = projects
        let url = projectsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
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
    // De-@Published: written during streaming → manual objectWillChange
    var activeSessions: [ActiveAgentSession] = []

    func killSession(_ id: UUID) {
        activeSessions.removeAll { $0.id == id }
        // Cancel agent state for any session that was using this active session
        for (sessionId, state) in sessionAgentStates {
            if state.isLoading {
                state.cancel()
                klog("killSession: cancelled agent for session \(sessionId)")
            }
        }
        syncAgentStateToUI()
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
        kcrit("performShutdownSave: sessions=\(sessions.count) tasks=\(taskSessions.count) workflows=\(workflowSessions.count) msgs=\(messages.count) activeAgents=\(sessionAgentStates.values.filter(\.isLoading).count)")
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

    }
}

// MARK: - Supporting Types

struct RuntimeMetrics: Equatable {
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

// MARK: - AgentTeam & TeamAgent Models

struct AgentTeam: Identifiable, Codable {
    var id: UUID
    var name: String
    var icon: String
    var agents: [TeamAgent]
    var description: String
    var goals: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, icon: String, agents: [TeamAgent], description: String, goals: [String] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.icon = icon; self.agents = agents
        self.description = description; self.goals = goals; self.createdAt = createdAt
    }

    static let defaults: [AgentTeam] = [
        AgentTeam(
            name: "Recherche-Team",
            icon: "magnifyingglass.circle.fill",
            agents: [
                TeamAgent(name: "Koordinator", role: "Teamleiter", instructions: "Plant und delegiert Aufgaben, fasst Ergebnisse zusammen.", profile: "planner"),
                TeamAgent(name: "Web-Analyst", role: "Researcher", instructions: "Durchsucht das Web nach relevanten Informationen.", profile: "researcher"),
                TeamAgent(name: "Fakten-Checker", role: "Validator", instructions: "Prüft Quellen und verifiziert Behauptungen.", profile: "researcher"),
            ],
            description: "Parallele Web-Recherche mit Validierung",
            goals: ["Gründliche Quellenprüfung", "Faktenbasierte Ergebnisse"]
        ),
        AgentTeam(
            name: "Code-Team",
            icon: "chevron.left.forwardslash.chevron.right",
            agents: [
                TeamAgent(name: "Architekt", role: "Lead Developer", instructions: "Entwirft die Architektur und verteilt Coding-Tasks.", profile: "planner"),
                TeamAgent(name: "Frontend", role: "UI/UX Dev", instructions: "Implementiert die Benutzeroberfläche.", profile: "coder"),
                TeamAgent(name: "Backend", role: "API Dev", instructions: "Implementiert Server-Logik und Datenbank.", profile: "coder"),
                TeamAgent(name: "Tester", role: "QA", instructions: "Schreibt Tests und prüft auf Bugs.", profile: "coder"),
            ],
            description: "Full-Stack-Entwicklung mit parallelen Agents",
            goals: ["Saubere Architektur", "Testabdeckung > 80%"]
        ),
        AgentTeam(
            name: "Content-Team",
            icon: "doc.richtext.fill",
            agents: [
                TeamAgent(name: "Editor", role: "Chefredakteur", instructions: "Koordiniert und redigiert alle Inhalte.", profile: "planner"),
                TeamAgent(name: "Texter", role: "Autor", instructions: "Schreibt Texte, Artikel und Blogposts.", profile: "general"),
                TeamAgent(name: "Designer", role: "Grafiker", instructions: "Erstellt Bilder und Illustrationen.", profile: "general"),
            ],
            description: "Content-Erstellung mit Text und Bild",
            goals: ["Konsistenter Tonfall", "SEO-optimiert"]
        ),
    ]
}

struct TeamAgent: Identifiable, Codable {
    var id: UUID
    var name: String
    var role: String
    var instructions: String
    var profile: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, role: String, instructions: String, profile: String = "general", isActive: Bool = true) {
        self.id = id; self.name = name; self.role = role
        self.instructions = instructions; self.profile = profile; self.isActive = isActive
    }
}

struct GroupMessage: Identifiable, Codable {
    var id: UUID
    let content: String
    let isUser: Bool
    let agentName: String
    let timestamp: Date
    var round: Int
    var isStreaming: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool, agentName: String, timestamp: Date = Date(), round: Int = 0, isStreaming: Bool = false) {
        self.id = id; self.content = content; self.isUser = isUser
        self.agentName = agentName; self.timestamp = timestamp
        self.round = round; self.isStreaming = isStreaming
    }
}

