import Foundation

// MARK: - HTTPTool (Simple HTTP GET/POST tool for the agent)

public struct HTTPTool: Tool {
    public let name = "http"
    public let description = "Make HTTP requests. Actions: get, post"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "url": ToolSchemaProperty(type: "string", description: "URL to request", required: true),
            "action": ToolSchemaProperty(type: "string", description: "HTTP method: get or post", enumValues: ["get", "post"]),
            "body": ToolSchemaProperty(type: "string", description: "Request body for POST")
        ], required: ["url"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard arguments["url"] != nil else {
            throw ToolError.missingRequired("url")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        guard let urlStr = arguments["url"],
              let url = URL(string: urlStr) else {
            throw ToolError.missingRequired("url (invalid)")
        }

        let action = arguments["action"] ?? "get"
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        switch action.lowercased() {
        case "post":
            request.httpMethod = "POST"
            if let body = arguments["body"] {
                request.httpBody = body.data(using: .utf8)
            }
            if let contentType = arguments["content_type"] {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        default:
            request.httpMethod = "GET"
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data.prefix(4096), encoding: .utf8) ?? "(binary data)"
        return "HTTP \(status)\n\(body)"
    }
}
