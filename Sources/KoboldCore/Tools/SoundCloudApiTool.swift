#if os(macOS)
import Foundation

// MARK: - SoundCloudApiTool (macOS) — mit Upload-Support
public struct SoundCloudApiTool: Tool {
    public let name = "soundcloud_api"
    public let description = "SoundCloud: Tracks lesen/suchen/hochladen, Playlists, Likes, User-Info. Upload via file_path Parameter."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "endpoint": ToolSchemaProperty(type: "string", description: "API endpoint path, e.g. me, me/tracks, tracks/123, tracks (für Upload)", required: true),
            "method": ToolSchemaProperty(type: "string", description: "HTTP method: GET, POST, PUT, DELETE", enumValues: ["GET", "POST", "PUT", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "Query parameters as JSON object, e.g. {\"q\": \"psytrance\", \"limit\": \"10\"}"),
            "body": ToolSchemaProperty(type: "string", description: "Request body as JSON string (für POST/PUT ohne Datei)"),
            "file_path": ToolSchemaProperty(type: "string", description: "Absoluter Pfad zur Audio-Datei für Upload (mp3, wav, flac, ogg, aac)"),
            "title": ToolSchemaProperty(type: "string", description: "Track-Titel (für Upload, Pflicht)"),
            "description": ToolSchemaProperty(type: "string", description: "Track-Beschreibung (für Upload, optional)"),
            "genre": ToolSchemaProperty(type: "string", description: "Genre, z.B. 'Psytrance', 'Techno', 'Ambient' (für Upload)"),
            "tags": ToolSchemaProperty(type: "string", description: "Tags kommagetrennt, z.B. 'electronic, dark, 145bpm' (für Upload)"),
            "sharing": ToolSchemaProperty(type: "string", description: "Sichtbarkeit: public oder private (Standard: private)")
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
        let filePath = arguments["file_path"]

        guard let accessToken = await getValidToken() else {
            return "Error: Nicht bei SoundCloud angemeldet. Bitte zuerst in Einstellungen → Verbindungen → SoundCloud anmelden."
        }

        // Route to upload handler if file_path is provided
        if let filePath = filePath, !filePath.isEmpty {
            return await uploadTrack(filePath: filePath, arguments: arguments, accessToken: accessToken)
        }

        // Regular API request
        return await regularRequest(endpoint: endpoint, method: method, paramsStr: paramsStr, bodyStr: bodyStr, accessToken: accessToken)
    }

    // MARK: - Regular API Request

    private func regularRequest(endpoint: String, method: String, paramsStr: String?, bodyStr: String?, accessToken: String) async -> String {
        var urlString = "https://api.soundcloud.com/\(endpoint)"

        if let paramsStr = paramsStr, !paramsStr.isEmpty,
           let paramsData = paramsStr.data(using: .utf8),
           let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            if var components = URLComponents(string: urlString) {
                components.queryItems = params.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
                urlString = components.url?.absoluteString ?? urlString
            }
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

        do {
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
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload Track (multipart/form-data)

    private func uploadTrack(filePath: String, arguments: [String: String], accessToken: String) async -> String {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: expandedPath) else {
            return "Error: Datei nicht gefunden: \(filePath)"
        }
        guard let fileData = fm.contents(atPath: expandedPath) else {
            return "Error: Datei konnte nicht gelesen werden: \(filePath)"
        }

        // SoundCloud limit: 5GB for Pro, but let's cap at 500MB for sanity
        guard fileData.count < 500_000_000 else {
            return "Error: Datei zu groß (\(fileData.count / 1_000_000) MB). Maximum: 500 MB."
        }

        let title = arguments["title"] ?? (expandedPath as NSString).lastPathComponent.replacingOccurrences(of: ".\((expandedPath as NSString).pathExtension)", with: "")
        let description = arguments["description"] ?? ""
        let genre = arguments["genre"] ?? ""
        let tags = arguments["tags"] ?? ""
        let sharing = arguments["sharing"] ?? "private"
        let fileName = (expandedPath as NSString).lastPathComponent
        let mimeType = detectAudioMime(path: expandedPath)

        guard let url = URL(string: "https://api.soundcloud.com/tracks") else {
            return "Error: Ungültige Upload-URL"
        }

        let boundary = "KoboldSC\(UUID().uuidString.prefix(8))"

        // Build multipart body
        var body = Data()

        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addField("track[title]", title)
        addField("track[sharing]", sharing)
        if !description.isEmpty { addField("track[description]", description) }
        if !genre.isEmpty { addField("track[genre]", genre) }
        if !tags.isEmpty { addField("track[tag_list]", tags) }

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"track[asset_data]\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 300 // 5 min for large files
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401 {
                if let newToken = await refreshToken() {
                    request.setValue("OAuth \(newToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let retryBody = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(empty)"
                    if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryBody)" }
                    return retryBody
                }
                return "Error: Token abgelaufen und Refresh fehlgeschlagen."
            }

            let respBody = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 { return "Error: HTTP \(status): \(respBody)" }

            // Parse response for track URL
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let trackId = json["id"],
               let permalink = json["permalink_url"] as? String {
                return "SoundCloud-Track erfolgreich hochgeladen! ID: \(trackId), URL: \(permalink), Sichtbarkeit: \(sharing)\n\nRaw: \(respBody)"
            }
            return respBody
        } catch {
            return "Error: Upload fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Token Management

    private func getValidToken() async -> String? {
        let d = UserDefaults.standard
        guard let token = d.string(forKey: "kobold.soundcloud.accessToken"), !token.isEmpty else { return nil }
        let expiryInterval = d.double(forKey: "kobold.soundcloud.tokenExpiry")
        if expiryInterval > 0 && Date(timeIntervalSince1970: expiryInterval) < Date() {
            return await refreshToken()
        }
        return token
    }

    private func detectAudioMime(path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3":         return "audio/mpeg"
        case "wav":         return "audio/wav"
        case "flac":        return "audio/flac"
        case "aac", "m4a":  return "audio/mp4"
        case "ogg", "oga":  return "audio/ogg"
        case "aiff", "aif": return "audio/aiff"
        default:            return "application/octet-stream"
        }
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
