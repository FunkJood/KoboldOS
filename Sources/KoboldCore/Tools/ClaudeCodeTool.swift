#if os(macOS)
import Foundation

// MARK: - ClaudeCodeTool (Agent can invoke Claude Code CLI for coding tasks)

public struct ClaudeCodeTool: Tool, @unchecked Sendable {
    public let name = "claude_code"
    public let description = "Claude Code CLI für Coding-Aufgaben nutzen. Delegiert komplexe Programmieraufgaben an Claude Code (ask, review). Nur verfügbar wenn Claude Code CLI installiert ist."
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "ask | review", required: true),
            "prompt": ToolSchemaProperty(type: "string", description: "Aufgabe/Frage für Claude Code", required: true),
            "working_dir": ToolSchemaProperty(type: "string", description: "Arbeitsverzeichnis (optional, Standard: ~/)")
        ], required: ["action", "prompt"])
    }

    private let backend = ClaudeCodeBackend()

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard backend.isAvailable() else {
            return "Error: Claude Code CLI nicht gefunden. Installation: https://docs.anthropic.com/en/docs/claude-code"
        }

        let action = arguments["action"] ?? "ask"
        let prompt = arguments["prompt"] ?? ""
        guard !prompt.isEmpty else { return "Error: 'prompt' Parameter fehlt." }

        switch action {
        case "ask":
            return await askClaude(prompt: prompt, workingDir: arguments["working_dir"])
        case "review":
            return await reviewCode(prompt: prompt, workingDir: arguments["working_dir"])
        default:
            return "Unbekannte Aktion: \(action). Verfügbar: ask, review"
        }
    }

    private func askClaude(prompt: String, workingDir: String?) async -> String {
        do {
            let result = try await backend.executeCodingTask(prompt)
            if result.isEmpty { return "Claude Code hat keine Ausgabe erzeugt." }
            // Cap output to prevent overwhelming the agent context
            let output = result.count > 6000 ? String(result.prefix(6000)) + "\n\n[... gekürzt, \(result.count) Zeichen gesamt]" : result
            return "Claude Code Ergebnis:\n\n\(output)"
        } catch {
            return "Error: Claude Code fehlgeschlagen — \(error.localizedDescription)"
        }
    }

    private func reviewCode(prompt: String, workingDir: String?) async -> String {
        let reviewPrompt = "Review the following code and provide feedback on quality, bugs, and improvements:\n\n\(prompt)"
        do {
            let result = try await backend.executeCodingTask(reviewPrompt)
            if result.isEmpty { return "Claude Code hat keine Ausgabe erzeugt." }
            let output = result.count > 6000 ? String(result.prefix(6000)) + "\n\n[... gekürzt]" : result
            return "Code-Review Ergebnis:\n\n\(output)"
        } catch {
            return "Error: Code-Review fehlgeschlagen — \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct ClaudeCodeTool: Tool, Sendable {
    public let name = "claude_code"
    public let description = "Claude Code CLI (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func execute(arguments: [String: String]) async throws -> String { "Claude Code ist auf Linux deaktiviert." }
}
#endif
