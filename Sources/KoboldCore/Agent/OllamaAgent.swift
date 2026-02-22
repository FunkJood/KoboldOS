import Foundation

// MARK: - Types

public struct OllamaMessage: Codable, Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AgentResponse: Sendable {
    public let text: String
    public let steps: [AgentStep]
}

// MARK: - OllamaAgent

public actor OllamaAgent {
    public static let shared = OllamaAgent()

    private let baseURL    = "http://localhost:11434"
    private let maxLoops   = 8      // prevent infinite agentic loops
    private let tools      = ToolEngine.shared

    private var _model: String = "qwen2.5:1.5b"

    public var model: String {
        get { _model }
    }

    private init() {}

    public func setModel(_ name: String) {
        _model = name
    }

    // MARK: - Main entry point

    public func chat(
        message: String,
        history: [OllamaMessage],
        agentMode: Bool
    ) async throws -> AgentResponse {

        // Build full message list
        var messages: [OllamaMessage] = [
            OllamaMessage(role: "system", content: agentMode ? toolSystemPrompt : "You are KoboldOS, a helpful AI assistant running locally on macOS.")
        ]
        messages.append(contentsOf: history)
        messages.append(OllamaMessage(role: "user", content: message))

        var steps: [AgentStep] = []

        for _ in 0..<maxLoops {
            let reply = try await ollamaChat(messages: messages)

            // Check for tool calls in the response
            if agentMode, let toolCall = parseToolCall(from: reply) {
                // Append assistant reply to context
                messages.append(OllamaMessage(role: "assistant", content: reply))

                // Execute the tool
                let t0 = DispatchTime.now().uptimeNanoseconds
                let result = await tools.execute(name: toolCall.name, argsJSON: toolCall.argsJSON)
                let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)

                steps.append(AgentStep(
                    tool: toolCall.name,
                    args: toolCall.argsJSON,
                    result: result,
                    durationMs: ms
                ))

                // Feed result back as user message (tool result format)
                let toolResultMsg = "<tool_result>\n\(result)\n</tool_result>"
                messages.append(OllamaMessage(role: "user", content: toolResultMsg))

                // Continue loop — model will now process the result
                continue
            }

            // No tool call — this is the final answer
            return AgentResponse(text: reply, steps: steps)
        }

        return AgentResponse(text: "(Agent loop limit reached)", steps: steps)
    }

    // MARK: - Ollama /api/chat

    private func ollamaChat(messages: [OllamaMessage]) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw URLError(.badURL)
        }

        let body: [String: Any] = [
            "model": _model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "options": ["temperature": 0.7]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw URLError(.cannotParseResponse)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "OllamaAgent", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama error: \(errText)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg  = json["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw NSError(domain: "OllamaAgent", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
        }
        return text
    }

    // MARK: - Tool call parsing

    private struct ParsedToolCall {
        let name: String
        let argsJSON: String
    }

    private func parseToolCall(from text: String) -> ParsedToolCall? {
        // Pattern: <tool_call>\n{...}\n</tool_call>
        guard let startRange = text.range(of: "<tool_call>"),
              let endRange   = text.range(of: "</tool_call>") else { return nil }

        let jsonText = text[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonText.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }

        // Extract args sub-object as JSON string
        let argsJSON: String
        if let argsObj = obj["args"] {
            argsJSON = (try? String(data: JSONSerialization.data(withJSONObject: argsObj), encoding: .utf8)) ?? "{}"
        } else {
            argsJSON = "{}"
        }

        return ParsedToolCall(name: name, argsJSON: argsJSON)
    }

    // MARK: - Model discovery

    public func availableModels() async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
