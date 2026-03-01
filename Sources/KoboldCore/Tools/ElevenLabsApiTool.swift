#if os(macOS)
import Foundation

// MARK: - ElevenLabsApiTool (Multi-Action: TTS, Sound FX, Voice Listing, Voice Cloning)

public struct ElevenLabsApiTool: Tool, @unchecked Sendable {
    public let name = "elevenlabs"
    public let description = "ElevenLabs API: Text-to-Speech Audio generieren (speak), Sound-Effekte erzeugen (sound_fx), Stimmen auflisten (list_voices), Stimme klonen (clone_voice)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "speak | sound_fx | list_voices | clone_voice", required: true),
            "text": ToolSchemaProperty(type: "string", description: "Text für TTS oder Beschreibung für Sound-Effekt"),
            "voice_id": ToolSchemaProperty(type: "string", description: "Voice-ID (von list_voices). Ohne = Standard-Stimme"),
            "model": ToolSchemaProperty(type: "string", description: "Modell: eleven_multilingual_v2, eleven_turbo_v2_5, eleven_flash_v2_5"),
            "output_path": ToolSchemaProperty(type: "string", description: "Speicherpfad für Audio-Datei (z.B. ~/Desktop/speech.mp3)"),
            "duration": ToolSchemaProperty(type: "string", description: "Dauer in Sekunden für sound_fx (0.5-30)"),
            "voice_name": ToolSchemaProperty(type: "string", description: "Name für geklonte Stimme"),
            "file_path": ToolSchemaProperty(type: "string", description: "Audio-Datei für Voice Cloning (wav/mp3)"),
        ], required: ["action"])
    }

    public init() {}

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
    }

    public func execute(arguments: [String: String]) async throws -> String {
        guard !apiKey.isEmpty else {
            return "Error: Kein ElevenLabs API-Key konfiguriert. Bitte unter Einstellungen → Sprache → ElevenLabs eintragen."
        }

        switch arguments["action"] ?? "" {
        case "speak": return await speak(arguments)
        case "sound_fx": return await soundFX(arguments)
        case "list_voices": return await listVoices()
        case "clone_voice": return await cloneVoice(arguments)
        default: return "Unbekannte Aktion. Verfügbar: speak, sound_fx, list_voices, clone_voice"
        }
    }

    // MARK: - Text-to-Speech (saves audio file)

    private func speak(_ args: [String: String]) async -> String {
        guard let text = args["text"], !text.isEmpty else { return "Error: 'text' Parameter fehlt." }

        let voiceId = args["voice_id"] ?? UserDefaults.standard.string(forKey: "kobold.elevenlabs.voiceId") ?? "21m00Tcm4TlvDq8ikWAM"
        let model = args["model"] ?? UserDefaults.standard.string(forKey: "kobold.elevenlabs.model") ?? "eleven_flash_v2_5"
        let outputPath = resolvePath(args["output_path"] ?? "~/Documents/KoboldOS/Audio/tts_\(Int(Date().timeIntervalSince1970)).mp3")

        // Ensure output directory exists
        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return "Error: ElevenLabs TTS fehlgeschlagen — \(errMsg)"
            }
            try data.write(to: URL(fileURLWithPath: outputPath))
            let sizeMB = String(format: "%.1f", Double(data.count) / 1_048_576)
            return "Audio gespeichert: \(outputPath) (\(sizeMB) MB, \(text.count) Zeichen, Modell: \(model))"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Sound Effects Generation

    private func soundFX(_ args: [String: String]) async -> String {
        guard let text = args["text"], !text.isEmpty else { return "Error: 'text' Beschreibung für den Sound-Effekt fehlt." }

        let duration = Double(args["duration"] ?? "3.0") ?? 3.0
        let outputPath = resolvePath(args["output_path"] ?? "~/Documents/KoboldOS/Audio/sfx_\(Int(Date().timeIntervalSince1970)).mp3")

        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let url = URL(string: "https://api.elevenlabs.io/v1/sound-generation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "text": text,
            "duration_seconds": min(30, max(0.5, duration))
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return "Error: Sound-Effekt-Generierung fehlgeschlagen — \(errMsg)"
            }
            try data.write(to: URL(fileURLWithPath: outputPath))
            let sizeMB = String(format: "%.1f", Double(data.count) / 1_048_576)
            return "Sound-Effekt gespeichert: \(outputPath) (\(sizeMB) MB, \(duration)s, Beschreibung: \(text))"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - List Available Voices

    private func listVoices() async -> String {
        let url = URL(string: "https://api.elevenlabs.io/v1/voices")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = json["voices"] as? [[String: Any]] else {
                return "Error: Stimmen konnten nicht geladen werden."
            }

            var out = "Verfügbare ElevenLabs-Stimmen (\(voices.count)):\n\n"
            for voice in voices.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
                let name = voice["name"] as? String ?? "?"
                let id = voice["voice_id"] as? String ?? "?"
                let category = voice["category"] as? String ?? ""
                let labels = voice["labels"] as? [String: String] ?? [:]
                let lang = labels["language"] ?? labels["accent"] ?? ""
                out += "- \(name) [\(id)] \(category) \(lang)\n"
            }
            return out
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Voice Cloning

    private func cloneVoice(_ args: [String: String]) async -> String {
        guard let name = args["voice_name"], !name.isEmpty else { return "Error: 'voice_name' fehlt." }
        guard let filePath = args["file_path"], !filePath.isEmpty else { return "Error: 'file_path' (Audio-Datei) fehlt." }

        let resolvedPath = resolvePath(filePath)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return "Error: Datei nicht gefunden: \(resolvedPath)"
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/voices/add")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var bodyData = Data()
        // Name field
        bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n".data(using: .utf8)!)
        // Description field
        let desc = args["description"] ?? "Kloned via KoboldOS"
        bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"description\"\r\n\r\n\(desc)\r\n".data(using: .utf8)!)
        // Audio file
        let fileName = (resolvedPath as NSString).lastPathComponent
        let fileData = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        guard let fileData else { return "Error: Datei konnte nicht gelesen werden." }
        bodyData.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\nContent-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        bodyData.append(fileData)
        bodyData.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return "Error: Voice Cloning fehlgeschlagen — \(errMsg)"
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voiceId = json["voice_id"] as? String else {
                return "Error: Antwort konnte nicht geparst werden."
            }
            return "Stimme erfolgreich geklont! Name: \(name), Voice-ID: \(voiceId)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Path Helper

    private func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

#elseif os(Linux)
import Foundation

public struct ElevenLabsApiTool: Tool, Sendable {
    public let name = "elevenlabs"
    public let description = "ElevenLabs API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func execute(arguments: [String: String]) async throws -> String { "ElevenLabs ist auf Linux deaktiviert." }
}
#endif
