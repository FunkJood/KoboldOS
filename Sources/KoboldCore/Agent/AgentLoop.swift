import Foundation

// MARK: - Agent Type

public enum AgentType: String, Sendable {
    case web     = "web"
    case coder   = "coder"
    case general = "general"

    public var stepLimit: Int {
        let defaults: Int
        switch self {
        case .web:     defaults = 200
        case .coder:   defaults = 150
        case .general: defaults = 100
        }
        let key: String
        switch self {
        case .web:     key = "kobold.agent.webSteps"
        case .coder:   key = "kobold.agent.coderSteps"
        case .general: key = "kobold.agent.generalSteps"
        }
        let userValue = UserDefaults.standard.integer(forKey: key)
        return userValue > 0 ? userValue : defaults
    }
}

// MARK: - AgentStep

public struct AgentStep: Sendable, Encodable {
    public let stepNumber: Int
    public let type: StepType
    public let content: String
    public let toolCallName: String?
    public let toolResultSuccess: Bool?
    public let timestamp: Date
    public let subAgentName: String?
    public var confidence: Double?
    public var checkpointId: String?

    public init(stepNumber: Int, type: StepType, content: String,
                toolCallName: String? = nil, toolResultSuccess: Bool? = nil,
                timestamp: Date = Date(), subAgentName: String? = nil,
                confidence: Double? = nil, checkpointId: String? = nil) {
        self.stepNumber = stepNumber; self.type = type; self.content = content
        self.toolCallName = toolCallName; self.toolResultSuccess = toolResultSuccess
        self.timestamp = timestamp; self.subAgentName = subAgentName
        self.confidence = confidence; self.checkpointId = checkpointId
    }

    public enum StepType: String, Sendable, Encodable {
        case think, toolCall, toolResult, finalAnswer, error
        case subAgentSpawn, subAgentResult, checkpoint
        case context_info
    }

