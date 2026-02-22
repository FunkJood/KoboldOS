import Foundation

// MARK: - TelegramTool — Agent can send messages via Telegram Bot

public struct TelegramTool: Tool, Sendable {
    public let name = "telegram_send"
    public let description = "Send a message via Telegram Bot to the configured chat"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "message": ToolSchemaProperty(type: "string", description: "The message text to send via Telegram", required: true),
            "chat_id": ToolSchemaProperty(type: "string", description: "Override chat ID (optional, uses configured default if empty)")
        ], required: ["message"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let msg = arguments["message"], !msg.isEmpty else {
            throw ToolError.missingRequired("message")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let message = arguments["message"] ?? ""

        let token = UserDefaults.standard.string(forKey: "kobold.telegram.token") ?? ""
        guard !token.isEmpty else {
            return "Error: Kein Telegram-Bot-Token konfiguriert. Bitte in Einstellungen → Verbindungen → Telegram konfigurieren."
        }

        let chatIdStr = arguments["chat_id"] ?? UserDefaults.standard.string(forKey: "kobold.telegram.chatId") ?? ""
        guard !chatIdStr.isEmpty, let chatId = Int64(chatIdStr) else {
            return "Error: Keine Chat-ID konfiguriert. Bitte in Einstellungen → Verbindungen → Telegram eine Chat-ID eingeben."
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            return "Error: Ungültige Bot-Token URL"
        }

        // Split long messages into chunks
        let chunks = splitMessage(message, maxLength: 4000)
        var sentCount = 0

        for chunk in chunks {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15

            let body: [String: Any] = [
                "chat_id": chatId,
                "text": chunk,
                "parse_mode": "Markdown"
            ]
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
}
