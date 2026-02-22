import Foundation

// MARK: - Agent Type

public enum AgentType: String, Sendable {
    case researcher = "researcher"
    case coder      = "coder"
    case general    = "general"
    case instructor = "instructor"
    case planner    = "planner"

    public var stepLimit: Int {
        switch self {
        case .researcher: return 20
        case .coder:      return 15
        case .instructor: return 12
        case .general:    return 10
        case .planner:    return 8
        }
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
    public let coreMemory: CoreMemory
    private var ruleEngine: ToolRuleEngine
    private var conversationHistory: [String] = []
    private let maxConversationHistory = 50
    private var agentType: AgentType = .general
    private var currentProviderConfig: LLMProviderConfig?

    /// Maximum number of message pairs (assistant+user) to keep in context window.
    /// System prompt + original user message are always preserved.
    private let maxContextMessages = 20

    public init(agentID: String = "default") {
        self.registry = ToolRegistry()
        self.parser = ToolCallParser()
        self.coreMemory = CoreMemory(agentID: agentID)
        self.ruleEngine = .default

        Task {
            await self.setupTools()
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
        // Memory tools
        await registry.register(CoreMemoryReadTool(memory: coreMemory))
        await registry.register(CoreMemoryAppendTool(memory: coreMemory))
        await registry.register(CoreMemoryReplaceTool(memory: coreMemory))
        // Archival memory tools (Letta/MemGPT paging)
        await registry.register(ArchivalMemorySearchTool(store: archivalStore))
        await registry.register(ArchivalMemoryInsertTool(store: archivalStore))
        // Management tools
        await registry.register(SkillWriteTool())
        await registry.register(TaskManageTool())
        await registry.register(WorkflowManageTool())
        // New tools
        await registry.register(NotifyTool())
        await registry.register(AppleScriptTool())
        // Sub-agent delegation (AgentZero-style call_subordinate) — pass provider config
        await registry.register(DelegateTaskTool(providerConfig: providerConfig))
        await registry.register(DelegateParallelTool(providerConfig: providerConfig))
    }

    // MARK: - Configuration

    public func setAgentType(_ type: AgentType) {
        agentType = type
        switch type {
        case .researcher: ruleEngine = .research
        case .coder:      ruleEngine = .coder
        default:          ruleEngine = .default
        }
    }

    public func setSystemPrompt(_ p: String) { /* stored in coreMemory persona block */ }
    public func clearHistory() { conversationHistory = [] }

    /// Trim conversation history to prevent unbounded memory growth
    private func trimConversationHistory() {
        if conversationHistory.count > maxConversationHistory {
            conversationHistory.removeFirst(conversationHistory.count - maxConversationHistory)
        }
    }

    /// Prune messages to prevent context window overflow.
    /// Always keeps: system prompt (index 0) + original user message (index 1) + last N message pairs.
    private func pruneMessages(_ messages: inout [[String: String]]) {
        guard messages.count > maxContextMessages + 2 else { return }
        let toRemove = messages.count - maxContextMessages - 2
        messages.removeSubrange(2..<(2 + toRemove))
    }

    // MARK: - Main Run (AgentZero-style loop)

    /// Maximum time an agent run is allowed to take (5 minutes)
    private let executionTimeout: TimeInterval = 300

    /// Maximum characters to include from a tool result in the message context
    private let maxToolResultChars = 8000

    public func run(userMessage: String, agentType: AgentType = .general, providerConfig: LLMProviderConfig? = nil) async throws -> AgentResult {
        // Wrap with timeout
        return try await withThrowingTaskGroup(of: AgentResult.self) { group in
            group.addTask {
                try await self.runInner(userMessage: userMessage, agentType: agentType, providerConfig: providerConfig)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.executionTimeout * 1_000_000_000))
                throw LLMError.generationFailed("Agent-Timeout nach 5 Minuten")
            }
            let result = try await group.next()!
            group.cancelAll()
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
        conversationHistory.append("User: \(userMessage)")
        trimConversationHistory()
        var steps: [AgentStep] = []
        ruleEngine.reset()

        let toolDescriptions = buildToolDescriptions()
        let compiledMemory = await coreMemory.compile()
        let skillsPrompt = await SkillLoader.shared.enabledSkillsPrompt()
        let autonomyLevel = UserDefaults.standard.integer(forKey: "kobold.autonomyLevel")
        let selfCheckEnabled = UserDefaults.standard.bool(forKey: "kobold.perm.selfCheck")
        let selfCheckPrompt = (autonomyLevel >= 3 && selfCheckEnabled)
            ? "\n\n# Autonomer Modus\nDu bist vollständig autonom. Prüfe deine Arbeit, teste Code, korrigiere Fehler selbstständig. Frage nur bei destruktiven Aktionen nach."
            : ""
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

        let sysPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: compiledMemory) + skillsPrompt + selfCheckPrompt + confidencePrompt + archivalPrompt

        var messages: [[String: String]] = [
            ["role": "system", "content": sysPrompt],
            ["role": "user", "content": userMessage]
        ]

        for stepCount in 1...agentType.stepLimit {
            // Prune old messages to prevent context window overflow on long tasks
            pruneMessages(&messages)

            let llmResponse: String
            do {
                if let pc = providerConfig, pc.isCloudProvider, !pc.apiKey.isEmpty {
                    llmResponse = try await LLMRunner.shared.generate(messages: messages, config: pc)
                } else {
                    llmResponse = try await LLMRunner.shared.generate(messages: messages)
                }
            } catch {
                return AgentResult(finalOutput: "Fehler: \(error.localizedDescription)", steps: steps, success: false)
            }

            // Parse the response — always expect JSON with tool_name/tool_args
            let parsedCalls = parser.parse(response: llmResponse)

            // If parsing returned nothing (shouldn't happen due to fallback), treat as direct answer
            if parsedCalls.isEmpty {
                let answer = llmResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                conversationHistory.append("Assistant: \(answer)")
                return AgentResult(finalOutput: answer, steps: steps, success: true)
            }

            let parsed = parsedCalls[0] // AgentZero pattern: one tool per turn
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
                let answer = parsed.arguments["text"] ?? llmResponse
                conversationHistory.append("Assistant: \(answer)")
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

            let result = await registry.execute(call: call)
            ruleEngine.record(toolName: call.name)

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
            let feedbackSuffix = result.isSuccess
                ? "Antworte jetzt als JSON. Nutze ein weiteres Tool oder antworte mit dem response-Tool."
                : "Das Tool hat einen Fehler gemeldet. Erkläre dem Nutzer auf Deutsch was schiefgegangen ist und schlage Alternativen vor. Gib KEINEN rohen JSON aus."
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
                case "researcher": type = .researcher
                case "planner": type = .planner
                case "instructor": type = .instructor
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
                            llmResponse = try await LLMRunner.shared.generate(messages: messages, config: pc)
                        } else {
                            llmResponse = try await LLMRunner.shared.generate(messages: messages)
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

                    let parsed = parsedCalls[0]
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
                    let result = await self.registry.execute(call: call)
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

    // MARK: - Memory Auto-Commit & Archival

    private func autoCommitMemory(message: String) async {
        let blocks = await coreMemory.allBlocks()
        var blockMap: [String: String] = [:]
        for b in blocks { blockMap[b.label] = b.value }
        let _ = await MemoryVersionStore.shared.commit(blocks: blockMap, message: message)
    }

    private func checkAndArchiveOverflow() async {
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

    // MARK: - Streaming Run (SSE-compatible)

    /// Runs the agent loop and yields each step as it happens, for real-time SSE streaming.
    public func runStreaming(userMessage: String, agentType: AgentType = .general, providerConfig: LLMProviderConfig? = nil) -> AsyncStream<AgentStep> {
        AsyncStream { continuation in
            Task {
                self.agentType = agentType
                // Store provider config for sub-agent delegation
                if let pc = providerConfig, self.currentProviderConfig == nil || self.currentProviderConfig?.apiKey != pc.apiKey {
                    self.currentProviderConfig = pc
                    await self.setupTools(providerConfig: pc)
                }
                conversationHistory.append("User: \(userMessage)")
                ruleEngine.reset()

                let toolDescriptions = buildToolDescriptions()
                let compiledMemory = await coreMemory.compile()
                let skillsPrompt = await SkillLoader.shared.enabledSkillsPrompt()
                let sysPrompt = buildSystemPrompt(toolDescriptions: toolDescriptions, compiledMemory: compiledMemory) + skillsPrompt

                var messages: [[String: String]] = [
                    ["role": "system", "content": sysPrompt],
                    ["role": "user", "content": userMessage]
                ]

                for stepCount in 1...agentType.stepLimit {
                    // Prune old messages to prevent context window overflow on long tasks
                    self.pruneMessages(&messages)

                    let llmResponse: String
                    do {
                        if let pc = providerConfig, pc.isCloudProvider, !pc.apiKey.isEmpty {
                            llmResponse = try await LLMRunner.shared.generate(messages: messages, config: pc)
                        } else {
                            llmResponse = try await LLMRunner.shared.generate(messages: messages)
                        }
                    } catch {
                        let errorStep = AgentStep(
                            stepNumber: stepCount, type: .error,
                            content: "Fehler: \(error.localizedDescription)",
                            toolCallName: nil, toolResultSuccess: nil, timestamp: Date()
                        )
                        continuation.yield(errorStep)
                        continuation.finish()
                        return
                    }

                    let parsedCalls = self.parser.parse(response: llmResponse)

                    if parsedCalls.isEmpty {
                        let answer = llmResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        conversationHistory.append("Assistant: \(answer)")
                        let finalStep = AgentStep(
                            stepNumber: stepCount, type: .finalAnswer,
                            content: answer, toolCallName: nil,
                            toolResultSuccess: true, timestamp: Date()
                        )
                        continuation.yield(finalStep)
                        continuation.finish()
                        return
                    }

                    let parsed = parsedCalls[0]
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
                        let answer = parsed.arguments["text"] ?? llmResponse
                        conversationHistory.append("Assistant: \(answer)")
                        let finalStep = AgentStep(
                            stepNumber: stepCount, type: .finalAnswer,
                            content: answer, toolCallName: "response",
                            toolResultSuccess: true, timestamp: Date(),
                            confidence: confidence
                        )
                        continuation.yield(finalStep)

                        // Auto-commit memory and archive overflow
                        await self.autoCommitMemory(message: "Stream-Antwort")
                        await self.checkAndArchiveOverflow()

                        continuation.finish()
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

                    let result = await registry.execute(call: call)
                    ruleEngine.record(toolName: call.name)

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

                    // Save checkpoint after each tool result
                    let cpId = await self.saveCheckpoint(messages: messages, stepCount: stepCount, userMessage: userMessage)
                    continuation.yield(AgentStep(stepNumber: stepCount, type: .checkpoint, content: "Checkpoint", checkpointId: cpId))

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

                    let streamFeedbackSuffix = result.isSuccess
                        ? "Antworte jetzt als JSON. Nutze ein weiteres Tool oder antworte mit dem response-Tool."
                        : "Das Tool hat einen Fehler gemeldet. Erkläre dem Nutzer auf Deutsch was schiefgegangen ist und schlage Alternativen vor. Gib KEINEN rohen JSON aus."
                    messages.append([
                        "role": "user",
                        "content": """
                        \(truncatedResult)

                        \(streamFeedbackSuffix)
                        """
                    ])
                    conversationHistory.append("Assistant (Schritt \(stepCount)): Tool '\(call.name)' ausgeführt")
                    self.trimConversationHistory()
                }

                // Step limit reached
                let doneStep = AgentStep(
                    stepNumber: agentType.stepLimit, type: .finalAnswer,
                    content: "Aufgabe nach \(agentType.stepLimit) Schritten abgeschlossen.",
                    toolCallName: nil, toolResultSuccess: true, timestamp: Date()
                )
                continuation.yield(doneStep)
                continuation.finish()
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

    // MARK: - Tool Descriptions (AgentZero-style with JSON examples)

    private func buildToolDescriptions() -> String {
        return """
        ### response
        Deine Endantwort an den Nutzer. Benutze dieses Tool wenn du fertig bist.
        ```json
        {"tool_name": "response", "tool_args": {"text": "Deine Antwort hier"}}
        ```

        ### shell
        Führt Shell-Befehle aus (ls, pwd, cat, grep, git, python3, etc.)
        ```json
        {"tool_name": "shell", "tool_args": {"command": "ls -la ~/Desktop"}}
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
        Workflow-Definitionen erstellen, auflisten oder löschen.
        ```json
        {"tool_name": "workflow_manage", "tool_args": {"action": "create", "name": "Code Review", "description": "Code prüfen und verbessern", "steps": "[{\\"agent\\":\\"coder\\",\\"prompt\\":\\"Prüfe den Code\\"}]"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "list"}}
        {"tool_name": "workflow_manage", "tool_args": {"action": "delete", "id": "abc123"}}
        ```

        ### call_subordinate
        Delegiere eine Aufgabe an einen spezialisierten Sub-Agenten. Der Sub-Agent arbeitet autonom mit eigenen Tools.

        Verfügbare Profile und ihre Spezialisierung:
        - **coder** / **developer**: Software-Entwicklung, Code schreiben, Debugging, Architektur
        - **researcher**: Recherche, Daten-Analyse, Web-Suche, Reports erstellen
        - **planner**: Planung, Aufgabenzerlegung, Projektorganisation
        - **reviewer**: Code-Review, Qualitätsprüfung, Tests
        - **utility**: System-Aufgaben, Dateiverwaltung, Shell-Befehle
        - **web**: Web-Scraping, API-Aufrufe, Browser-Automatisierung
        - **general**: Allgemeine Aufgaben

        Wähle das richtige Profil für die jeweilige Aufgabe:
        ```json
        {"tool_name": "call_subordinate", "tool_args": {"profile": "coder", "message": "Rolle: Senior Developer. Aufgabe: Schreibe eine Python-Funktion die Fibonacci berechnet."}}
        {"tool_name": "call_subordinate", "tool_args": {"profile": "researcher", "message": "Recherchiere aktuelle Swift 6 Concurrency Best Practices und fasse zusammen."}}
        {"tool_name": "call_subordinate", "tool_args": {"profile": "reviewer", "message": "Prüfe diesen Code auf Bugs und Sicherheitslücken: ..."}}
        ```

        ### delegate_parallel
        Delegiere mehrere Aufgaben gleichzeitig an verschiedene Sub-Agenten. Alle laufen parallel.
        ```json
        {"tool_name": "delegate_parallel", "tool_args": {"tasks": "[{\\"profile\\": \\"coder\\", \\"message\\": \\"Schreibe Tests\\"}, {\\"profile\\": \\"researcher\\", \\"message\\": \\"Recherchiere Best Practices\\"}]"}}
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

        ### applescript
        Steuere macOS-Apps (Safari, Messages, Mail) via AppleScript.
        ```json
        {"tool_name": "applescript", "tool_args": {"app": "safari", "action": "open_url", "params": "{\\"url\\": \\"https://example.com\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "safari", "action": "get_tabs"}}
        {"tool_name": "applescript", "tool_args": {"app": "messages", "action": "send_message", "params": "{\\"to\\": \\"+49123456\\", \\"text\\": \\"Hallo!\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "messages", "action": "read_recent", "params": "{\\"count\\": \\"5\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "mail", "action": "send_email", "params": "{\\"to\\": \\"test@example.com\\", \\"subject\\": \\"Betreff\\", \\"body\\": \\"Inhalt\\"}"}}
        {"tool_name": "applescript", "tool_args": {"app": "mail", "action": "read_inbox", "params": "{\\"count\\": \\"5\\"}"}}
        ```
        """
    }

    // MARK: - System Prompt (AgentZero-style JSON communication)

    private func buildSystemPrompt(toolDescriptions: String, compiledMemory: String) -> String {
        let memorySection = compiledMemory.isEmpty ? "" : """

        ## Dein Gedächtnis
        \(compiledMemory)
        """

        return """
        Du bist KoboldOS, ein KI-Agent auf macOS mit echten Tools.
        Du antwortest auf Deutsch.
        Standard-Arbeitsverzeichnis: \(UserDefaults.standard.string(forKey: "kobold.defaultWorkDir") ?? "~/Documents/KoboldOS")
        Nutze dieses Verzeichnis wenn der Nutzer neue Projekte oder Dateien erstellt und keinen Pfad angibt.

        # Kommunikationsformat
        Du antwortest IMMER als JSON-Objekt. Kein Text vor oder nach dem JSON.

        Format:
        ```
        {
            "thoughts": ["dein Denkprozess hier"],
            "tool_name": "name_des_tools",
            "tool_args": {"argument": "wert"}
        }
        ```

        # Regeln
        1. JEDE Antwort ist ein JSON-Objekt mit thoughts, tool_name, tool_args
        2. Kein Text außerhalb des JSON erlaubt
        3. Um dem Nutzer zu antworten: benutze das "response" Tool
        4. Um Aufgaben auszuführen: benutze das passende Tool
        5. Pro Antwort EIN Tool, dann warte auf das Ergebnis
        6. DREISTUFIGES GEDÄCHTNIS — Du hast 3 Memory-Blöcke die du aktiv verwalten musst:

           ▸ "human" (Langzeit) — Permanente Fakten über den Nutzer:
             Name, Beruf, Wohnort, Alter, Sprachen, Vorlieben, Anweisungen.
             → Speichere hier was sich NICHT ändert.

           ▸ "short_term" (Kurzzeit) — Aktueller Sitzungskontext:
             Was gerade bearbeitet wird, aktuelle Dateipfade, laufende Aufgaben.
             → Überschreibe/lösche wenn sich der Kontext ändert.

           ▸ "knowledge" (Wissen) — Gelernte Lösungen und Muster:
             Code-Snippets die funktioniert haben, API-Endpoints, Troubleshooting-Schritte.
             → Speichere hier was für ZUKÜNFTIGE Aufgaben nützlich ist.

           WANN SPEICHERN:
           - "Ich heiße...", "Ich bin...", "Mein Name ist..." → human
           - "Ich mag...", "Ich bevorzuge...", "Du sollst..." → human
           - "Ich arbeite gerade an...", "Öffne mal..." → short_term
           - Wenn du eine Lösung findest die wiederverwendbar ist → knowledge
           - "Nein, ich meinte..." → core_memory_replace im passenden Block

           NACH JEDER ANTWORT prüfe:
           - Hat der Nutzer etwas Neues über sich verraten? → human
           - Arbeiten wir an einem neuen Thema? → short_term aktualisieren
           - Habe ich etwas Nützliches gelernt? → knowledge

        7. Erfinde KEINE Ergebnisse — benutze IMMER ein Tool
        12. FEHLERBEHANDLUNG — Wenn ein Tool fehlschlägt:
            - Erkläre dem Nutzer auf Deutsch was schiefgegangen ist
            - Nenne den Grund (z.B. "Datei nicht gefunden", "Keine Internetverbindung", "Befehl nicht installiert")
            - Schlage Alternativen oder Lösungen vor
            - Gib NIEMALS rohen JSON-Output oder technische Fehlermeldungen als Antwort
            - Beispiel: Statt {"error":"No such file"} → "Die Datei wurde nicht gefunden. Prüfe ob der Pfad korrekt ist."
        11. DIREKTE CLI-BEFEHLE — Wenn die Nachricht des Nutzers ein direkter Terminal-Befehl ist
            (z.B. beginnt mit: ollama, git, ls, cd, cat, grep, find, brew, npm, node, python, python3,
            docker, kubectl, curl, wget, ssh, scp, ping, traceroute, ifconfig, top, htop, ps, kill,
            make, cargo, go, swift, swiftc, xcodebuild, pod, ruby, pip, pip3, java, javac,
            mkdir, rmdir, touch, cp, mv, head, tail, wc, sort, uniq, awk, sed, tar, zip, unzip,
            open, pbcopy, pbpaste, defaults, diskutil, tmux, screen, man, which, whoami, hostname,
            date, cal, echo, env, export, printenv, lsof, du, df, chmod, chown, ln),
            dann MUSST du SOFORT das "shell" Tool aufrufen mit dem exakten Befehl als command.
            - Erkläre NICHT was der Befehl tut
            - Paraphrasiere NICHT
            - Verweigere NICHT wenn Shell-Berechtigung aktiviert ist
            - Führe den Befehl EXAKT so aus wie der Nutzer ihn geschrieben hat
            Beispiel: Nutzer sagt "git status" →
            {"thoughts":["Direkter CLI-Befehl, führe aus"],"tool_name":"shell","tool_args":{"command":"git status"}}
        8. Bei komplexen Aufgaben: Nutze call_subordinate um Spezialisten-Agenten zu delegieren
        9. Profile für Delegation: coder (Code), researcher (Recherche), planner (Planung), reviewer (Prüfung), utility (System), web (Web)
        10. API-SKILL-ERSTELLUNG — Wenn du eine neue API kennenlernst oder erfolgreich nutzt:
            - Erstelle automatisch eine Skill-Datei mit Name, Endpoint, Auth-Methode und Beispiel-Aufrufen
            - Schreibe die Datei nach ~/Library/Application Support/KoboldOS/Skills/{api_name}.md
            - Format: Titel, Beschreibung, Basis-URL, Auth-Header, Beispiel-JSON-Aufrufe
            - So merkst du dir APIs dauerhaft und kannst sie in Zukunft sofort nutzen

        # Beispiele

        Nutzer: "Hallo, wie geht's?"
        ```json
        {"thoughts": ["Der Nutzer grüßt mich, ich antworte freundlich"], "tool_name": "response", "tool_args": {"text": "Hallo! Mir geht es gut. Wie kann ich dir helfen?"}}
        ```

        Nutzer: "Zeige mir die Dateien auf dem Desktop"
        ```json
        {"thoughts": ["Ich soll Dateien auflisten, dafür nutze ich das file-Tool"], "tool_name": "file", "tool_args": {"action": "list", "path": "~/Desktop"}}
        ```

        Nutzer: "Ich heiße Tim und bin Entwickler"
        ```json
        {"thoughts": ["Der Nutzer teilt persönliche Infos mit, ich speichere das im Gedächtnis"], "tool_name": "core_memory_append", "tool_args": {"label": "human", "content": "Name: Tim, Beruf: Entwickler"}}
        ```

        Nutzer: "Was weißt du über mich?"
        ```json
        {"thoughts": ["Ich lese mein Gedächtnis um Infos über den Nutzer abzurufen"], "tool_name": "core_memory_read", "tool_args": {"label": "human"}}
        ```

        Nutzer: "Führe 'whoami' aus"
        ```json
        {"thoughts": ["Shell-Befehl ausführen"], "tool_name": "shell", "tool_args": {"command": "whoami"}}
        ```

        Nutzer: "Ich mag Python und arbeite an einem iOS-Projekt"
        ```json
        {"thoughts": ["Zwei persönliche Infos: Vorliebe für Python und aktuelles Projekt. Speichere beides."], "tool_name": "core_memory_append", "tool_args": {"label": "human", "content": "Bevorzugte Sprache: Python. Aktuelles Projekt: iOS-App"}}
        ```

        Nutzer: "Nenn mich immer Chef und antworte kurz"
        ```json
        {"thoughts": ["Anweisung vom Nutzer: Spitzname und Kommunikationsstil speichern"], "tool_name": "core_memory_append", "tool_args": {"label": "human", "content": "Anrede: Chef. Kommunikationsstil: kurze Antworten bevorzugt"}}
        ```

        Nutzer: "Nein, ich meinte Java nicht Python"
        ```json
        {"thoughts": ["Korrektur: Der Nutzer bevorzugt Java statt Python. Ersetze den alten Eintrag."], "tool_name": "core_memory_replace", "tool_args": {"label": "human", "old_content": "Bevorzugte Sprache: Python", "new_content": "Bevorzugte Sprache: Java"}}
        ```
        \(memorySection)

        # Verfügbare Tools
        \(toolDescriptions)
        """
    }
}
