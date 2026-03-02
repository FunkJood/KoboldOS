import Foundation

// MARK: - A2AClientTool (Agent can discover and communicate with remote A2A agents)

public struct A2AClientTool: Tool, @unchecked Sendable {
    public let name = "a2a_call"
    public let description = "Mit einem entfernten A2A-kompatiblen Agenten kommunizieren. Aktionen: discover (Agent Card abrufen), send (Nachricht senden und auf Antwort warten)."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "discover | send", enumValues: ["discover", "send"], required: true),
            "url": ToolSchemaProperty(type: "string", description: "Basis-URL des entfernten Agenten (z.B. http://192.168.1.5:8080)", required: true),
            "message": ToolSchemaProperty(type: "string", description: "Nachricht an den entfernten Agenten (für send)"),
            "token": ToolSchemaProperty(type: "string", description: "Bearer Token für Authentifizierung"),
            "task_id": ToolSchemaProperty(type: "string", description: "Bestehende Task-ID für Konversation (optional)"),
            "context_id": ToolSchemaProperty(type: "string", description: "Context-ID für Gruppierung (optional)")
        ], required: ["action", "url"])
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? "discover"
        let baseURL = (arguments["url"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = arguments["token"] ?? ""

        switch action {
        case "discover":
            return await discoverAgent(baseURL: baseURL)
        case "send":
            let message = arguments["message"] ?? ""
            guard !message.isEmpty else { return "Error: 'message' Parameter fehlt für send." }
            return await sendMessage(baseURL: baseURL, message: message, token: token,
                                    taskId: arguments["task_id"], contextId: arguments["context_id"])
        default:
            return "Unbekannte Aktion: \(action). Verfügbar: discover, send"
        }
    }

    // MARK: - Discover

    private func discoverAgent(baseURL: String) async -> String {
        guard let url = URL(string: "\(baseURL)/.well-known/agent.json") else {
            return "Error: Ungültige URL: \(baseURL)"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return "Agent Card nicht gefunden (HTTP \(status))" }

            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                let text = String(data: pretty, encoding: .utf8) ?? "{}"
                return "Agent Card von \(baseURL):\n\n\(text)"
            }
            return String(data: data, encoding: .utf8) ?? "(keine Daten)"
        } catch {
            return "Error: Verbindung fehlgeschlagen — \(error.localizedDescription)"
        }
    }

    // MARK: - Send (blocking JSON-RPC message/send)

    private func sendMessage(baseURL: String, message: String, token: String,
                             taskId: String?, contextId: String?) async -> String {
        guard let url = URL(string: "\(baseURL)/a2a") else {
            return "Error: Ungültige URL: \(baseURL)/a2a"
        }

        var params: [String: Any] = [
            "message": [
                "role": "user",
                "parts": [["text": message]]
            ]
        ]
        if let tid = taskId { params["taskId"] = tid }
        if let cid = contextId { params["contextId"] = cid }

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "message/send",
            "params": params
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: rpcBody) else {
            return "Error: JSON-Serialisierung fehlgeschlagen"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = bodyData
        req.timeoutInterval = 300  // 5 min for blocking agent calls

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard status == 200 else {
                let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                return "Error HTTP \(status): \(body)"
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return String(data: data.prefix(4096), encoding: .utf8) ?? "(keine Daten)"
            }

            // Check for JSON-RPC error
            if let error = json["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unbekannter Fehler"
                let code = error["code"] as? Int ?? -1
                return "A2A Fehler [\(code)]: \(msg)"
            }

            // Extract result
            if let result = json["result"] as? [String: Any] {
                if let artifacts = result["artifacts"] as? [[String: Any]] {
                    let texts = artifacts.flatMap { artifact -> [String] in
                        let parts = artifact["parts"] as? [[String: Any]] ?? []
                        return parts.compactMap { $0["text"] as? String }
                    }
                    if !texts.isEmpty {
                        let state = (result["status"] as? [String: Any])?["state"] as? String ?? "unknown"
                        let tid = result["id"] as? String ?? "unknown"
                        return "[A2A Task \(tid) (\(state))]\n\n\(texts.joined(separator: "\n"))"
                    }
                }
                // Fallback: raw result
                if let pretty = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    return String(data: pretty, encoding: .utf8) ?? "{}"
                }
            }

            return String(data: data.prefix(4096), encoding: .utf8) ?? "(keine Daten)"
        } catch {
            return "Error: A2A Anfrage fehlgeschlagen — \(error.localizedDescription)"
        }
    }
}
