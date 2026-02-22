import Foundation

// MARK: - Telegram Bot Integration
// Connects KoboldOS to Telegram — chat with the agent from your phone.
// Uses Telegram Bot API with long polling (no webhook/server needed).

final class TelegramBot: @unchecked Sendable {
    static let shared = TelegramBot()

    private let lock = NSLock()
    private var _isRunning = false
    private var _botToken = ""
    private var _botUsername = ""
    private var _allowedChatId: Int64 = 0
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateId: Int = 0
    private var _messagesReceived = 0
    private var _messagesSent = 0
    /// Per-chat conversation history for context (chatId -> messages)
    private var _chatHistory: [Int64: [(role: String, text: String)]] = [:]
    private let maxHistoryPerChat = 20

    // Thread-safe synchronous accessors
    var isRunning: Bool { lock.withLock { _isRunning } }
    var botUsername: String { lock.withLock { _botUsername } }
    var stats: (received: Int, sent: Int) { lock.withLock { (_messagesReceived, _messagesSent) } }

    private func getToken() -> String { lock.withLock { _botToken } }
    private func getAllowed() -> Int64 { lock.withLock { _allowedChatId } }
    private func setRunning(_ v: Bool) { lock.withLock { _isRunning = v } }
    private func setBotUsername(_ v: String) { lock.withLock { _botUsername = v } }
    private func incReceived() { lock.withLock { _messagesReceived += 1 } }
    private func incSent() { lock.withLock { _messagesSent += 1 } }

    private func appendHistory(chatId: Int64, role: String, text: String) {
        lock.withLock {
            if _chatHistory[chatId] == nil { _chatHistory[chatId] = [] }
            _chatHistory[chatId]!.append((role: role, text: text))
            if _chatHistory[chatId]!.count > maxHistoryPerChat {
                _chatHistory[chatId]!.removeFirst(_chatHistory[chatId]!.count - maxHistoryPerChat)
            }
        }
    }

    private func getHistory(chatId: Int64) -> [(role: String, text: String)] {
        lock.withLock { _chatHistory[chatId] ?? [] }
    }

    private func clearHistory(chatId: Int64) {
        lock.withLock { _chatHistory[chatId] = nil }
    }

    // MARK: - Start / Stop

    func start(token: String, allowedChatId: Int64 = 0) {
        guard !isRunning else { return }
        lock.withLock {
            _botToken = token
            _allowedChatId = allowedChatId
            _isRunning = true
            _messagesReceived = 0
            _messagesSent = 0
        }

        // Verify bot token and get username
        Task {
            if let me = await getMe(token: token) {
                setBotUsername(me)
                print("[TelegramBot] Started as @\(me)")
            }
        }

        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        setRunning(false)
        pollingTask?.cancel()
        pollingTask = nil
        setBotUsername("")
        print("[TelegramBot] Stopped")
    }

    // MARK: - Bot API: getMe