    /// JSON representation for SSE streaming
    public func toJSON() -> String {
        var obj: [String: Any] = [
            "step": stepNumber,
            "type": type.rawValue,
            "content": content,
            "tool": toolCallName ?? "",
            "success": toolResultSuccess ?? true
        ]
        if let sub = subAgentName { obj["subAgent"] = sub }
        if let c = confidence { obj["confidence"] = c }
        if let cp = checkpointId { obj["checkpointId"] = cp }
        // context_info: parse prompt_tokens/completion_tokens/usage_percent/context_window from content JSON
        if type == .context_info, let data = content.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in parsed { obj[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - AgentResult

public struct AgentResult: Sendable {
    public let finalOutput: String
    public let steps: [AgentStep]
    public let success: Bool
}

// MARK: - AgentLoop

public actor AgentLoop {
    private let registry: ToolRegistry
    private let parser: ToolCallParser
    public let agentID: String
    public let coreMemory: CoreMemory
    private var ruleEngine: ToolRuleEngine
    /// Dedicated LLMRunner for this AgentLoop instance.
    /// Using a per-instance runner instead of the shared singleton allows
    /// multiple AgentLoops to call Ollama truly in parallel (no actor serialization).
    private let llmRunner: LLMRunner
    private var conversationHistory: [String] = []
    private let maxConversationHistory = 500
    /// Proper message pairs for LLM context injection across turns
    private var conversationMessages: [[String: String]] = []
    private let maxConversationPairs = 250
    private var agentType: AgentType = .general
    private var currentProviderConfig: LLMProviderConfig?

    /// G6: Statische Logging-Callbacks — einmal bei App-Start setzen, gelten für ALLE AgentLoop-Instanzen.
    /// Ermöglicht Cross-Module Logging ohne KoboldLogger-Dependency in KoboldCore.
    public nonisolated(unsafe) static var onToolLog: (@Sendable (String) -> Void)?
    public nonisolated(unsafe) static var onBuildLog: (@Sendable (String) -> Void)?

    /// Maximum number of message pairs (assistant+user) to keep in context window.
    /// System prompt + original user message are always preserved.
    private let maxContextMessages = 200

    // MARK: - Context Management

    /// Context window size from UserDefaults (default 32768)
    private var contextWindowSize: Int {
        let v = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        return v > 0 ? v : 32768
    }

    /// Reserve 10% of context window for response generation
    private var responseReserve: Int { Int(Double(contextWindowSize) * 0.10) }

    /// Compression threshold (percentage 0.0-1.0, default 0.8)
    private var compressionThreshold: Double {
        let v = UserDefaults.standard.double(forKey: "kobold.context.threshold")
        return v > 0 ? v : 0.8
    }

    /// Whether auto-compression is enabled
    private var isAutoCompressEnabled: Bool {
        if UserDefaults.standard.object(forKey: "kobold.context.autoCompress") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kobold.context.autoCompress")
    }

    /// Last known token counts from API response
    private var lastKnownPromptTokens: Int = 0
    private var lastKnownCompletionTokens: Int = 0

    /// Get current context info for UI
    public func getContextInfo() -> ContextInfo {
        return ContextInfo(
            promptTokens: lastKnownPromptTokens,
            completionTokens: lastKnownCompletionTokens,
            contextWindowSize: contextWindowSize,
            isEstimated: lastKnownPromptTokens == 0
        )
    }

    /// Create an AgentLoop.
    /// - Parameters:
    ///   - agentID: Unique ID for memory isolation (default "default" = shared memory)
    ///   - llmRunner: Optional dedicated LLMRunner. If nil, uses llmRunner.
    ///     Pass a fresh LLMRunner() to avoid actor serialization with concurrent sessions.
    public init(agentID: String = "default", llmRunner: LLMRunner? = nil) {
        self.agentID = agentID
        self.registry = ToolRegistry()
        self.parser = ToolCallParser()
        self.coreMemory = CoreMemory(agentID: agentID)
        self.ruleEngine = .default
        self.llmRunner = llmRunner ?? LLMRunner.shared

        Task {
            await self.setupTools()
        }
    }

    /// Inject conversation history from UI session so the agent knows what was discussed.
    /// Called by DaemonListener before runStreaming() to provide full chat context.
    public func injectConversationHistory(_ history: [[String: String]]) {
        // Take last N pairs to stay within context limits
        let maxPairs = maxConversationPairs
        let trimmed = history.count > maxPairs * 2 ? Array(history.suffix(maxPairs * 2)) : history
        self.conversationMessages = trimmed
        // Also populate string history for memory
        for msg in trimmed {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            conversationHistory.append("\(role == "user" ? "User" : "Assistant"): \(content.prefix(500))")
        }
    }

    private let archivalStore = ArchivalMemoryStore.shared

    private func setupTools(providerConfig: LLMProviderConfig? = nil) async {
        // Response tool MUST be registered — it's how the agent delivers answers
        await registry.register(ResponseTool())
        // Core tools
        await registry.register(FileTool())
        await registry.register(ShellTool())
        await registry.register(BrowserTool())
        await registry.register(CalculatorPlugin())
        // Memory tools (legacy core memory blocks)
        await registry.register(CoreMemoryReadTool(memory: coreMemory))
        await registry.register(CoreMemoryAppendTool(memory: coreMemory))
        await registry.register(CoreMemoryReplaceTool(memory: coreMemory))
        // Archival memory tools (Letta/MemGPT paging)
        await registry.register(ArchivalMemorySearchTool(store: archivalStore))
        await registry.register(ArchivalMemoryInsertTool(store: archivalStore))
        // Tagged memory tools (new tag-based system)
        await registry.register(MemorySaveTool(store: memoryStore))
        await registry.register(MemoryRecallTool(store: memoryStore))
        await registry.register(MemoryForgetTool(store: memoryStore))
        // Management tools
        await registry.register(SkillWriteTool())
        await registry.register(TaskManageTool())
        await registry.register(WorkflowManageTool())
        // New tools
        await registry.register(NotifyTool())
        await registry.register(ChecklistTool())

        // Register platform-specific tools conditionally
        #if os(macOS)
        await registry.register(AppleScriptTool())
        // Apple Integration tools
        await registry.register(CalendarTool())
        await registry.register(ContactsTool())
        // Browser automation — Screen control only (PlaywrightTool deaktiviert: synchrones waitUntilExit blockiert UI)
        // await registry.register(PlaywrightTool())
        await registry.register(ScreenControlTool())
        #endif

        // Sub-agent delegation (AgentZero-style call_subordinate) — pass provider config + parent memory + agentId for live streaming
        await registry.register(DelegateTaskTool(providerConfig: providerConfig, parentMemory: coreMemory, parentAgentId: agentID))
        await registry.register(DelegateParallelTool(providerConfig: providerConfig, parentMemory: coreMemory, parentAgentId: agentID))
        // OAuth API tools - macOS only
        #if os(macOS)
        await registry.register(GoogleApiTool())
        await registry.register(SoundCloudApiTool())
        // Phase 1 connection tools
        await registry.register(GitHubApiTool())
        await registry.register(MicrosoftApiTool())
        await registry.register(SlackApiTool())
        await registry.register(NotionApiTool())
        await registry.register(WhatsAppApiTool())
        await registry.register(HuggingFaceApiTool())
        await registry.register(LieferandoApiTool())
        await registry.register(UberApiTool())
        await registry.register(SunoApiTool())
        await registry.register(RedditApiTool())
        await registry.register(TwilioSmsTool())
        await registry.register(EmailTool())
        await registry.register(CalDAVTool())
        await registry.register(MQTTTool())
        #endif
        // App control tools (Terminal + Browser in-app)
        await registry.register(AppTerminalTool())
        await registry.register(AppBrowserTool())
        // Self-awareness (Agent kann eigenen Zustand sehen/ändern)
        await registry.register(SelfAwarenessTool())
        // Vision/OCR (Bilder analysieren, Text extrahieren)
        await registry.register(VisionTool())
        // Platform-independent tools
        await registry.register(RSSReaderTool())
        await registry.register(WebhookTool())
        // Telegram send tool
        await registry.register(TelegramTool())
        // Text-to-Speech
        await registry.register(TTSTool())
        // Secrets & Keychain access
        await registry.register(SecretsTool())
        // Settings read/write
        await registry.register(SettingsReadTool())

    }

    // MARK: - Configuration

    public func setAgentType(_ type: AgentType) {
        agentType = type
        switch type {
        case .web:    ruleEngine = .web
        case .coder:  ruleEngine = .coder
        default:      ruleEngine = .default
        }
    }

    public func setSystemPrompt(_ p: String) { /* stored in coreMemory persona block */ }
    public func clearHistory() {
        conversationHistory = []
        conversationMessages = []
    }

    /// Public context compression — triggered by /agent/compress endpoint.
    /// Prunes old messages, truncates tool results, returns remaining message count.
    public func compressContext() -> Int {
        guard !conversationMessages.isEmpty else { return 0 }
        manageContext(&conversationMessages)
        truncateOldToolResults(&conversationMessages)
        return conversationMessages.count
    }

    /// Trim conversation history to prevent unbounded memory growth
    private func trimConversationHistory() {
        if conversationHistory.count > maxConversationHistory {
            conversationHistory.removeFirst(conversationHistory.count - maxConversationHistory)
        }
    }

    /// Trim conversation messages (proper LLM message pairs) to last N pairs.
    /// Also truncates individual large messages to prevent memory bloat.
    private func trimConversationMessages() {
        let maxMessages = maxConversationPairs * 2
        if conversationMessages.count > maxMessages {
            conversationMessages.removeFirst(conversationMessages.count - maxMessages)
        }
        // Truncate individual messages over 4000 chars to prevent RAM bloat
        for i in 0..<conversationMessages.count {
            if let content = conversationMessages[i]["content"], content.count > 4000 {
                conversationMessages[i]["content"] = String(content.prefix(3800)) + "\n... (gekürzt)"
            }
        }
    }

    /// Prune messages to prevent context window overflow.
    /// Always keeps: system prompt (index 0) + original user message (index 1) + last N message pairs.
    private func pruneMessages(_ messages: inout [[String: String]]) {
        guard messages.count > maxContextMessages + 2 else { return }
        let toRemove = messages.count - maxContextMessages - 2
        messages.removeSubrange(2..<(2 + toRemove))
    }

    /// Smart context management: estimates tokens, compresses if needed, falls back to pruning.
    private func manageContext(_ messages: inout [[String: String]]) {
        // 1. Estimate current token usage
        let estimated = TokenEstimator.estimateTokens(messages: messages)
        // Threshold accounts for response reserve (15%) — compress before we hit the wall
        let effectiveLimit = contextWindowSize - responseReserve
        let threshold = Int(Double(effectiveLimit) * compressionThreshold)

        // Update last known if we're estimating
        if lastKnownPromptTokens == 0 {
            lastKnownPromptTokens = estimated
        }

        guard estimated > threshold else { return }

        // 2. Try auto-compression if enabled
        if isAutoCompressEnabled {
            // 2a. Truncate old tool results first (cheapest operation)
            truncateOldToolResults(&messages)

            // Re-check after truncation
            let afterTruncate = TokenEstimator.estimateTokens(messages: messages)
            if afterTruncate <= threshold { return }

            // 2b. Save highlights before discarding
            saveConversationHighlights(messages)
        }

        // 3. Fallback: hard prune by message count
        pruneMessages(&messages)
    }

    /// Truncate tool results older than the last 3, keeping only first 200 chars
    private func truncateOldToolResults(_ messages: inout [[String: String]]) {
        guard messages.count > 5 else { return }

        // Find indices of tool-result messages (user role messages that start with tool result markers)
        var toolResultIndices: [Int] = []
        for i in 2..<messages.count {
            if let content = messages[i]["content"],
               messages[i]["role"] == "user",
               (content.hasPrefix("[Tool Result") || content.hasPrefix("Tool '") || content.contains("\"tool_result\"")) {
                toolResultIndices.append(i)
            }
        }

        // Keep last 10 tool results intact, truncate older ones
        guard toolResultIndices.count > 10 else { return }
        let toTruncate = toolResultIndices.dropLast(10)
        for idx in toTruncate {
            if let content = messages[idx]["content"], content.count > 500 {
                messages[idx]["content"] = String(content.prefix(500)) + "\n... (gekürzt)"
            }
        }
    }

    /// Extract key facts from messages before they get pruned, save to archival memory
    private func saveConversationHighlights(_ messages: [[String: String]]) {
        // Only save from messages that will be pruned (middle section)
        guard messages.count > maxContextMessages + 2 else { return }
        let pruneEnd = messages.count - maxContextMessages
        let toPrune = messages[2..<pruneEnd]

        // Extract assistant messages that contain useful content
        var highlights: [String] = []
        for msg in toPrune {
            guard msg["role"] == "assistant", let content = msg["content"] else { continue }
            // Skip JSON tool calls, only save meaningful responses
            if content.contains("\"tool_name\"") && !content.contains("\"response\"") { continue }
            if content.count > 50 {
                highlights.append(String(content.prefix(300)))
            }
        }

        guard !highlights.isEmpty else { return }
        let summary = highlights.prefix(3).joined(separator: "\n---\n")
        Task {
            await archivalStore.insert(label: "conversation_highlights", content: summary)
        }
    }

    // MARK: - Main Run (AgentZero-style loop)

    /// Maximum time an agent run is allowed to take (10 minutes — was 2 hours which caused hangs)
    private let executionTimeout: TimeInterval = 600

    /// Maximum characters to include from a tool result in the message context
    private let maxToolResultChars = 32000

    public func run(userMessage: String, agentType: AgentType = .general, providerConfig: LLMProviderConfig? = nil) async throws -> AgentResult {
        // Wrap with timeout
        return try await withThrowingTaskGroup(of: AgentResult.self) { group in
            defer { group.cancelAll() } // P12: IMMER canceln — auch bei Exception (verhindert Worker-Leak)
            group.addTask {
                try await self.runInner(userMessage: userMessage, agentType: agentType, providerConfig: providerConfig)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.executionTimeout * 1_000_000_000))
                throw LLMError.generationFailed("Agent-Timeout nach \(Int(self.executionTimeout / 60)) Minuten")
            }
            guard let result = try await group.next() else {
                throw LLMError.generationFailed("Agent lieferte kein Ergebnis")
            }
            return result
        }
    }

    private func runInner(userMessage: String, agentType: AgentType = .general, providerConfig: LLMProviderConfig? = nil) async throws -> AgentResult {
        self.agentType = agentType
        // Store provider config and re-register delegation tools with it
        if let pc = providerConfig, self.currentProviderConfig == nil || self.currentProviderConfig?.apiKey != pc.apiKey {
            self.currentProviderConfig = pc
            await setupTools(providerConfig: pc)
        }
        // Set Ollama model on the runner if specified
        if let pc = providerConfig, !pc.model.isEmpty, pc.provider == "ollama" {
            await llmRunner.setModel(pc.model)
        }
        conversationHistory.append("User: \(userMessage)")
        trimConversationHistory()
        var steps: [AgentStep] = []
        ruleEngine.reset()

        // Cache static parts of system prompt (don't rebuild every step)
        let toolDescriptions = buildToolDescriptions()
        let skillsPrompt = await SkillLoader.shared.enabledSkillsPrompt()
        let rawAutonomy = UserDefaults.standard.integer(forKey: "kobold.autonomyLevel")
        let autonomyLevel = rawAutonomy == 0 ? 2 : min(max(rawAutonomy, 1), 3) // Default: Normal (2)
        let selfCheckEnabled = UserDefaults.standard.bool(forKey: "kobold.perm.selfCheck")
        let selfCheckPrompt: String
        if autonomyLevel >= 3 && selfCheckEnabled {
            selfCheckPrompt = "\n\n# Autonomer Modus\nDu bist vollständig autonom. Prüfe deine Arbeit, teste Code, korrigiere Fehler selbstständig. Frage nur bei destruktiven Aktionen (rm -rf, Daten löschen) nach."
        } else if autonomyLevel >= 2 {
            selfCheckPrompt = "\n\n# Werkzeug-Nutzung\nDu darfst alle aktivierten Tools selbstständig nutzen ohne nachzufragen. Handle Aufgaben direkt. Frage NUR bei potenziell destruktiven Aktionen (Dateien löschen, System ändern) nach Bestätigung."
        } else {
            selfCheckPrompt = ""
        }
        let confidencePrompt = """

        # Confidence Self-Assessment
        Include a "confidence" field (0.0-1.0) in every JSON response.
        1.0 = certain, 0.0 = unsure. If confidence < 0.5, use the response tool to ask the user for clarification instead of guessing.
        """

        let archivalPrompt = """

        # Archival Memory
        Wenn Core Memory Blöcke voll sind (>80% Limit), nutze archival_memory_insert um ältere Informationen zu archivieren.
        Nutze archival_memory_search um archivierte Informationen wieder zu finden.
        """

        // Build initial system prompt with current memory
        let compiledMemory = await coreMemory.compile()

        // A3: Run memory retrieval + skill search in parallel (both are independent I/O)
        async let relevantMemoriesAsync = smartMemoryRetrieval(query: userMessage)
        async let relevantSkillsAsync = SkillLoader.shared.relevantSkills(query: userMessage)
        let relevantMemories = await relevantMemoriesAsync
        let relevantSkillsPrompt = await relevantSkillsAsync
        let memoryRetrievalPrompt = relevantMemories.isEmpty ? "" : "\n\n## Relevante Erinnerungen (automatisch geladen)\n\(relevantMemories)"

        // Context status for LLM awareness
        let ctxTokens = lastKnownPromptTokens > 0 ? lastKnownPromptTokens : TokenEstimator.estimateTokens(messages: conversationMessages)
        let ctxPercent = Int(TokenEstimator.usagePercent(estimatedTokens: ctxTokens, contextSize: contextWindowSize) * 100)
        let contextStatusPrompt = "\n\n# Kontext-Status\nNutzung: ~\(ctxTokens) / \(contextWindowSize) Tokens (\(ctxPercent)%)"

        let sysPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: compiledMemory) + skillsPrompt + selfCheckPrompt + confidencePrompt + archivalPrompt + memoryRetrievalPrompt + relevantSkillsPrompt + contextStatusPrompt

        var messages: [[String: String]] = [
            ["role": "system", "content": sysPrompt]
        ]
        // Inject prior conversation context so the LLM sees the full conversation
        messages.append(contentsOf: conversationMessages)
        // Add current user message
        messages.append(["role": "user", "content": userMessage])

        for stepCount in 1...agentType.stepLimit {
            // Refresh memory in system prompt every step (agent sees its own updates)
            let freshMemory = await coreMemory.compile()
            if freshMemory != compiledMemory {
                let freshPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: freshMemory) + skillsPrompt + selfCheckPrompt + confidencePrompt + archivalPrompt
                if !messages.isEmpty { messages[0] = ["role": "system", "content": freshPrompt] }
            }

            // Smart context management (estimate tokens, compress if needed, fallback prune)
            manageContext(&messages)

            let llmResponse: String
            do {
                let resp: LLMResponse
                if let pc = providerConfig, pc.isCloudProvider, !pc.apiKey.isEmpty {
                    resp = try await llmRunner.generateWithTokens(messages: messages, config: pc)
                } else {
                    resp = try await llmRunner.generateWithTokens(messages: messages)
                }
                llmResponse = resp.content
                // Update token tracking from API response
                if let pt = resp.promptTokens { lastKnownPromptTokens = pt }
                if let ct = resp.completionTokens { lastKnownCompletionTokens = ct }
            } catch {
                // LLM generation failed — retry up to 2 times with brief delay
                let llmRetryCount = steps.filter { $0.type == .error }.count
                if llmRetryCount < 2 {
                    steps.append(AgentStep(
                        stepNumber: stepCount, type: .error,
                        content: "LLM-Fehler (Versuch \(llmRetryCount + 1)/3): \(error.localizedDescription)",
                        toolCallName: nil, toolResultSuccess: false, timestamp: Date()
                    ))
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay before retry
                    continue
                }
                return AgentResult(finalOutput: "Fehler nach 3 Versuchen: \(error.localizedDescription)", steps: steps, success: false)
            }

            // Parse the response — always expect JSON with tool_name/tool_args
            let parsedCalls = parser.parse(response: llmResponse)

            // Parser now always returns at least a "response" fallback
            let parsed = parsedCalls.first ?? ParsedToolCall(
                name: "response",
                arguments: ["text": llmResponse.trimmingCharacters(in: .whitespacesAndNewlines)],
                thoughts: []
            )
            let confidence = parsed.confidence

            // Record thoughts
            if !parsed.thoughts.isEmpty {
                steps.append(AgentStep(
                    stepNumber: stepCount, type: .think,
                    content: parsed.thoughts.joined(separator: "\n"),
                    toolCallName: nil, toolResultSuccess: nil, timestamp: Date(),
                    confidence: confidence
                ))
            }

            // Check if this is the "response" tool (terminal — delivers answer to user)
            if parsed.name == "response" {
                // Extract response text — try multiple key names (local models vary heavily)
                var rawAnswer: String = {
                    for key in ["text", "content", "response", "message", "answer", "reply", "output"] {
                        if let v = parsed.arguments[key], !v.isEmpty { return v }
                    }
                    // Fallback: first non-JSON argument value (model used an unknown key)
                    for (_, v) in parsed.arguments {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty && !t.hasPrefix("{") && !t.hasPrefix("[") { return v }
                    }
                    return llmResponse
                }()

                // Recovery: Check if the LLM embedded an actual tool call inside the "response" text.
                // Local models sometimes wrap tool calls in response text instead of proper JSON format.
                if let recovered = extractEmbeddedToolCall(from: rawAnswer) {
                    // Execute the recovered tool call instead of treating as final answer
                    steps.append(AgentStep(
                        stepNumber: stepCount, type: .toolCall, content: rawAnswer,
                        toolCallName: recovered.name, toolResultSuccess: nil, timestamp: Date()
                    ))
                    messages.append(["role": "assistant", "content": llmResponse])
                    let call = recovered.toToolCall()
                    let result = await registry.execute(call: call)
                    ruleEngine.record(toolName: call.name)
                    let resultText = parser.formatToolResult(result, callId: recovered.callId, toolName: call.name)
                    steps.append(AgentStep(
                        stepNumber: stepCount, type: .toolResult,
                        content: result.outputOrError, toolCallName: call.name,
                        toolResultSuccess: result.isSuccess, timestamp: Date()
                    ))
                    let truncatedResult = resultText.count > maxToolResultChars
                        ? String(resultText.prefix(maxToolResultChars)) + "\n... (gekürzt)"
                        : resultText
                    messages.append(["role": "user", "content": truncatedResult + "\nAntworte jetzt als JSON."])
                    continue // Continue agent loop — don't treat as final answer
                }

                // Extract text from JSON if the response is still wrapped in JSON
                // (same logic as runStreaming — local models often wrap response in JSON)
                if rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    if let data = rawAnswer.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        var extracted: String? = nil
                        // Check nested args with multiple text-like keys
                        let textKeys = ["text", "content", "response", "message", "answer", "reply", "output"]
                        for argsKey in ["tool_args", "toolargs", "args", "arguments"] {
                            if let args = json[argsKey] as? [String: Any] {
                                for tk in textKeys {
                                    if let s = args[tk] as? String, !s.isEmpty { extracted = s; break }
                                }
                                // Generic: any non-JSON string in args
                                if extracted == nil {
                                    for (_, value) in args {
                                        if let s = value as? String, !s.isEmpty, !s.hasPrefix("{") { extracted = s; break }
                                    }
                                }
                                if extracted != nil { break }
                            }
                        }
                        // Top-level text keys
                        if extracted == nil {
                            for tk in textKeys {
                                if let s = json[tk] as? String, !s.isEmpty { extracted = s; break }
                            }
                        }
                        // String-encoded args
                        if extracted == nil {
                            for key in ["tool_args", "toolargs", "args", "arguments"] {
                                if let str = json[key] as? String, !str.isEmpty {
                                    if let innerData = str.data(using: .utf8),
                                       let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
                                       let t = inner["text"] as? String, !t.isEmpty {
                                        extracted = t; break
                                    }
                                    if !str.hasPrefix("{") { extracted = str; break }
                                }
                            }
                        }
                        // Ultimate fallback: any non-metadata top-level string
                        if extracted == nil {
                            let skip: Set<String> = ["tool_name", "toolname", "name", "tool", "function", "action", "confidence", "thoughts"]
                            for (key, value) in json where !skip.contains(key) {
                                if let s = value as? String, !s.isEmpty, !s.hasPrefix("{"), s.count > 3 { extracted = s; break }
                            }
                        }
                        if let extracted = extracted, !extracted.isEmpty {
                            rawAnswer = extracted
                        }
                    } else {
                        // JSON is malformed — try regex recovery for toolargs sub-object
                        let recoveredCall = parser.parse(response: rawAnswer)
                        if let first = recoveredCall.first, first.name == "response",
                           let t = first.arguments["text"], !t.isEmpty {
                            rawAnswer = t
                        }
                    }
                }

                let answer = rawAnswer
                conversationHistory.append("Assistant: \(answer)")
                // Store proper message pair for next conversation turn
                conversationMessages.append(["role": "user", "content": userMessage])
                conversationMessages.append(["role": "assistant", "content": answer])
                trimConversationMessages()
                steps.append(AgentStep(
                    stepNumber: stepCount, type: .finalAnswer,
                    content: answer, toolCallName: "response",
                    toolResultSuccess: true, timestamp: Date(),
                    confidence: confidence
                ))

                // Auto-commit memory version
                await autoCommitMemory(message: "Nach Antwort auf: \(String(userMessage.prefix(40)))")
                // Check and archive overflow blocks
                await checkAndArchiveOverflow()

                return AgentResult(finalOutput: answer, steps: steps, success: true)
            }

