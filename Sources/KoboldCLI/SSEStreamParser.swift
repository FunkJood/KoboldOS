import Foundation

// MARK: - SSEStreamParser
// Parses SSE events from /agent/stream and prints formatted terminal output.

struct SSEStreamParser {

    /// Parse and display a single SSE step dictionary from the agent stream.
    static func displayStep(_ step: [String: String]) {
        let type = step["type"] ?? ""
        let content = step["content"] ?? ""
        let tool = step["tool"] ?? ""
        let success = step["success"] != "false"
        let confidence = step["confidence"].flatMap { Double($0) }
        let subAgent = step["subAgent"]

        switch type {
        case "think":
            print(TerminalFormatter.thinking(truncate(content, max: 200)))

        case "toolCall":
            print(TerminalFormatter.toolCall(tool, truncate(content, max: 150)))

        case "toolResult":
            let summary = summarizeResult(content)
            print(TerminalFormatter.toolResult(summary, success: success))

        case "finalAnswer":
            print(TerminalFormatter.finalAnswer(content))
            if let c = confidence {
                print(TerminalFormatter.confidence(c))
            }

        case "error":
            print(TerminalFormatter.error(content))

        case "subAgentSpawn":
            let name = subAgent ?? "unknown"
            print(TerminalFormatter.info("  \u{1F916} Sub-Agent '\(name)' gestartet..."))

        case "subAgentResult":
            let name = subAgent ?? "unknown"
            let summary = summarizeResult(content)
            print(TerminalFormatter.toolResult("[\(name)] \(summary)", success: success))

        case "checkpoint":
            let id = step["checkpointId"] ?? ""
            print(TerminalFormatter.info("  \u{1F4BE} Checkpoint gespeichert: \(id)"))

        default:
            if !content.isEmpty {
                print("  \(content)")
            }
        }
    }

    /// Summarize a potentially long tool result to one line.
    private static func summarizeResult(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        if lines.count <= 1 {
            return truncate(content, max: 120)
        }
        let firstLine = truncate(lines[0], max: 80)
        return "\(firstLine) (\(lines.count) lines)"
    }

    /// Truncate text to max characters with ellipsis.
    private static func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max - 3)) + "..."
    }
}
