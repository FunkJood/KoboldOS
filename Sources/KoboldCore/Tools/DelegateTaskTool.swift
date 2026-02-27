import Foundation

// MARK: - Sub-Agent Step Relay (forwards sub-agent steps to parent stream)

/// Shared relay that allows sub-agent tools to forward intermediate steps
/// to the parent AgentLoop's SSE stream for live display in the UI.
public actor SubAgentStepRelay {
    public static let shared = SubAgentStepRelay()

    private var continuations: [String: AsyncStream<AgentStep>.Continuation] = [:]
    /// Track registration time to clean up stale entries
    private var registrationTimes: [String: Date] = [:]

    /// Register a parent agent's stream continuation so sub-agents can forward steps to it.
    public func register(agentId: String, continuation: AsyncStream<AgentStep>.Continuation) {
        continuations[agentId] = continuation
        registrationTimes[agentId] = Date()
        // Clean up stale continuations (older than 15 min — prevents memory leaks from crashed agents)
        let staleThreshold = Date().addingTimeInterval(-900)
        for (id, time) in registrationTimes where time < staleThreshold {
            continuations.removeValue(forKey: id)
            registrationTimes.removeValue(forKey: id)
        }
    }

    /// Unregister when streaming ends.
    public func unregister(agentId: String) {
        continuations.removeValue(forKey: agentId)
        registrationTimes.removeValue(forKey: agentId)
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

    /// Max concurrent sub-agents, configurable via Settings (default 2 for local Ollama)
    private var maxConcurrent: Int {
        let v = UserDefaults.standard.integer(forKey: "kobold.subagent.maxConcurrent")
        return v > 0 ? v : 2
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
        case "instructor":           return .general       // Legacy-Alias für general
        case "reviewer":             return .coder        // Code-Review mit Coder-Tools
        case "utility":              return .general      // Allgemeine Aufgaben (Shell, Dateien, Rechner)
        default:                     return .general
        }
    }
}