            // Record tool call step
            let argsJSON = (try? JSONSerialization.data(withJSONObject: parsed.arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(parsed.arguments)"
            steps.append(AgentStep(
                stepNumber: stepCount, type: .toolCall, content: argsJSON,
                toolCallName: parsed.name, toolResultSuccess: nil, timestamp: Date()
            ))

            // Append assistant turn
            messages.append(["role": "assistant", "content": llmResponse])

            // Execute the tool
            let call = parsed.toToolCall()

            if ruleEngine.isAtLimit(toolName: call.name) {
                let limitMsg = "Tool '\(call.name)' hat sein Nutzungslimit erreicht."
                messages.append(["role": "user", "content": limitMsg])
                continue
            }

            // G2: Tool-Logging mit Dauer
            let toolStart = CFAbsoluteTimeGetCurrent()
            let result = await registry.execute(call: call)
            let toolDuration = CFAbsoluteTimeGetCurrent() - toolStart
            ruleEngine.record(toolName: call.name)
            Self.onToolLog?("[\(call.name)] duration=\(String(format: "%.2f", toolDuration))s success=\(result.isSuccess) input=\(String(call.arguments.description.prefix(200))) output=\(String(result.outputOrError.prefix(500)))")

            let resultText = parser.formatToolResult(result, callId: parsed.callId, toolName: call.name)

            steps.append(AgentStep(
                stepNumber: stepCount, type: .toolResult,
                content: result.outputOrError, toolCallName: call.name,
                toolResultSuccess: result.isSuccess, timestamp: Date()
            ))

            if ruleEngine.shouldTerminate(afterCalling: call.name) {
                let answer = result.outputOrError
                return AgentResult(finalOutput: answer, steps: steps, success: result.isSuccess)
            }

            // Truncate tool result to prevent context overflow
            let truncatedResult: String
            if resultText.count > maxToolResultChars {
                truncatedResult = String(resultText.prefix(maxToolResultChars)) + "\n... (Ausgabe gekürzt, \(resultText.count) Zeichen gesamt)"
            } else {
                truncatedResult = resultText
            }

            // Feed tool result back — instruct to continue
            // Track consecutive errors to allow retries before giving up
            let consecutiveErrors = steps.suffix(6).filter { $0.type == .toolResult && $0.toolResultSuccess == false }.count
            let feedbackSuffix: String
            if result.isSuccess {
                feedbackSuffix = "Antworte jetzt als JSON. Nutze ein weiteres Tool oder antworte mit dem response-Tool."
            } else if consecutiveErrors < 3 {
                feedbackSuffix = #"Das Tool hat einen Fehler gemeldet. Analysiere den Fehler und versuche einen ANDEREN Ansatz. Du hast noch \#(3 - consecutiveErrors) Versuche. Probiere alternative Tools, andere Parameter oder einen komplett anderen Lösungsweg. Antworte als JSON."#
            } else {
                feedbackSuffix = #"Das Tool hat wiederholt Fehler gemeldet (\#(consecutiveErrors) Fehlversuche). Erkläre dem Nutzer was schiefgegangen ist und welche Ansätze du versucht hast. Antworte als JSON mit dem response-Tool. Beispiel: {"thoughts":["error analysis"],"tool_name":"response","tool_args":{"text":"Erklärung"}}"#
            }
            messages.append([
                "role": "user",
                "content": """
                \(truncatedResult)

                \(feedbackSuffix)
                """
            ])
            conversationHistory.append("Assistant (Schritt \(stepCount)): Tool '\(call.name)' ausgeführt")
            trimConversationHistory()
        }

        // Step limit reached — return last result
        let lastToolResult = steps.last(where: { $0.type == .toolResult })?.content ?? ""
        await autoCommitMemory(message: "Step-Limit erreicht")
        return AgentResult(
            finalOutput: lastToolResult.isEmpty
                ? "Aufgabe nach \(agentType.stepLimit) Schritten abgeschlossen."
                : lastToolResult,
            steps: steps,
            success: true
        )
    }

    // MARK: - Checkpoint Save/Restore

    public func saveCheckpoint(messages: [[String: String]], stepCount: Int, userMessage: String) async -> String {
        let blocks = await coreMemory.allBlocks()
        var blockMap: [String: String] = [:]
        for b in blocks { blockMap[b.label] = b.value }

        let checkpoint = AgentCheckpoint(
            agentType: agentType.rawValue,
            messages: messages,
            stepCount: stepCount,
            memoryBlocks: blockMap,
            userMessage: userMessage
        )
        await CheckpointStore.shared.save(checkpoint)
        // Prune old checkpoints periodically (fire-and-forget)
        if stepCount % 10 == 0 {
            Task { await CheckpointStore.shared.pruneOldCheckpoints(keep: 50) }
        }
        return checkpoint.id
    }

