import Foundation

// MARK: - TelegramTool — Agent can send messages, files, photos, audio via Telegram Bot

public struct TelegramTool: Tool, Sendable {
    public let name = "telegram_send"
    public let description = "Telegram Bot: Textnachrichten, Dateien, Fotos und Audio senden"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: send_text, send_file, send_photo, send_audio", enumValues: ["send_text", "send_file", "send_photo", "send_audio"]),
            "message": ToolSchemaProperty(type: "string", description: "Nachrichtentext (für send_text) oder Caption (für Dateien)"),
            "file_path": ToolSchemaProperty(type: "string", description: "Absoluter Pfad zur Datei (für send_file, send_photo, send_audio)"),
            "chat_id": ToolSchemaProperty(type: "string", description: "Override Chat-ID (optional, nutzt konfigurierte Standard-ID)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        let action = arguments["action"] ?? "send_text"
        switch action {
        case "send_text":
            guard let msg = arguments["message"], !msg.isEmpty else {
                throw ToolError.missingRequired("message")
            }
        case "send_file", "send_photo", "send_audio":
            guard let path = arguments["file_path"], !path.isEmpty else {
                throw ToolError.missingRequired("file_path")
            }
        default:
            break
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? "send_text"

        let token = UserDefaults.standard.string(forKey: "kobold.telegram.token") ?? ""
        guard !token.isEmpty else {
            return "Error: Kein Telegram-Bot-Token konfiguriert. Bitte in Einstellungen → Verbindungen → Telegram konfigurieren."
        }

        let chatIdStr = arguments["chat_id"] ?? UserDefaults.standard.string(forKey: "kobold.telegram.chatId") ?? ""
        guard !chatIdStr.isEmpty, let chatId = Int64(chatIdStr) else {
            return "Error: Keine Chat-ID konfiguriert. Bitte in Einstellungen → Verbindungen → Telegram eine Chat-ID eingeben."
        }

        switch action {
        case "send_text":
            return await sendText(token: token, chatId: chatId, text: arguments["message"] ?? "")
        case "send_file":
            return await sendFile(token: token, chatId: chatId, filePath: arguments["file_path"] ?? "", caption: arguments["message"], method: "sendDocument")
        case "send_photo":
            return await sendFile(token: token, chatId: chatId, filePath: arguments["file_path"] ?? "", caption: arguments["message"], method: "sendPhoto")
        case "send_audio":
            return await sendFile(token: token, chatId: chatId, filePath: arguments["file_path"] ?? "", caption: arguments["message"], method: "sendAudio")
        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: send_text, send_file, send_photo, send_audio"
        }
    }

    // MARK: - Send Text Message

    private func sendText(token: String, chatId: Int64, text: String) async -> String {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            return "Error: Ungültige Bot-Token URL"
        }

        let chunks = splitMessage(text, maxLength: 4000)
        var sentCount = 0

        for chunk in chunks {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15

            let body: [String: Any] = ["chat_id": chatId, "text": chunk, "parse_mode": "Markdown"]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool {
                    if ok {
                        sentCount += 1
                    } else {
                        // Retry without Markdown
                        let plainBody: [String: Any] = ["chat_id": chatId, "text": chunk]
                        req.httpBody = try? JSONSerialization.data(withJSONObject: plainBody)
                        let (retryData, _) = try await URLSession.shared.data(for: req)
                        if let retryJson = try? JSONSerialization.jsonObject(with: retryData) as? [String: Any],
                           let retryOk = retryJson["ok"] as? Bool, retryOk {
                            sentCount += 1
                        } else {
                            let errDesc = json["description"] as? String ?? "Unbekannter Fehler"
                            return "Error: Telegram API Fehler: \(errDesc)"
                        }
                    }
                }
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }

        return "Telegram-Nachricht gesendet (\(sentCount) Teil\(sentCount == 1 ? "" : "e"))."
    }

    // MARK: - Send File / Photo / Audio (multipart/form-data)

    private func sendFile(token: String, chatId: Int64, filePath: String, caption: String?, method: String) async -> String {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: expandedPath) else {
            return "Error: Datei nicht gefunden: \(filePath)"
        }
        guard fm.isReadableFile(atPath: expandedPath) else {
            return "Error: Datei nicht lesbar: \(filePath)"
        }
        guard let fileData = fm.contents(atPath: expandedPath) else {
            return "Error: Datei konnte nicht gelesen werden: \(filePath)"
        }

        // Telegram file size limits: 50MB for bots
        guard fileData.count < 50_000_000 else {
            return "Error: Datei zu groß (\(fileData.count / 1_000_000) MB). Telegram-Bots können max. 50 MB senden."
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            return "Error: Ungültige Bot-Token URL"
        }

        let boundary = "KoboldTG\(UUID().uuidString.prefix(8))"
        let fileName = (expandedPath as NSString).lastPathComponent
        let mimeType = detectMimeType(path: expandedPath)

        // Determine the form field name based on method
        let fieldName: String
        switch method {
        case "sendPhoto": fieldName = "photo"
        case "sendAudio": fieldName = "audio"
        default: fieldName = "document"
        }

        // Build multipart/form-data body
        var body = Data()

        // chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)

        // caption field (optional)
        if let caption = caption, !caption.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(caption)\r\n".data(using: .utf8)!)
        }

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        req.timeoutInterval = 120 // Longer timeout for file uploads
        req.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                if ok {
                    let methodLabel: String
                    switch method {
                    case "sendPhoto": methodLabel = "Foto"
                    case "sendAudio": methodLabel = "Audio"
                    default: methodLabel = "Datei"
                    }
                    return "\(methodLabel) '\(fileName)' erfolgreich via Telegram gesendet."
                } else {
                    let errDesc = json["description"] as? String ?? "Unbekannter Fehler"
                    return "Error: Telegram API Fehler: \(errDesc)"
                }
            }
            return "Error: Unerwartete Telegram-Antwort"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func splitMessage(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: min(maxLength, remaining.count))
            chunks.append(String(remaining[remaining.startIndex..<end]))
            remaining = String(remaining[end...])
        }
        return chunks
    }

    private func detectMimeType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3":                return "audio/mpeg"
        case "wav":                return "audio/wav"
        case "flac":               return "audio/flac"
        case "aac", "m4a":         return "audio/mp4"
        case "ogg", "oga":         return "audio/ogg"
        case "mp4", "m4v":         return "video/mp4"
        case "mov":                return "video/quicktime"
        case "avi":                return "video/x-msvideo"
        case "webm":               return "video/webm"
        case "png":                return "image/png"
        case "jpg", "jpeg":        return "image/jpeg"
        case "gif":                return "image/gif"
        case "webp":               return "image/webp"
        case "pdf":                return "application/pdf"
        case "zip":                return "application/zip"
        case "txt":                return "text/plain"
        case "json":               return "application/json"
        default:                   return "application/octet-stream"
        }
    }
}
