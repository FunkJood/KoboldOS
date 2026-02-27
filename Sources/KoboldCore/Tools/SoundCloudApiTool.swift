#if os(macOS)
import Foundation

// MARK: - SoundCloudApiTool (macOS)
public struct SoundCloudApiTool: Tool {
    public let name = "soundcloud_api"
    public let description = "Make authenticated SoundCloud API requests (tracks, playlists, users, likes)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "endpoint": ToolSchemaProperty(type: "string", description: "API endpoint path, e.g. me, me/tracks, tracks/123, users/456/tracks, me/likes", required: true),
            "method": ToolSchemaProperty(type: "string", description: "HTTP method: GET, POST, PUT, DELETE", enumValues: ["GET", "POST", "PUT", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "Query parameters as JSON object, e.g. {\"q\": \"psytrance\", \"limit\": \"10\"}"),
            "body": ToolSchemaProperty(type: "string", description: "Request body as JSON string (for POST/PUT)")
        ], required: ["endpoint"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else {
            throw ToolError.missingRequired("endpoint")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let endpoint = arguments["endpoint"] ?? ""
        let method = (arguments["method"] ?? "GET").uppercased()
        let paramsStr = arguments["params"]
        let bodyStr = arguments["body"]

        let d = UserDefaults.standard
        guard var accessToken = d.string(forKey: "kobold.soundcloud.accessToken"), !accessToken.isEmpty else {
            return "Error: Nicht bei SoundCloud angemeldet. Bitte zuerst in Einstellungen → Verbindungen → SoundCloud anmelden."
        }

        // Check expiry and refresh
        let expiryInterval = d.double(forKey: "kobold.soundcloud.tokenExpiry")
        if expiryInterval > 0 && Date(timeIntervalSince1970: expiryInterval) < Date() {
            if let newToken = await refreshToken() {
                accessToken = newToken
            } else {
                return "Error: SoundCloud-Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden."
            }
        }

        // Build URL
        var urlString = "https://api.soundcloud.com/\(endpoint)"

        if let paramsStr = paramsStr, !paramsStr.isEmpty,
           let paramsData = paramsStr.data(using: .utf8),
           let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            var components = URLComponents(string: urlString)!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            urlString = components.url?.absoluteString ?? urlString
        }

        guard let url = URL(string: urlString) else {
            return "Error: Ungültige URL: \(urlString)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let bodyStr = bodyStr, !bodyStr.isEmpty {
            request.httpBody = bodyStr.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            if let newToken = await refreshToken() {
                request.setValue("OAuth \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                let retryBody = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(empty)"
                if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryBody)" }
                return retryBody
            } else {
                return "Error: Token abgelaufen und Refresh fehlgeschlagen."
            }
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
        if status >= 400 { return "Error: HTTP \(status): \(body)" }
        return body
    }

    // MARK: - Refresh

    private let scClientId = "56Xd1suRhHAWfNXKY8BGYIfWAkZJEAsk"
    private let scClientSecret = "wj9oBAItfD0X1asfihfOABkql9FTZAV1"

    private func refreshToken() async -> String? {
        let d = UserDefaults.standard
        guard let refreshToken = d.string(forKey: "kobold.soundcloud.refreshToken"), !refreshToken.isEmpty else { return nil }

        guard let url = URL(string: "https://secure.soundcloud.com/oauth/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)",
            "client_id=\(scClientId)",
            "client_secret=\(scClientSecret)",
            "grant_type=refresh_token"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String else { return nil }

            let expiresIn = json["expires_in"] as? Int ?? 86400
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            d.set(newToken, forKey: "kobold.soundcloud.accessToken")
            d.set(expiry.timeIntervalSince1970, forKey: "kobold.soundcloud.tokenExpiry")
            if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                d.set(newRefresh, forKey: "kobold.soundcloud.refreshToken")
            }
            return newToken
        } catch {
            return nil
        }
    }
}

#elseif os(Linux)
import Foundation

public struct SoundCloudApiTool: Tool {
    public let name = "soundcloud_api"
    public let description = "SoundCloud API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["endpoint": ToolSchemaProperty(type: "string", description: "API endpoint", required: true)], required: ["endpoint"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String {
        return "SoundCloud API ist auf Linux deaktiviert."
    }
}
#endif
