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
        // Strip <think>...</think> tags (Qwen3 thinking mode) before parsing
        let cleaned = stripThinkTags(response)

        // Strategy 1: Try markdown code blocks FIRST (most explicit format)
        let codeCalls = parseJSONCodeBlocks(cleaned)
        if !codeCalls.isEmpty { return codeCalls }

        // Strategy 2: Try to extract a JSON object from the response (first { to last })
        if let json = extractAndParseJSON(from: cleaned) {
            if let call = parseAgentJSON(json) {
                return [call]
            }
        }

        // Strategy 3: Try finding individual balanced JSON objects containing tool_name
        if let call = findToolCallJSON(in: cleaned) {
            return [call]
        }

        // Strategy 4: Try XML-style <tool_call> (backwards compat)
        let xmlCalls = parseXMLStyle(cleaned)
        if !xmlCalls.isEmpty { return xmlCalls }

        // Strategy 5: Line-by-line scan for JSON objects
        if let call = lineScanForJSON(in: cleaned) {
            return [call]
        }

        // Fallback: treat as implicit "response"
        let text = extractReadableText(from: cleaned)
        print("[ToolCallParser] FALLBACK: No tool call found. Response starts with: \(String(cleaned.prefix(200)))")
        return [ParsedToolCall(
            name: "response",
            arguments: ["text": text],
            thoughts: []
        )]
    }

    /// Strip <think>...</think> blocks that Qwen3 and similar models emit
    private func stripThinkTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>\\s*",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract readable text from a possibly JSON-contaminated response
    private func extractReadableText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it looks like a JSON object, try to extract "text" or "content" field
        if trimmed.hasPrefix("{"), let json = extractAndParseJSON(from: trimmed) {
            // Try to find a user-facing text field
            if let t = json["text"] as? String { return t }
            if let t = json["content"] as? String { return t }
            if let args = json["tool_args"] as? [String: Any], let t = args["text"] as? String { return t }
            if let args = json["arguments"] as? [String: Any], let t = args["text"] as? String { return t }
            if let args = json["args"] as? [String: Any], let t = args["text"] as? String { return t }
            // Last resort: return thoughts if available
            if let thoughts = json["thoughts"] as? [String], !thoughts.isEmpty {
                return thoughts.joined(separator: " ")
            }
        }

        // Strip markdown code blocks to get just the text around them
        let stripped = trimmed
            .replacingOccurrences(of: "```(?:\\w+)?\\s*\\n?[\\s\\S]*?```", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty { return stripped }

        // Not JSON — return as-is
        return trimmed
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
        } else if let n = json["action"] as? String, !n.isEmpty {
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
            json["args"] as? [String: Any] ??
            json["input"] as? [String: Any]

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
        } else if let t = json["reasoning"] as? String {
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

    // MARK: - Find balanced JSON objects containing tool_name

    private func findToolCallJSON(in text: String) -> ParsedToolCall? {
        // Find all top-level balanced {...} blocks
        let blocks = extractBalancedJSONBlocks(from: text)
        for block in blocks {
            // Try to parse this block
            if let data = block.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let call = parseAgentJSON(json) {
                return call
            }
            // Try with dirty cleaning
            let cleaned = dirtyJSONClean(block)
            if let data = cleaned.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let call = parseAgentJSON(json) {
                return call
            }
        }
        return nil
    }

    /// Extract all balanced top-level {...} JSON blocks from text
    private func extractBalancedJSONBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        var depth = 0
        var startIndex: String.Index?

        for (idx, char) in text.enumerated() {
            let strIdx = text.index(text.startIndex, offsetBy: idx)
            if char == "{" {
                if depth == 0 { startIndex = strIdx }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    let block = String(text[start...strIdx])
                    // Only collect blocks that look like they might have tool_name
                    if block.contains("tool_name") || block.contains("\"name\"") ||
                       block.contains("\"tool\"") || block.contains("\"function\"") ||
                       block.contains("\"action\"") {
                        blocks.append(block)
                    }
                }
            }
        }
        return blocks
    }

    // MARK: - Line-by-line scan for JSON

    private func lineScanForJSON(in text: String) -> ParsedToolCall? {
        let lines = text.components(separatedBy: .newlines)
        var jsonBuffer = ""
        var depth = 0

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if depth == 0 && trimmedLine.hasPrefix("{") {
                jsonBuffer = ""
                depth = 0
            }

            if depth > 0 || trimmedLine.hasPrefix("{") {
                jsonBuffer += line + "\n"
                depth += line.filter({ $0 == "{" }).count
                depth -= line.filter({ $0 == "}" }).count

                if depth <= 0 {
                    // Try to parse accumulated JSON
                    if let data = jsonBuffer.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let call = parseAgentJSON(json) {
                        return call
                    }
                    let cleaned = dirtyJSONClean(jsonBuffer)
                    if let data = cleaned.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let call = parseAgentJSON(json) {
                        return call
                    }
                    jsonBuffer = ""
                    depth = 0
                }
            }
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
