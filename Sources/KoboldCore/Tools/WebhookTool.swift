import Foundation

// MARK: - Webhook Tool (HTTP POST senden + empfangene Webhooks anzeigen)
public struct WebhookTool: Tool {
    public let name = "webhook"
    public let description = "Webhooks senden und empfangen: HTTP POST an URLs senden, empfangene Webhooks auflisten, Pfade registrieren"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: send, list_received, register_path, unregister_path, status", enumValues: ["send", "list_received", "register_path", "unregister_path", "status"], required: true),
            "url": ToolSchemaProperty(type: "string", description: "Ziel-URL für send"),
            "body": ToolSchemaProperty(type: "string", description: "JSON-Body für send"),
            "headers": ToolSchemaProperty(type: "string", description: "Zusätzliche Headers als JSON-Objekt für send"),
            "path": ToolSchemaProperty(type: "string", description: "Webhook-Pfad für register_path/unregister_path"),
            "limit": ToolSchemaProperty(type: "string", description: "Max. Anzahl Ergebnisse (Standard: 10)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {
        case "send":
            guard let urlStr = arguments["url"], !urlStr.isEmpty else { return "Error: 'url' Parameter fehlt." }
            let body = arguments["body"] ?? "{}"
            let headersStr = arguments["headers"]
            return await sendWebhook(urlString: urlStr, body: body, headersJson: headersStr)

        case "list_received":
            let limit = Int(arguments["limit"] ?? "10") ?? 10
            return listReceived(limit: limit)

        case "register_path":
            guard let path = arguments["path"], !path.isEmpty else { return "Error: 'path' Parameter fehlt." }
            return registerPath(path)

        case "unregister_path":
            guard let path = arguments["path"], !path.isEmpty else { return "Error: 'path' Parameter fehlt." }
            return unregisterPath(path)

        case "status":
            return getStatus()

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: send, list_received, register_path, unregister_path, status"
        }
    }

    // MARK: - Send Webhook

    private func sendWebhook(urlString: String, body: String, headersJson: String?) async -> String {
        guard let url = URL(string: urlString) else {
            return "Error: Ungültige URL: \(urlString)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KoboldOS Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        // Custom headers
        if let headersStr = headersJson, !headersStr.isEmpty,
           let headersData = headersStr.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(4096), encoding: .utf8) ?? "(empty)"

            if status >= 400 {
                return "Error: HTTP \(status): \(responseStr)"
            }
            return "Webhook gesendet an \(urlString) (HTTP \(status)).\nAntwort: \(responseStr)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Received Webhooks (reads from WebhookServer via UserDefaults bridge)

    private func listReceived(limit: Int) -> String {
        // Read from shared storage
        guard let data = UserDefaults.standard.data(forKey: "kobold.webhook.received"),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "Keine empfangenen Webhooks. Stelle sicher, dass der Webhook-Server in den Einstellungen aktiviert ist."
        }

        let recent = entries.suffix(limit)
        if recent.isEmpty { return "Keine empfangenen Webhooks." }

        var result = "Empfangene Webhooks (letzte \(recent.count)):\n\n"
        for (i, entry) in recent.enumerated() {
            let method = entry["method"] as? String ?? "?"
            let path = entry["path"] as? String ?? "?"
            let timestamp = entry["timestamp"] as? String ?? "?"
            let body = entry["body"] as? String ?? ""
            result += "[\(i + 1)] \(method) \(path) — \(timestamp)\n"
            if !body.isEmpty { result += "    Body: \(body.prefix(200))\n" }
            result += "\n"
        }
        return String(result.prefix(8192))
    }

    private func registerPath(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        var paths = UserDefaults.standard.stringArray(forKey: "kobold.webhook.paths") ?? []
        if paths.contains(normalized) {
            return "Pfad bereits registriert: \(normalized)"
        }
        paths.append(normalized)
        UserDefaults.standard.set(paths, forKey: "kobold.webhook.paths")
        return "Webhook-Pfad registriert: \(normalized)"
    }

    private func unregisterPath(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        var paths = UserDefaults.standard.stringArray(forKey: "kobold.webhook.paths") ?? []
        guard let index = paths.firstIndex(of: normalized) else {
            return "Pfad nicht gefunden: \(normalized)"
        }
        paths.remove(at: index)
        UserDefaults.standard.set(paths, forKey: "kobold.webhook.paths")
        return "Webhook-Pfad entfernt: \(normalized)"
    }

    private func getStatus() -> String {
        let isRunning = UserDefaults.standard.bool(forKey: "kobold.webhook.running")
        let port = UserDefaults.standard.integer(forKey: "kobold.webhook.port")
        let paths = UserDefaults.standard.stringArray(forKey: "kobold.webhook.paths") ?? []

        var result = "Webhook-Server Status:\n"
        result += "  Aktiv: \(isRunning ? "Ja" : "Nein")\n"
        if isRunning { result += "  Port: \(port)\n" }
        result += "  Registrierte Pfade: \(paths.isEmpty ? "keine" : paths.joined(separator: ", "))\n"
        return result
    }
}
