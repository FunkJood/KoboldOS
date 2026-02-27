#if os(macOS)
import Foundation

// MARK: - Reddit API Tool (OAuth2-basiert)
public struct RedditApiTool: Tool {
    public let name = "reddit_api"
    public let description = "Reddit: Suchen, Posts lesen, kommentieren, subreddits durchsuchen. Benötigt OAuth-Verbindung in Einstellungen."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: search, hot, new, read_post, comment, user_info, subreddit_info", enumValues: ["search", "hot", "new", "read_post", "comment", "user_info", "subreddit_info"], required: true),
            "subreddit": ToolSchemaProperty(type: "string", description: "Subreddit-Name ohne r/ (z.B. 'programming', 'de')"),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff (für search)"),
            "post_id": ToolSchemaProperty(type: "string", description: "Post-ID (für read_post, comment)"),
            "text": ToolSchemaProperty(type: "string", description: "Kommentartext (für comment)"),
            "limit": ToolSchemaProperty(type: "string", description: "Anzahl Ergebnisse (Standard: 10, max: 25)")
        ], required: ["action"])
    }

    public init() {}

    private let oauth = OAuthTokenHelper(
        prefix: "kobold.reddit",
        tokenURL: "https://www.reddit.com/api/v1/access_token",
        useBasicAuth: true
    )

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        guard let accessToken = await oauth.getValidToken() else {
            return "Error: Nicht mit Reddit verbunden. Bitte unter Einstellungen → Verbindungen → Reddit authentifizieren."
        }

        let limit = Int(arguments["limit"] ?? "10") ?? 10
        let clampedLimit = min(max(limit, 1), 25)

        switch action {
        case "search":
            let query = arguments["query"] ?? ""
            guard !query.isEmpty else { return "Error: 'query' Parameter fehlt für Suche." }
            let sub = arguments["subreddit"]
            let endpoint = sub != nil && !sub!.isEmpty
                ? "/r/\(sub!)/search?q=\(query.redditEncoded)&restrict_sr=on&limit=\(clampedLimit)"
                : "/search?q=\(query.redditEncoded)&limit=\(clampedLimit)"
            return await redditRequest(endpoint: endpoint, token: accessToken)

        case "hot":
            let sub = arguments["subreddit"] ?? ""
            guard !sub.isEmpty else { return "Error: 'subreddit' Parameter fehlt." }
            return await redditRequest(endpoint: "/r/\(sub)/hot?limit=\(clampedLimit)", token: accessToken)

        case "new":
            let sub = arguments["subreddit"] ?? ""
            guard !sub.isEmpty else { return "Error: 'subreddit' Parameter fehlt." }
            return await redditRequest(endpoint: "/r/\(sub)/new?limit=\(clampedLimit)", token: accessToken)

        case "read_post":
            let postId = arguments["post_id"] ?? ""
            guard !postId.isEmpty else { return "Error: 'post_id' Parameter fehlt." }
            return await redditRequest(endpoint: "/comments/\(postId)?limit=10", token: accessToken)

        case "comment":
            let postId = arguments["post_id"] ?? ""
            let text = arguments["text"] ?? ""
            guard !postId.isEmpty else { return "Error: 'post_id' Parameter fehlt." }
            guard !text.isEmpty else { return "Error: 'text' Parameter fehlt." }
            let body = "thing_id=t3_\(postId)&text=\(text.redditEncoded)"
            return await redditRequest(endpoint: "/api/comment", method: "POST", body: body, token: accessToken)

        case "user_info":
            return await redditRequest(endpoint: "/api/v1/me", token: accessToken)

        case "subreddit_info":
            let sub = arguments["subreddit"] ?? ""
            guard !sub.isEmpty else { return "Error: 'subreddit' Parameter fehlt." }
            return await redditRequest(endpoint: "/r/\(sub)/about", token: accessToken)

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    // MARK: - API Request

    private func redditRequest(endpoint: String, method: String = "GET", body: String? = nil, token: String) async -> String {
        let urlStr = "https://oauth.reddit.com\(endpoint)"
        guard let url = URL(string: urlStr) else { return "Error: Ungültige URL: \(urlStr)" }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("KoboldOS/0.3 by KoboldBot", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        if let body = body, method == "POST" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401 {
                if let newToken = await oauth.refreshToken() {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let retryText = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(leer)"
                    if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryText)" }
                    return retryText
                }
                return "Error: Reddit-Token abgelaufen. Bitte neu anmelden unter Einstellungen → Verbindungen → Reddit."
            }

            let text = String(data: data.prefix(8192), encoding: .utf8) ?? "(leer)"
            if status >= 400 { return "Error: HTTP \(status): \(text)" }
            return text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

private extension String {
    var redditEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

#elseif os(Linux)
import Foundation

public struct RedditApiTool: Tool {
    public let name = "reddit_api"
    public let description = "Reddit API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Reddit API ist auf Linux deaktiviert." }
}
#endif
