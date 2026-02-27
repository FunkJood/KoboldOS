#if os(macOS)
import Foundation

// MARK: - Notion API Tool (OAuth Token via UserDefaults)
public struct NotionApiTool: Tool {
    public let name = "notion_api"
    public let description = "Notion API: Seiten suchen, lesen, erstellen, bearbeiten und Datenbanken abfragen"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: search, get_page, create_page, update_page, query_database, raw", enumValues: ["search", "get_page", "create_page", "update_page", "query_database", "raw"], required: true),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff für search"),
            "page_id": ToolSchemaProperty(type: "string", description: "Seiten-ID für get_page/update_page"),
            "database_id": ToolSchemaProperty(type: "string", description: "Datenbank-ID für query_database/create_page"),
            "parent_id": ToolSchemaProperty(type: "string", description: "Parent-Seiten-ID für create_page (alternativ zu database_id)"),
            "title": ToolSchemaProperty(type: "string", description: "Titel für create_page"),
            "content": ToolSchemaProperty(type: "string", description: "Text-Inhalt für create_page/update_page"),
            "properties": ToolSchemaProperty(type: "string", description: "JSON-Properties für create_page/update_page"),
            "filter": ToolSchemaProperty(type: "string", description: "JSON-Filter für query_database"),
            "endpoint": ToolSchemaProperty(type: "string", description: "API-Endpunkt für raw"),
            "method": ToolSchemaProperty(type: "string", description: "HTTP-Methode für raw", enumValues: ["GET", "POST", "PATCH", "DELETE"]),
            "body": ToolSchemaProperty(type: "string", description: "JSON-Body für raw")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private func getToken() -> String? {
        let token = UserDefaults.standard.string(forKey: "kobold.notion.accessToken") ?? ""
        return token.isEmpty ? nil : token
    }

    private func notionRequest(endpoint: String, method: String = "GET", body: String? = nil) async -> String {
        guard let token = getToken() else {
            return "Error: Nicht bei Notion angemeldet. Bitte unter Einstellungen → Verbindungen → Notion anmelden."
        }

        let urlStr = endpoint.hasPrefix("http") ? endpoint : "https://api.notion.com/v1\(endpoint)"
        guard let url = URL(string: urlStr) else { return "Error: Ungültige URL: \(urlStr)" }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 30

        if let body = body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status == 401 {
                return "Error: Notion-Token ungültig. Bitte unter Einstellungen → Verbindungen → Notion neu anmelden."
            }
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {
        case "search":
            let query = arguments["query"] ?? ""
            let body = query.isEmpty ? "{}" : "{\"query\":\"\(escapeJson(query))\"}"
            return await notionRequest(endpoint: "/search", method: "POST", body: body)

        case "get_page":
            guard let pageId = arguments["page_id"], !pageId.isEmpty else { return "Error: 'page_id' Parameter fehlt." }
            return await notionRequest(endpoint: "/pages/\(pageId)")

        case "create_page":
            let title = arguments["title"] ?? "Neue Seite"
            let content = arguments["content"] ?? ""

            var parentJson: String
            if let dbId = arguments["database_id"], !dbId.isEmpty {
                parentJson = "{\"database_id\":\"\(dbId)\"}"
            } else if let parentId = arguments["parent_id"], !parentId.isEmpty {
                parentJson = "{\"page_id\":\"\(parentId)\"}"
            } else {
                return "Error: 'database_id' oder 'parent_id' Parameter fehlt."
            }

            var propsJson = arguments["properties"] ?? ""
            if propsJson.isEmpty {
                propsJson = "{\"title\":{\"title\":[{\"text\":{\"content\":\"\(escapeJson(title))\"}}]}}"
            }

            var body = "{\"parent\":\(parentJson),\"properties\":\(propsJson)"
            if !content.isEmpty {
                body += ",\"children\":[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"\(escapeJson(content))\"}}]}}]"
            }
            body += "}"
            return await notionRequest(endpoint: "/pages", method: "POST", body: body)

        case "update_page":
            guard let pageId = arguments["page_id"], !pageId.isEmpty else { return "Error: 'page_id' Parameter fehlt." }
            let propsJson = arguments["properties"] ?? "{}"
            return await notionRequest(endpoint: "/pages/\(pageId)", method: "PATCH", body: "{\"properties\":\(propsJson)}")

        case "query_database":
            guard let dbId = arguments["database_id"], !dbId.isEmpty else { return "Error: 'database_id' Parameter fehlt." }
            let filter = arguments["filter"] ?? "{}"
            let body = filter == "{}" ? "{\"page_size\":20}" : "{\"filter\":\(filter),\"page_size\":20}"
            return await notionRequest(endpoint: "/databases/\(dbId)/query", method: "POST", body: body)

        case "raw":
            guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else { return "Error: 'endpoint' Parameter fehlt." }
            let method = arguments["method"] ?? "GET"
            return await notionRequest(endpoint: endpoint, method: method, body: arguments["body"])

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

public struct NotionApiTool: Tool {
    public let name = "notion_api"
    public let description = "Notion API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Notion API ist auf Linux deaktiviert." }
}
#endif