    public func resume(checkpoint: AgentCheckpoint, providerConfig: LLMProviderConfig? = nil) -> AsyncStream<AgentStep> {
        AsyncStream { continuation in
            Task {
                // Restore memory
                for (label, content) in checkpoint.memoryBlocks {
                    await self.coreMemory.upsert(MemoryBlock(label: label, value: content))
                }

                // Restore agent type
                let type: AgentType
                switch checkpoint.agentType {
                case "coder": type = .coder
                case "researcher", "web": type = .web
                case "instructor": type = .general
                default: type = .general
                }
                self.agentType = type

                // Resume from checkpoint messages
                var messages = checkpoint.messages
                let remainingSteps = type.stepLimit - checkpoint.stepCount

                for stepCount in 1...max(1, remainingSteps) {
                    let actualStep = checkpoint.stepCount + stepCount
                    let llmResponse: String
                    do {
                        if let pc = providerConfig, pc.isCloudProvider, !pc.apiKey.isEmpty {
                            llmResponse = try await llmRunner.generate(messages: messages, config: pc)
                        } else {
                            llmResponse = try await llmRunner.generate(messages: messages)
                        }
                    } catch {
                        continuation.yield(AgentStep(stepNumber: actualStep, type: .error, content: "Fehler: \(error.localizedDescription)"))
                        continuation.finish()
                        return
                    }

                    let parsedCalls = self.parser.parse(response: llmResponse)
                    if parsedCalls.isEmpty {
                        continuation.yield(AgentStep(stepNumber: actualStep, type: .finalAnswer, content: llmResponse))
                        continuation.finish()
                        return
                    }

                    guard let parsed = parsedCalls.first else { continue }
                    if !parsed.thoughts.isEmpty {
                        continuation.yield(AgentStep(stepNumber: actualStep, type: .think, content: parsed.thoughts.joined(separator: "\n"), confidence: parsed.confidence))
                    }

                    if parsed.name == "response" {
                        let answer = parsed.arguments["text"] ?? llmResponse
                        continuation.yield(AgentStep(stepNumber: actualStep, type: .finalAnswer, content: answer, toolCallName: "response", toolResultSuccess: true, confidence: parsed.confidence))
                        continuation.finish()
                        // Mark checkpoint as completed
                        var cp = checkpoint
                        cp.status = .completed
                        await CheckpointStore.shared.save(cp)
                        return
                    }

                    let argsJSON = (try? JSONSerialization.data(withJSONObject: parsed.arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(parsed.arguments)"
                    continuation.yield(AgentStep(stepNumber: actualStep, type: .toolCall, content: argsJSON, toolCallName: parsed.name))

                    messages.append(["role": "assistant", "content": llmResponse])
                    let call = parsed.toToolCall()
                    // G2: Tool-Logging mit Dauer
                    let toolStart2 = CFAbsoluteTimeGetCurrent()
                    let result = await self.registry.execute(call: call)
                    let toolDuration2 = CFAbsoluteTimeGetCurrent() - toolStart2
                    AgentLoop.onToolLog?("[\(call.name)] duration=\(String(format: "%.2f", toolDuration2))s success=\(result.isSuccess) input=\(String(call.arguments.description.prefix(200))) output=\(String(result.outputOrError.prefix(500)))")
                    let resultText = self.parser.formatToolResult(result, callId: parsed.callId, toolName: call.name)

                    continuation.yield(AgentStep(stepNumber: actualStep, type: .toolResult, content: result.outputOrError, toolCallName: call.name, toolResultSuccess: result.isSuccess))

                    let resumeFeedback = result.isSuccess
                        ? "Antworte jetzt als JSON. Nutze ein weiteres Tool oder antworte mit dem response-Tool."
                        : "Das Tool hat einen Fehler gemeldet. Erkläre dem Nutzer auf Deutsch was schiefgegangen ist und schlage Alternativen vor."
                    messages.append(["role": "user", "content": "\(resultText)\n\n\(resumeFeedback)"])
                }

                continuation.yield(AgentStep(stepNumber: checkpoint.stepCount + max(1, type.stepLimit - checkpoint.stepCount), type: .finalAnswer, content: "Checkpoint-Aufgabe abgeschlossen."))
                continuation.finish()
            }
        }
    }

    // MARK: - Memory Settings (read from UserDefaults, set by SettingsView)

    private var isMemoryAutosaveEnabled: Bool {
        if UserDefaults.standard.object(forKey: "kobold.memory.autosave") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kobold.memory.autosave")
    }

    private var isMemoryMemorizeEnabled: Bool {
        if UserDefaults.standard.object(forKey: "kobold.memory.memorizeEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kobold.memory.memorizeEnabled")
    }

    private var isMemoryConsolidationEnabled: Bool {
        if UserDefaults.standard.object(forKey: "kobold.memory.consolidation") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kobold.memory.consolidation")
    }

    private var memoryMaxSearchResults: Int {
        let v = UserDefaults.standard.integer(forKey: "kobold.memory.maxResults")
        return v > 0 ? v : 5
    }

    // MARK: - Memory Auto-Commit & Archival

    private func autoCommitMemory(message: String) async {
        guard isMemoryAutosaveEnabled else { return }
        let blocks = await coreMemory.allBlocks()
        var blockMap: [String: String] = [:]
        for b in blocks { blockMap[b.label] = b.value }
        let _ = await MemoryVersionStore.shared.commit(blocks: blockMap, message: message)
    }

    private func checkAndArchiveOverflow() async {
        guard isMemoryAutosaveEnabled else { return }
        let blocks = await coreMemory.allBlocks()
        for block in blocks where !block.readOnly && block.usagePercent > 0.8 {
            // Archive the oldest 50% of content
            let lines = block.value.components(separatedBy: "\n")
            guard lines.count > 1 else { continue }
            let splitPoint = lines.count / 2
            let toArchive = lines.prefix(splitPoint).joined(separator: "\n")
            let toKeep = lines.suffix(from: splitPoint).joined(separator: "\n")

            // Save old content to archival store
            await archivalStore.insert(label: block.label, content: toArchive)

            // Update block with remaining content
            var updated = block
            updated.value = toKeep
            await coreMemory.upsert(updated)
        }
    }

    // MARK: - Embedded Tool Call Recovery

    /// Scans response text for an embedded tool call JSON that the LLM wrapped inside a "response".
    /// Local models sometimes output: {"tool_name":"response","tool_args":{"text":"Blah {\"tool_name\":\"suno_api\",...}"}}
    /// This helper finds the actual tool call within the text.
    private func extractEmbeddedToolCall(from text: String) -> ParsedToolCall? {
        // Quick check — only scan if there's a tool_name indicator
        guard text.contains("\"tool_name\"") || text.contains("\"toolname\"") || text.contains("\"tool_name\\\"") else { return nil }

        // String-aware balanced brace extraction (handles braces inside JSON strings correctly)
        var depth = 0
        var startIdx: String.Index?
        var inString = false
        var escaped = false

        for idx in text.indices {
            let char = text[idx]
            if escaped { escaped = false; continue }
            if char == "\\" && inString { escaped = true; continue }
            if char == "\"" && !escaped { inString.toggle(); continue }
            if inString { continue }

            if char == "{" {
                if depth == 0 { startIdx = idx }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIdx {
                    let block = String(text[start...idx])
                    // Try to parse as tool call (skip "response" — that's what we're escaping FROM)
                    if let data = block.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let toolName = (json["tool_name"] as? String) ?? (json["toolname"] as? String),
                       toolName != "response" {
                        let argsObj = json["tool_args"] as? [String: Any] ?? json["toolargs"] as? [String: Any] ?? [:]
                        var strArgs: [String: String] = [:]
                        for (key, value) in argsObj {
                            if let s = value as? String { strArgs[key] = s }
                            else if let n = value as? NSNumber { strArgs[key] = n.stringValue }
                            else if let data = try? JSONSerialization.data(withJSONObject: value),
                                    let s = String(data: data, encoding: .utf8) { strArgs[key] = s }
                        }
                        let thoughts = (json["thoughts"] as? [String]) ?? []
                        return ParsedToolCall(name: toolName, arguments: strArgs, thoughts: thoughts)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Streaming Run (SSE-compatible)

    /// Runs the agent loop and yields each step as it happens, for real-time SSE streaming.
    public func runStreaming(userMessage: String, agentType: AgentType = .general, providerConfig: LLMProviderConfig? = nil) -> AsyncStream<AgentStep> {
        // P12: print() entfernt — blockierte I/O auf Hot Path
        return AsyncStream { continuation in
            Task {
              do {
                // Register continuation for sub-agent step relay (live UI streaming)
                let relayId = self.agentID
                await SubAgentStepRelay.shared.register(agentId: relayId, continuation: continuation)
                defer { Task { await SubAgentStepRelay.shared.unregister(agentId: relayId) } }
                self.agentType = agentType
                // Store provider config for sub-agent delegation
                if let pc = providerConfig, self.currentProviderConfig == nil || self.currentProviderConfig?.apiKey != pc.apiKey {
                    self.currentProviderConfig = pc
                    await self.setupTools(providerConfig: pc)
                }
                // Set Ollama model on the runner if specified (fixes model mismatch from Settings → Agenten)
                if let pc = providerConfig, !pc.model.isEmpty, pc.provider == "ollama" {
                    await llmRunner.setModel(pc.model)
                    // P12: print entfernt
                }
                conversationHistory.append("User: \(userMessage)")
                trimConversationHistory()
                ruleEngine.reset()

                let toolDescriptions = buildToolDescriptions()
                let skillsPrompt = await SkillLoader.shared.enabledSkillsPrompt()
                let initialMemory = await coreMemory.compile()

                // Autonomy / self-check prompt (same as runInner)
                let rawAutonomy = UserDefaults.standard.integer(forKey: "kobold.autonomyLevel")
                let autonomyLevel = rawAutonomy == 0 ? 2 : min(max(rawAutonomy, 1), 3)
                let selfCheckEnabled = UserDefaults.standard.bool(forKey: "kobold.perm.selfCheck")
                let selfCheckPrompt: String
                if autonomyLevel >= 3 && selfCheckEnabled {
                    selfCheckPrompt = "\n\n# Autonomer Modus\nDu bist vollständig autonom. Prüfe deine Arbeit, teste Code, korrigiere Fehler selbstständig. Frage nur bei destruktiven Aktionen (rm -rf, Daten löschen) nach."
                } else if autonomyLevel >= 2 {
                    selfCheckPrompt = "\n\n# Werkzeug-Nutzung\nDu darfst alle aktivierten Tools selbstständig nutzen ohne nachzufragen. Handle Aufgaben direkt. Frage NUR bei potenziell destruktiven Aktionen (Dateien löschen, System ändern) nach Bestätigung."
                } else {
                    selfCheckPrompt = ""
                }
                let confidencePrompt = "\n\n# Confidence Self-Assessment\nInclude a \"confidence\" field (0.0-1.0) in every JSON response. 1.0 = certain, 0.0 = unsure. If confidence < 0.5, use the response tool to ask the user for clarification instead of guessing."
                let archivalPrompt = "\n\n# Archival Memory\nWenn Core Memory Blöcke voll sind (>80% Limit), nutze archival_memory_insert um ältere Informationen zu archivieren. Nutze archival_memory_search um archivierte Informationen wieder zu finden."

                // A3: Run memory retrieval + skill search in parallel (both are independent I/O)
                async let relevantMemoriesAsync = self.smartMemoryRetrieval(query: userMessage)
                async let relevantSkillsAsync = SkillLoader.shared.relevantSkills(query: userMessage)
                let relevantMemories = await relevantMemoriesAsync
                let relevantSkillsPrompt = await relevantSkillsAsync
                let memoryRetrievalPrompt = relevantMemories.isEmpty ? "" : "\n\n## Relevante Erinnerungen (automatisch geladen)\n\(relevantMemories)"

                // Context status for LLM awareness
                let ctxTokens = lastKnownPromptTokens > 0 ? lastKnownPromptTokens : TokenEstimator.estimateTokens(messages: conversationMessages)
                let ctxPercent = Int(TokenEstimator.usagePercent(estimatedTokens: ctxTokens, contextSize: contextWindowSize) * 100)
                let contextStatusPrompt = "\n\n# Kontext-Status\nNutzung: ~\(ctxTokens) / \(contextWindowSize) Tokens (\(ctxPercent)%)"

                let sysPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: initialMemory) + skillsPrompt + selfCheckPrompt + confidencePrompt + archivalPrompt + memoryRetrievalPrompt + relevantSkillsPrompt + contextStatusPrompt

                var messages: [[String: String]] = [
                    ["role": "system", "content": sysPrompt]
                ]
                // Inject prior conversation context
                messages.append(contentsOf: self.conversationMessages)
                messages.append(["role": "user", "content": userMessage])
                var lastMemorySnapshot = initialMemory
                // Track consecutive tool failures for retry logic (mirrors runInner behavior)
                var consecutiveToolErrors = 0
                // Track LLM failures for retry-with-backoff
                var consecutiveLLMErrors = 0

                for stepCount in 1...agentType.stepLimit {
                    // Refresh memory in system prompt if it changed — only every 3rd step to reduce overhead
                    if stepCount == 1 || stepCount % 3 == 0 {
                        let freshMemory = await coreMemory.compile()
                        if freshMemory != lastMemorySnapshot {
                            lastMemorySnapshot = freshMemory
                            let freshPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: freshMemory) + skillsPrompt
                            if !messages.isEmpty { messages[0] = ["role": "system", "content": freshPrompt] }
                        }
                    }

                    // Smart context management — only every 2nd step (token estimation is expensive)
                    if stepCount == 1 || stepCount % 2 == 0 {
                        self.manageContext(&messages)
                    }

                    // UI breathing room before LLM call (lets MainActor process pending renders)
                    if stepCount > 1 {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms pause between steps
                    }

                    let llmResponse: String
                    do {
                        let msgChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
                        // P12: print entfernt — war auf Hot Path (pro LLM-Step)

                        // LLM call with per-step timeout (prevents hanging on unresponsive providers)
                        let llmTimeoutSecs: UInt64 = 180 // 3 minutes per step
                        let llmMessages = messages // Copy for sendable closure
                        let llmPC = providerConfig
                        let capturedRunner = llmRunner // Capture for sendable closure
                        let resp: LLMResponse = try await withThrowingTaskGroup(of: LLMResponse.self) { group in
                            defer { group.cancelAll() } // P12: verhindert hängende LLM-Calls
                            group.addTask {
                                if let pc = llmPC, pc.isCloudProvider, !pc.apiKey.isEmpty {
                                    return try await capturedRunner.generateWithTokens(messages: llmMessages, config: pc)
                                } else {
                                    return try await capturedRunner.generateWithTokens(messages: llmMessages)
                                }
                            }
                            group.addTask {
                                try await Task.sleep(nanoseconds: llmTimeoutSecs * 1_000_000_000)
                                throw LLMError.generationFailed("LLM-Timeout nach \(llmTimeoutSecs)s bei Step \(stepCount)")
                            }
                            guard let first = try await group.next() else {
                                throw LLMError.generationFailed("LLM lieferte kein Ergebnis")
                            }
                            return first
                        }

                        llmResponse = resp.content
                        // P12: print entfernt
                        // Update token tracking from API response
                        if let pt = resp.promptTokens { self.lastKnownPromptTokens = pt }
                        if let ct = resp.completionTokens { self.lastKnownCompletionTokens = ct }

                        // Emit context update as JSON (for SSEAccumulator parsing)
                        let ctxTokens = self.lastKnownPromptTokens > 0 ? self.lastKnownPromptTokens : TokenEstimator.estimateTokens(messages: messages)
                        let ctxCompletion = self.lastKnownCompletionTokens
                        let usagePct = TokenEstimator.usagePercent(estimatedTokens: ctxTokens, contextSize: self.contextWindowSize)
                        let ctxJSON: [String: Any] = [
                            "prompt_tokens": ctxTokens,
                            "completion_tokens": ctxCompletion,
                            "usage_percent": usagePct,
                            "context_window": self.contextWindowSize
                        ]
                        if let ctxData = try? JSONSerialization.data(withJSONObject: ctxJSON),
                           let ctxStr = String(data: ctxData, encoding: .utf8) {
                            continuation.yield(AgentStep(stepNumber: stepCount, type: .context_info, content: ctxStr))
                        }
                    } catch {
                        consecutiveLLMErrors += 1
                        // Error-Logging bleibt — selten, aber diagnostisch wichtig
                        let errorStep = AgentStep(
                            stepNumber: stepCount, type: .error,
                            content: "LLM-Fehler (Versuch \(consecutiveLLMErrors)/3): \(error.localizedDescription)",
                            toolCallName: nil, toolResultSuccess: nil, timestamp: Date()
                        )
                        continuation.yield(errorStep)
                        if consecutiveLLMErrors < 3 {
                            // Retry after short backoff — don't give up on transient errors
                            try? await Task.sleep(nanoseconds: UInt64(consecutiveLLMErrors) * 2_000_000_000)
                            continue
                        }
                        // Three consecutive LLM failures — abort
                        continuation.finish()
                        return
                    }
                    consecutiveLLMErrors = 0 // Reset on successful LLM call

                    let parsedCalls = self.parser.parse(response: llmResponse)

                    // Parser now always returns at least a "response" fallback.
                    // If the parser couldn't find a tool call, the LLM may have responded with
                    // plain text — use it directly as the final answer.
                    let fallbackText = llmResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parsed = parsedCalls.first ?? ParsedToolCall(
                        name: "response",
                        arguments: ["text": fallbackText],
                        thoughts: []
                    )
                    let confidence = parsed.confidence

                    // Yield thoughts
                    if !parsed.thoughts.isEmpty {
                        let thoughtStep = AgentStep(
                            stepNumber: stepCount, type: .think,
                            content: parsed.thoughts.joined(separator: "\n"),
                            toolCallName: nil, toolResultSuccess: nil, timestamp: Date(),
                            confidence: confidence
                        )
                        continuation.yield(thoughtStep)
                    }

                    // Check for response tool (terminal)
                    if parsed.name == "response" {
                        // Strip raw JSON if the parser returned the unprocessed LLM output as text.
                        // This happens when the LLM wraps its answer in JSON but the parser used the fallback.
                        var rawAnswer: String = {
                            for key in ["text", "content", "response", "message", "answer", "reply", "output"] {
                                if let v = parsed.arguments[key], !v.isEmpty { return v }
                            }
                            for (_, v) in parsed.arguments {
                                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty && !t.hasPrefix("{") && !t.hasPrefix("[") { return v }
                            }
                            return llmResponse
                        }()

                        // Recovery: Check for embedded tool call ANYWHERE in the text.
                        // Local models sometimes wrap tool calls in response text:
                        // {"tool_name":"response","tool_args":{"text":"Blah {\"tool_name\":\"suno_api\",...}"}}
                        if let recovered = self.extractEmbeddedToolCall(from: rawAnswer) {
                            let toolCallStep = AgentStep(
                                stepNumber: stepCount, type: .toolCall,
                                content: rawAnswer, toolCallName: recovered.name
                            )
                            continuation.yield(toolCallStep)
                            let call = ToolCall(name: recovered.name, arguments: recovered.arguments)
                            let recoveredResult: ToolResult
                            do {
                                recoveredResult = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                                    defer { group.cancelAll() }
                                    group.addTask { await self.registry.execute(call: call) }
                                    group.addTask { try await Task.sleep(nanoseconds: 300 * 1_000_000_000); throw CancellationError() }
                                    guard let first = try await group.next() else { return .failure(error: "Tool-Timeout") }
                                    return first
                                }
                            } catch {
                                recoveredResult = .failure(error: "Tool '\(call.name)' Timeout nach 300s")
                            }
                            let toolResultStep = AgentStep(
                                stepNumber: stepCount, type: .toolResult,
                                content: recoveredResult.outputOrError, toolCallName: call.name,
                                toolResultSuccess: recoveredResult.isSuccess
                            )
                            continuation.yield(toolResultStep)
                            messages.append(["role": "assistant", "content": llmResponse])
                            let resultText = self.parser.formatToolResult(recoveredResult, callId: "recovered", toolName: call.name)
                            messages.append(["role": "user", "content": resultText + "\nAntworte jetzt als JSON."])
                            continue // Continue agent loop — don't treat as final answer
                        }

                        if rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                            if let data = rawAnswer.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                // CRITICAL: Check if this is actually a tool call that the parser missed!
                                // If JSON has tool_name and it's NOT "response", re-parse as tool call
                                if let toolName = json["tool_name"] as? String, toolName != "response",
                                   let toolArgs = json["tool_args"] as? [String: Any] {
                                    let strArgs = toolArgs.compactMapValues { v -> String? in
                                        if let s = v as? String { return s }
                                        if let n = v as? NSNumber { return n.stringValue }
                                        if let data = try? JSONSerialization.data(withJSONObject: v),
                                           let s = String(data: data, encoding: .utf8) { return s }
                                        return nil
                                    }
                                    let recoveredCall = ParsedToolCall(name: toolName, arguments: strArgs, thoughts: parsed.thoughts)
                                    // Execute this tool call instead of treating it as response
                                    // P12: print entfernt
                                    let toolCallStep = AgentStep(
                                        stepNumber: stepCount, type: .toolCall,
                                        content: rawAnswer, toolCallName: toolName
                                    )
                                    continuation.yield(toolCallStep)
                                    let call = ToolCall(name: recoveredCall.name, arguments: recoveredCall.arguments)
                                    // Execute with TaskGroup timeout (same pattern as normal tool execution)
                                    let recoveredResult: ToolResult
                                    do {
                                        recoveredResult = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                                            defer { group.cancelAll() }
                                            group.addTask { await self.registry.execute(call: call) }
                                            group.addTask { try await Task.sleep(nanoseconds: 300 * 1_000_000_000); throw CancellationError() }
                                            guard let first = try await group.next() else { return .failure(error: "Tool-Timeout") }
                                            return first
                                        }
                                    } catch {
                                        recoveredResult = .failure(error: "Tool '\(call.name)' Timeout nach 300s")
                                    }
                                    let toolResultStep = AgentStep(
                                        stepNumber: stepCount, type: .toolResult,
                                        content: recoveredResult.outputOrError, toolCallName: call.name,
                                        toolResultSuccess: recoveredResult.isSuccess
                                    )
                                    continuation.yield(toolResultStep)
                                    // Add to conversation history (messages array is what runStreaming uses)
                                    messages.append(["role": "assistant", "content": rawAnswer])
                                    let resultText = self.parser.formatToolResult(recoveredResult, callId: "recovered", toolName: call.name)
                                    messages.append(["role": "user", "content": resultText])
                                    continue // Continue the agent loop — don't treat as final answer
                                }

                                var extracted: String? = nil
                                let textKeys = ["text", "content", "response", "message", "answer", "reply", "output"]
                                // Check nested args with multiple text-like keys
                                for argsKey in ["tool_args", "toolargs", "args", "arguments"] {
                                    if let args = json[argsKey] as? [String: Any] {
                                        for tk in textKeys {
                                            if let s = args[tk] as? String, !s.isEmpty { extracted = s; break }
                                        }
                                        if extracted == nil {
                                            for (_, value) in args {
                                                if let s = value as? String, !s.isEmpty, !s.hasPrefix("{") { extracted = s; break }
                                            }
                                        }
                                        if extracted != nil { break }
                                    }
                                }
                                // Top-level text keys
                                if extracted == nil {
                                    for tk in textKeys {
                                        if let s = json[tk] as? String, !s.isEmpty { extracted = s; break }
                                    }
                                }
                                // String-encoded tool_args
                                if extracted == nil {
                                    for key in ["tool_args", "toolargs", "args", "arguments"] {
                                        if let str = json[key] as? String, !str.isEmpty {
                                            if let innerData = str.data(using: .utf8),
                                               let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
                                               let t = inner["text"] as? String, !t.isEmpty {
                                                extracted = t; break
                                            }
                                            if !str.hasPrefix("{") { extracted = str; break }
                                        }
                                    }
                                }
                                // Ultimate fallback: any non-metadata string
                                if extracted == nil {
                                    let skip: Set<String> = ["tool_name", "toolname", "name", "tool", "function", "action", "confidence", "thoughts"]
                                    for (key, value) in json where !skip.contains(key) {
                                        if let s = value as? String, !s.isEmpty, !s.hasPrefix("{"), s.count > 3 { extracted = s; break }
                                    }
                                }
                                if let extracted = extracted, !extracted.isEmpty {
                                    rawAnswer = extracted
                                }
                            }
                        }
                        let answer = rawAnswer
                        conversationHistory.append("Assistant: \(answer)")
                        // Store proper message pair for next conversation turn
                        self.conversationMessages.append(["role": "user", "content": userMessage])
                        self.conversationMessages.append(["role": "assistant", "content": answer])
                        self.trimConversationMessages()
                        let finalStep = AgentStep(
                            stepNumber: stepCount, type: .finalAnswer,
                            content: answer, toolCallName: "response",
                            toolResultSuccess: true, timestamp: Date(),
                            confidence: confidence
                        )
                        continuation.yield(finalStep)
                        continuation.finish()

                        // Fire-and-forget: memory operations AFTER stream is done (non-blocking)
                        Task {
                            await self.autoCommitMemory(message: "Stream-Antwort")
                            await self.checkAndArchiveOverflow()
                        }
                        return
                    }

                    // Yield tool call step
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: parsed.arguments))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "\(parsed.arguments)"
                    let toolCallStep = AgentStep(
                        stepNumber: stepCount, type: .toolCall, content: argsJSON,
                        toolCallName: parsed.name, toolResultSuccess: nil, timestamp: Date()
                    )
                    continuation.yield(toolCallStep)

                    messages.append(["role": "assistant", "content": llmResponse])

                    let call = parsed.toToolCall()

                    if ruleEngine.isAtLimit(toolName: call.name) {
                        let limitMsg = "Tool '\(call.name)' hat sein Nutzungslimit erreicht."
                        messages.append(["role": "user", "content": limitMsg])
                        continue
                    }

                    // Yield sub-agent spawn indicator for delegation tools
                    let isSubAgent = call.name == "call_subordinate" || call.name == "delegate_parallel"
                    if isSubAgent {
                        let profile = call.arguments["profile"] ?? "general"
                        continuation.yield(AgentStep(
                            stepNumber: stepCount, type: .subAgentSpawn,
                            content: "Sub-Agent '\(profile)' gestartet...",
                            subAgentName: profile
                        ))
                    }

                    // Tool execution with timeout to prevent infinite hangs
                    // G2: Tool-Logging mit Dauer
                    let toolTimeoutSecs: UInt64 = call.name.contains("subordinate") || call.name.contains("parallel") || call.name.contains("delegate") ? 900 : 300
                    let toolStart3 = CFAbsoluteTimeGetCurrent()
                    let result: ToolResult
                    do {
                        result = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                            defer { group.cancelAll() } // P12: verhindert hängende Tool-Prozesse
                            group.addTask {
                                await self.registry.execute(call: call)
                            }
                            group.addTask {
                                try await Task.sleep(nanoseconds: toolTimeoutSecs * 1_000_000_000)
                                throw CancellationError()
                            }
                            guard let first = try await group.next() else {
                                return .failure(error: "Tool-Timeout")
                            }
                            return first
                        }
                    } catch {
                        result = .failure(error: "Tool '\(call.name)' Timeout nach \(toolTimeoutSecs)s")
                    }
                    let toolDuration3 = CFAbsoluteTimeGetCurrent() - toolStart3
                    ruleEngine.record(toolName: call.name)
                    Self.onToolLog?("[\(call.name)] duration=\(String(format: "%.2f", toolDuration3))s success=\(result.isSuccess) input=\(String(call.arguments.description.prefix(200))) output=\(String(result.outputOrError.prefix(500)))")

                    let resultText = parser.formatToolResult(result, callId: parsed.callId, toolName: call.name)

                    if isSubAgent {
                        // Yield sub-agent result as special step
                        let profile = call.arguments["profile"] ?? "general"
                        continuation.yield(AgentStep(
                            stepNumber: stepCount, type: .subAgentResult,
                            content: result.outputOrError, toolCallName: call.name,
                            toolResultSuccess: result.isSuccess,
                            subAgentName: profile
                        ))
                    } else {
                        let toolResultStep = AgentStep(
                            stepNumber: stepCount, type: .toolResult,
                            content: result.outputOrError, toolCallName: call.name,
                            toolResultSuccess: result.isSuccess
                        )
                        continuation.yield(toolResultStep)
                    }

                    // Save checkpoint every 5 steps (not every tool call — reduces disk I/O by 80%)
                    if stepCount % 5 == 0 || stepCount == 1 {
                        let cpStep = stepCount
                        let cpId = UUID().uuidString
                        continuation.yield(AgentStep(stepNumber: cpStep, type: .checkpoint, content: "Checkpoint", checkpointId: cpId))
                        let cpMessages = messages
                        let cpUser = userMessage
                        Task { [weak self] in
                            guard let self = self else { return }
                            _ = await self.saveCheckpoint(messages: cpMessages, stepCount: cpStep, userMessage: cpUser)
                        }
                    }

                    if ruleEngine.shouldTerminate(afterCalling: call.name) {
                        continuation.finish()
                        return
                    }

                    // Truncate tool result to prevent context overflow
                    let truncatedResult: String
                    if resultText.count > self.maxToolResultChars {
                        truncatedResult = String(resultText.prefix(self.maxToolResultChars)) + "\n... (Ausgabe gekürzt, \(resultText.count) Zeichen gesamt)"
                    } else {
                        truncatedResult = resultText
                    }

                    let streamFeedbackSuffix: String
                    if result.isSuccess {
                        consecutiveToolErrors = 0
                        streamFeedbackSuffix = "Antworte jetzt als JSON. Nutze ein weiteres Tool oder antworte mit dem response-Tool."
                    } else {
                        consecutiveToolErrors += 1
                        if consecutiveToolErrors < 3 {
                            // Retry — give the agent a chance to think of another approach
                            streamFeedbackSuffix = """
                            Das Tool '\(call.name)' hat einen Fehler gemeldet (\(consecutiveToolErrors). Versuch).
                            Analysiere den Fehler genau: Was ist schiefgelaufen? Warum? Was kannst du anders machen?
                            Versuche einen ANDEREN Ansatz: andere Parameter, andere Tools, andere Reihenfolge.
                            Du hast noch \(3 - consecutiveToolErrors) Versuch(e). Antworte als JSON mit dem nächsten Tool.
                            LERNE aus diesem Fehler für den nächsten Versuch.
                            """
                        } else {
                            // Three failures on this task — explain and move on
                            consecutiveToolErrors = 0
                            streamFeedbackSuffix = """
                            Nach \(consecutiveToolErrors + 3) fehlgeschlagenen Versuchen: Erkläre dem Nutzer auf Deutsch was passiert ist,
                            welche Ansätze du probiert hast und warum sie gescheitert sind.
                            Schlage alternative Wege vor die der Nutzer selbst versuchen kann.
                            Antworte mit dem response-Tool.
                            """
                        }
                    }
                    messages.append([
                        "role": "user",
                        "content": """
                        \(truncatedResult)

                        \(streamFeedbackSuffix)
                        """
                    ])
                    conversationHistory.append("Assistant (Schritt \(stepCount)): Tool '\(call.name)' ausgeführt")
                    self.trimConversationHistory()

                    // Micro-pause between tool steps — gives the UI thread breathing room
                    // Without this, back-to-back tool calls (shell, file, etc.) starve the MainActor
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                }

                // Step limit reached
                let doneStep = AgentStep(
                    stepNumber: agentType.stepLimit, type: .finalAnswer,
                    content: "Aufgabe nach \(agentType.stepLimit) Schritten abgeschlossen.",
                    toolCallName: nil, toolResultSuccess: true, timestamp: Date()
                )
                continuation.yield(doneStep)
                continuation.finish()
              } catch {
                // CRITICAL: Always finish the continuation to prevent AsyncStream from hanging forever
                // P12: print entfernt — error wird als AgentStep an UI gesendet
                continuation.yield(AgentStep(
                    stepNumber: 0, type: .error,
                    content: "Interner Fehler: \(error.localizedDescription)",
                    toolCallName: nil, toolResultSuccess: false, timestamp: Date()
                ))
                continuation.finish()
              }
            }
        }
    }

    // Legacy API compat
    public func run(prompt: String) async -> String {
        let result = try? await run(userMessage: prompt, agentType: agentType)
        return result?.finalOutput ?? "Error"
    }

    public func getSteps() -> [AgentStep] { [] }
    public func getHistory() -> [String] { conversationHistory }
    public func getTraceJSON() async -> String { "{}" }
    public func getTimelineJSON() async -> String { "{}" }

    private func buildGoalsSection() -> String {
        guard let data = UserDefaults.standard.data(forKey: "kobold.proactive.goals") else { return "" }
        // Parse GoalEntry-style JSON
        struct GoalEntry: Codable { var text: String; var isActive: Bool; var priority: String }
        if let entries = try? JSONDecoder().decode([GoalEntry].self, from: data) {
            let active = entries.filter { $0.isActive }
            guard !active.isEmpty else { return "" }
            let list = active.map { "- [\($0.priority)] \($0.text)" }.joined(separator: "\n")
            return """

        ## Langfristige Ziele (vom Nutzer definiert)
        Arbeite proaktiv auf diese Ziele hin. Schlage relevante Aktionen vor wenn passend.
        \(list)
        """
        }
        return ""
    }

    // MARK: - Tool Descriptions (AgentZero-style with JSON examples)

    private func buildConnectionsContext() -> String {
        var lines: [String] = []

        // Telegram
        let telegramToken = UserDefaults.standard.string(forKey: "kobold.telegram.token") ?? ""
        let telegramChatId = UserDefaults.standard.string(forKey: "kobold.telegram.chatId") ?? ""
        if !telegramToken.isEmpty && !telegramChatId.isEmpty {
            lines.append("- Telegram: VERBUNDEN (Chat-ID: \(telegramChatId)). Der Bot empfängt Nachrichten automatisch. Nutze telegram_send NUR für Datei-/Foto-/Audio-Versand und proaktive Benachrichtigungen. Text-Antworten auf Telegram-Nachrichten werden automatisch weitergeleitet — nutze dafür das response-Tool.")
        } else if !telegramToken.isEmpty {
            lines.append("- Telegram: Bot-Token konfiguriert, aber keine Chat-ID gesetzt. telegram_send ist eingeschränkt.")
        }

        // Google
        let googleConnected = UserDefaults.standard.bool(forKey: "kobold.google.connected")
        if googleConnected {
            let email = UserDefaults.standard.string(forKey: "kobold.google.email") ?? "unbekannt"
            // Read enabled scopes from UserDefaults
            var scopeNames: [String] = []
            if let scopeData = UserDefaults.standard.data(forKey: "kobold.google.scopes"),
               let rawScopes = try? JSONDecoder().decode(Set<String>.self, from: scopeData) {
                scopeNames = rawScopes.sorted()
            } else {
                scopeNames = ["youtube_readonly", "youtube_upload", "drive", "docs", "sheets", "gmail", "calendar", "contacts", "tasks"]
            }
            let scopeList = scopeNames.joined(separator: ", ")
            lines.append("- Google: VERBUNDEN als \(email). Aktive Scopes: \(scopeList). Nutze google_api Tool für authentifizierte API-Anfragen.")
        }

        // SoundCloud
        let scConnected = UserDefaults.standard.bool(forKey: "kobold.soundcloud.connected")
        if scConnected {
            let scUser = UserDefaults.standard.string(forKey: "kobold.soundcloud.username") ?? "unbekannt"
            lines.append("- SoundCloud: VERBUNDEN als \(scUser). Nutze soundcloud_api Tool für Tracks, Playlists, Likes, Suche und Uploads (file_path Parameter).")
        }

        // Suno
        let sunoKey = UserDefaults.standard.string(forKey: "kobold.suno.apiKey") ?? ""
        if !sunoKey.isEmpty {
            lines.append("- Suno AI: VERBUNDEN. Nutze suno_api Tool um Musik zu generieren. WICHTIG: Jede Generierung erzeugt 2 Versionen! Workflow: generate → status prüfen → get_track → BEIDE Audio-URLs herunterladen (z.B. nach ~/Desktop/).")
        }

        // Reddit
        let redditToken = UserDefaults.standard.string(forKey: "kobold.reddit.accessToken") ?? ""
        if !redditToken.isEmpty {
            let redditUser = UserDefaults.standard.string(forKey: "kobold.reddit.username") ?? "unbekannt"
            lines.append("- Reddit: VERBUNDEN als \(redditUser). Nutze reddit_api Tool für Posts, Suche, Kommentare.")
        }

        if lines.isEmpty {
            return "Keine externen Dienste verbunden."
        }
        return lines.joined(separator: "\n")
    }

    private func buildToolDescriptions() -> String {
        return """
        ### response
        Deine Endantwort an den Nutzer. Benutze dieses Tool wenn du fertig bist.
        ```json
        {"tool_name": "response", "tool_args": {"text": "Deine Antwort hier"}}
        ```

        ### shell
        Führt Shell-Befehle auf macOS aus. WICHTIG: macOS = BSD-Unix, NICHT Linux/GNU!

        macOS-spezifische Befehle:
        - Dateien suchen: mdfind "name" (Spotlight, schnell!) ODER find ~ -name "*.txt" -maxdepth 4
        - Apps öffnen: open -a "Safari" https://example.com ODER open ~/Desktop/datei.pdf
        - Clipboard: pbcopy / pbpaste (echo "text" | pbcopy)
        - Benachrichtigung: osascript -e 'display notification "Text" with title "Titel"'
        - Sprache: say "Hallo"
        - Screenshot: screencapture -x /tmp/screen.png (lautlos)
        - Einstellungen: defaults read/write com.apple.finder AppleShowAllFiles
        - Prozesse: launchctl list | grep kobold

        BSD vs GNU Unterschiede (ACHTUNG!):
        - ls -G statt ls --color (Farbe auf macOS)
        - grep -E statt grep --extended-regexp
        - sed -i '' 's/alt/neu/g' datei (leerer String nach -i erforderlich!)
        - date -v+1d statt date --date="+1 day"

        Pfade: Homeverzeichnis = /Users/username/ (NICHT /home/ — gibt es auf macOS nicht!)
        Python: python3 (nicht python), pip3 (nicht pip), /usr/bin/env python3
        Shell: /bin/zsh (Standard auf macOS), /bin/bash als Alternative
        Homebrew: /usr/local/bin/brew ODER /opt/homebrew/bin/brew (Apple Silicon)
        ```json
        {"tool_name": "shell", "tool_args": {"command": "mdfind -name 'dokument' -onlyin ~/Documents"}}
        {"tool_name": "shell", "tool_args": {"command": "ls -la ~/Desktop"}}
        {"tool_name": "shell", "tool_args": {"command": "open -a 'TextEdit' ~/Desktop/notiz.txt"}}
        {"tool_name": "shell", "tool_args": {"command": "defaults read com.apple.finder AppleShowAllFiles"}}
        ```

        ### file
        Liest, schreibt, listet Dateien. Aktionen: read, write, list, exists, delete
        ```json
        {"tool_name": "file", "tool_args": {"action": "read", "path": "~/Documents/notiz.txt"}}
        {"tool_name": "file", "tool_args": {"action": "write", "path": "~/Desktop/test.txt", "content": "Hallo Welt"}}
        {"tool_name": "file", "tool_args": {"action": "list", "path": "~/Desktop"}}
        ```

        ### browser
        Webseiten abrufen oder im Web suchen. Aktionen: fetch, search. Unterstützt GET/POST/PUT/DELETE, eigene Header und Body.
        ```json
        {"tool_name": "browser", "tool_args": {"action": "fetch", "url": "https://example.com"}}
        {"tool_name": "browser", "tool_args": {"action": "fetch", "url": "https://api.example.com/data", "method": "POST", "headers": "{\"Authorization\": \"Bearer token\"}", "body": "{\"key\": \"value\"}"}}
        {"tool_name": "browser", "tool_args": {"action": "search", "query": "macOS Swift tutorial"}}
        ```

        ### calculator
        Mathematische Ausdrücke berechnen.
        ```json
        {"tool_name": "calculator", "tool_args": {"expression": "sqrt(144) + 5^2"}}
        ```

        ### core_memory_read
        Dein Gedächtnis lesen. Ohne Parameter = alle Blöcke anzeigen.
        ```json
        {"tool_name": "core_memory_read", "tool_args": {}}
        {"tool_name": "core_memory_read", "tool_args": {"label": "human"}}
        ```

        ### core_memory_append
        Information im Gedächtnis speichern.
        Labels: "human" (Langzeit-Fakten), "short_term" (aktueller Kontext), "knowledge" (gelernte Lösungen), "persona" (Selbstbild)
        ```json
        {"tool_name": "core_memory_append", "tool_args": {"label": "human", "content": "Der Nutzer heißt Tim"}}
        {"tool_name": "core_memory_append", "tool_args": {"label": "short_term", "content": "Arbeitet gerade an: iOS App Projekt"}}
        {"tool_name": "core_memory_append", "tool_args": {"label": "knowledge", "content": "Python venv erstellen: python3 -m venv .venv && source .venv/bin/activate"}}
        ```

        ### core_memory_replace
        Gespeicherte Information aktualisieren.
        ```json
        {"tool_name": "core_memory_replace", "tool_args": {"label": "human", "old_content": "alter Text", "new_content": "neuer Text"}}
        ```

        ### skill_write
        Skills erstellen, auflisten oder löschen. Skills sind Markdown-Dateien die dein Verhalten erweitern.
        ```json
        {"tool_name": "skill_write", "tool_args": {"action": "create", "name": "freundlich", "content": "# Freundlich\\nSei immer freundlich und hilfsbereit."}}
        {"tool_name": "skill_write", "tool_args": {"action": "list"}}
        {"tool_name": "skill_write", "tool_args": {"action": "delete", "name": "freundlich"}}
        ```

        ### task_manage
        Geplante Aufgaben erstellen, auflisten, aktualisieren oder löschen.
        ```json
        {"tool_name": "task_manage", "tool_args": {"action": "create", "name": "Nachrichten", "prompt": "Fasse die wichtigsten Nachrichten zusammen", "schedule": "0 8 * * *"}}
        {"tool_name": "task_manage", "tool_args": {"action": "list"}}
        {"tool_name": "task_manage", "tool_args": {"action": "update", "id": "abc123", "enabled": "false"}}
        {"tool_name": "task_manage", "tool_args": {"action": "delete", "id": "abc123"}}
        ```

        ### workflow_manage
        Visuelle Workflows mit Nodes, Connections und Triggern erstellen. Erstelle zuerst ein Projekt, dann füge Nodes hinzu und verbinde sie.

        Projekt erstellen:
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "create_project", "name": "Email Workflow", "description": "Automatisierte Email-Verarbeitung"}}
        ```

        Nodes hinzufügen (werden automatisch verbunden und positioniert):
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "add_node", "project_id": "abc123", "node_type": "Trigger", "title": "Start"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "add_node", "project_id": "abc123", "node_type": "Agent", "title": "Analysiere", "prompt": "Analysiere die eingehende Email", "agent_type": "web"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "add_node", "project_id": "abc123", "node_type": "Agent", "title": "Antworte", "prompt": "Schreibe eine Antwort", "agent_type": "coder", "model_override": "gpt-4o"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "add_node", "project_id": "abc123", "node_type": "Output", "title": "Ergebnis"}}
        ```

        Node-Typen: Trigger, Input, Agent, Tool, Output, Condition, Merger, Delay, Webhook, Formula
        Agent-Typen: general, coder, web

        Nodes manuell verbinden:
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "connect", "project_id": "abc123", "source_node_id": "node1", "target_node_id": "node2"}}
        ```

        Trigger konfigurieren (Manual, Zeitplan, Webhook, Datei-Watcher, App-Event):
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "set_trigger", "project_id": "abc123", "node_id": "trigger1", "trigger_type": "Zeitplan", "cron_expression": "0 8 * * *"}}
        ```

        Nodes auflisten, löschen, Workflow ausführen:
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "list_nodes", "project_id": "abc123"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "delete_node", "project_id": "abc123", "node_id": "xyz"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "run", "project_id": "abc123"}}
        ```

        ### call_subordinate
        Delegiere eine Aufgabe an einen spezialisierten Sub-Agenten. Der Sub-Agent arbeitet autonom mit eigenen Tools.

        Verfügbare Profile und ihre Spezialisierung:
        - **coder** / **developer**: Software-Entwicklung, Code schreiben, Debugging, Architektur
        - **web**: Recherche, Web-Suche, API-Aufrufe, Browser-Automatisierung, Daten-Analyse
        - **reviewer**: Code-Review, Qualitätsprüfung (nutzt Coder-Tools)
        - **utility**: System-Aufgaben, Dateiverwaltung, Shell-Befehle
        - **general**: Allgemeine Aufgaben (Standard)

        Wähle das richtige Profil für die jeweilige Aufgabe:
        ```json
        {"tool_name": "call_subordinate", "tool_args": {"profile": "coder", "message": "Rolle: Senior Developer. Aufgabe: Schreibe eine Python-Funktion die Fibonacci berechnet."}}
        {"tool_name": "call_subordinate", "tool_args": {"profile": "web", "message": "Recherchiere aktuelle Swift 6 Concurrency Best Practices und fasse zusammen."}}
        {"tool_name": "call_subordinate", "tool_args": {"profile": "reviewer", "message": "Prüfe diesen Code auf Bugs und Sicherheitslücken: ..."}}
        ```

        ### delegate_parallel
        Delegiere mehrere Aufgaben gleichzeitig an verschiedene Sub-Agenten. Alle laufen parallel.
        ```json
        {"tool_name": "delegate_parallel", "tool_args": {"tasks": "[{\\"profile\\": \\"coder\\", \\"message\\": \\"Schreibe Tests\\"}, {\\"profile\\": \\"web\\", \\"message\\": \\"Recherchiere Best Practices\\"}]"}}
        ```

        ### memory_save
        Speichere eine einzelne Erinnerung mit Tags. BEVORZUGE dieses Tool für neue Erinnerungen!
        Typen: "langzeit" (Fakten über Nutzer), "kurzzeit" (aktueller Kontext), "wissen" (gelernte Lösungen)
        ```json
        {"tool_name": "memory_save", "tool_args": {"text": "Tim ist Entwickler und arbeitet an KoboldOS", "type": "langzeit", "tags": "persönlich,beruf"}}
        {"tool_name": "memory_save", "tool_args": {"text": "Python venv: python3 -m venv .venv && source .venv/bin/activate", "type": "wissen", "tags": "python,entwicklung,snippet"}}
        {"tool_name": "memory_save", "tool_args": {"text": "Arbeitet gerade an Memory-System Verbesserung", "type": "kurzzeit", "tags": "projekt,aktuell"}}
        ```

        ### memory_recall
        Durchsuche alle Erinnerungen nach Text, Typ oder Tags.
        ```json
        {"tool_name": "memory_recall", "tool_args": {"query": "Python venv"}}
        {"tool_name": "memory_recall", "tool_args": {"query": "", "type": "langzeit"}}
        {"tool_name": "memory_recall", "tool_args": {"query": "API", "tags": "coding"}}
        ```

        ### memory_forget
        Lösche eine einzelne Erinnerung anhand ihrer ID.
        ```json
        {"tool_name": "memory_forget", "tool_args": {"id": "abc-123-def"}}
        ```

        ### archival_memory_search
        Durchsuche archivierte Erinnerungen die aus dem Core Memory ausgelagert wurden.
        ```json
        {"tool_name": "archival_memory_search", "tool_args": {"query": "API key für OpenAI"}}
        {"tool_name": "archival_memory_search", "tool_args": {"query": "Python venv", "label": "knowledge"}}
        ```

        ### archival_memory_insert
        Speichere Informationen im Archiv für langfristige Aufbewahrung.
        ```json
        {"tool_name": "archival_memory_insert", "tool_args": {"label": "knowledge", "content": "macOS: screencapture -x für lautlose Screenshots"}}
        ```

        ### notify_user
        Sende eine macOS Push-Benachrichtigung an den Nutzer.
        ```json
        {"tool_name": "notify_user", "tool_args": {"title": "Aufgabe erledigt", "body": "Die Datei wurde erfolgreich erstellt."}}
        ```

        ### calendar
        Kalender-Events und Erinnerungen verwalten (Apple EventKit).
        ```json
        {"tool_name": "calendar", "tool_args": {"action": "list_events", "days": 7}}
        {"tool_name": "calendar", "tool_args": {"action": "create_event", "title": "Meeting mit Team", "start": "2026-02-23T14:00:00", "end": "2026-02-23T15:00:00", "location": "Büro"}}
        {"tool_name": "calendar", "tool_args": {"action": "search_events", "query": "Zahnarzt"}}
        {"tool_name": "calendar", "tool_args": {"action": "list_reminders"}}
        {"tool_name": "calendar", "tool_args": {"action": "create_reminder", "title": "Einkaufen gehen", "notes": "Milch, Brot, Käse"}}
        ```

        ### contacts
        Kontakte durchsuchen (Apple Contacts).
        ```json
        {"tool_name": "contacts", "tool_args": {"action": "search", "query": "Tim"}}
        {"tool_name": "contacts", "tool_args": {"action": "list_recent"}}
        ```

        ### applescript
        Steuere macOS-Apps (Safari, Messages, Mail, Notizen) via AppleScript.
        ```json
        {"tool_name": "applescript", "tool_args": {"app": "safari", "action": "open_url", "params": "{\\"url\\": \\"https://example.com\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "safari", "action": "get_tabs"}}
        {"tool_name": "applescript", "tool_args": {"app": "messages", "action": "send_message", "params": "{\\"to\\": \\"+49123456\\", \\"text\\": \\"Hallo!\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "messages", "action": "read_recent", "params": "{\\"count\\": \\"5\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "mail", "action": "send_email", "params": "{\\"to\\": \\"test@example.com\\", \\"subject\\": \\"Betreff\\", \\"body\\": \\"Inhalt\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "mail", "action": "read_inbox", "params": "{\\"count\\": \\"5\\"}"}}
        ```

        Für Apple Notizen und Mail nutze AppleScript direkt über das shell-Tool:
        ```json
        {"tool_name": "shell", "tool_args": {"command": "osascript -e 'tell application \\"Notes\\" to get name of every note of default account'"}}
        {"tool_name": "shell", "tool_args": {"command": "osascript -e 'tell application \\"Notes\\" to get body of note \\"Einkaufsliste\\" of default account'"}}
        {"tool_name": "shell", "tool_args": {"command": "osascript -e 'tell application \\"Notes\\" to tell default account to make new note at folder \\"Notizen\\" with properties {name:\\"Titel\\", body:\\"Inhalt\\"}'"}}
        ```

        ### google_api
        Authentifizierte Google-API-Anfragen (YouTube, Drive, Gmail, Calendar, Sheets, Docs, Contacts, Tasks).
        Token wird automatisch geladen und bei Bedarf erneuert.
        Base-URL: https://www.googleapis.com/ — gib nur den Pfad danach an.
        WICHTIG: Für Datei-Uploads (YouTube-Video, Drive) nutze den file_path Parameter mit absolutem Pfad.
        ```json
        {"tool_name": "google_api", "tool_args": {"endpoint": "youtube/v3/search", "method": "GET", "params": "{\\"part\\": \\"snippet\\", \\"q\\": \\"Swift Tutorial\\", \\"maxResults\\": \\"5\\"}"}}
        {"tool_name": "google_api", "tool_args": {"endpoint": "upload/youtube/v3/videos", "method": "POST", "params": "{\\"part\\": \\"snippet,status\\"}", "body": "{\\"snippet\\":{\\"title\\":\\"Mein Video\\",\\"description\\":\\"Beschreibung\\",\\"tags\\":[\\"tag1\\"]},\\"status\\":{\\"privacyStatus\\":\\"private\\"}}", "file_path": "/Users/tim/Desktop/video.mp4"}}
        {"tool_name": "google_api", "tool_args": {"endpoint": "upload/drive/v3/files", "method": "POST", "body": "{\\"name\\":\\"dokument.pdf\\"}", "file_path": "/Users/tim/Documents/dokument.pdf"}}
        {"tool_name": "google_api", "tool_args": {"endpoint": "drive/v3/files", "method": "GET", "params": "{\\"pageSize\\": \\"10\\", \\"fields\\": \\"files(id,name,mimeType)\\"}"}}
        {"tool_name": "google_api", "tool_args": {"endpoint": "gmail/v1/users/me/messages", "method": "GET", "params": "{\\"maxResults\\": \\"5\\"}"}}
        {"tool_name": "google_api", "tool_args": {"endpoint": "calendar/v3/calendars/primary/events", "method": "GET", "params": "{\\"maxResults\\": \\"10\\", \\"orderBy\\": \\"startTime\\", \\"singleEvents\\": \\"true\\", \\"timeMin\\": \\"2026-02-22T00:00:00Z\\"}"}}
        ```

        ### soundcloud_api
        SoundCloud: Tracks lesen/suchen/hochladen, Playlists, Likes, User-Info.
        Base-URL: https://api.soundcloud.com/ — gib nur den Pfad danach an.
        WICHTIG: Für Uploads nutze file_path + title Parameter. Unterstützt mp3, wav, flac, ogg, aac.
        ```json
        {"tool_name": "soundcloud_api", "tool_args": {"endpoint": "me", "method": "GET"}}
        {"tool_name": "soundcloud_api", "tool_args": {"endpoint": "me/tracks", "method": "GET"}}
        {"tool_name": "soundcloud_api", "tool_args": {"endpoint": "tracks", "method": "GET", "params": "{\\"q\\": \\"psytrance\\", \\"limit\\": \\"10\\"}"}}
        {"tool_name": "soundcloud_api", "tool_args": {"endpoint": "tracks", "method": "POST", "file_path": "/Users/tim/Desktop/track.mp3", "title": "Mein Track", "genre": "Psytrance", "tags": "electronic, dark", "sharing": "private"}}
        ```

        ### telegram_send
        Sende Dateien, Fotos und Audio über Telegram, oder proaktive Benachrichtigungen.
        WICHTIG: Wenn der Nutzer ÜBER Telegram schreibt, antworte mit dem response-Tool — die Antwort wird automatisch weitergeleitet! Nutze telegram_send in diesem Fall NUR für Datei-/Foto-/Audio-Versand.
        Nutze send_text NUR für proaktive Benachrichtigungen (Cron-Tasks, Erinnerungen) oder wenn der Nutzer explizit sagt "schick mir das auf Telegram".
        Aktionen: send_text (proaktive Nachricht), send_file (beliebige Datei), send_photo (Bild), send_audio (Audio/Musik).
        Für Dateien: file_path = absoluter Pfad. Caption optional über message Parameter.
        ```json
        {"tool_name": "telegram_send", "tool_args": {"action": "send_text", "message": "Dein Cron-Task ist fertig: 3 neue Tech-News gefunden."}}
        {"tool_name": "telegram_send", "tool_args": {"action": "send_file", "file_path": "/Users/tim/Desktop/dokument.pdf", "message": "Hier ist dein Dokument"}}
        {"tool_name": "telegram_send", "tool_args": {"action": "send_photo", "file_path": "/Users/tim/Desktop/screenshot.png"}}
        {"tool_name": "telegram_send", "tool_args": {"action": "send_audio", "file_path": "/Users/tim/Desktop/song.mp3", "message": "Dein generiertes Lied"}}
        ```

        ### suno_api
        Musik generieren mit Suno AI. WICHTIG: Jede Generierung erzeugt 2 Versionen!
        Workflow: 1) generate → taskId, 2) status prüfen (PENDING → SUCCESS), 3) get_track → BEIDE audio_url Werte per shell/curl herunterladen.
        Lade IMMER beide Versionen herunter, z.B. nach ~/Desktop/songname_v1.mp3 und ~/Desktop/songname_v2.mp3.
        ```json
        {"tool_name": "suno_api", "tool_args": {"action": "generate", "prompt": "Ein fröhlicher Popsong über den Sommer"}}
        {"tool_name": "suno_api", "tool_args": {"action": "generate", "style": "psytrance", "title": "Digital Dreams", "instrumental": "true", "model": "V4"}}
        {"tool_name": "suno_api", "tool_args": {"action": "status", "task_id": "abc123"}}
        {"tool_name": "suno_api", "tool_args": {"action": "get_track", "task_id": "abc123"}}
        ```

        ### reddit_api
        Reddit: Posts suchen/lesen, kommentieren, Subreddit-Info.
        ```json
        {"tool_name": "reddit_api", "tool_args": {"action": "hot", "subreddit": "programming", "limit": "5"}}
        {"tool_name": "reddit_api", "tool_args": {"action": "search", "query": "SwiftUI tutorial", "subreddit": "swift"}}
        {"tool_name": "reddit_api", "tool_args": {"action": "read_post", "post_id": "1abc23"}}
        {"tool_name": "reddit_api", "tool_args": {"action": "comment", "post_id": "1abc23", "text": "Guter Post!"}}
        {"tool_name": "reddit_api", "tool_args": {"action": "user_info"}}
        ```

        ### speak
        Lies Text laut vor (Text-to-Speech). Nutze dieses Tool wenn der Nutzer sagt "lies vor", "sag mir", "vorlesen", "sprich" oder ähnliches.
        Args: text (erforderlich), voice (optional, z.B. "de-DE", "en-US"), rate (optional, 0.1-1.0)
        ```json
        {"tool_name": "speak", "tool_args": {"text": "Hallo! Ich bin dein KoboldOS Assistent."}}
        {"tool_name": "speak", "tool_args": {"text": "The weather is nice today.", "voice": "en-US"}}
        {"tool_name": "speak", "tool_args": {"text": "Wichtige Nachricht!", "rate": "0.4"}}
        ```
        """
    }

    // MARK: - Smart Memory Retrieval

    private let memoryStore = MemoryStore()

    /// Search memories relevant to the user's query using semantic RAG (Ollama embeddings).
    /// Falls back to TF-IDF if the embedding model is unavailable.
    private func smartMemoryRetrieval(query: String, limit: Int = 5) async -> String {
        guard !query.isEmpty else { return "" }

        // --- Semantic RAG path ---
        if let queryEmb = await EmbeddingRunner.shared.embed(query) {
            let hits = await EmbeddingStore.shared.search(queryEmbedding: queryEmb, limit: limit)
            if !hits.isEmpty {
                return hits.map { h in
                    let tags = h.tags.isEmpty ? "" : " [\(h.tags.joined(separator: ", "))]"
                    return "- (\(h.memoryType))\(tags) \(h.text)"
                }.joined(separator: "\n")
            }
        }

        // --- Fallback: TF-IDF ---
        // P12: print entfernt
        do {
            let results = try await memoryStore.smartSearch(query: query, limit: limit)
            guard !results.isEmpty else { return "" }
            return results.map { entry in
                let tags = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ", "))]"
                return "- (\(entry.memoryType))\(tags) \(entry.text)"
            }.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    // MARK: - System Prompt (AgentZero-style JSON communication)

    private func buildSystemPrompt(toolDescriptions: String, compiledMemory: String) -> String {
        let memorySection = compiledMemory.isEmpty ? "" : """

        ## Dein Gedächtnis
        \(compiledMemory)
        """

        // Agent personality from settings (read both old and new keys for compatibility)
        let soul = UserDefaults.standard.string(forKey: "kobold.agent.soul") ?? ""
        let personality = UserDefaults.standard.string(forKey: "kobold.agent.personality")
            ?? UserDefaults.standard.string(forKey: "kobold.personality") ?? ""
        let tone = UserDefaults.standard.string(forKey: "kobold.agent.tone") ?? "freundlich"
        let agentLang = UserDefaults.standard.string(forKey: "kobold.agent.language") ?? "deutsch"
        let verbosity = UserDefaults.standard.double(forKey: "kobold.agent.verbosity")
        let userName = UserDefaults.standard.string(forKey: "kobold.userName") ?? ""

        let memoryPolicy = UserDefaults.standard.string(forKey: "kobold.agent.memoryPolicy") ?? "auto"
        let behaviorRules = UserDefaults.standard.string(forKey: "kobold.agent.behaviorRules") ?? ""
        let memoryRules = UserDefaults.standard.string(forKey: "kobold.agent.memoryRules") ?? ""

        let personalitySection = (soul.isEmpty && personality.isEmpty) ? "" : """

        ## Persönlichkeit
        \(soul.isEmpty ? "" : "Kernidentität: \(soul)")
        \(personality.isEmpty ? "" : "Verhaltensstil: \(personality)")
        Tonfall: \(tone)
        Ausführlichkeit: \(verbosity > 0.7 ? "ausführlich" : verbosity < 0.3 ? "kurz und knapp" : "normal")
        """

        let memoryPolicySection: String = {
            switch memoryPolicy {
            case "auto":
                return "\n## Gedächtnis-Richtlinie\nSpeichere automatisch wichtige Fakten über den Nutzer und gelernte Lösungen in deinem Gedächtnis. Du MUSST aktiv core_memory_append/replace nutzen."
            case "ask":
                return "\n## Gedächtnis-Richtlinie\nFrage den Nutzer IMMER bevor du etwas ins Gedächtnis schreibst. Sage z.B. 'Soll ich mir merken, dass...?'"
            case "manual":
                return "\n## Gedächtnis-Richtlinie\nSchreibe NICHTS eigenständig ins Gedächtnis. Nur wenn der Nutzer explizit sagt 'Merk dir...' oder 'Speichere...'."
            case "disabled":
                return "\n## Gedächtnis-Richtlinie\nGedächtnis ist deaktiviert. Benutze KEINE Memory-Tools."
            default:
                return ""
            }
        }()

        let behaviorRulesSection = behaviorRules.isEmpty ? "" : """

        ## Verhaltensregeln (vom Nutzer definiert — IMMER befolgen!)
        \(behaviorRules)
        """

        let memoryRulesSection = memoryRules.isEmpty ? "" : """

        ## Gedächtnis-Regeln (vom Nutzer definiert — IMMER befolgen!)
        \(memoryRules)
        """

        // Current model + identity info for self-awareness
        let currentModel = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "unbekannt"
        let koboldName = UserDefaults.standard.string(forKey: "kobold.koboldName") ?? "KoboldOS"
        let koboldVersion = "v0.3.4"

        let userGreeting = userName.isEmpty ? "" : "\nDer Nutzer heißt \(userName)."

        return """
        Dein Name ist \(koboldName). Dein Core ist KoboldOS \(koboldVersion), ein lokaler KI-Agent auf macOS. Dein Sprachmodell: \(currentModel) (via Ollama, lokal auf diesem Mac).
        Sprache: \(agentLang == "auto" ? "Sprache des Nutzers" : agentLang.isEmpty ? "Deutsch" : agentLang.capitalized). Tonfall: \(tone).\(userGreeting)
        Arbeitsverzeichnis: \(UserDefaults.standard.string(forKey: "kobold.defaultWorkDir") ?? "~/Documents/KoboldOS")
        WebGUI-Dateien: ~/Library/Application Support/KoboldOS/webgui/ (index.html etc. — du kannst diese Dateien mit file_read/file_write bearbeiten, um die Web-Oberfläche anzupassen)
        \(personalitySection)\(memoryPolicySection)\(behaviorRulesSection)\(memoryRulesSection)\(buildGoalsSection())

        ## Verbindungen
        \(buildConnectionsContext())

        # Kernregeln
        - Du erinnerst dich an den gesamten Gesprächsverlauf. Löse Bezüge ("das", "sie", "die Datei") aus dem Kontext auf.
        - Sage NIEMALS "das kann ich nicht". Du hast eine vollständige macOS-Shell + Tools. Es gibt IMMER einen Weg.
        - Arbeite Aufgaben komplett ab. Gehe nicht idle. Speichere wichtige Erkenntnisse mit memory_save.
        - Wenn ein Weg fehlschlägt: probiere einen anderen. Nutze `man`, `--help`, oder Web-Suche.

        # Antwortformat
        IMMER JSON: {"thoughts":["..."],"tool_name":"...","tool_args":{...}}
        - Nutzer antworten: NUR über "response" Tool (einziger Weg, den der Nutzer sieht)
        - Pro Antwort EIN Tool, dann auf Ergebnis warten
        - Zeige dem Nutzer NIEMALS JSON oder technische Fehlermeldungen direkt

        # CLI-Befehle
        Wenn die Nachricht ein Terminal-Befehl ist (git, ls, brew, python, etc.): SOFORT shell ausführen, nicht erklären.

        # Gedächtnis
        memory_save: Einzelne Erinnerung mit Typ (langzeit/kurzzeit/wissen) + Tags speichern
        memory_recall: Nach Text/Typ/Tags suchen | memory_forget: Löschen
        EINE Erinnerung pro Fakt. Gute Tags wählen (persönlich, coding, projekt, etc.)\(isMemoryMemorizeEnabled ? "" : "\nGedächtnis DEAKTIVIERT — nur speichern wenn Nutzer es verlangt.")

        # Delegation
        call_subordinate: Sub-Agent (coder/web/reviewer/utility) | delegate_parallel: Mehrere gleichzeitig

        # Fehlerbehandlung
        Bei Fehler: Erkläre auf Deutsch über response Tool, nenne Grund, schlage Alternativen vor.

        # Quellen
        Wenn du Informationen aus Web-Recherchen verwendest, bette die Quellen-URLs als Markdown-Links in deine Antwort ein.
        Format: [Beschreibung](URL). Platziere Links natuerlich im Text oder als "Quellen:"-Abschnitt am Ende.

        \(memorySection)

        # Verfügbare Tools
        \(toolDescriptions)
        """
    }
}
