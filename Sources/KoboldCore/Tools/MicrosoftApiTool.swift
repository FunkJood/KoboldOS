#if os(macOS)
import Foundation

// MARK: - Microsoft Graph API Tool (OAuth Token via UserDefaults)
public struct MicrosoftApiTool: Tool {
    public let name = "microsoft_api"
    public let description = "Microsoft Graph API: OneDrive, Outlook, Calendar, Teams Chat"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: list_files, upload_file, list_mail, send_mail, list_events, create_event, send_chat, raw", enumValues: ["list_files", "upload_file", "list_mail", "send_mail", "list_events", "create_event", "send_chat", "raw"], required: true),
            "path": ToolSchemaProperty(type: "string", description: "OneDrive-Pfad für list_files/upload_file (Standard: root)"),
            "content": ToolSchemaProperty(type: "string", description: "Datei-Inhalt für upload_file oder Nachricht für send_chat"),
            "to": ToolSchemaProperty(type: "string", description: "Empfänger für send_mail/send_chat"),
            "subject": ToolSchemaProperty(type: "string", description: "Betreff für send_mail/create_event"),
            "body": ToolSchemaProperty(type: "string", description: "Inhalt für send_mail/create_event"),
            "start": ToolSchemaProperty(type: "string", description: "Startzeit für create_event (ISO 8601)"),
            "end": ToolSchemaProperty(type: "string", description: "Endzeit für create_event (ISO 8601)"),
            "endpoint": ToolSchemaProperty(type: "string", description: "API-Endpunkt für raw"),
            "method": ToolSchemaProperty(type: "string", description: "HTTP-Methode für raw", enumValues: ["GET", "POST", "PUT", "PATCH", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "JSON-Body für raw")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private let oauth = OAuthTokenHelper(
        prefix: "kobold.microsoft",
        tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    )

    private func getToken() async -> String? {
        await oauth.getValidToken()
    }

    private func graphRequest(endpoint: String, method: String = "GET", body: String? = nil) async -> String {
        guard var token = await getToken() else {
            return "Error: Nicht bei Microsoft angemeldet oder Token abgelaufen. Bitte unter Einstellungen → Verbindungen → Microsoft anmelden."
        }

        let urlStr = endpoint.hasPrefix("http") ? endpoint : "https://graph.microsoft.com/v1.0\(endpoint)"
        guard let url = URL(string: urlStr) else { return "Error: Ungültige URL: \(urlStr)" }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let body = body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Auto-refresh on 401
            if status == 401 {
                if let newToken = await oauth.refreshToken() {
                    token = newToken
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let retryBody = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(empty)"
                    if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryBody)" }
                    return retryBody
                } else {
                    return "Error: Microsoft-Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden unter Einstellungen → Verbindungen → Microsoft."
                }
            }

            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {
        case "list_files":
            let path = arguments["path"] ?? ""
            if path.isEmpty || path == "/" || path == "root" {
                return await graphRequest(endpoint: "/me/drive/root/children?$select=name,size,lastModifiedDateTime,folder&$top=25")
            }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return await graphRequest(endpoint: "/me/drive/root:/\(encoded):/children?$select=name,size,lastModifiedDateTime,folder&$top=25")

        case "upload_file":
            guard let path = arguments["path"], !path.isEmpty else { return "Error: 'path' Parameter fehlt." }
            guard let content = arguments["content"], !content.isEmpty else { return "Error: 'content' Parameter fehlt." }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return await graphRequest(endpoint: "/me/drive/root:/\(encoded):/content", method: "PUT", body: content)

        case "list_mail":
            return await graphRequest(endpoint: "/me/messages?$select=subject,from,receivedDateTime,isRead&$top=15&$orderby=receivedDateTime desc")

        case "send_mail":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt." }
            guard let subject = arguments["subject"], !subject.isEmpty else { return "Error: 'subject' Parameter fehlt." }
            let body = arguments["body"] ?? ""
            let jsonBody = """
            {"message":{"subject":"\(escapeJson(subject))","body":{"contentType":"Text","content":"\(escapeJson(body))"},"toRecipients":[{"emailAddress":{"address":"\(escapeJson(to))"}}]}}
            """
            return await graphRequest(endpoint: "/me/sendMail", method: "POST", body: jsonBody)

        case "list_events":
            return await graphRequest(endpoint: "/me/events?$select=subject,start,end,location&$top=15&$orderby=start/dateTime")

        case "create_event":
            guard let subject = arguments["subject"], !subject.isEmpty else { return "Error: 'subject' Parameter fehlt." }
            guard let start = arguments["start"], !start.isEmpty else { return "Error: 'start' Parameter fehlt (ISO 8601)." }
            guard let end = arguments["end"], !end.isEmpty else { return "Error: 'end' Parameter fehlt (ISO 8601)." }
            let body = arguments["body"] ?? ""
            let jsonBody = """
            {"subject":"\(escapeJson(subject))","body":{"contentType":"Text","content":"\(escapeJson(body))"},"start":{"dateTime":"\(start)","timeZone":"Europe/Berlin"},"end":{"dateTime":"\(end)","timeZone":"Europe/Berlin"}}
            """
            return await graphRequest(endpoint: "/me/events", method: "POST", body: jsonBody)

        case "send_chat":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt (User-ID oder Chat-ID)." }
            guard let content = arguments["content"], !content.isEmpty else { return "Error: 'content' Parameter fehlt." }
            let jsonBody = "{\"body\":{\"content\":\"\(escapeJson(content))\"}}"
            return await graphRequest(endpoint: "/chats/\(to)/messages", method: "POST", body: jsonBody)

        case "raw":
            guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else { return "Error: 'endpoint' Parameter fehlt." }
            let method = arguments["method"] ?? "GET"
            return await graphRequest(endpoint: endpoint, method: method, body: arguments["params"])

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    private func escapeJson(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

#elseif os(Linux)
import Foundation

public struct MicrosoftApiTool: Tool {
    public let name = "microsoft_api"
    public let description = "Microsoft Graph API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Microsoft API ist auf Linux deaktiviert." }
}
#endif
