import Foundation

// MARK: - App Terminal Tool
// Lets the agent control the in-app terminal via NotificationCenter → SharedTerminalManager

public struct AppTerminalTool: Tool, @unchecked Sendable {
    public let name = "app_terminal"
    public let description = """
        Control the in-app terminal. Actions: send_command (execute a shell command), \
        read_output (get last N lines), snapshot (get terminal state), \
        new_session (create new terminal tab), close_session, list_sessions. \
        Use this when the user is in the Apps tab or asks you to run something in the terminal.
        """
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action to perform",
                    enumValues: ["send_command", "read_output", "snapshot", "new_session", "close_session", "list_sessions"],
                    required: true
                ),
                "command": ToolSchemaProperty(
                    type: "string",
                    description: "Shell command to send (for send_command action)"
                ),
                "session_id": ToolSchemaProperty(
                    type: "string",
                    description: "Target session UUID (optional, defaults to active session)"
                ),
                "lines": ToolSchemaProperty(
                    type: "string",
                    description: "Number of output lines to read (for read_output, default: 50)"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard let action = arguments["action"] else {
            throw ToolError.missingRequired("action")
        }

        // Check permission
        guard permissionEnabled("kobold.permission.appTerminal", defaultValue: true) else {
            return "[App-Terminal-Steuerung ist deaktiviert. Aktiviere sie in Einstellungen → Apps.]"
        }

        let resultId = UUID().uuidString
        let sessionId = arguments["session_id"]

        // Session-Validierung vor der Verwendung
        if let sessionIdStr = sessionId, !sessionIdStr.isEmpty {
            guard UUID(uuidString: sessionIdStr) != nil else {
                return "[Ungültige Session-ID: \(sessionIdStr)]"
            }
        }

        switch action {
        case "send_command":
            guard let command = arguments["command"], !command.isEmpty else {
                throw ToolError.missingRequired("command")
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "send_command",
                        "command": command,
                        "session_id": sessionId ?? "",
                        "result_id": resultId
                    ]
                )
            }
            // Single wait - no polling loop (prevents continuation leak)
            let output = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 15)
            defer { Task { await AppToolResultWaiter.shared.cleanup(id: resultId) } }

            if let output = output, !output.isEmpty {
                if output.contains("[Fehler:") {
                    return "[Terminal-Fehler: \(output)]"
                }
                return output
            }

            return "[Befehl gesendet: \(command)]"

        case "read_output":
            let lines = Int(arguments["lines"] ?? "50") ?? 50
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "read_output",
                        "lines": "\(lines)",
                        "session_id": sessionId ?? "",
                        "result_id": resultId
                    ]
                )
            }
            let output = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 5)
            return output ?? "[Kein Output verfügbar]"

        case "snapshot":
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "snapshot",
                        "session_id": sessionId ?? "",
                        "result_id": resultId
                    ]
                )
            }
            let output = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 5)
            return output ?? "[Snapshot nicht verfügbar]"

        case "new_session":
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldNavigateTo"),
                    object: nil,
                    userInfo: ["tab": "applications", "sub_tab": "terminal"]
                )
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "new_session",
                        "result_id": resultId
                    ]
                )
            }
            let output = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 5)
            return output ?? "[Neue Terminal-Session erstellt]"

        case "close_session":
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "close_session",
                        "session_id": sessionId ?? "",
                        "result_id": resultId
                    ]
                )
            }
            return "[Session geschlossen]"

        case "list_sessions":
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldAppTerminalAction"),
                    object: nil,
                    userInfo: [
                        "action": "list_sessions",
                        "result_id": resultId
                    ]
                )
            }
            let output = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 5)
            return output ?? "[Keine Sessions]"

        default:
            return "[Unbekannte Aktion: \(action). Verfügbar: send_command, read_output, snapshot, new_session, close_session, list_sessions]"
        }
    }

}
