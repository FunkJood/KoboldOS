#if os(macOS)
import Foundation

// MARK: - GoogleApiTool (macOS implementation)
public struct GoogleApiTool: Tool {
    public let name = "google_api"
    public let description = "Make authenticated Google API requests (YouTube, Drive, Gmail, Calendar, etc.). Supports file uploads for YouTube and Drive via file_path parameter."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "endpoint": ToolSchemaProperty(type: "string", description: "API endpoint path, e.g. youtube/v3/search, upload/youtube/v3/videos, upload/drive/v3/files", required: true),
            "method": ToolSchemaProperty(type: "string", description: "HTTP method: GET, POST, PUT, DELETE", enumValues: ["GET", "POST", "PUT", "DELETE"]),
            "params": ToolSchemaProperty(type: "string", description: "Query parameters as JSON object, e.g. {\"part\": \"snippet,status\", \"uploadType\": \"resumable\"}"),
            "body": ToolSchemaProperty(type: "string", description: "Request body as JSON string (for POST/PUT). For YouTube uploads: video metadata JSON"),
            "file_path": ToolSchemaProperty(type: "string", description: "Absolute path to file for upload (YouTube video, Drive file). File must exist and be under 2GB.")
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

        // Get valid access token
        guard let accessToken = await getValidAccessToken() else {
            return "Error: Nicht bei Google angemeldet. Bitte zuerst in den Einstellungen unter Verbindungen → Google anmelden."
        }

        // Route to upload handler if file_path is provided
        if let filePath = filePath, !filePath.isEmpty {
            return await handleFileUpload(
                endpoint: endpoint, params: paramsStr, metadata: bodyStr,
                filePath: filePath, accessToken: accessToken
            )
        }

