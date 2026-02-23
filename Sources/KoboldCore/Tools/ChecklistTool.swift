import Foundation

// MARK: - ChecklistTool
// Allows the agent to create/update a visual checklist overlay in the chat UI.
// The agent uses this to show multi-step progress to the user.

public struct ChecklistTool: Tool, Sendable {
    public let name = "checklist"
    public let description = "Erstelle oder aktualisiere eine visuelle Checkliste im Chat. Nutze dies bei mehrstufigen Aufgaben um dem Nutzer den Fortschritt zu zeigen."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion: 'set' (neue Liste), 'check' (Schritt abhaken), 'clear' (Liste löschen)",
                    required: true
                ),
                "items": ToolSchemaProperty(
                    type: "string",
                    description: "Komma-getrennte Liste der Schritte (nur bei action=set). Beispiel: 'Dateien suchen,Backup erstellen,Aufräumen'",
                    required: false
                ),
                "index": ToolSchemaProperty(
                    type: "string",
                    description: "Index des abzuhakenden Schritts (0-basiert, nur bei action=check)",
                    required: false
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? "set"

        switch action {
        case "set":
            guard let itemsStr = arguments["items"], !itemsStr.isEmpty else {
                throw ToolError.missingRequired("items")
            }
            let items = itemsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldChecklist"),
                    object: nil,
                    userInfo: ["action": "set", "items": items]
                )
            }
            return "Checkliste erstellt mit \(items.count) Schritten: \(items.joined(separator: ", "))"

        case "check":
            guard let indexStr = arguments["index"], let index = Int(indexStr) else {
                throw ToolError.missingRequired("index")
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldChecklist"),
                    object: nil,
                    userInfo: ["action": "check", "index": index]
                )
            }
            return "Schritt \(index) abgehakt."

        case "clear":
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldChecklist"),
                    object: nil,
                    userInfo: ["action": "clear"]
                )
            }
            return "Checkliste gelöscht."

        default:
            return "Unbekannte Aktion: \(action). Verwende 'set', 'check' oder 'clear'."
        }
    }
}
