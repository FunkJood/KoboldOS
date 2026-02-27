import Foundation

// MARK: - ToolRouter (Actor-based, thread-safe routing)

public actor ToolRouter {

    private var tools: [String: any Tool] = [:]
    private var errorCounts: [String: Int] = [:]
    private var disabledTools: Set<String> = []
    private let maxErrorsBeforeDisable = 50
    private let defaultTimeoutSeconds: TimeInterval = 120

    /// Tools that run without timeout (sub-agent delegation, etc.)
    private let noTimeoutTools: Set<String> = ["call_subordinate", "delegate_parallel"]

    /// Critical tools that must never be auto-disabled (general agent core tools)
    private let neverDisableTools: Set<String> = [
        "response", "call_subordinate", "delegate_parallel",
        "core_memory_read", "core_memory_append", "core_memory_replace",
        "shell", "file", "browser"
    ]

    public init() {}

    // MARK: - Registration

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
        errorCounts[tool.name] = 0
        print("[ToolRouter] Registered: \(tool.name) (risk: \(tool.riskLevel.rawValue))")
    }

    public func unregister(_ name: String) {
        tools.removeValue(forKey: name)
        errorCounts.removeValue(forKey: name)
        disabledTools.remove(name)
    }

    public func get(_ name: String) -> (any Tool)? {
        tools[name]
    }

    public func list() -> [String] {
        Array(tools.keys).sorted()
    }

    public func listEnabled() -> [String] {
        tools.keys.filter { !disabledTools.contains($0) }.sorted()
    }

    public func isDisabled(_ name: String) -> Bool {
        disabledTools.contains(name)
    }

    public func enableTool(_ name: String) {
        disabledTools.remove(name)
        errorCounts[name] = 0
        print("[ToolRouter] Re-enabled: \(name)")
    }

    // MARK: - Execution

    public func execute(call: ToolCall, timeout: TimeInterval? = nil) async -> ToolResult {
        let name = call.name

        // Disabled check
        if disabledTools.contains(name) {
            return .fail("Tool '\(name)' is disabled due to repeated errors. Use 'kobold tool enable \(name)' to re-enable.")
        }

        // Lookup
        guard let tool = tools[name] else {
            return .fail("Unknown tool: \(name). Available: \(list().joined(separator: ", "))")
        }

        // Validate parameters
        do {
            try tool.validate(arguments: call.arguments)
        } catch {
            return .fail("Validation error: \(error.localizedDescription)")
        }

        // Execute — no timeout for delegation tools, configurable for others
        let skipTimeout = noTimeoutTools.contains(name)
        let effectiveTimeout = timeout ?? defaultTimeoutSeconds
        do {
            let result: String
            if skipTimeout {
                // Delegation tools run without timeout (sub-agents manage their own)
                result = try await tool.execute(arguments: call.arguments)
            } else {
                result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await tool.execute(arguments: call.arguments)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                        throw ToolError.timeout
                    }
                    guard let first = try await group.next() else {
                        throw ToolError.timeout
                    }
                    group.cancelAll()
                    return first
                }
            }
            // Reset error count on success
            errorCounts[name] = 0
            return .success(output: result)
        } catch ToolError.timeout {
            recordError(name)
            return .fail("Tool '\(name)' timed out after \(Int(effectiveTimeout))s")
        } catch {
            recordError(name)
            return .fail(error.localizedDescription)
        }
    }

    private func recordError(_ name: String) {
        errorCounts[name, default: 0] += 1
        let count = errorCounts[name] ?? 0
        if count >= maxErrorsBeforeDisable && !neverDisableTools.contains(name) {
            disabledTools.insert(name)
            print("[ToolRouter] Auto-disabled '\(name)' after \(count) consecutive errors")
        } else if count >= maxErrorsBeforeDisable {
            // Reset error count for critical tools instead of disabling
            errorCounts[name] = 0
            print("[ToolRouter] Reset error count for critical tool '\(name)' (never-disable)")
        }
    }

    // MARK: - Schema Export for LLM

    public func getToolDescriptions() -> String {
        let enabled = tools.filter { !disabledTools.contains($0.key) }
        return enabled.map { (name, tool) in
            """
            Tool: \(name)
            Description: \(tool.description)
            Risk: \(tool.riskLevel.rawValue)
            Parameters: \(tool.schema.toJSONString())
            """
        }.joined(separator: "\n\n")
    }

    public func getToolSchemas() -> [[String: Any]] {
        return tools.filter { !disabledTools.contains($0.key) }.map { (name, tool) in
            var props: [String: Any] = [:]
            for (key, prop) in tool.schema.properties {
                var p: [String: Any] = ["type": prop.type, "description": prop.description]
                if let ev = prop.enumValues { p["enum"] = ev }
                props[key] = p
            }
            return [
                "name": name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": tool.schema.required
                ]
            ] as [String: Any]
        }
    }
}