    private func getMe(token: String) async -> String? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getMe") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok,
               let result = json["result"] as? [String: Any],
               let username = result["username"] as? String {
                return username
            }
        } catch {}
        return nil
    }

    // MARK: - Long Polling Loop

    private func pollLoop() async {
        while !Task.isCancelled && isRunning {
            let token = getToken()

            do {
                let updates = try await getUpdates(token: token, offset: lastUpdateId + 1, timeout: 30)
                for update in updates {
                    await handleUpdate(update, token: token)
                }
            } catch {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - Get Updates

    private func getUpdates(token: String, offset: Int, timeout: Int) async throws -> [[String: Any]] {
        let urlString = "https://api.telegram.org/bot\(token)/getUpdates?timeout=\(timeout)&offset=\(offset)&allowed_updates=%5B%22message%22%5D"
        guard let url = URL(string: urlString) else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(timeout + 10)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [[String: Any]] else { return [] }
        return result
    }

    // MARK: - Handle Update

    private func handleUpdate(_ update: [String: Any], token: String) async {
        guard let updateId = update["update_id"] as? Int else { return }
        lastUpdateId = max(lastUpdateId, updateId)

        guard let message = update["message"] as? [String: Any],
              let chat = message["chat"] as? [String: Any],
              let chatId = chat["id"] as? Int64,
              let text = message["text"] as? String else { return }

        // Check allowed chat ID
        let allowed = getAllowed()
        if allowed != 0 && chatId != allowed {
            await sendMessage(token: token, chatId: chatId, text: "Zugriff verweigert. Deine Chat-ID: \(chatId)")
            return
        }

        incReceived()

        // Handle /start command
        if text == "/start" {
            await sendMessage(token: token, chatId: chatId,
                text: "Willkommen bei KoboldOS! Sende mir eine Nachricht und ich leite sie an deinen Agent weiter.\n\nBefehle:\n/status — Bot-Status\n/clear — Gespr\u{00E4}ch zur\u{00FC}cksetzen\n\nDeine Chat-ID: \(chatId)")
            return
        }

        // Handle /status command
        if text == "/status" {
            let s = stats
            let histLen = getHistory(chatId: chatId).count
            await sendMessage(token: token, chatId: chatId,
                text: "KoboldOS Telegram Bot\nEmpfangen: \(s.received)\nGesendet: \(s.sent)\nKontext: \(histLen) Nachrichten\nStatus: Aktiv")
            return
        }

        // Handle /clear command
        if text == "/clear" {
            clearHistory(chatId: chatId)
            await sendMessage(token: token, chatId: chatId, text: "Gespr\u{00E4}ch zur\u{00FC}ckgesetzt.")
            return
        }

        // Send "typing" indicator
        await sendChatAction(token: token, chatId: chatId, action: "typing")

        // Add user message to history
        appendHistory(chatId: chatId, role: "user", text: text)

        // Forward to KoboldOS agent with conversation context
        let response = await forwardToAgent(message: text, chatId: chatId)

        // Add assistant response to history
        appendHistory(chatId: chatId, role: "assistant", text: response)

        // Send response back to Telegram
        await sendMessage(token: token, chatId: chatId, text: response)
    }

    // MARK: - Forward to Agent

    private func forwardToAgent(message: String, chatId: Int64) async -> String {
        let daemonPort = UserDefaults.standard.integer(forKey: "kobold.port")
        let port = daemonPort == 0 ? 8080 : daemonPort
        let authToken = UserDefaults.standard.string(forKey: "kobold.authToken") ?? ""

        guard let url = URL(string: "http://localhost:\(port)/agent") else {
            return "Daemon nicht erreichbar."
        }

        let provider = UserDefaults.standard.string(forKey: "kobold.provider") ?? "ollama"
        let model = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? ""
        let apiKey = UserDefaults.standard.string(forKey: "kobold.apiKey") ?? ""

        // Build message with conversation context
        let history = getHistory(chatId: chatId)
        var contextMessage = message
        if history.count > 1 {
            // Include recent conversation context (excluding the just-added current message)
            let prior = history.dropLast()
            let contextLines = prior.map { entry in
                entry.role == "user" ? "Nutzer: \(entry.text)" : "Agent: \(entry.text)"
            }.joined(separator: "\n")
            contextMessage = "[Bisheriges Gespr\u{00E4}ch (Telegram)]\n\(contextLines)\n\n[Aktuelle Nachricht]\n\(message)"
        }

        var body: [String: Any] = ["message": contextMessage, "source": "telegram"]
        if !provider.isEmpty { body["provider"] = provider }
        if !model.isEmpty { body["model"] = model }
        if !apiKey.isEmpty { body["api_key"] = apiKey }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let output = json["output"] as? String {
                return output
            }
            return "Keine Antwort vom Agent."
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    // MARK: - Send Message

    private func sendMessage(token: String, chatId: Int64, text: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }

        let chunks = splitMessage(text, maxLength: 4000)
        for chunk in chunks {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Try Markdown first, fall back to plain text
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "chat_id": chatId,
                "text": chunk,
                "parse_mode": "Markdown"
            ] as [String : Any])

            if let (data, _) = try? await URLSession.shared.data(for: req) {
                // Check if Markdown parsing failed
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, !ok {
                    // Retry without Markdown
                    req.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "chat_id": chatId,
                        "text": chunk
                    ] as [String : Any])
                    _ = try? await URLSession.shared.data(for: req)
                }
            }

            incSent()
        }
    }

    private func sendChatAction(token: String, chatId: Int64, action: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendChatAction") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatId,
            "action": action
        ] as [String : Any])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Helpers

    private func splitMessage(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            let endIndex = remaining.index(remaining.startIndex, offsetBy: min(maxLength, remaining.count))
            if let newlineIdx = remaining[..<endIndex].lastIndex(of: "\n"), newlineIdx > remaining.startIndex {
                chunks.append(String(remaining[..<newlineIdx]))
                remaining = String(remaining[remaining.index(after: newlineIdx)...])
            } else {
                chunks.append(String(remaining[..<endIndex]))
                remaining = String(remaining[endIndex...])
            }
        }
        return chunks
    }
}
