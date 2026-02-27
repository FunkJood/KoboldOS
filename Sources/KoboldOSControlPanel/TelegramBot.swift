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
    private let maxHistoryPerChat = 100

    private var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/telegram_history.json")
    }

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
            var history = _chatHistory[chatId] ?? []
            history.append((role: role, text: text))
            if history.count > maxHistoryPerChat {
                history.removeFirst(history.count - maxHistoryPerChat)
            }
            _chatHistory[chatId] = history
        }
        // Alle ~10 Nachrichten auf Disk sichern (nicht jede einzelne)
        let count = lock.withLock { _messagesReceived + _messagesSent }
        if count % 10 == 0 { saveHistoryToDisk() }
    }

    private func getHistory(chatId: Int64) -> [(role: String, text: String)] {
        lock.withLock { _chatHistory[chatId] ?? [] }
    }

    private func clearHistory(chatId: Int64) {
        lock.withLock { _chatHistory[chatId] = nil }
        saveHistoryToDisk()
    }

    /// Persistent History — JSON auf Disk speichern
    private func saveHistoryToDisk() {
        let snapshot = lock.withLock { _chatHistory }
        // Convert to serializable format
        var dict: [String: [[String: String]]] = [:]
        for (chatId, msgs) in snapshot {
            dict["\(chatId)"] = msgs.map { ["role": $0.role, "text": $0.text] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: historyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyFileURL)
    }

    /// Persistent History — JSON von Disk laden
    private func loadHistoryFromDisk() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]] else { return }
        lock.withLock {
            for (chatIdStr, msgs) in dict {
                guard let chatId = Int64(chatIdStr) else { continue }
                _chatHistory[chatId] = msgs.compactMap { m in
                    guard let role = m["role"], let text = m["text"] else { return nil }
                    return (role: role, text: text)
                }
            }
        }
    }

    // MARK: - Start / Stop

    func start(token: String, allowedChatId: Int64 = 0) {
        guard !isRunning else { return }
        // Persistente History laden
        loadHistoryFromDisk()
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
        saveHistoryToDisk() // Persistente History sichern
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
              let chatId = chat["id"] as? Int64 else { return }

        // Check allowed chat ID
        let allowed = getAllowed()
        if allowed != 0 && chatId != allowed {
            await sendMessage(token: token, chatId: chatId, text: "Zugriff verweigert. Deine Chat-ID: \(chatId)")
            return
        }

        incReceived()

        // Determine message content: text or voice
        let messageText: String
        if let text = message["text"] as? String {
            messageText = text
        } else if let voice = message["voice"] as? [String: Any],
                  let fileId = voice["file_id"] as? String {
            // Voice message — transcribe via STT
            await sendChatAction(token: token, chatId: chatId, action: "typing")
            if let transcribed = await transcribeVoiceMessage(token: token, fileId: fileId) {
                messageText = transcribed
                // Show what was transcribed
                await sendMessage(token: token, chatId: chatId, text: "\u{1F399}\u{FE0F} Erkannt: \"\(transcribed)\"")
            } else {
                await sendMessage(token: token, chatId: chatId,
                    text: "Sprachnachricht konnte nicht transkribiert werden. Ist das Whisper-Modell in den Einstellungen geladen?")
                return
            }
        } else if let audio = message["audio"] as? [String: Any],
                  let fileId = audio["file_id"] as? String {
            // Audio file — also transcribe
            await sendChatAction(token: token, chatId: chatId, action: "typing")
            if let transcribed = await transcribeVoiceMessage(token: token, fileId: fileId) {
                messageText = transcribed
                await sendMessage(token: token, chatId: chatId, text: "\u{1F399}\u{FE0F} Erkannt: \"\(transcribed)\"")
            } else {
                await sendMessage(token: token, chatId: chatId,
                    text: "Audio konnte nicht transkribiert werden. Ist das Whisper-Modell geladen?")
                return
            }
        } else {
            // Unsupported message type (sticker, photo without caption, etc.)
            return
        }

        // Handle /start command
        if messageText == "/start" {
            await sendMessage(token: token, chatId: chatId,
                text: "Willkommen bei KoboldOS! Sende mir eine Nachricht oder Sprachnachricht.\n\nBefehle:\n/status \u{2014} Bot-Status\n/clear \u{2014} Gespr\u{00E4}ch zur\u{00FC}cksetzen\n\nDeine Chat-ID: \(chatId)")
            return
        }

        // Handle /status command
        if messageText == "/status" {
            let s = stats
            let histLen = getHistory(chatId: chatId).count
            await sendMessage(token: token, chatId: chatId,
                text: "KoboldOS Telegram Bot\nEmpfangen: \(s.received)\nGesendet: \(s.sent)\nKontext: \(histLen) Nachrichten\nStatus: Aktiv")
            return
        }

        // Handle /clear command
        if messageText == "/clear" {
            clearHistory(chatId: chatId)
            await sendMessage(token: token, chatId: chatId, text: "Gespr\u{00E4}ch zur\u{00FC}ckgesetzt.")
            return
        }

        // Send "typing" indicator
        await sendChatAction(token: token, chatId: chatId, action: "typing")

        // Add user message to history
        appendHistory(chatId: chatId, role: "user", text: messageText)

        // Forward to KoboldOS agent with conversation context
        var response = await forwardToAgent(message: messageText, chatId: chatId)

        // Guard against empty responses (Telegram rejects empty messages)
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            response = "Ich konnte leider keine Antwort generieren. Bitte versuche es nochmal."
        }

        // Add assistant response to history
        appendHistory(chatId: chatId, role: "assistant", text: response)

        // Send response back to Telegram
        await sendMessage(token: token, chatId: chatId, text: response)
    }

    // MARK: - Voice Message Transcription

    /// Downloads a voice/audio file from Telegram and transcribes it via STTManager (whisper.cpp)
    private func transcribeVoiceMessage(token: String, fileId: String) async -> String? {
        // Step 1: Get file path from Telegram
        guard let filePath = await getTelegramFilePath(token: token, fileId: fileId) else {
            print("[TelegramBot] Failed to get file path for \(fileId)")
            return nil
        }

        // Step 2: Download the audio file
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent("tg_voice_\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: localURL) }

        guard await downloadTelegramFile(token: token, filePath: filePath, to: localURL) else {
            print("[TelegramBot] Failed to download voice file")
            return nil
        }

        // Step 3: Ensure STT model is loaded (might be first access to STTManager)
        await STTManager.shared.loadModelIfAvailable()
        let isLoaded = await MainActor.run { STTManager.shared.isModelLoaded }
        guard isLoaded else {
            print("[TelegramBot] STT model not available — no model file found")
            return nil
        }

        // Step 4: Transcribe via whisper.cpp
        let result = await STTManager.shared.transcribe(audioURL: localURL)
        if let text = result {
            print("[TelegramBot] Transcribed voice: \(text.prefix(80))...")
        } else {
            print("[TelegramBot] Transcription returned nil — ffmpeg installed?")
        }
        return result
    }

    /// Calls Telegram getFile API to resolve file_id → file_path
    private func getTelegramFilePath(token: String, fileId: String) async -> String? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getFile?file_id=\(fileId)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok,
               let result = json["result"] as? [String: Any],
               let path = result["file_path"] as? String {
                return path
            }
        } catch {
            print("[TelegramBot] getFile error: \(error)")
        }
        return nil
    }

    /// Downloads a file from Telegram's file server to a local path
    private func downloadTelegramFile(token: String, filePath: String, to localURL: URL) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return false }
            try data.write(to: localURL)
            return true
        } catch {
            print("[TelegramBot] Download error: \(error)")
            return false
        }
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
                return cleanJSONResponse(output)
            }
            return "Keine Antwort vom Agent."
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    /// Safety net: if the agent output is still raw JSON, extract the text field.
    /// Uses regex as primary method (works even with malformed JSON from local models).
    private func cleanJSONResponse(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Not JSON-like → pass through
        guard trimmed.hasPrefix("{") || trimmed.contains("\"tool_name\"") || trimmed.contains("\"toolname\"") else {
            return text
        }

        // Strategy 1: Regex — extract "text" value directly (works with broken JSON)
        if let extracted = regexExtractText(from: trimmed) {
            return extracted
        }

        // Strategy 2: Valid JSON → deep extract
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let deep = deepExtractText(json) {
            return deep
        }

        // Strategy 3: Balanced-brace scan for tool_args sub-object
        if let extracted = extractTextFromMalformedJSON(trimmed) {
            return extracted
        }

        return text
    }

    /// Extracts "text" value from JSON-like string using regex (tolerates malformed JSON)
    private func regexExtractText(from text: String) -> String? {
        let pattern = #""text"\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[range])
        let unescaped = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
        guard !unescaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return unescaped
    }

    /// Recursively searches a JSON dictionary for the most likely user-facing text value.
    private func deepExtractText(_ dict: [String: Any]) -> String? {
        let textKeys = ["text", "content", "response", "message", "answer", "reply", "output", "result"]
        let skipKeys: Set<String> = ["tool_name", "toolname", "name", "tool", "function", "action", "confidence", "thoughts"]
        // 1. Direct text keys
        for key in textKeys {
            if let s = dict[key] as? String, !s.isEmpty,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return s }
        }
        // 2. Nested args objects
        for key in ["tool_args", "toolargs", "args", "arguments", "parameters", "input"] {
            if let nested = dict[key] as? [String: Any] {
                for tk in textKeys {
                    if let s = nested[tk] as? String, !s.isEmpty,
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return s }
                }
                for (_, value) in nested {
                    if let s = value as? String, !s.isEmpty,
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return s }
                }
            }
            if let str = dict[key] as? String, !str.isEmpty {
                if let d = str.data(using: .utf8),
                   let inner = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let deep = deepExtractText(inner) { return deep }
                if !str.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return str }
            }
        }
        // 3. Any non-metadata string (longest)
        var best = ""
        for (key, value) in dict where !skipKeys.contains(key) {
            if let s = value as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
               s.count > best.count { best = s }
        }
        return best.isEmpty ? nil : best
    }

    /// Extracts the "text" field from a toolargs/tool_args sub-object in malformed JSON.
    /// Uses balanced brace scanning (string-aware) to find the valid sub-object.
    private func extractTextFromMalformedJSON(_ text: String) -> String? {
        // Must look like a tool call response
        guard text.contains("\"response\""),
              text.contains("\"toolargs\"") || text.contains("\"tool_args\"") else { return nil }

        // Find "toolargs": { or "tool_args": {
        let pattern = #""(?:tool_args|toolargs)"\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let matchRange = Range(match.range, in: text) else { return nil }

        // Find the opening brace
        guard let braceStart = text[matchRange].lastIndex(of: "{") else { return nil }

        // Balanced brace scan (string-aware) to find matching }
        var depth = 0
        var inStr = false
        var esc = false
        var pos = braceStart
        while pos < text.endIndex {
            let ch = text[pos]
            if esc { esc = false }
            else if ch == "\\" && inStr { esc = true }
            else if ch == "\"" { inStr.toggle() }
            else if !inStr {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let argsJSON = String(text[braceStart...pos])
                        if let data = argsJSON.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let t = json["text"] as? String, !t.isEmpty {
                            return t
                        }
                        break
                    }
                }
            }
            pos = text.index(after: pos)
        }
        return nil
    }

    // MARK: - Send Message

    /// Send a notification to the configured Telegram chat (called from GUI notification system)
    func sendNotification(_ text: String) {
        let token = getToken()
        let chatId = getAllowed()
        guard !token.isEmpty, chatId != 0, isRunning else { return }
        Task {
            await sendMessage(token: token, chatId: chatId, text: text)
        }
    }

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
