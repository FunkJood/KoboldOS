#if os(macOS)
import Foundation
@preconcurrency import UserNotifications

// MARK: - NotifyTool (macOS implementation)
public struct NotifyTool: Tool, Sendable {
    public let name = "notify_user"
    public let description = "Sende eine macOS Push-Benachrichtigung an den Nutzer"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "title": ToolSchemaProperty(
                    type: "string",
                    description: "Titel der Benachrichtigung",
                    required: true
                ),
                "body": ToolSchemaProperty(
                    type: "string",
                    description: "Inhalt der Benachrichtigung",
                    required: true
                )
            ],
            required: ["title", "body"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard permissionEnabled("kobold.perm.notifications") else {
            return "Benachrichtigungen sind in den Einstellungen deaktiviert."
        }
        let title = arguments["title"] ?? "KoboldOS"
        let body = arguments["body"] ?? ""

        guard !body.isEmpty else {
            throw ToolError.missingRequired("body")
        }

        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

        guard granted else {
            return "Benachrichtigungs-Berechtigung wurde nicht erteilt. Bitte in Systemeinstellungen aktivieren."
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "KOBOLD_AGENT"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)

        return "Benachrichtigung gesendet: \(title) — \(body)"
    }
}

#elseif os(Linux)
import Foundation

// MARK: - NotifyTool (Linux implementation - placeholder)
public struct NotifyTool: Tool, Sendable {
    public let name = "notify_user"
    public let description = "Sende eine Benachrichtigung an den Nutzer (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "title": ToolSchemaProperty(
                    type: "string",
                    description: "Titel der Benachrichtigung",
                    required: true
                ),
                "body": ToolSchemaProperty(
                    type: "string",
                    description: "Inhalt der Benachrichtigung",
                    required: true
                )
            ],
            required: ["title", "body"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        return "Benachrichtigungen sind auf Linux deaktiviert. Verwenden Sie stdout oder eine Logging-Lösung."
    }
}
#endif