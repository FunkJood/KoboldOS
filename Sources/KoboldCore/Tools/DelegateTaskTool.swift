import Foundation

// MARK: - Sub-Agent Cache (actor for concurrency safety)

private actor SubAgentCache {
    static let shared = SubAgentCache()
    private var agents: [String: AgentLoop] = [:]
    private var activeCount: Int = 0

    /// Max concurrent sub-agents, configurable via Settings (default 3)
    private var maxConcurrent: Int {
        let v = UserDefaults.standard.integer(forKey: "kobold.subagent.maxConcurrent")
        return v > 0 ? v : 3
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
        case "researcher", "web":    return .researcher   // Websuche, Analyse, Informationen sammeln
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
// Sub-agents run their own AgentLoop and return results to the parent.

public struct DelegateTaskTool: Tool, Sendable {
    public let name = "call_subordinate"
    public let description = "Delegiere eine Aufgabe an einen spezialisierten Sub-Agenten. Der Sub-Agent arbeitet autonom und liefert das Ergebnis zurück."
    public let riskLevel: RiskLevel = .medium

    /// Provider config inherited from the parent agent, so sub-agents use the same backend
    public var providerConfig: LLMProviderConfig?
    /// Parent agent's CoreMemory for inheritance
    public var parentMemory: CoreMemory?

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "profile": ToolSchemaProperty(
                    type: "string",
                    description: "Agent-Profil: coder (Code/Dateien), researcher (Web/Analyse), planner (Pläne), reviewer (Code-Review), utility (Shell/Rechner), web (Browser/Suche). Standard: general",
                    enumValues: ["coder", "researcher", "planner", "reviewer", "utility", "web", "general"]
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

    public init(providerConfig: LLMProviderConfig? = nil, parentMemory: CoreMemory? = nil) {
        self.providerConfig = providerConfig
        self.parentMemory = parentMemory
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

        // Concurrency limit: max 3 sub-agents at once
        guard await SubAgentCache.shared.acquireSlot() else {
            return "⚠️ Max. 3 Sub-Agenten gleichzeitig erlaubt. Warte bis ein anderer fertig ist."
        }
        defer { Task { await SubAgentCache.shared.releaseSlot() } }

        let agentType = SubAgentProfile.agentType(for: profile)

        // Always create fresh agent to prevent state contamination between calls
        let subAgent = AgentLoop(agentID: "sub-\(profile)-\(UUID().uuidString.prefix(6))")
        if let parent = parentMemory {
            await subAgent.coreMemory.inheritFrom(parent)
        }

        // Run sub-agent with configurable timeout (default 5 min)
        let timeoutSecs = UserDefaults.standard.integer(forKey: "kobold.subagent.timeout")
        let timeoutNs = UInt64(timeoutSecs > 0 ? timeoutSecs : 300) * 1_000_000_000
        let result: AgentResult
        do {
            result = try await withThrowingTaskGroup(of: AgentResult.self) { group in
                group.addTask {
                    try await subAgent.run(userMessage: message, agentType: agentType, providerConfig: self.providerConfig)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw ToolError.executionFailed("Sub-Agent Timeout nach \(timeoutSecs > 0 ? timeoutSecs : 300) Sekunden")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            return "⚠️ Sub-Agent (\(profile)) fehlgeschlagen: \(error.localizedDescription)"
        }

        // Build summary of steps for the instructor
        var stepsSummary = ""
        for step in result.steps {
            switch step.type {
            case .think:
                stepsSummary += "💭 \(step.content.prefix(200))\n"
            case .toolCall:
                stepsSummary += "🔧 \(step.toolCallName ?? "tool"): \(step.content.prefix(150))\n"
            case .toolResult:
                let icon = (step.toolResultSuccess ?? true) ? "✅" : "❌"
                stepsSummary += "\(icon) \(step.toolCallName ?? "tool"): \(step.content.prefix(200))\n"
            case .finalAnswer:
                break
            case .error:
                stepsSummary += "⚠️ \(step.content.prefix(200))\n"
            case .subAgentSpawn, .subAgentResult, .checkpoint:
                break
            }
        }

        return """
        [Sub-Agent: \(profile) (\(agentType.rawValue))]

        Ergebnis:
        \(result.finalOutput)

        \(stepsSummary.isEmpty ? "" : "Schritte:\n\(stepsSummary)")Status: \(result.success ? "Erfolgreich" : "Fehlgeschlagen") (\(result.steps.count) Schritte)
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

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "tasks": ToolSchemaProperty(
                    type: "string",
                    description: "JSON-Array von Aufgaben: [{\"profile\": \"coder\", \"message\": \"Aufgabe 1\"}, {\"profile\": \"researcher\", \"message\": \"Aufgabe 2\"}]",
                    required: true
                )
            ],
            required: ["tasks"]
        )
    }

    public init(providerConfig: LLMProviderConfig? = nil, parentMemory: CoreMemory? = nil) {
        self.providerConfig = providerConfig
        self.parentMemory = parentMemory
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
            // LLM sometimes sends {}, {} instead of [{}, {}] — fix by wrapping
            let wrapped = "[\(tasksStr)]"
            if let data = wrapped.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                tasks = parsed
            } else {
                // Try to extract JSON objects from the string using regex
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

        // Hard limit: max 4 parallel sub-agents
        let cappedTasks = Array(tasks.prefix(4))
        if tasks.count > 4 {
            print("[DelegateParallel] Capped \(tasks.count) tasks to 4")
        }

        let parentConfig = self.providerConfig
        let parentMem = self.parentMemory

        // Run tasks in parallel with configurable timeout per agent
        let parTimeoutSecs = UserDefaults.standard.integer(forKey: "kobold.subagent.timeout")
        let parTimeoutNs = UInt64(parTimeoutSecs > 0 ? parTimeoutSecs : 300) * 1_000_000_000
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
                    do {
                        let result = try await withThrowingTaskGroup(of: AgentResult.self) { tg in
                            tg.addTask {
                                try await subAgent.run(userMessage: message, agentType: agentType, providerConfig: parentConfig)
                            }
                            tg.addTask {
                                try await Task.sleep(nanoseconds: parTimeoutNs)
                                throw ToolError.executionFailed("Timeout nach \(parTimeoutSecs > 0 ? parTimeoutSecs : 300) Sek.")
                            }
                            let first = try await tg.next()!
                            tg.cancelAll()
                            return first
                        }
                        return (index, profile, result.finalOutput)
                    } catch {
                        return (index, profile, "Fehler: \(error.localizedDescription)")
                    }
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
