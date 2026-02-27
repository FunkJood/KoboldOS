#if os(macOS)
import Foundation

// MARK: - GoogleApiTool (macOS implementation)
public struct GoogleApiTool: Tool {
    public let name = "google_api"
    public let description = "Make authenticated Google API requests (YouTube, Drive, Gmail, Calendar, etc.)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "endpoint": ToolSchemaProperty(type: "string", description: "API endpoint path, e.g. youtube/v3/search, drive/v3/files, gmail/v1/users/me/messages", required: true),
            "method": ToolSchemaProperty(type: "string", description: "HTTP method: GET, POST, PUT, DELETE", enumValues: ["GET", "POST", "PUT", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "Query parameters as JSON object, e.g. {\"q\": \"test\", \"maxResults\": \"5\"}"),
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

        // Get access token from UserDefaults (same storage as GoogleOAuth in UI)
        let defaults = UserDefaults.standard
        guard var accessToken = defaults.string(forKey: "kobold.google.accessToken"), !accessToken.isEmpty else {
            return "Error: Nicht bei Google angemeldet. Bitte zuerst in den Einstellungen unter Verbindungen → Google anmelden."
        }

        // Check token expiry and refresh if needed
        let expiryInterval = defaults.double(forKey: "kobold.google.tokenExpiry")
        if expiryInterval > 0 {
            let expiry = Date(timeIntervalSince1970: expiryInterval)
            if expiry < Date() {
                let refreshed = await refreshToken()
                if let newToken = refreshed {
                    accessToken = newToken
                } else {
                    return "Error: Google-Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden."
                }
            }
        }

        // Build URL
        var urlString = "https://www.googleapis.com/\(endpoint)"

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
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let bodyStr = bodyStr, !bodyStr.isEmpty {
            request.httpBody = bodyStr.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // Auto-refresh on 401
            if let newToken = await refreshToken() {
                request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                let retryBody = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(empty)"
                if retryStatus >= 400 {
                    return "Error: HTTP \(retryStatus): \(retryBody)"
                }
                return retryBody
            } else {
                return "Error: Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden."
            }
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"

        if status >= 400 {
            return "Error: HTTP \(status): \(body)"
        }

        return body
    }

    // MARK: - Token Refresh

    // OAuth credentials from UserDefaults (same keys as GoogleOAuth in UI)
    private var googleClientId: String { UserDefaults.standard.string(forKey: "kobold.google.clientId") ?? "" }
    private var googleClientSecret: String { UserDefaults.standard.string(forKey: "kobold.google.clientSecret") ?? "" }

    private func refreshToken() async -> String? {
        let defaults = UserDefaults.standard
        guard let refreshToken = defaults.string(forKey: "kobold.google.refreshToken"), !refreshToken.isEmpty else { return nil }
        guard !googleClientId.isEmpty, !googleClientSecret.isEmpty else { return nil }

        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)",
            "client_id=\(googleClientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? googleClientId)",
            "client_secret=\(googleClientSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? googleClientSecret)",
            "grant_type=refresh_token"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String else {
                return nil
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            defaults.set(newToken, forKey: "kobold.google.accessToken")
            defaults.set(expiry.timeIntervalSince1970, forKey: "kobold.google.tokenExpiry")

            return newToken
        } catch {
            print("[GoogleApiTool] Refresh error: \(error)")
            return nil
        }
    }
}

#elseif os(Linux)
import Foundation

// MARK: - GoogleApiTool (Linux implementation - placeholder)
public struct GoogleApiTool: Tool {
    public let name = "google_api"
    public let description = "Make authenticated Google API requests (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "endpoint": ToolSchemaProperty(type: "string", description: "API endpoint path", required: true)
        ], required: ["endpoint"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        // No validation needed for placeholder
    }

    public func execute(arguments: [String: String]) async throws -> String {
        return "Google API Funktionen sind auf Linux deaktiviert. Verwenden Sie direkte HTTP-Anfragen über das browser-Tool."
    }
}
#endif