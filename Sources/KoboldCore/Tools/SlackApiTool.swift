#if os(macOS)
import Foundation

// MARK: - Slack API Tool (OAuth Token via UserDefaults)
public struct SlackApiTool: Tool {
    public let name = "slack_api"
    public let description = "Slack API: Kanäle auflisten, Nachrichten senden, Verlauf lesen, Benutzer auflisten"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: list_channels, send_message, get_history, list_users, raw", enumValues: ["list_channels", "send_message", "get_history", "list_users", "raw"], required: true),
            "channel": ToolSchemaProperty(type: "string", description: "Channel-ID (z.B. 'C01234ABCDE')"),
            "text": ToolSchemaProperty(type: "string", description: "Nachrichtentext für send_message"),
            "limit": ToolSchemaProperty(type: "string", description: "Max. Anzahl Ergebnisse (Standard: 20)"),
            "endpoint": ToolSchemaProperty(type: "string", description: "API-Methode für raw (z.B. 'conversations.info')"),
            "params": ToolSchemaProperty(type: "string", description: "JSON-Parameter für raw")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private func getToken() -> String? {
        let token = UserDefaults.standard.string(forKey: "kobold.slack.accessToken") ?? ""
        return token.isEmpty ? nil : token
    }

    private func slackRequest(method: String, params: [String: String] = [:]) async -> String {
        guard let token = getToken() else {
            return "Error: Nicht bei Slack angemeldet. Bitte unter Einstellungen → Verbindungen → Slack anmelden."
        }

        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            return "Error: Ungültige API-Methode"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if !params.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status == 401 {
                return "Error: Slack-Token ungültig oder abgelaufen. Bitte unter Einstellungen → Verbindungen → Slack neu anmelden."
            }
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }

            // Check Slack's own error response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, !ok {
                let error = json["error"] as? String ?? "unknown"
                if error == "invalid_auth" || error == "token_expired" || error == "token_revoked" {
                    return "Error: Slack-Token ungültig (\(error)). Bitte unter Einstellungen → Verbindungen → Slack neu anmelden."
                }
                return "Error: Slack API Fehler: \(error)"
            }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let limit = arguments["limit"] ?? "20"

        switch action {
        case "list_channels":
            return await slackRequest(method: "conversations.list", params: ["limit": limit, "types": "public_channel,private_channel"])

        case "send_message":
            guard let channel = arguments["channel"], !channel.isEmpty else { return "Error: 'channel' Parameter fehlt." }
            guard let text = arguments["text"], !text.isEmpty else { return "Error: 'text' Parameter fehlt." }
            return await slackRequest(method: "chat.postMessage", params: ["channel": channel, "text": text])

        case "get_history":
            guard let channel = arguments["channel"], !channel.isEmpty else { return "Error: 'channel' Parameter fehlt." }
            return await slackRequest(method: "conversations.history", params: ["channel": channel, "limit": limit])

        case "list_users":
            return await slackRequest(method: "users.list", params: ["limit": limit])

        case "raw":
            guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else { return "Error: 'endpoint' Parameter fehlt." }
            var params: [String: String] = [:]
            if let paramsStr = arguments["params"], !paramsStr.isEmpty,
               let paramsData = paramsStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: paramsData) as? [String: String] {
                params = parsed
            }
            return await slackRequest(method: endpoint, params: params)

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }
}

#elseif os(Linux)
import Foundation

public struct SlackApiTool: Tool {
    public let name = "slack_api"
    public let description = "Slack API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Slack API ist auf Linux deaktiviert." }
}
#endif
