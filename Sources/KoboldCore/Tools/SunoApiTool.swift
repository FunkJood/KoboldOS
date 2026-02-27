#if os(macOS)
import Foundation

// MARK: - Suno API Tool (Musik-Generierung via sunoapi.org)
public struct SunoApiTool: Tool {
    public let name = "suno_api"
    public let description = "Suno AI: Musik generieren, Status prüfen, Tracks abrufen. Benötigt API-Key in Einstellungen → Verbindungen."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: generate, status, get_track, list_tracks", enumValues: ["generate", "status", "get_track", "list_tracks"], required: true),
            "prompt": ToolSchemaProperty(type: "string", description: "Beschreibung des gewünschten Songs (für generate)"),
            "style": ToolSchemaProperty(type: "string", description: "Musikstil/Genre, z.B. 'psytrance', 'lo-fi hip hop', 'acoustic ballad' (für custom generate)"),
            "title": ToolSchemaProperty(type: "string", description: "Titel des Songs (für custom generate)"),
            "instrumental": ToolSchemaProperty(type: "string", description: "true = ohne Gesang, false = mit Gesang (Standard: false)"),
            "task_id": ToolSchemaProperty(type: "string", description: "Task-ID für Statusabfrage (für status/get_track)"),
            "model": ToolSchemaProperty(type: "string", description: "Suno-Modell: V4, V4_5 (Standard: V4)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        let apiKey = UserDefaults.standard.string(forKey: "kobold.suno.apiKey") ?? ""
        guard !apiKey.isEmpty else {
            return "Error: Kein Suno API-Key konfiguriert. Bitte in Einstellungen → Verbindungen → Suno den API-Key eintragen (von sunoapi.org)."
        }

        switch action {
        case "generate":
            return await generateTrack(arguments: arguments, apiKey: apiKey)
        case "status":
            guard let taskId = arguments["task_id"], !taskId.isEmpty else {
                return "Error: 'task_id' Parameter fehlt für Statusabfrage."
            }
            return await checkStatus(taskId: taskId, apiKey: apiKey)
        case "get_track":
            guard let taskId = arguments["task_id"], !taskId.isEmpty else {
                return "Error: 'task_id' Parameter fehlt."
            }
            return await getTrack(taskId: taskId, apiKey: apiKey)
        case "list_tracks":
            return await listTracks(apiKey: apiKey)
        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: generate, status, get_track, list_tracks"
        }
    }

    // MARK: - Generate Track

    private func generateTrack(arguments: [String: String], apiKey: String) async -> String {
        let prompt = arguments["prompt"] ?? ""
        let style = arguments["style"] ?? ""
        let title = arguments["title"] ?? ""
        let instrumental = arguments["instrumental"]?.lowercased() == "true"
        let model = arguments["model"] ?? "V4"

        // Custom mode when style + title are provided
        let customMode = !style.isEmpty && !title.isEmpty

        // callBackUrl is required by sunoapi.org — use tunnel URL if available, else placeholder.
        // Polling via "status" action works regardless of callback reachability.
        let tunnelUrl = UserDefaults.standard.string(forKey: "kobold.tunnel.url") ?? ""
        let callbackUrl = tunnelUrl.isEmpty ? "https://localhost/suno-callback" : "\(tunnelUrl)/suno-callback"

        var body: [String: Any] = [
            "customMode": customMode,
            "instrumental": instrumental,
            "model": model,
            "callBackUrl": callbackUrl
        ]

        if customMode {
            body["style"] = style
            body["title"] = title
            if !instrumental && !prompt.isEmpty {
                body["prompt"] = prompt // Lyrics text
            }
        } else {
            guard !prompt.isEmpty else {
                return "Error: 'prompt' Parameter fehlt. Beschreibe den gewünschten Song oder nutze style+title für Custom Mode."
            }
            body["prompt"] = prompt
        }

        let result = await apiRequest(endpoint: "/api/v1/generate", method: "POST", body: body, apiKey: apiKey)

        // Append workflow hint for the agent
        if result.contains("taskId") {
            return result + "\n\n[WICHTIG: Jede Generierung erzeugt 2 Versionen! Nutze 'status' mit der taskId (PENDING → SUCCESS). Bei SUCCESS: 'get_track' aufrufen → Response enthält 2 Einträge mit je einer audio_url. Lade BEIDE herunter mit: curl -L \"<audio_url>\" -o ~/Desktop/song_v1.mp3 und song_v2.mp3]"
        }
        return result
    }

    // MARK: - Check Status

    private func checkStatus(taskId: String, apiKey: String) async -> String {
        return await apiRequest(
            endpoint: "/api/v1/generate/record-info?taskId=\(taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId)",
            method: "GET",
            apiKey: apiKey
        )
    }

    // MARK: - Get Track

    private func getTrack(taskId: String, apiKey: String) async -> String {
        return await apiRequest(
            endpoint: "/api/v1/get?ids=\(taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId)",
            method: "GET",
            apiKey: apiKey
        )
    }

    // MARK: - List Tracks

    private func listTracks(apiKey: String) async -> String {
        return await apiRequest(endpoint: "/api/v1/get", method: "GET", apiKey: apiKey)
    }

    // MARK: - API Request Helper

    private func apiRequest(endpoint: String, method: String = "GET", body: [String: Any]? = nil, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.sunoapi.org\(endpoint)") else {
            return "Error: Ungültige URL"
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(8192), encoding: .utf8) ?? "(leer)"

            if status == 401 || status == 403 {
                return "Error: Suno API-Key ungültig oder abgelaufen. Bitte unter Einstellungen → Verbindungen → Suno prüfen."
            }
            if status >= 400 {
                return "Error: HTTP \(status): \(text)"
            }
            return text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct SunoApiTool: Tool {
    public let name = "suno_api"
    public let description = "Suno AI (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Suno API ist auf Linux deaktiviert." }
}
#endif
