import Foundation

// MARK: - Risk Level

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Tool Schema

public struct ToolSchemaProperty: Codable, Sendable {
    public let type: String
    public let description: String
    public let enumValues: [String]?
    public let required: Bool

    public init(type: String, description: String, enumValues: [String]? = nil, required: Bool = false) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.required = required
    }

    enum CodingKeys: String, CodingKey {
        case type, description, enumValues = "enum", required
    }
}

public struct ToolSchema: Codable, Sendable {
    public let properties: [String: ToolSchemaProperty]
    public let required: [String]

    public init(properties: [String: ToolSchemaProperty], required: [String] = []) {
        self.properties = properties
        self.required = required
    }

    public func toJSONString() -> String {
        var props: [String: Any] = [:]
        for (key, prop) in properties {
            var p: [String: Any] = ["type": prop.type, "description": prop.description]
            if let ev = prop.enumValues { p["enum"] = ev }
            props[key] = p
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": props,
            "required": required
        ]
        let data = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Tool State Machine

public enum ToolState: String, Codable, Sendable {
    case idle
    case planning
    case validating
    case executing
    case completed
    case failed
    case disabled
}

// MARK: - Tool Call Structure

public struct ToolCall: Sendable, Codable {
    public let name: String
    public let arguments: [String: String]
    public let callId: String

    public init(name: String, arguments: [String: String], callId: String = UUID().uuidString) {
        self.name = name
        self.arguments = arguments
        self.callId = callId
    }
}

// MARK: - Tool Protocol

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var schema: ToolSchema { get }
    var riskLevel: RiskLevel { get }
    var requiresPermission: Bool { get }

    func validate(arguments: [String: String]) throws
    func execute(arguments: [String: String]) async throws -> String
}

// Default implementations
public extension Tool {
    var riskLevel: RiskLevel { .medium }
    var requiresPermission: Bool { riskLevel >= .high }

    func validate(arguments: [String: String]) throws {
        for required in schema.required {
            guard let val = arguments[required], !val.isEmpty else {
                throw ToolError.missingRequired(required)
            }
        }
    }
}

// MARK: - Tool Errors

public enum ToolError: Error, LocalizedError, Sendable {
    case missingRequired(String)
    case invalidParameter(String, String)
    case executionFailed(String)
    case unauthorized(String)
    case timeout
    case disabled(String)
    case pathViolation(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequired(let p): return "Missing required parameter: \(p)"
        case .invalidParameter(let p, let r): return "Invalid parameter '\(p)': \(r)"
        case .executionFailed(let r): return "Execution failed: \(r)"
        case .unauthorized(let r): return "Unauthorized: \(r)"
        case .timeout: return "Tool execution timed out"
        case .disabled(let name): return "Tool '\(name)' is disabled (too many errors)"
        case .pathViolation(let p): return "Path violation: \(p)"
        case .networkError(let r): return "Network error: \(r)"
        }
    }
}

// MARK: - Tool Permission

public enum ToolPermission: String, Codable, Sendable {
    case allow
    case deny
    case confirmRequired
}

// MARK: - Tool Execution Record

public struct ToolExecutionRecord: Sendable {
    public let id: String
    public let toolName: String
    public let arguments: [String: String]
    public let result: String
    public let state: ToolState
    public let timestamp: Date
    public let durationMs: Int

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        arguments: [String: String],
        result: String,
        state: ToolState,
        timestamp: Date = Date(),
        durationMs: Int = 0
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.state = state
        self.timestamp = timestamp
        self.durationMs = durationMs
    }
}
