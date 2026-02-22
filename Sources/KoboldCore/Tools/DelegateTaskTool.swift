import Foundation

// MARK: - Sub-Agent Cache (actor for concurrency safety)

private actor SubAgentCache {
    static let shared = SubAgentCache()
    private var agents: [String: AgentLoop] = [:]

    func get(_ profile: String) -> AgentLoop? { agents[profile] }
    func set(_ profile: String, agent: AgentLoop) { agents[profile] = agent }
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
        let reset = arguments["reset"]?.lowercased() != "false"

        guard !message.isEmpty else {
            throw ToolError.missingRequired("message")
        }

        let agentType = SubAgentProfile.agentType(for: profile)

        // Get or create sub-agent (actor-safe cache)
        let subAgent: AgentLoop
        if !reset, let existing = await SubAgentCache.shared.get(profile) {
            subAgent = existing
        } else {
            subAgent = AgentLoop(agentID: "sub-\(profile)")
            // Inherit parent memory so sub-agent knows context
            if let parent = parentMemory {
                await subAgent.coreMemory.inheritFrom(parent)
            }
            await SubAgentCache.shared.set(profile, agent: subAgent)
        }

        // Run sub-agent with inherited provider config
        let result = try await subAgent.run(userMessage: message, agentType: agentType, providerConfig: providerConfig)

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
        guard let tasksStr = arguments["tasks"],
              let data = tasksStr.data(using: .utf8),
              let tasks = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw ToolError.executionFailed("Ungültiges JSON-Array für 'tasks'. Format: [{\"profile\": \"coder\", \"message\": \"...\"}]")
        }

        guard !tasks.isEmpty else {
            throw ToolError.executionFailed("Leeres Aufgaben-Array.")
        }

        let parentConfig = self.providerConfig
        let parentMem = self.parentMemory

        // Run all tasks in parallel using TaskGroup
        let results = await withTaskGroup(of: (Int, String, String).self, returning: [(Int, String, String)].self) { group in
            for (index, task) in tasks.enumerated() {
                let profile = task["profile"] ?? "general"
                let message = task["message"] ?? ""

                group.addTask {
                    let agentType = SubAgentProfile.agentType(for: profile)
                    let subAgent = AgentLoop(agentID: "parallel-\(profile)-\(index)")
                    // Inherit parent memory
                    if let parent = parentMem {
                        await subAgent.coreMemory.inheritFrom(parent)
                    }
                    do {
                        let result = try await subAgent.run(userMessage: message, agentType: agentType, providerConfig: parentConfig)
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
