import Foundation

// MARK: - Sub-Agent Step Relay (forwards sub-agent steps to parent stream)

/// Shared relay that allows sub-agent tools to forward intermediate steps
/// to the parent AgentLoop's SSE stream for live display in the UI.
public actor SubAgentStepRelay {
    public static let shared = SubAgentStepRelay()

    private var continuations: [String: AsyncStream<AgentStep>.Continuation] = [:]

    /// Register a parent agent's stream continuation so sub-agents can forward steps to it.
    public func register(agentId: String, continuation: AsyncStream<AgentStep>.Continuation) {
        continuations[agentId] = continuation
    }

    /// Unregister when streaming ends.
    public func unregister(agentId: String) {
        continuations.removeValue(forKey: agentId)
    }

    /// Forward a step from a sub-agent to the parent's stream.
    /// The step will appear in the parent's ThinkingPanel with the sub-agent's name.
    public func forward(parentAgentId: String, step: AgentStep) {
        continuations[parentAgentId]?.yield(step)
    }
}

// MARK: - Sub-Agent Cache (actor for concurrency safety)

private actor SubAgentCache {
    static let shared = SubAgentCache()
    private var agents: [String: AgentLoop] = [:]
    private var activeCount: Int = 0

    /// Max concurrent sub-agents, configurable via Settings (default 10)
    private var maxConcurrent: Int {
        let v = UserDefaults.standard.integer(forKey: "kobold.subagent.maxConcurrent")
        return v > 0 ? v : 10
    }

    func get(_ profile: String) -> AgentLoop? { agents[profile] }
    func set(_ profile: String, agent: AgentLoop) { agents[profile] = agent }

    /// Try to acquire a slot for a new sub-agent. Returns false if at capacity.
    func acquireSlot() -> Bool {
        guard activeCount < maxConcurrent else { return false }
        activeCount += 1
        return true
    }
    func releaseSlot() { activeCount = max(0, activeCount - 1) }
    func currentActive() -> Int { activeCount }
}

// MARK: - Profile → AgentType mapping

/// Maps human-readable profile names to AgentType with role descriptions.
/// Used by both DelegateTaskTool and DelegateParallelTool.
enum SubAgentProfile {
    static func agentType(for profile: String) -> AgentType {
        switch profile.lowercased() {
        case "coder", "developer":   return .coder       // Code schreiben, Dateien bearbeiten, Bugs fixen
        case "researcher", "web":    return .web          // Websuche, Analyse, Informationen sammeln
        case "planner":              return .planner      // Pläne erstellen, Aufgaben strukturieren
        case "instructor":           return .instructor   // Andere Agenten koordinieren
        case "reviewer":             return .coder        // Code-Review mit Coder-Tools
        case "utility":              return .general      // Allgemeine Aufgaben (Shell, Dateien, Rechner)
        default:                     return .general
        }
    }
}

// MARK: - DelegateTaskTool (call_subordinate — AgentZero-Muster)
// Allows the instructor to spawn sub-agents with specific profiles.
// Sub-agents now stream their steps live to the parent's UI.

public struct DelegateTaskTool: Tool, Sendable {
    public let name = "call_subordinate"
    public let description = "Delegiere eine Aufgabe an einen spezialisierten Sub-Agenten. Der Sub-Agent arbeitet autonom und liefert das Ergebnis zurück."
    public let riskLevel: RiskLevel = .medium

