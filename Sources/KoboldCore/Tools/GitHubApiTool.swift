#if os(macOS)
import Foundation

// MARK: - GitHub API Tool (OAuth Token via UserDefaults)
public struct GitHubApiTool: Tool {
    public let name = "github_api"
    public let description = "GitHub API: Repos, Issues, PRs verwalten, Code durchsuchen"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: list_repos, get_repo, list_issues, create_issue, list_prs, create_pr, search_code, raw", enumValues: ["list_repos", "get_repo", "list_issues", "create_issue", "list_prs", "create_pr", "search_code", "raw"], required: true),
            "owner": ToolSchemaProperty(type: "string", description: "Repository-Owner (z.B. 'octocat')"),
            "repo": ToolSchemaProperty(type: "string", description: "Repository-Name (z.B. 'hello-world')"),
            "title": ToolSchemaProperty(type: "string", description: "Titel für create_issue/create_pr"),
            "body": ToolSchemaProperty(type: "string", description: "Beschreibung für create_issue/create_pr"),
            "head": ToolSchemaProperty(type: "string", description: "Source-Branch für create_pr"),
            "base": ToolSchemaProperty(type: "string", description: "Target-Branch für create_pr (Standard: main)"),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff für search_code"),
            "endpoint": ToolSchemaProperty(type: "string", description: "API-Endpunkt für raw (z.B. '/user/repos')"),
            "method": ToolSchemaProperty(type: "string", description: "HTTP-Methode für raw", enumValues: ["GET", "POST", "PUT", "PATCH", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "JSON-Body/Query für raw")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private func getToken() -> String? {
        let token = UserDefaults.standard.string(forKey: "kobold.github.accessToken") ?? ""
        return token.isEmpty ? nil : token
    }

    private func apiRequest(endpoint: String, method: String = "GET", body: String? = nil) async -> String {
        guard let token = getToken() else {
            return "Error: Nicht bei GitHub angemeldet. Bitte unter Einstellungen → Verbindungen → GitHub anmelden."
        }

        let urlStr = endpoint.hasPrefix("http") ? endpoint : "https://api.github.com\(endpoint)"
        guard let url = URL(string: urlStr) else { return "Error: Ungültige URL: \(urlStr)" }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let body = body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let owner = arguments["owner"] ?? ""
        let repo = arguments["repo"] ?? ""

        switch action {
        case "list_repos":
            if owner.isEmpty {
                return await apiRequest(endpoint: "/user/repos?sort=updated&per_page=20")
            }
            return await apiRequest(endpoint: "/users/\(owner)/repos?sort=updated&per_page=20")

        case "get_repo":
            guard !owner.isEmpty, !repo.isEmpty else { return "Error: 'owner' und 'repo' Parameter benötigt." }
            return await apiRequest(endpoint: "/repos/\(owner)/\(repo)")

        case "list_issues":
            guard !owner.isEmpty, !repo.isEmpty else { return "Error: 'owner' und 'repo' Parameter benötigt." }
            return await apiRequest(endpoint: "/repos/\(owner)/\(repo)/issues?state=open&per_page=20")

        case "create_issue":
            guard !owner.isEmpty, !repo.isEmpty else { return "Error: 'owner' und 'repo' Parameter benötigt." }
            guard let title = arguments["title"], !title.isEmpty else { return "Error: 'title' Parameter fehlt." }
            let body = arguments["body"] ?? ""
            let jsonBody = "{\"title\":\(jsonString(title)),\"body\":\(jsonString(body))}"
            return await apiRequest(endpoint: "/repos/\(owner)/\(repo)/issues", method: "POST", body: jsonBody)

        case "list_prs":
            guard !owner.isEmpty, !repo.isEmpty else { return "Error: 'owner' und 'repo' Parameter benötigt." }
            return await apiRequest(endpoint: "/repos/\(owner)/\(repo)/pulls?state=open&per_page=20")

        case "create_pr":
            guard !owner.isEmpty, !repo.isEmpty else { return "Error: 'owner' und 'repo' Parameter benötigt." }
            guard let title = arguments["title"], !title.isEmpty else { return "Error: 'title' Parameter fehlt." }
            guard let head = arguments["head"], !head.isEmpty else { return "Error: 'head' Parameter fehlt." }
            let base = arguments["base"] ?? "main"
            let body = arguments["body"] ?? ""
            let jsonBody = "{\"title\":\(jsonString(title)),\"head\":\(jsonString(head)),\"base\":\(jsonString(base)),\"body\":\(jsonString(body))}"
            return await apiRequest(endpoint: "/repos/\(owner)/\(repo)/pulls", method: "POST", body: jsonBody)

        case "search_code":
            guard let query = arguments["query"], !query.isEmpty else { return "Error: 'query' Parameter fehlt." }
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return await apiRequest(endpoint: "/search/code?q=\(q)&per_page=10")

        case "raw":
            guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else { return "Error: 'endpoint' Parameter fehlt." }
            let method = arguments["method"] ?? "GET"
            return await apiRequest(endpoint: endpoint, method: method, body: arguments["params"])

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    private func jsonString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

#elseif os(Linux)
import Foundation

public struct GitHubApiTool: Tool {
    public let name = "github_api"
    public let description = "GitHub API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "GitHub API ist auf Linux deaktiviert." }
}
#endif