        // Regular API request (no file upload)
        return await regularRequest(
            endpoint: endpoint, method: method, paramsStr: paramsStr,
            bodyStr: bodyStr, accessToken: accessToken
        )
    }

    // MARK: - Regular API Request

    private func regularRequest(endpoint: String, method: String, paramsStr: String?, bodyStr: String?, accessToken: String) async -> String {
        var urlString = "https://www.googleapis.com/\(endpoint)"

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
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let bodyStr = bodyStr, !bodyStr.isEmpty {
            request.httpBody = bodyStr.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                if let newToken = await refreshToken() {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let retryBody = String(data: retryData.prefix(8192), encoding: .utf8) ?? "(empty)"
                    if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryBody)" }
                    return retryBody
                } else {
                    return "Error: Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden."
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

    // MARK: - File Upload (YouTube Resumable / Drive Multipart)

    private func handleFileUpload(endpoint: String, params: String?, metadata: String?, filePath: String, accessToken: String) async -> String {
        // Validate file exists and is readable
        let fm = FileManager.default
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: expandedPath) else {
            return "Error: Datei nicht gefunden: \(filePath)"
        }
        guard fm.isReadableFile(atPath: expandedPath) else {
            return "Error: Datei nicht lesbar: \(filePath)"
        }

        // Get file size
        guard let attrs = try? fm.attributesOfItem(atPath: expandedPath),
              let fileSize = attrs[.size] as? UInt64 else {
            return "Error: Dateigröße konnte nicht ermittelt werden."
        }

        // 2GB limit
        guard fileSize < 2_000_000_000 else {
            return "Error: Datei ist zu groß (\(fileSize / 1_000_000) MB). Maximum: 2 GB."
        }

        let mimeType = detectMimeType(path: expandedPath)

        // YouTube upload → Resumable Upload Protocol
        if endpoint.contains("youtube/v3/videos") {
            return await youtubeResumableUpload(
                params: params, metadata: metadata, filePath: expandedPath,
                fileSize: fileSize, mimeType: mimeType, accessToken: accessToken
            )
        }

        // Drive upload → Multipart Related
        if endpoint.contains("drive/v3/files") || endpoint.contains("drive/v2/files") {
            return await driveMultipartUpload(
                endpoint: endpoint, params: params, metadata: metadata,
                filePath: expandedPath, fileSize: fileSize, mimeType: mimeType,
                accessToken: accessToken
            )
        }

        return "Error: Datei-Upload nur für YouTube und Drive Endpoints unterstützt. Endpoint: \(endpoint)"
    }

    // MARK: - YouTube Resumable Upload

    private func youtubeResumableUpload(params: String?, metadata: String?, filePath: String, fileSize: UInt64, mimeType: String, accessToken: String) async -> String {
        // Step 1: Initiate resumable upload session
        var urlString = "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable"

        // Add query params (part is required)
        if let params = params, !params.isEmpty,
           let paramsData = params.data(using: .utf8),
           let paramsDict = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            for (key, value) in paramsDict {
                urlString += "&\(key)=\("\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(value)")"
            }
        } else {
            // Default: snippet + status
            urlString += "&part=snippet,status"
        }

        guard let initURL = URL(string: urlString) else {
            return "Error: Ungültige Upload-URL"
        }

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        initRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        initRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        initRequest.timeoutInterval = 30

        // Metadata body (snippet, status, etc.)
        let metadataJSON = metadata ?? "{\"snippet\":{\"title\":\"Upload\",\"description\":\"\"},\"status\":{\"privacyStatus\":\"private\"}}"
        initRequest.httpBody = metadataJSON.data(using: .utf8)

        do {
            let (initData, initResponse) = try await URLSession.shared.data(for: initRequest)
            guard let httpResponse = initResponse as? HTTPURLResponse else {
                return "Error: Keine HTTP-Antwort bei Upload-Initiierung."
            }

            // Handle 401 with token refresh
            if httpResponse.statusCode == 401 {
                guard let newToken = await refreshToken() else {
                    return "Error: Token abgelaufen und Refresh fehlgeschlagen."
                }
                initRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: initRequest)
                guard let retryHttp = retryResponse as? HTTPURLResponse,
                      let uploadUri = retryHttp.value(forHTTPHeaderField: "Location") else {
                    let body = String(data: retryData.prefix(4096), encoding: .utf8) ?? ""
                    return "Error: Upload-Initiierung fehlgeschlagen (nach Refresh): \(body)"
                }
                return await uploadFileToUri(uploadUri: uploadUri, filePath: filePath, fileSize: fileSize, mimeType: mimeType, accessToken: newToken)
            }

            guard httpResponse.statusCode == 200,
                  let uploadUri = httpResponse.value(forHTTPHeaderField: "Location") else {
                let body = String(data: initData.prefix(4096), encoding: .utf8) ?? ""
                return "Error: Upload-Initiierung fehlgeschlagen (HTTP \(httpResponse.statusCode)): \(body)"
            }

            // Step 2: Upload the actual file
            return await uploadFileToUri(uploadUri: uploadUri, filePath: filePath, fileSize: fileSize, mimeType: mimeType, accessToken: accessToken)
        } catch {
            return "Error: Upload-Initiierung: \(error.localizedDescription)"
        }
    }

    private func uploadFileToUri(uploadUri: String, filePath: String, fileSize: UInt64, mimeType: String, accessToken: String) async -> String {
        guard let url = URL(string: uploadUri) else {
            return "Error: Ungültige Upload-URI"
        }

        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            return "Error: Datei konnte nicht gelesen werden: \(filePath)"
        }

        var uploadRequest = URLRequest(url: url)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        uploadRequest.timeoutInterval = 600 // 10 min for large files
        uploadRequest.httpBody = fileData

        do {
            let (data, response) = try await URLSession.shared.data(for: uploadRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"

            if status >= 400 {
                return "Error: Upload fehlgeschlagen (HTTP \(status)): \(body)"
            }

            // Extract video ID from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let videoId = json["id"] as? String {
                let title = (json["snippet"] as? [String: Any])?["title"] as? String ?? "?"
                return "YouTube-Video erfolgreich hochgeladen! ID: \(videoId), Titel: \(title). URL: https://youtu.be/\(videoId)\n\nRaw: \(body)"
            }
            return body
        } catch {
            return "Error: Datei-Upload: \(error.localizedDescription)"
        }
    }

    // MARK: - Drive Multipart Upload

    private func driveMultipartUpload(endpoint: String, params: String?, metadata: String?, filePath: String, fileSize: UInt64, mimeType: String, accessToken: String) async -> String {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            return "Error: Datei konnte nicht gelesen werden: \(filePath)"
        }

        let boundary = "kobold_boundary_\(UUID().uuidString)"
        var urlString = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"

        if let params = params, !params.isEmpty,
           let paramsData = params.data(using: .utf8),
           let paramsDict = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            for (key, value) in paramsDict where key != "uploadType" {
                urlString += "&\(key)=\("\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(value)")"
            }
        }

        guard let url = URL(string: urlString) else {
            return "Error: Ungültige Upload-URL"
        }

        // Build multipart/related body
        let metadataJSON = metadata ?? "{\"name\":\"\((filePath as NSString).lastPathComponent)\"}"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadataJSON)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 300
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401 {
                if let newToken = await refreshToken() {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
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

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fileId = json["id"] as? String {
                let name = json["name"] as? String ?? "?"
                return "Drive-Datei erfolgreich hochgeladen! ID: \(fileId), Name: \(name)\n\nRaw: \(respBody)"
            }
            return respBody
        } catch {
            return "Error: Drive-Upload: \(error.localizedDescription)"
        }
    }

    // MARK: - Token Management

    private func getValidAccessToken() async -> String? {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "kobold.google.accessToken"), !token.isEmpty else { return nil }
        let expiryInterval = defaults.double(forKey: "kobold.google.tokenExpiry")
        if expiryInterval > 0 && Date(timeIntervalSince1970: expiryInterval) < Date() {
            return await refreshToken()
        }
        return token
    }

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
            return nil
        }
    }

    // MARK: - MIME Type Detection

    private func detectMimeType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v":         return "video/mp4"
        case "mov":                return "video/quicktime"
        case "avi":                return "video/x-msvideo"
        case "wmv":                return "video/x-ms-wmv"
        case "flv":                return "video/x-flv"
        case "webm":               return "video/webm"
        case "mkv":                return "video/x-matroska"
        case "3gp":                return "video/3gpp"
        case "mp3":                return "audio/mpeg"
        case "wav":                return "audio/wav"
        case "flac":               return "audio/flac"
        case "aac", "m4a":         return "audio/mp4"
        case "ogg":                return "audio/ogg"
        case "pdf":                return "application/pdf"
        case "doc":                return "application/msword"
        case "docx":               return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":                return "application/vnd.ms-excel"
        case "xlsx":               return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":                return "application/vnd.ms-powerpoint"
        case "pptx":               return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip":                return "application/zip"
        case "png":                return "image/png"
        case "jpg", "jpeg":        return "image/jpeg"
        case "gif":                return "image/gif"
        case "webp":               return "image/webp"
        case "svg":                return "image/svg+xml"
        case "txt":                return "text/plain"
        case "csv":                return "text/csv"
        case "json":               return "application/json"
        case "xml":                return "application/xml"
        default:                   return "application/octet-stream"
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