    /// Provider config inherited from the parent agent, so sub-agents use the same backend
    public var providerConfig: LLMProviderConfig?
    /// Parent agent's CoreMemory for inheritance
    public var parentMemory: CoreMemory?
    /// Parent agent's ID for step relay (live streaming sub-agent steps to parent UI)
    public var parentAgentId: String?

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "profile": ToolSchemaProperty(
                    type: "string",
                    description: "Agent-Profil: coder (Code/Dateien), web (Recherche/APIs/Browser), planner (Pläne), reviewer (Code-Review), utility (Shell/Rechner). Standard: general",
                    enumValues: ["coder", "web", "planner", "reviewer", "utility", "general"]
                ),
                "message": ToolSchemaProperty(
                    type: "string",
                    description: "Aufgabe oder Nachricht an den Sub-Agenten. Sei spezifisch mit Rolle + Ziel.",
                    required: true
                ),
                "reset": ToolSchemaProperty(
                    type: "string",
                    description: "true = neuen Sub-Agent starten, false = vorherigen fortsetzen (Standard: true)",
                    enumValues: ["true", "false"]
                )
            ],
            required: ["message"]
        )
    }

    public init(providerConfig: LLMProviderConfig? = nil, parentMemory: CoreMemory? = nil, parentAgentId: String? = nil) {
        self.providerConfig = providerConfig
        self.parentMemory = parentMemory
        self.parentAgentId = parentAgentId
    }

    public func validate(arguments: [String: String]) throws {
        guard let msg = arguments["message"], !msg.isEmpty else {
            throw ToolError.missingRequired("message")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let profile = arguments["profile"] ?? "general"
        let message = arguments["message"] ?? ""
        let _ = arguments["reset"] // reserved for future use

        guard !message.isEmpty else {
            throw ToolError.missingRequired("message")
        }

        // Concurrency limit: configurable via Settings
        guard await SubAgentCache.shared.acquireSlot() else {
            let max = await SubAgentCache.shared.currentActive()
            return "Max. \(max) Sub-Agenten gleichzeitig erlaubt. Warte bis ein anderer fertig ist."
        }
        defer { Task { await SubAgentCache.shared.releaseSlot() } }

        let agentType = SubAgentProfile.agentType(for: profile)

        // Always create fresh agent to prevent state contamination between calls
        let subAgent = AgentLoop(agentID: "sub-\(profile)-\(UUID().uuidString.prefix(6))")
        if let parent = parentMemory {
            await subAgent.coreMemory.inheritFrom(parent)
        }

        // Run sub-agent with STREAMING — forward steps live to parent UI
        let parentId = parentAgentId
        let timeoutSecs = UserDefaults.standard.integer(forKey: "kobold.subagent.timeout")
        let effectiveTimeout = timeoutSecs > 0 ? timeoutSecs : 600  // Default 10 Min statt 5

        // Use runStreaming to get live steps
        let stream = await subAgent.runStreaming(userMessage: message, agentType: agentType, providerConfig: providerConfig)

        var stepsSummary = ""
        var finalOutput = ""
        var stepCount = 0
        var success = true

        // Timeout: cancel current task after limit
        let currentTask = Task<Void, Never> { [weak subAgent = Optional(subAgent)] in
            try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000_000)
            // Timeout reached — subAgent stream will end naturally when cancelled
            _ = subAgent
        }

        // Iterate stream directly (no separate Task needed — we're already async)
        for await step in stream {
            if Task.isCancelled { break }
            stepCount += 1

            // Forward step to parent's SSE stream (live UI update)
            if let parentId = parentId {
                let taggedStep = AgentStep(
                    stepNumber: step.stepNumber,
                    type: step.type,
                    content: step.content,
                    toolCallName: step.toolCallName,
                    toolResultSuccess: step.toolResultSuccess,
                    timestamp: step.timestamp,
                    subAgentName: profile,
                    confidence: step.confidence,
                    checkpointId: step.checkpointId
                )
                await SubAgentStepRelay.shared.forward(parentAgentId: parentId, step: taggedStep)
            }

            // Collect for summary
            switch step.type {
            case .think:
                stepsSummary += "[\(profile)] \(step.content.prefix(200))\n"
            case .toolCall:
                stepsSummary += "[\(profile)] \(step.toolCallName ?? "tool"): \(step.content.prefix(150))\n"
            case .toolResult:
                let icon = (step.toolResultSuccess ?? true) ? "+" : "x"
                stepsSummary += "[\(profile)] \(icon) \(step.toolCallName ?? "tool"): \(step.content.prefix(200))\n"
                if step.toolResultSuccess == false { success = false }
            case .finalAnswer:
                finalOutput += step.content
            case .error:
                stepsSummary += "[\(profile)] Fehler: \(step.content.prefix(200))\n"
                success = false
            default:
                break
            }
        }
        currentTask.cancel()

        return """
        [Sub-Agent: \(profile) (\(agentType.rawValue))]

        Ergebnis:
        \(finalOutput)

        \(stepsSummary.isEmpty ? "" : "Schritte:\n\(stepsSummary)")Status: \(success ? "Erfolgreich" : "Fehlgeschlagen") (\(stepCount) Schritte)
        """
    }
}

// MARK: - DelegateParallelTool
// Spawns multiple sub-agents in parallel (like TaskGroup)

public struct DelegateParallelTool: Tool, Sendable {
    public let name = "delegate_parallel"
    public let description = "Delegiere mehrere Aufgaben parallel an verschiedene Sub-Agenten. Alle laufen gleichzeitig."
    public let riskLevel: RiskLevel = .medium

