import Foundation

// MARK: - ResponseTool
// Like AgentZero's "response" tool — the ONLY way for the agent to deliver a final answer.
// When called, the agent loop breaks and returns the text to the user.
// This ensures every LLM output is a structured JSON tool call, never raw text.

public struct ResponseTool: Tool {
    public let name = "response"
    public let description = "Deliver your final answer to the user. Use this tool ONLY when you have completed the task or want to respond directly. The text will be shown to the user."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "text": ToolSchemaProperty(type: "string", description: "Your complete answer to the user", required: true)
            ],
            required: ["text"]
        )
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let text = arguments["text"], !text.isEmpty else {
            throw ToolError.missingRequired("text")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        // The response text is returned as-is — AgentLoop handles it as terminal
        return arguments["text"] ?? ""
    }
}