// MARK: - DelegateTaskTool (call_subordinate — AgentZero-Muster)
// Allows the general agent to spawn sub-agents with specific profiles.
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
                    description: "Agent-Profil: coder (Code/Dateien), web (Recherche/APIs/Browser), reviewer (Code-Review), utility (Shell/Rechner). Standard: general",
                    enumValues: ["coder", "web", "reviewer", "utility", "general"]
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
        let effectiveTimeout = timeoutSecs > 0 ? timeoutSecs : 600  // Default 10 Min

        // Use runStreaming to get live steps
        let stream = await subAgent.runStreaming(userMessage: message, agentType: agentType, providerConfig: providerConfig)

        // Proper timeout: race stream iteration against timeout using withThrowingTaskGroup
        // All mutable state lives inside the task closure to satisfy Sendable requirements
        struct SubAgentResult: Sendable {
            var stepsSummary: String = ""
            var finalOutput: String = ""
            var stepCount: Int = 0
            var success: Bool = true
        }

        let capturedParentId = parentId
        let capturedProfile = profile
        var subResult: SubAgentResult
        do {
            subResult = try await withThrowingTaskGroup(of: SubAgentResult.self) { group in
                group.addTask {
                    var result = SubAgentResult()
                    var lastRelayTime: Date = .distantPast
                    for await step in stream {
                        if Task.isCancelled { break }
                        result.stepCount += 1

                        // Forward step to parent's SSE stream (rate-limited to prevent 100% CPU)
                        if let pid = capturedParentId {
                            let now = Date()
                            if now.timeIntervalSince(lastRelayTime) >= 0.5 || step.type == .finalAnswer || step.type == .error {
                                lastRelayTime = now
                                let taggedStep = AgentStep(
                                    stepNumber: step.stepNumber,
                                    type: step.type,
                                    content: step.content,
                                    toolCallName: step.toolCallName,
                                    toolResultSuccess: step.toolResultSuccess,
                                    timestamp: step.timestamp,
                                    subAgentName: capturedProfile,
                                    confidence: step.confidence,
                                    checkpointId: step.checkpointId
                                )
                                await SubAgentStepRelay.shared.forward(parentAgentId: pid, step: taggedStep)
                            }
                        }

                        switch step.type {
                        case .think:
                            result.stepsSummary += "[\(capturedProfile)] \(step.content.prefix(200))\n"
                        case .toolCall:
                            result.stepsSummary += "[\(capturedProfile)] \(step.toolCallName ?? "tool"): \(step.content.prefix(150))\n"
                        case .toolResult:
                            let icon = (step.toolResultSuccess ?? true) ? "+" : "x"
                            result.stepsSummary += "[\(capturedProfile)] \(icon) \(step.toolCallName ?? "tool"): \(step.content.prefix(200))\n"
                            if step.toolResultSuccess == false { result.success = false }
                        case .finalAnswer:
                            result.finalOutput += step.content
                        case .error:
                            result.stepsSummary += "[\(capturedProfile)] Fehler: \(step.content.prefix(200))\n"
                            result.success = false
                        default:
                            break
                        }
                    }
                    return result
                }
                // Timeout task — cancels the stream iteration when time runs out
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000_000)
                    throw CancellationError()
                }
                guard let first = try await group.next() else {
                    return SubAgentResult(finalOutput: "Kein Ergebnis", success: false)
                }
                group.cancelAll()
                return first
            }
        } catch {
            subResult = SubAgentResult(finalOutput: "Sub-Agent Timeout nach \(effectiveTimeout)s ohne Ergebnis.", success: false)
        }
        let stepsSummary = subResult.stepsSummary
        let finalOutput = subResult.finalOutput
        let stepCount = subResult.stepCount
        let success = subResult.success

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
        let maxParallel = maxParallelRaw > 0 ? maxParallelRaw : 2
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

        // Run parallel sub-agents with global timeout
        var results: [(Int, String, String)] = []
        do {
            results = try await withThrowingTaskGroup(of: (Int, String, String).self, returning: [(Int, String, String)].self) { group in
                for (index, task) in cappedTasks.enumerated() {
                    let profile = task["profile"] ?? "general"
                    let message = task["message"] ?? ""

                    group.addTask {
                        let agentType = SubAgentProfile.agentType(for: profile)
                        let subAgent = AgentLoop(agentID: "par-\(profile)-\(index)-\(UUID().uuidString.prefix(4))")
                        if let parent = parentMem {
                            await subAgent.coreMemory.inheritFrom(parent)
                        }

                        let stream = await subAgent.runStreaming(userMessage: message, agentType: agentType, providerConfig: parentConfig)

                        var finalOutput = ""
                        var lastRelay: Date = .distantPast
                        for await step in stream {
                            if Task.isCancelled { break }
                            // Rate-limited relay (max 1 per 500ms) to prevent UI flood
                            if let pid = parentId {
                                let now = Date()
                                if now.timeIntervalSince(lastRelay) >= 0.5 || step.type == .finalAnswer || step.type == .error {
                                    lastRelay = now
                                    let tagged = AgentStep(
                                        stepNumber: step.stepNumber, type: step.type,
                                        content: step.content, toolCallName: step.toolCallName,
                                        toolResultSuccess: step.toolResultSuccess,
                                        subAgentName: "\(profile)[\(index + 1)]"
                                    )
                                    await SubAgentStepRelay.shared.forward(parentAgentId: pid, step: tagged)
                                }
                            }
                            if step.type == .finalAnswer { finalOutput += step.content }
                        }
                        return (index, profile, finalOutput)
                    }
                }

                // Global timeout task — cancels all parallel agents
                group.addTask {
                    try await Task.sleep(nanoseconds: effectiveTimeout)
                    throw CancellationError()
                }

                var collected: [(Int, String, String)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }
            }
        } catch {
            // Timeout — return whatever partial results we have
            if results.isEmpty {
                results = [(0, "timeout", "Parallele Sub-Agenten Timeout nach \(effectiveTimeout / 1_000_000_000)s")]
            }
        }

        // Format output
        var output = "Parallele Ergebnisse (\(results.count) Agenten):\n\n"
        for (index, profile, result) in results {
            output += "--- [\(index + 1)] \(profile) ---\n\(result)\n\n"
        }

        return output
    }
}
