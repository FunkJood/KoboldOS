import Foundation

// MARK: - ToolCallParser (AgentZero-style)
// Parses LLM output as JSON with tool_name/tool_args fields.
// Supports multiple formats and dirty JSON parsing for local models.
//
// Expected LLM format:
// {
//     "thoughts": ["reasoning here"],
//     "tool_name": "tool_name",
//     "tool_args": {"key": "value"}
// }

public struct ParsedToolCall: Sendable {
    public let callId: String
    public let name: String
    public let arguments: [String: String]
    public let thoughts: [String]
    public let confidence: Double?

    public init(callId: String = UUID().uuidString, name: String, arguments: [String: String], thoughts: [String] = [], confidence: Double? = nil) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
        self.thoughts = thoughts
        self.confidence = confidence
    }

    public func toToolCall() -> ToolCall {
        ToolCall(name: name, arguments: arguments, callId: callId)
    }
}

public struct ToolCallParser: Sendable {

    public init() {}

    // MARK: - Parse LLM Response (AgentZero-style)

    public func parse(response: String) -> [ParsedToolCall] {
        // Strategy: extract JSON from response, then parse tool_name/tool_args

        // Step 1: Try to extract a JSON object from the response
        if let json = extractAndParseJSON(from: response) {
            if let call = parseAgentJSON(json) {
                return [call]
            }
        }

        // Step 2: Try XML-style <tool_call> (backwards compat)
        let xmlCalls = parseXMLStyle(response)
        if !xmlCalls.isEmpty { return xmlCalls }

        // Step 3: Try code blocks
        let codeCalls = parseJSONCodeBlocks(response)
        if !codeCalls.isEmpty { return codeCalls }

        // Step 4: If response looks like plain text with no JSON at all,
        // treat it as an implicit "response" tool call (the LLM just answered directly)
        if !response.contains("{") {
            return [ParsedToolCall(
                name: "response",
                arguments: ["text": response.trimmingCharacters(in: .whitespacesAndNewlines)],
                thoughts: []
            )]
        }

        return []
    }

    // MARK: - Format Tool Result (fed back to LLM)

    public func formatToolResult(_ result: ToolResult, callId: String, toolName: String) -> String {
        switch result {
        case .success(let output, _):
            return "[Tool '\(toolName)' completed successfully]\n\(output)"
        case .failure(let error, _):
            return "[Tool '\(toolName)' failed]\n\(error)"
        }
    }

    // MARK: - AgentZero-style JSON parsing

    private func parseAgentJSON(_ json: [String: Any]) -> ParsedToolCall? {
        // Extract tool name — try multiple key names
        let name: String
        if let n = json["tool_name"] as? String, !n.isEmpty {
            name = n
        } else if let n = json["name"] as? String, !n.isEmpty {
            name = n
        } else if let n = json["tool"] as? String, !n.isEmpty {
            name = n
        } else if let n = json["function"] as? String, !n.isEmpty {
            name = n
        } else {
            return nil
        }

        // Extract arguments — try multiple key names
        var args: [String: String] = [:]
        let argsObj: [String: Any]? =
            json["tool_args"] as? [String: Any] ??
            json["parameters"] as? [String: Any] ??
            json["arguments"] as? [String: Any] ??
            json["args"] as? [String: Any]

        if let argsObj {
            for (key, value) in argsObj {
                args[key] = stringify(value)
            }
        }

        // Extract thoughts
        var thoughts: [String] = []
        if let t = json["thoughts"] as? [String] {
            thoughts = t
        } else if let t = json["thoughts"] as? [Any] {
            thoughts = t.map { stringify($0) }
        } else if let t = json["thought"] as? String {
            thoughts = [t]
        } else if let t = json["headline"] as? String {
            thoughts = [t]
        }

        // Extract confidence
        let confidence = json["confidence"] as? Double

        return ParsedToolCall(name: name, arguments: args, thoughts: thoughts, confidence: confidence)
    }

    // MARK: - Extract JSON from LLM output (dirty parsing)

    private func extractAndParseJSON(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first { and last } to extract the JSON object
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}") else {
            return nil
        }
        guard firstBrace < lastBrace else { return nil }

        let jsonStr = String(trimmed[firstBrace...lastBrace])

        // Try standard JSON parsing first
        if let data = jsonStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Dirty JSON: fix common LLM mistakes
        let cleaned = dirtyJSONClean(jsonStr)
        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }

    /// Fixes common JSON errors from local LLMs
    private func dirtyJSONClean(_ json: String) -> String {
        var s = json

        // Remove trailing commas before } or ]
        s = s.replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)

        // Fix single quotes → double quotes (but not inside strings)
        // Only do this if there are no double-quoted strings already
        if !s.contains("\"") && s.contains("'") {
            s = s.replacingOccurrences(of: "'", with: "\"")
        }

        // Fix unquoted keys: { key: "value" } → { "key": "value" }
        s = s.replacingOccurrences(
            of: "([{,])\\s*([a-zA-Z_][a-zA-Z0-9_]*)\\s*:",
            with: "$1\"$2\":",
            options: .regularExpression
        )

        // Remove comments (// ... and /* ... */)
        s = s.replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "/\\*.*?\\*/", with: "", options: .regularExpression)

        // Fix Python True/False/None → JSON true/false/null
        s = s.replacingOccurrences(of: ":\\s*True\\b", with: ": true", options: .regularExpression)
        s = s.replacingOccurrences(of: ":\\s*False\\b", with: ": false", options: .regularExpression)
        s = s.replacingOccurrences(of: ":\\s*None\\b", with: ": null", options: .regularExpression)

        return s
    }

    // MARK: - XML-style (backwards compat)

    private func parseXMLStyle(_ text: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        let pattern = "<tool_call[^>]*>(.*?)</tool_call>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return calls
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches {
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { continue }

            let jsonStr = String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = extractAndParseJSON(from: jsonStr),
               let call = parseAgentJSON(json) {
                calls.append(call)
            }
        }

        return calls
    }

    // MARK: - Code blocks

    private func parseJSONCodeBlocks(_ text: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        let pattern = "```(?:\\w+)?\\s*\\n?(\\{[\\s\\S]*?\\})\\s*```"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return calls
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches {
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { continue }

            let jsonStr = String(text[captureRange])
            if let json = extractAndParseJSON(from: jsonStr),
               let call = parseAgentJSON(json) {
                calls.append(call)
            }
        }

        return calls
    }

    // MARK: - Stringify

    private func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as Int: return String(n)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        case let a as [Any]:
            let items = a.map { stringify($0) }
            return items.joined(separator: ", ")
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let str = String(data: data, encoding: .utf8) { return str }
            return String(describing: d)
        default: return String(describing: value)
        }
    }
}
