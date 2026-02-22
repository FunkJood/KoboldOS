import Foundation

// MARK: - ToolRule (OpenClaw / Letta pattern)
// Declarative state machine over tool call sequences

public enum ToolRule: Sendable, Codable {
    /// This tool must be called first in the loop
    case initial(toolName: String)
    /// Calling this tool ends the agent loop immediately
    case terminal(toolName: String)
    /// After calling this tool, the agent must next call one of `children`
    case child(toolName: String, children: [String])
    /// Cannot call this tool more than `limit` times per loop run
    case maxCount(toolName: String, limit: Int)
    /// Must continue loop after calling this tool (never terminal)
    case continueAfter(toolName: String)
}

// MARK: - ToolRuleEngine

public struct ToolRuleEngine: Sendable {

    public let rules: [ToolRule]
    private var callCounts: [String: Int] = [:]
    private var stepCount: Int = 0
    public private(set) var initialToolName: String? = nil
    public private(set) var terminalToolNames: Set<String> = []

    public init(rules: [ToolRule] = []) {
        self.rules = rules
        // Pre-compute terminal tool set and initial tool
        for rule in rules {
            switch rule {
            case .terminal(let name): terminalToolNames.insert(name)
            case .initial(let name): initialToolName = name
            default: break
            }
        }
    }

    /// Returns true if the loop should terminate after this tool call
    public func shouldTerminate(afterCalling toolName: String) -> Bool {
        // If there's a continueAfter rule, override terminal
        if rules.contains(where: { if case .continueAfter(let n) = $0 { return n == toolName } ; return false }) {
            return false
        }
        return terminalToolNames.contains(toolName)
    }

    /// Returns the required next tool names after a given call, or nil if any is fine
    public func requiredNextTools(after toolName: String) -> [String]? {
        for rule in rules {
            if case .child(let name, let children) = rule, name == toolName {
                return children
            }
        }
        return nil
    }

    /// Returns true if this tool has exceeded its per-run call limit
    public func isAtLimit(toolName: String) -> Bool {
        for rule in rules {
            if case .maxCount(let name, let limit) = rule, name == toolName {
                return (callCounts[toolName] ?? 0) >= limit
            }
        }
        return false
    }

    /// Record a tool call (updates call counts)
    public mutating func record(toolName: String) {
        callCounts[toolName, default: 0] += 1
        stepCount += 1
    }

    /// Reset counts for a new loop run
    public mutating func reset() {
        callCounts = [:]
        stepCount = 0
    }

    /// Returns a description for LLM context
    public func describe() -> String {
        guard !rules.isEmpty else { return "" }
        var lines: [String] = ["## Tool Rules"]
        for rule in rules {
            switch rule {
            case .initial(let n):        lines.append("- First call MUST be '\(n)'")
            case .terminal(let n):       lines.append("- Calling '\(n)' ends the session immediately")
            case .child(let n, let c):   lines.append("- After '\(n)', next call must be one of: \(c.joined(separator: ", "))")
            case .maxCount(let n, let l):lines.append("- '\(n)' may be called at most \(l) time(s) per run")
            case .continueAfter(let n):  lines.append("- Must continue loop after calling '\(n)'")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Default rule sets (inspired by Letta's built-in agents)

public extension ToolRuleEngine {

    /// Standard rules: response tool is handled by AgentLoop directly (not via rule engine)
    static var `default`: ToolRuleEngine {
        ToolRuleEngine(rules: [
            .maxCount(toolName: "core_memory_read", limit: 10),
            .maxCount(toolName: "shell", limit: 20),
            .maxCount(toolName: "browser", limit: 5)
        ])
    }

    /// Research agent: more tool calls allowed
    static var research: ToolRuleEngine {
        ToolRuleEngine(rules: [
            .maxCount(toolName: "browser", limit: 20),
            .maxCount(toolName: "http", limit: 30),
            .maxCount(toolName: "shell", limit: 10)
        ])
    }

    /// Coder agent: file + shell heavy
    static var coder: ToolRuleEngine {
        ToolRuleEngine(rules: [
            .maxCount(toolName: "file", limit: 50),
            .maxCount(toolName: "shell", limit: 30),
            .maxCount(toolName: "browser", limit: 5)
        ])
    }
}