    /// Provider config inherited from the parent agent
    public var providerConfig: LLMProviderConfig?
    /// Parent agent's CoreMemory for inheritance
    public var parentMemory: CoreMemory?
    /// Parent agent's ID for step relay
    public var parentAgentId: String?

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "tasks": ToolSchemaProperty(
                    type: "string",
                    description: "JSON-Array von Aufgaben: [{\"profile\": \"coder\", \"message\": \"Aufgabe 1\"}, {\"profile\": \"web\", \"message\": \"Aufgabe 2\"}]",
                    required: true
                )
            ],
            required: ["tasks"]
        )
    }

    public init(providerConfig: LLMProviderConfig? = nil, parentMemory: CoreMemory? = nil, parentAgentId: String? = nil) {
        self.providerConfig = providerConfig
        self.parentMemory = parentMemory
        self.parentAgentId = parentAgentId
    }

    public func validate(arguments: [String: String]) throws {
        guard let tasks = arguments["tasks"], !tasks.isEmpty else {
            throw ToolError.missingRequired("tasks")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        guard let tasksStr = arguments["tasks"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tasksStr.isEmpty else {
            throw ToolError.executionFailed("Ungültiges JSON-Array für 'tasks'. Format: [{\"profile\": \"coder\", \"message\": \"...\"}]")
        }

        // Tolerant JSON parsing: try as-is, then wrap in [] if it's not an array
        let tasks: [[String: String]]
        if let data = tasksStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            tasks = parsed
        } else {
            let wrapped = "[\(tasksStr)]"
            if let data = wrapped.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                tasks = parsed
            } else {
                var extracted: [[String: String]] = []
                let pattern = "\\{[^{}]*\\}"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let matches = regex.matches(in: tasksStr, range: NSRange(tasksStr.startIndex..., in: tasksStr))
                    for match in matches {
                        if let range = Range(match.range, in: tasksStr) {
                            let objStr = String(tasksStr[range])
                            if let objData = objStr.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: objData) as? [String: String] {
                                extracted.append(obj)
                            }
                        }
                    }
                }
                guard !extracted.isEmpty else {
                    throw ToolError.executionFailed("Ungültiges JSON-Array für 'tasks'. Format: [{\"profile\": \"coder\", \"message\": \"...\"}]")
                }
                tasks = extracted
            }
        }

        guard !tasks.isEmpty else {
            throw ToolError.executionFailed("Leeres Aufgaben-Array.")
        }

        let maxParallelRaw = UserDefaults.standard.integer(forKey: "kobold.subagent.maxConcurrent")
        let maxParallel = maxParallelRaw > 0 ? maxParallelRaw : 10
        let cappedTasks = Array(tasks.prefix(maxParallel))
        if tasks.count > maxParallel {
            print("[DelegateParallel] Capped \(tasks.count) tasks to \(maxParallel)")
        }

        let parentConfig = self.providerConfig
        let parentMem = self.parentMemory
        let parentId = self.parentAgentId

        // Timeout: configurable, default 10 min
        let parTimeoutSecs = UserDefaults.standard.integer(forKey: "kobold.subagent.timeout")
        let effectiveTimeout = UInt64(parTimeoutSecs > 0 ? parTimeoutSecs : 600) * 1_000_000_000

        let results = await withTaskGroup(of: (Int, String, String).self, returning: [(Int, String, String)].self) { group in
            for (index, task) in cappedTasks.enumerated() {
                let profile = task["profile"] ?? "general"
                let message = task["message"] ?? ""

                group.addTask {
                    let agentType = SubAgentProfile.agentType(for: profile)
                    let subAgent = AgentLoop(agentID: "par-\(profile)-\(index)-\(UUID().uuidString.prefix(4))")
                    if let parent = parentMem {
                        await subAgent.coreMemory.inheritFrom(parent)
                    }

                    // Use streaming for live UI updates
                    let stream = await subAgent.runStreaming(userMessage: message, agentType: agentType, providerConfig: parentConfig)

                    var finalOutput = ""
                    for await step in stream {
                        if Task.isCancelled { break }
                        // Forward to parent UI
                        if let pid = parentId {
                            let tagged = AgentStep(
                                stepNumber: step.stepNumber, type: step.type,
                                content: step.content, toolCallName: step.toolCallName,
                                toolResultSuccess: step.toolResultSuccess,
                                subAgentName: "\(profile)[\(index + 1)]"
                            )
                            await SubAgentStepRelay.shared.forward(parentAgentId: pid, step: tagged)
                        }
                        if step.type == .finalAnswer { finalOutput += step.content }
                    }
                    return (index, profile, finalOutput)
                }
            }

            var collected: [(Int, String, String)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        // Format output
        var output = "Parallele Ergebnisse (\(results.count) Agenten):\n\n"
        for (index, profile, result) in results {
            output += "--- [\(index + 1)] \(profile) ---\n\(result)\n\n"
        }

        return output
    }
}
