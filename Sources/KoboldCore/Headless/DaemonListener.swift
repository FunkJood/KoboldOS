import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - DaemonListener
// Minimal HTTP server for KoboldOS daemon API

public actor DaemonListener {
    private let port: Int
    private let authToken: String
    private var agentLoop: AgentLoop?
    private let taggedMemoryStore = MemoryStore.shared

    /// STT-Handler: Wird von der App gesetzt (da STTManager im GUI-Modul lebt).
    /// Transkribiert eine WAV-Datei → Text. Wird für Twilio Voice gebraucht.
    public nonisolated(unsafe) static var sttHandler: (@Sendable (URL) async -> String?)? = nil

    // Metrics
    private var chatRequests = 0
    private var toolCalls = 0
    private var errors = 0
    private var tokensTotal = 0
    private var startTime = Date()
    private var activeAgentStreams = 0

    // Latency tracking
    private var latencySamples: [(Date, Double)] = []  // (timestamp, milliseconds)
    private let maxLatencySamples = 500

    private var averageLatencyMs: Double {
        guard !latencySamples.isEmpty else { return 0 }
        let sum = latencySamples.reduce(0.0) { $0 + $1.1 }
        return sum / Double(latencySamples.count)
    }

    private func recordLatency(_ ms: Double) {
        latencySamples.append((Date(), ms))
        if latencySamples.count > maxLatencySamples {
            latencySamples = Array(latencySamples.suffix(maxLatencySamples / 2))
        }
    }

    // P12: Connection limits — Thread-safe via NSLock (activeConnections wird von Background-Threads modifiziert)
    private let connectionLock = NSLock()
    private var _activeConnections = 0
    private var activeConnections: Int {
        get { connectionLock.lock(); defer { connectionLock.unlock() }; return _activeConnections }
        set { connectionLock.lock(); _activeConnections = newValue; connectionLock.unlock() }
    }
    private let maxConcurrentConnections = 1000

    // Request log
    private var requestLog: [(Date, String, String)] = [] // (time, path, status)

    // Activity trace timeline
    private var traceTimeline: [[String: Any]] = []
    private let maxTraceEntries = 500
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private func addTrace(event: String, detail: String) {
        let ts = DaemonListener.isoFormatter.string(from: Date())
        let entry: [String: Any] = [
            "event": event,
            "detail": detail,
            "timestamp": ts
        ]
        traceTimeline.append(entry)
        if traceTimeline.count > maxTraceEntries {
            traceTimeline = Array(traceTimeline.suffix(maxTraceEntries / 2))
        }
    }

    // Rate limiting: [path: [timestamps]]
    private var rateLimitMap: [String: [Date]] = [:]
    private let rateLimitMax = 6000       // effectively unlimited — no artificial throttling
    private let bodyLimitBytes = 10_485_760 // 10 MB

    /// B1: Shutdown-Flag für graceful termination — P12: Thread-safe via lock
    private let runningLock = NSLock()
    private var _isRunning = true
    private var isRunning: Bool {
        get { runningLock.lock(); defer { runningLock.unlock() }; return _isRunning }
        set { runningLock.lock(); _isRunning = newValue; runningLock.unlock() }
    }

    public init(port: Int, authToken: String) {
        self.port = port
        self.authToken = authToken
        self.agentLoop = AgentLoop()
    }

    public func start() async {
        addTrace(event: "Start", detail: "DaemonListener on :\(port)")
        isRunning = true
        migrateA2APermissions()
        startTaskScheduler()
        // Start ConsciousnessEngine with shared memory stores
        await ConsciousnessEngine.shared.configure(
            memoryStore: taggedMemoryStore,
            coreMemory: agentLoop?.coreMemory ?? CoreMemory()
        )
        await ConsciousnessEngine.shared.start(intervalSeconds: 300)
        await runServer()
    }

    /// B1: Graceful Shutdown — schließt Server-Socket und beendet Accept-Loop
    public func stop() {
        isRunning = false
        print("[DaemonListener] Stop requested — closing server socket")
    }

    // MARK: - Main Server Loop

    private func runServer() async {
        let listenPort = port
        guard let sock = ServerSocket(port: listenPort) else {
            print("❌ Failed to bind port \(listenPort) — another instance may be running")
            return
        }
        print("✅ Listening on port \(listenPort) (PID \(ProcessInfo.processInfo.processIdentifier))")

        // Bridge blocking Darwin.accept() to async via AsyncStream
        // accept() is already blocking — no busy-wait needed
        // B1: Accept-Loop — wird durch Process-Exit beendet (sock.close() in stop())
        let clientStream = AsyncStream<ClientSocket> { continuation in
            let t = Thread {
                while true {
                    guard let client = sock.accept() else {
                        // accept() failed (e.g. fd closed or shutdown) — check if we should stop
                        if !Thread.current.isCancelled { Thread.sleep(forTimeInterval: 0.5) }
                        continue
                    }
                    continuation.yield(client)
                }
            }
            t.qualityOfService = .utility
            t.start()
        }

        // Use Task.detached so each request runs CONCURRENTLY, not serialized on the actor.
        // CRITICAL: Socket read + HTTP parsing happen OFF the actor (in the detached task)
        // to prevent blocking the actor queue while waiting for slow clients.
        let maxBytes = self.bodyLimitBytes
        for await client in clientStream {
            let canAccept = self.canAcceptConnection()
            guard canAccept else {
                client.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                client.close()
                continue
            }
            Task.detached(priority: .userInitiated) {
                await self.incrementConnections()
                // Read + parse request OFF the actor (blocking I/O happens here, not on actor queue)
                guard let raw = client.readRequest(maxBytes: maxBytes) else {
                    client.close()
                    await self.decrementConnections()
                    return
                }
                let parsed = DaemonListener.parseHTTPRequestStatic(raw)
                // Only route on actor (quick dispatch, no blocking I/O)
                await self.handleParsedRequest(client: client, parsed: parsed)
                client.close()
                await self.decrementConnections()
            }
        }
    }

    private func canAcceptConnection() -> Bool {
        activeConnections < maxConcurrentConnections
    }

    private func incrementConnections() { activeConnections += 1 }
    private func decrementConnections() { activeConnections = max(0, activeConnections - 1) }

    // MARK: - Request Handler

    /// Handles an already-parsed HTTP request on the actor.
    /// Socket read + parsing happened off-actor to avoid blocking the actor queue.
    private func handleParsedRequest(client: ClientSocket, parsed: (method: String, path: String, headers: [String: String], body: Data?)) async {
        let requestStart = CFAbsoluteTimeGetCurrent()
        let (method, path, headers, body) = parsed

        // Body size check
        if let b = body, b.count > bodyLimitBytes {
            client.write(httpResponse(status: "413 Payload Too Large", body: "{\"error\":\"Body exceeds 10MB limit\"}"))
            return
        }

        // Auth check — /health, /.well-known/agent.json, and Twilio webhooks are public
        // Twilio sendet KEINEN Authorization-Header bei Webhook-Aufrufen
        let isPublicPath = path == "/health"
            || path == "/.well-known/agent.json"
            || path.hasPrefix("/twilio/")
        if !isPublicPath {
            let authHeader = headers["authorization"] ?? ""
            // Case-insensitive "Bearer " prefix removal
            let provided: String
            if authHeader.lowercased().hasPrefix("bearer ") {
                provided = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else {
                provided = authHeader
            }

            // A2A routes use their own token (kobold.a2a.token), not the daemon token
            if path == "/a2a" {
                let a2aToken = UserDefaults.standard.string(forKey: "kobold.a2a.token") ?? ""
                let a2aEnabled = UserDefaults.standard.bool(forKey: "kobold.a2a.enabled")
                if !a2aEnabled {
                    client.write(httpResponse(status: "403 Forbidden", body: "{\"error\":\"A2A is disabled\"}"))
                    return
                }
                if a2aToken.isEmpty || provided != a2aToken {
                    client.write(httpResponse(status: "401 Unauthorized", body: "{\"error\":\"Invalid or missing A2A token\"}"))
                    return
                }
                // A2A auth passed — fall through to routing
            } else if !authToken.isEmpty && provided != authToken {
                // Debug: Bei Proxy-Pfad detailliert loggen
                if path.hasPrefix("/v1/") {
                    print("[Auth] ❌ 401 für \(path) — Header: '\(authHeader.prefix(30))...', erwartet Token-Länge: \(authToken.count)")
                }
                client.write(httpResponse(status: "401 Unauthorized", body: "{\"error\":\"Invalid or missing auth token\"}"))
                return
            }
        }

        // Rate limiting
        if isRateLimited(path: path) {
            client.write(httpResponse(status: "429 Too Many Requests", body: "{\"error\":\"Rate limit exceeded (\(rateLimitMax)/min)\"}"))
            return
        }

        // WebSocket upgrade für Twilio Voice Media Streams
        if path == "/twilio/voice/ws" && (headers["upgrade"] ?? "").lowercased() == "websocket" {
            let wsKey = headers["sec-websocket-key"] ?? ""
            guard !wsKey.isEmpty else {
                client.write(httpResponse(status: "400 Bad Request", body: "Missing Sec-WebSocket-Key"))
                return
            }
            // WebSocket Handshake (RFC 6455)
            if client.performWebSocketHandshake(key: wsKey) {
                await handleTwilioMediaStream(client: client)
            }
            return
        }

        // SSE streaming endpoint — writes directly to socket, does NOT return a single response
        if path == "/agent/stream" && method == "POST" {
            await handleAgentStream(client: client, body: body)
            return
        }

        // A2A streaming endpoint (JSON-RPC message/sendStream)
        if path == "/a2a" && method == "POST" {
            if let body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let rpcMethod = json["method"] as? String,
               rpcMethod == "message/sendStream" {
                await handleA2AStream(client: client, body: body, json: json)
                return
            }
        }

        // OpenAI-compatible proxy (für ElevenLabs Custom LLM → Ollama)
        if path == "/v1/chat/completions" && method == "POST" {
            await handleOpenAIProxy(client: client, body: body)
            return
        }

        let response = await routeRequest(method: method, path: path, body: body)
        client.write(response)

        let elapsed = (CFAbsoluteTimeGetCurrent() - requestStart) * 1000.0
        recordLatency(elapsed)
    }

    private func isRateLimited(path: String) -> Bool {
        let now = Date()
        // Prevent unbounded map growth: evict all entries if too many paths
        if rateLimitMap.count > 200 {
            rateLimitMap = rateLimitMap.filter { !$0.value.allSatisfy { now.timeIntervalSince($0) >= 60 } }
        }
        var timestamps = rateLimitMap[path] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 60 }
        if timestamps.isEmpty {
            rateLimitMap.removeValue(forKey: path)
        }
        if timestamps.count >= rateLimitMax {
            rateLimitMap[path] = timestamps
            return true
        }
        timestamps.append(now)
        rateLimitMap[path] = timestamps
        return false
    }

    private func routeRequest(method: String, path: String, body: Data?) async -> String {
        requestLog.append((Date(), path, "200"))
        if requestLog.count > 500 { requestLog = Array(requestLog.suffix(250)) }

        switch path {
        case "/health":
            return jsonOK([
                "status": "ok",
                "version": KoboldVersion.current,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "uptime": Int(Date().timeIntervalSince(startTime)),
                "active_streams": activeAgentStreams
            ])

        case "/agent":
            guard method == "POST", let body else { return jsonError("No body") }
            chatRequests += 1
            return await handleAgent(body: body)

        case "/agent/compress":
            guard method == "POST" else { return jsonError("POST required") }
            let pool = AgentWorkerPool.shared
            let agent = await pool.acquire()
            let remaining = await agent.compressContext()
            Task.detached { await pool.release(agent) }
            return jsonOK(["success": true, "messages_remaining": remaining])

        case "/chat":
            guard method == "POST", let body else { return jsonError("No body") }
            chatRequests += 1
            return await handleChat(body: body)

        case "/metrics":
            let activeModel = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "unknown"
            return jsonOK([
                "chat_requests": chatRequests,
                "tool_calls": toolCalls,
                "errors": errors,
                "tokens_total": tokensTotal,
                "uptime": Int(Date().timeIntervalSince(startTime)),
                "avg_latency_ms": round(averageLatencyMs * 100) / 100,
                "backend": "ollama",
                "model": activeModel
            ])

        case "/metrics/reset":
            chatRequests = 0; toolCalls = 0; errors = 0; tokensTotal = 0; startTime = Date(); latencySamples = []
            return jsonOK(["ok": true])

        case "/daemon/logs":
            // Return trace timeline + request log for live log viewer in Security tab
            let since = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["since_index"] as? Int ?? 0
            let logsToSend = since < traceTimeline.count ? Array(traceTimeline.suffix(from: since)) : []
            let recentRequests = requestLog.suffix(50).map { (ts, path, status) -> [String: Any] in
                ["timestamp": DaemonListener.isoFormatter.string(from: ts), "path": path, "status": status]
            }
            return jsonOK([
                "logs": logsToSend,
                "total_count": traceTimeline.count,
                "requests": recentRequests
            ])

        case "/memory":
            if let agent = agentLoop {
                let blocks = await agent.coreMemory.allBlocks()
                let arr = blocks.map { ["label": $0.label, "content": $0.value, "limit": $0.limit] }
                return jsonOK(["blocks": arr])
            }
            return jsonOK(["blocks": []])

        case "/memory/update":
            guard method == "POST", let body else { return jsonError("No body") }
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let label = json["label"] as? String {
                if let agent = agentLoop {
                    let isDelete = json["delete"] as? Bool ?? false
                    if isDelete {
                        try? await agent.coreMemory.clear(label: label)
                        addTrace(event: "Gedächtnis", detail: "Gelöscht: \(label)")
                    } else if let content = json["content"] as? String {
                        let limit = json["limit"] as? Int ?? 2000
                        await agent.coreMemory.upsert(MemoryBlock(label: label, value: content, limit: limit))
                        addTrace(event: "Gedächtnis", detail: "Aktualisiert: \(label)")
                    }
                }
                return jsonOK(["ok": true])
            }
            return jsonError("Invalid body")

        case "/memory/flush":
            if let agent = agentLoop {
                await agent.coreMemory.flush()
            }
            return jsonOK(["ok": true, "msg": "Memory flushed to disk"])

        case "/memory/snapshot":
            return jsonOK(["ok": true, "msg": "Snapshot created"])

        case "/models":
            return await handleModels()

        case "/model/set":
            guard method == "POST", let body else { return jsonError("No body") }
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let model = json["model"] as? String {
                UserDefaults.standard.set(model, forKey: "kobold.ollamaModel")
                addTrace(event: "Modell", detail: "Gewechselt: \(model)")
                return jsonOK(["ok": true, "model": model])
            }
            return jsonError("Invalid body")

        case "/settings":
            return handleSettings(method: method, body: body)

        case "/consciousness":
            let state = await ConsciousnessEngine.shared.getState()
            let fmt = ISO8601DateFormatter()
            return jsonOK([
                "valence": state.valence,
                "arousal": state.arousal,
                "successRate": state.successRate,
                "cycleCount": state.cycleCount,
                "lastCycle": state.lastCycle.map { fmt.string(from: $0) } ?? "never",
                "errorCount": state.errorCount,
                "solutionCount": state.solutionCount,
                "isRunning": state.isRunning
            ])

        // MARK: Twilio SMS Webhook (eingehende SMS empfangen + antworten)
        case "/twilio/sms/webhook":
            guard method == "POST", let body else { return twimlError("POST required") }
            return await handleTwilioSmsWebhook(body: body)

        // MARK: Twilio Voice Webhook (eingehende/ausgehende Anrufe)
        case "/twilio/voice/webhook":
            guard method == "POST", let body else { return twimlError("POST required") }
            return await handleTwilioVoiceWebhook(body: body)

        case "/tts/elevenlabs/voices":
            return await handleElevenLabsVoices()

        case "/tts/elevenlabs/speak":
            guard method == "POST", let body else { return jsonError("POST required") }
            return await handleElevenLabsSpeak(body: body)

        case "/skills":
            let skills = await SkillLoader.shared.loadSkills()
            let list = skills.map { ["name": $0.name, "filename": $0.filename, "enabled": $0.isEnabled] as [String: Any] }
            return jsonOK(["skills": list])

        case "/skills/toggle":
            guard method == "POST", let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = json["name"] as? String,
                  let enabled = json["enabled"] as? Bool else {
                return jsonError("Invalid body — expected {name, enabled}")
            }
            var enabledList = UserDefaults.standard.stringArray(forKey: "kobold.skills.enabled") ?? []
            if enabled { if !enabledList.contains(name) { enabledList.append(name) } }
            else { enabledList.removeAll { $0 == name } }
            UserDefaults.standard.set(enabledList, forKey: "kobold.skills.enabled")
            await SkillLoader.shared.invalidateCache()
            addTrace(event: "Skill", detail: "\(name) \(enabled ? "aktiviert" : "deaktiviert")")
            return jsonOK(["ok": true, "name": name, "enabled": enabled])

        case "/tasks":
            if method == "POST", let body {
                return handleTasksPost(body: body)
            }
            return jsonOK(["tasks": loadTasks()])

        case "/idle-tasks":
            if method == "POST", let body {
                return handleIdleTasksPost(body: body)
            }
            return loadIdleTasksJSON()

        case "/workflows":
            if method == "POST", let body {
                return handleWorkflowsPost(body: body)
            }
            let wfs = loadWorkflowDefinitions()
            let wfDicts: [[String: Any]] = wfs.map { ["id": $0.id, "name": $0.name, "description": $0.description, "steps": $0.steps, "createdAt": $0.createdAt] }
            return jsonOK(["workflows": wfDicts])

        case "/trace":
            return jsonOK(["timeline": traceTimeline, "count": traceTimeline.count])

        case "/history/clear":
            agentLoop = AgentLoop()
            addTrace(event: "System", detail: "Chat-Verlauf gelöscht")
            return jsonOK(["ok": true])

        // MARK: - A2A Agent Card (public)
        case "/.well-known/agent.json":
            return jsonOK(buildAgentCard())

        // MARK: - A2A JSON-RPC (authenticated via kobold.a2a.token)
        case "/a2a":
            guard method == "POST", let body else { return jsonError("POST required") }
            return await handleA2ARPC(body: body)

        // MARK: - Checkpoints
        case "/checkpoints":
            if method == "POST", let body {
                return await handleCheckpointAction(body: body)
            }
            return await handleCheckpointsList()

        case "/checkpoints/delete":
            guard method == "POST", let body else { return jsonError("No body") }
            return await handleCheckpointDelete(body: body)

        case "/checkpoints/resume":
            guard method == "POST", let body else { return jsonError("No body") }
            return await handleCheckpointResume(body: body)

        // MARK: - Tagged Memory Entries
        case "/memory/entries":
            return await handleMemoryEntries(method: method, body: body)

        case "/memory/entries/search":
            guard method == "POST", let body else { return jsonError("No body") }
            return await handleMemoryEntriesSearch(body: body)

        case "/memory/entries/tags":
            return await handleMemoryEntryTags()

        // MARK: - Memory Versioning
        case "/memory/versions":
            return await handleMemoryVersions()

        case "/memory/diff":
            guard method == "POST", let body else { return jsonError("No body") }
            return await handleMemoryDiff(body: body)

        case "/memory/rollback":
            guard method == "POST", let body else { return jsonError("No body") }
            return await handleMemoryRollback(body: body)

        // MARK: - Chat History Logs
        case "/logs/chat":
            return handleChatLogs(method: method, body: body)

        // MARK: - Topics
        case "/topics":
            if method == "POST", let body {
                return handleTopicsPost(body: body)
            }
            return loadTopicsJSON()

        default:
            return httpResponse(status: "404 Not Found", body: "{\"error\":\"Not found\"}")
        }
    }

    // MARK: - Chat History Logs Handler

    private func handleChatLogs(method: String, body: Data?) -> String {
        let fm = FileManager.default
        let chatDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/logs/chat")

        // POST mit { "date": "2026-02-28", "lastLines": 100 } → Inhalt eines bestimmten Tages
        if method == "POST", let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let dateStr = json["date"] as? String
            let lastLines = json["lastLines"] as? Int ?? 200
            let today = Self.todayString()
            let fileName = (dateStr ?? today) + ".log"
            let fileURL = chatDir.appendingPathComponent(fileName)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                let tail = lines.suffix(lastLines).joined(separator: "\n")
                return jsonOK(["date": dateStr ?? today, "lines": lines.count, "content": tail])
            }
            return jsonOK(["date": dateStr ?? today, "lines": 0, "content": ""])
        }

        // GET → Liste aller verfügbaren Chat-Log-Dateien
        guard let files = try? fm.contentsOfDirectory(at: chatDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return jsonOK(["logs": [] as [Any]])
        }
        let logs: [[String: Any]] = files
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> [String: Any]? in
                let name = url.deletingPathExtension().lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ["date": name, "size": size]
            }
            .sorted { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }
        return jsonOK(["logs": logs])
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    // MARK: - Topics Handler

    private func loadTopicsJSON() -> String {
        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/topics.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return jsonOK(["topics": [] as [Any]])
        }
        return jsonOK(["topics": arr])
    }

    private func handleTopicsPost(body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonError("Invalid body")
        }

        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/topics.json")

        // Load existing topics
        var topics: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            topics = arr
        }

        switch action {
        case "create":
            let name = json["name"] as? String ?? "Neues Thema"
            let color = json["color"] as? String ?? "#888888"
            let id = UUID().uuidString
            let topic: [String: Any] = [
                "id": id,
                "name": name,
                "color": color,
                "isExpanded": true,
                "projectPath": "",
                "instructions": "",
                "useOwnMemory": false,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]
            topics.append(topic)

        case "update":
            guard let id = json["id"] as? String,
                  let idx = topics.firstIndex(where: { $0["id"] as? String == id }) else {
                return jsonError("Topic not found")
            }
            if let name = json["name"] as? String { topics[idx]["name"] = name }
            if let color = json["color"] as? String { topics[idx]["color"] = color }
            if let expanded = json["isExpanded"] as? Bool { topics[idx]["isExpanded"] = expanded }
            if let instructions = json["instructions"] as? String { topics[idx]["instructions"] = instructions }

        case "delete":
            guard let id = json["id"] as? String else { return jsonError("id required") }
            topics.removeAll { $0["id"] as? String == id }

        case "assign":
            // Assign a session to a topic — notifies desktop via shared file
            // We store session-topic mappings in topics.json under a "sessionMappings" key
            // But the WebGUI stores topicId in localStorage — this is for sync
            addTrace(event: "Topics", detail: "Session \(json["sessionId"] ?? "") → Topic \(json["topicId"] ?? "")")
            return jsonOK(["ok": true])

        default:
            return jsonError("Unknown action: \(action)")
        }

        // Save
        if let data = try? JSONSerialization.data(withJSONObject: topics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        return jsonOK(["ok": true])
    }

    // MARK: - Agent Handler

    private func handleAgent(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var message = json["message"] as? String else {
            return agentError("Ungültige Anfrage — 'message' Feld fehlt")
        }

        // Source-spezifische Anweisungen
        let source = json["source"] as? String ?? ""
        if source == "telegram" {
            message = "[TELEGRAM-NACHRICHT — Antworte mit dem response-Tool. Deine Antwort wird automatisch an Telegram weitergeleitet. Nutze telegram_send NUR für Datei-/Foto-/Audio-Versand, NICHT für Text-Antworten.]\n\n\(message)"
        } else if source == "voice" {
            let maxWords = UserDefaults.standard.integer(forKey: "kobold.voice.maxResponseWords")
            let wordLimit = maxWords > 0 ? maxWords : 50
            message = "[SPRACHMODUS — Echtzeit-Gespräch per Mikrofon. STRIKTE Regeln: 1) MAX \(wordLimit) Wörter. 2) 1-2 kurze Sätze wie in einem natürlichen Gespräch. 3) KEIN Vortrag, KEINE Listen, KEINE Aufzählungen. 4) Sei direkt, natürlich, gesprächig. 5) Bei komplexen Fragen: kurz antworten und nachfragen ob der User mehr Details will.]\n\n\(message)"
        }

        let agentTypeStr = json["agent_type"] as? String ?? "general"
        let type: AgentType
        switch agentTypeStr {
        case "general", "instructor": type = .general
        case "coder":                  type = .coder
        case "researcher", "web":      type = .web
        default:                       type = .general
        }
        let images = json["images"] as? [String] ?? []

        // Extract provider config
        let provider = json["provider"] as? String ?? "ollama"
        let model = json["model"] as? String ?? ""
        let apiKey = json["api_key"] as? String ?? ""
        let temperature = json["temperature"] as? Double ?? 0.7

        // If images provided, handle via vision API directly
        if !images.isEmpty {
            return await handleVision(message: message, images: images)
        }

        // Acquire a worker from the shared pool (same pool as SSE requests)
        let pool = AgentWorkerPool.shared
        let agent = await pool.acquire()
        defer { Task.detached { await pool.release(agent) } }

        // Skip HiTL approval for headless sources (Telegram, voice — no GUI to approve)
        if source == "telegram" || source == "voice" || source == "scheduled" {
            await agent.setSkipApproval(true)
        }

        // Inject conversation history if available
        if let history = json["conversation_history"] as? [[String: String]], !history.isEmpty {
            await agent.injectConversationHistory(history)
        }

        addTrace(event: "Chat", detail: String(message.prefix(80)))

        let providerConfig = LLMProviderConfig(provider: provider, model: model, apiKey: apiKey, temperature: temperature)
        do {
            let result = try await agent.run(userMessage: message, agentType: type, providerConfig: providerConfig)

            // Count actual tool calls from steps
            let callSteps = result.steps.filter { $0.type == .toolCall }
            toolCalls += callSteps.count

            // Log tool calls to trace
            for step in callSteps {
                addTrace(event: "Tool: \(step.toolCallName ?? "unknown")", detail: String(step.content.prefix(60)))
            }

            // Build tool_results array for UI (collapsible bubbles)
            let toolResultsForUI: [[String: Any]] = result.steps
                .filter { $0.type == .toolResult }
                .map { step in
                    [
                        "name": step.toolCallName ?? "tool",
                        "output": step.content,
                        "success": step.toolResultSuccess == true
                    ] as [String: Any]
                }

            // Strip any leaked JSON from the output (ultimate safety net — for Telegram, WebApp, and all sources)
            let output = Self.stripJSONForTelegram(result.finalOutput)

            addTrace(event: "Antwort", detail: String(output.prefix(60)))

            return jsonOK([
                "output": output,
                "steps": result.steps.count,
                "success": result.success,
                "tool_results": toolResultsForUI
            ])
        } catch {
            let msg = error.localizedDescription
            addTrace(event: "Fehler", detail: String(msg.prefix(60)))
            // Return 200 with error in body — client can display the message
            return agentError("Agent-Fehler: \(msg)")
        }
    }

    // MARK: - Agent SSE Stream Handler

    private func handleAgentStream(client: ClientSocket, body: Data?) async {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String else {
            client.write(httpResponse(status: "400 Bad Request", body: "{\"error\":\"Missing message\"}"))
            return
        }

        let agentTypeStr = json["agent_type"] as? String ?? "general"
        let type: AgentType
        switch agentTypeStr {
        case "general", "instructor": type = .general
        case "coder":                  type = .coder
        case "researcher", "web":      type = .web
        default:                       type = .general
        }

        // Extract provider config
        let provider = json["provider"] as? String ?? "ollama"
        let model = json["model"] as? String ?? ""
        let apiKey = json["api_key"] as? String ?? ""
        let temperature = json["temperature"] as? Double ?? 0.7

        // Voice-Modus: Kurze, gesprächige Antworten erzwingen (Latenz-kritisch!)
        let source = json["source"] as? String ?? ""
        var agentMessage = message
        if source == "voice" {
            let maxWords = UserDefaults.standard.integer(forKey: "kobold.voice.maxResponseWords")
            let wordLimit = maxWords > 0 ? maxWords : 50
            agentMessage = "[SPRACHMODUS — Echtzeit-Gespräch per Mikrofon. STRIKTE Regeln: 1) MAX \(wordLimit) Wörter. 2) 1-2 kurze Sätze. 3) KEIN Vortrag, KEINE Listen. 4) Sei direkt und natürlich.]\n\n\(message)"
        }

        // Extract conversation history from payload (sent by RuntimeViewModel)
        // Voice: max 6 Messages (3 Paare) → weniger Kontext = schnellere Verarbeitung
        let conversationHistory: [[String: String]]
        if let history = json["conversation_history"] as? [[String: String]] {
            if source == "voice" && history.count > 6 {
                conversationHistory = Array(history.suffix(6))
            } else {
                conversationHistory = history
            }
        } else {
            conversationHistory = []
        }

        chatRequests += 1
        activeAgentStreams += 1

        // Acquire a worker from the pool — suspends if all workers are busy.
        // Each worker has its own LLMRunner to enable true Ollama parallelism
        // (requires OLLAMA_NUM_PARALLEL ≥ pool size on the Ollama side).
        let pool = AgentWorkerPool.shared
        let poolStatus = await pool.statusDescription
        addTrace(event: "SSE", detail: "Acquiring worker (pool: \(poolStatus))")
        let agent = await pool.acquire()
        // Release worker back to pool when SSE is done (whether success, error, or disconnect)
        // Using a detached task avoids holding the DaemonListener actor during the async release
        defer {
            activeAgentStreams -= 1
            Task.detached { await pool.release(agent) }
        }

        // Send a "waiting" event if the pool was saturated (user sees feedback in UI)
        let waitCount = await pool.waitingRequestCount
        if waitCount > 0 {
            let waitEvent = "event: step\ndata: {\"type\":\"waiting\",\"content\":\"⏳ Warte auf freien Worker (\(waitCount + 1) in Warteschlange)...\",\"tool\":\"pool\"}\n\n"
            _ = client.tryWrite(waitEvent)
        }

        // Skip HiTL approval for headless sources (no GUI to approve)
        if source == "telegram" || source == "voice" || source == "scheduled" {
            await agent.setSkipApproval(true)
        }

        // CRITICAL: Inject conversation history so the agent knows what was discussed
        if !conversationHistory.isEmpty {
            await agent.injectConversationHistory(conversationHistory)
        }

        let modelDisplay = model.isEmpty ? (UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "default") : model
        addTrace(event: "SSE Start", detail: "[\(agentTypeStr)] \(modelDisplay) — \(String(message.prefix(60)))")
        addTrace(event: "Model", detail: "\(provider)/\(modelDisplay) (Kontext: \(conversationHistory.count) Msgs)")

        // Socket-Optionen VOR dem ersten Write setzen (verhindert Nagle-Delay beim Header)
        var yes: Int32 = 1
        setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client.fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Write SSE headers — Connection: close tells URLSession the response ends at EOF
        let sseHeaders = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "X-Accel-Buffering: no\r\n" +
            "X-Content-Type-Options: nosniff\r\n\r\n"
        client.write(sseHeaders)

        // Heartbeat: send immediate event to confirm SSE connection is live
        // URLSession needs at least one data frame to start delivering bytes.lines
        _ = client.tryWrite("event: step\ndata: {\"type\":\"think\",\"content\":\"Verbunden, Agent startet...\",\"tool\":\"\",\"success\":true,\"step\":0}\n\n")

        // Stream steps with provider config
        // Voice: niedrigeres num_predict (256 statt 4096) → Ollama reserviert weniger KV-cache → schnellere Antwort
        let voiceNumPredict: Int? = source == "voice" ? 256 : nil
        let providerConfig = LLMProviderConfig(provider: provider, model: model, apiKey: apiKey, temperature: temperature, numPredict: voiceNumPredict)
        let stream = await agent.runStreaming(userMessage: agentMessage, agentType: type, providerConfig: providerConfig)
        var stepCount = 0
        for await step in stream {
            if step.type == .toolCall {
                toolCalls += 1
                addTrace(event: "Tool: \(step.toolCallName ?? "unknown")", detail: String(step.content.prefix(60)))
            }
            // Strip leaked JSON from finalAnswer content (same safety net as /agent route)
            var cleanedStep = step
            if step.type == .finalAnswer {
                cleanedStep = AgentStep(stepNumber: step.stepNumber, type: .finalAnswer, content: Self.stripJSONForTelegram(step.content), toolCallName: step.toolCallName, toolResultSuccess: step.toolResultSuccess, confidence: step.confidence)
            }
            // Include checkpoint steps in SSE for UI visibility
            // Escape literal newlines in JSON to prevent SSE event injection
            let safeJSON = cleanedStep.toJSON().replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            let eventData = "event: step\ndata: \(safeJSON)\n\n"
            // Detect client disconnect — stop streaming if write fails
            if !client.tryWrite(eventData) {
                addTrace(event: "SSE aborted", detail: "Client disconnected after \(stepCount) steps")
                return
            }
            stepCount += 1
            // CRITICAL: Yield after each step to prevent actor starvation.
            // Without this, rapid SSE steps monopolize the DaemonListener actor
            // and starve /metrics, /health, and other concurrent requests.
            await Task.yield()
        }

        // SSE fertig — wird bereits via addTrace geloggt
        addTrace(event: "SSE Fertig", detail: "\(stepCount) Schritte gestreamt [\(agentTypeStr)/\(modelDisplay)]")

        // End event
        client.write("event: done\ndata: {}\n\n")
    }

    /// Returns a 200 response with the error as assistant output (not HTTP 400).
    /// This ensures the error message reaches the user in the chat UI.
    private func agentError(_ msg: String) -> String {
        errors += 1
        let body = (try? JSONSerialization.data(withJSONObject: [
            "output": "⚠️ \(msg)",
            "success": false,
            "steps": 0
        ], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return httpResponse(status: "200 OK", body: body)
    }

    // MARK: - Vision Handler (images → Ollama multimodal)

    private func handleVision(message: String, images: [String]) async -> String {
        let model = await ModelConfigManager.shared.getModel(for: "general").model
        let payload: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": message,
                "images": images
            ]],
            "stream": false
        ]
        guard let url = URL(string: "http://localhost:11434/api/chat"),
              let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return agentError("Vision-Anfrage konnte nicht erstellt werden")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 120
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = resp["message"] as? [String: Any],
               let content = msg["content"] as? String {
                chatRequests += 1
                return jsonOK(["output": content, "steps": 1, "success": true])
            }
            return agentError("Ollama Vision hat keine Antwort geliefert")
        } catch {
            errors += 1
            return agentError("Vision-Fehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Chat Handler

    private func handleChat(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String else {
            return jsonError("Missing 'message' field")
        }

        let model = await ModelConfigManager.shared.getModel(for: "general").model
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": message]],
            "stream": false
        ]

        guard let url = URL(string: "http://localhost:11434/api/chat"),
              let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return jsonError("Could not build request")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = resp["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return jsonOK(["output": content])
            }
            return jsonError("Could not parse LLM response")
        } catch {
            errors += 1
            return jsonError("LLM error: \(error.localizedDescription)")
        }
    }

    // MARK: - OpenAI-Compatible Proxy (für ElevenLabs Custom LLM → lokales Ollama)

    private func handleOpenAIProxy(client: ClientSocket, body: Data?) async {
        let proxyStart = CFAbsoluteTimeGetCurrent()
        guard let body else {
            print("[OpenAI Proxy] ❌ Kein Body empfangen")
            client.write(httpResponse(status: "400 Bad Request", body: "{\"error\":{\"message\":\"No body\",\"type\":\"invalid_request_error\"}}"))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = json["messages"] as? [[String: Any]] else {
            let bodyStr = String(data: body.prefix(500), encoding: .utf8) ?? "(binary)"
            print("[OpenAI Proxy] ❌ JSON-Parse fehlgeschlagen: \(bodyStr)")
            client.write(httpResponse(status: "400 Bad Request", body: "{\"error\":{\"message\":\"Invalid JSON\",\"type\":\"invalid_request_error\"}}"))
            return
        }

        let isStream = json["stream"] as? Bool ?? false
        let temperature = json["temperature"] as? Double ?? 0.7
        let model = json["model"] as? String ?? UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "llama3"

        let msgCount = messages.count
        let firstRole = (messages.first?["role"] as? String) ?? "?"
        print("[OpenAI Proxy] ✅ Request empfangen: \(msgCount) msgs, model=\(model), stream=\(isStream), firstRole=\(firstRole)")

        // IMMER Kobold System-Prompt injizieren wenn agentLoop verfügbar
        // (nicht nur wenn customLLM toggle gesetzt — der Proxy SOLLTE immer Persönlichkeit haben)
        let customLLMEnabled = true  // Proxy wird nur von ElevenLabs genutzt, immer Persönlichkeit injizieren
        if customLLMEnabled {
            let koboldName = UserDefaults.standard.string(forKey: "kobold.koboldName") ?? "KoboldOS"
            let soul = UserDefaults.standard.string(forKey: "kobold.agent.soul") ?? ""
            let personality = UserDefaults.standard.string(forKey: "kobold.agent.personality")
                ?? UserDefaults.standard.string(forKey: "kobold.personality") ?? ""
            let tone = UserDefaults.standard.string(forKey: "kobold.agent.tone") ?? "freundlich"
            let agentLang = UserDefaults.standard.string(forKey: "kobold.agent.language") ?? "deutsch"
            let userName = UserDefaults.standard.string(forKey: "kobold.userName") ?? ""
            let behaviorRules = UserDefaults.standard.string(forKey: "kobold.agent.behaviorRules") ?? ""
            let maxWords = UserDefaults.standard.integer(forKey: "kobold.voice.maxResponseWords")
            let wordLimit = maxWords > 0 ? maxWords : 50

            // Memory-Kontext laden (Core Memory Blocks)
            var memoryContext = ""
            if let agent = agentLoop {
                let blocks = await agent.coreMemory.allBlocks()
                let memLines = blocks.compactMap { b -> String? in
                    b.value.isEmpty ? nil : "[\(b.label)]: \(b.value)"
                }
                if !memLines.isEmpty {
                    memoryContext = "\n\n## Dein Gedächtnis\n" + memLines.joined(separator: "\n")
                }
                print("[OpenAI Proxy] Memory: \(memLines.count) Blöcke geladen")
            } else {
                print("[OpenAI Proxy] ⚠️ agentLoop ist nil — KEINE Erinnerungen verfügbar!")
            }

            // Integrationen + Ziele laden
            var connectionsContext = ""
            var goalsContext = ""
            if let agent = agentLoop {
                let conn = await agent.buildConnectionsContext()
                if !conn.isEmpty && conn != "Keine externen Dienste verbunden." {
                    connectionsContext = "\n\n## Integrationen\n\(conn)"
                }
                let goals = await agent.buildGoalsSection()
                if !goals.isEmpty {
                    goalsContext = "\n\(goals)"
                }
                print("[OpenAI Proxy] Connections: \(conn.prefix(50))..., Goals: \(!goals.isEmpty)")
            }

            let userGreeting = userName.isEmpty ? "" : "\nDer Nutzer heißt \(userName)."
            let soulLine = soul.isEmpty ? "" : "\nKernidentität: \(soul)"
            let personalityLine = personality.isEmpty ? "" : "\nVerhaltensstil: \(personality)"
            let rulesLine = behaviorRules.isEmpty ? "" : "\n\n## Verhaltensregeln (IMMER befolgen!)\n\(behaviorRules)"

            let systemPrompt = """
            Dein Name ist \(koboldName). Du führst ein Live-TELEFONGESPRÄCH.\(userGreeting)
            Sprache: \(agentLang == "auto" ? "Sprache des Nutzers" : agentLang.capitalized). Tonfall: \(tone).\(soulLine)\(personalityLine)\(rulesLine)

            ## WICHTIG: Telefonregeln (STRIKT einhalten!)
            - MAXIMAL \(wordLimit) Wörter pro Antwort. NIEMALS länger!
            - Nur 1-2 kurze Sätze. Das ist ein TELEFONAT, kein Essay.
            - KEIN Markdown, KEINE Listen, KEINE Code-Blöcke, KEINE Sternchen.
            - Sprich natürlich wie ein Mensch am Telefon. Kurz und direkt.
            - Beantworte Fragen sofort in einem Satz. Nicht ausschmücken.
            - Bei Aufgaben (Termin, Erinnerung, Recherche): kurz bestätigen, fertig.
            - Du erinnerst dich an alles aus deinem Gedächtnis.
            - Wenn das Gespräch beendet werden soll (Verabschiedung, 'tschüss', Aufgabe erledigt), füge am ENDE deiner Antwort [AUFLEGEN] hinzu.\(memoryContext)\(connectionsContext)\(goalsContext)\(Self.activeCallPurposeContext())
            """

            // System-Message am Anfang einfügen (falls nicht schon vorhanden)
            let hasSystem = messages.first.flatMap { $0["role"] as? String } == "system"
            if !hasSystem {
                messages.insert(["role": "system", "content": systemPrompt], at: 0)
            } else {
                // Bestehende System-Message mit Kobold-Kontext ergänzen
                if var existing = messages[0]["content"] as? String {
                    existing = systemPrompt + "\n\n" + existing
                    messages[0]["content"] = existing
                }
            }
        }

        // An Ollama OpenAI-kompatiblen Endpoint weiterleiten
        // max_tokens=150 → Standard OpenAI-Parameter (Ollama versteht beides)
        // options.num_predict=150 → Ollama-nativer Fallback
        // 150 Tokens ≈ 40-60 Wörter Deutsch → verhindert lange Antworten physisch
        let ollamaPayload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": isStream,
            "temperature": temperature,
            "max_tokens": 150,
            "options": ["num_predict": 150]
        ]

        guard let ollamaURL = URL(string: "http://localhost:11434/v1/chat/completions"),
              let ollamaBody = try? JSONSerialization.data(withJSONObject: ollamaPayload) else {
            client.write(httpResponse(status: "500 Internal Server Error", body: "{\"error\":{\"message\":\"Internal error\"}}"))
            return
        }

        var req = URLRequest(url: ollamaURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = ollamaBody
        req.timeoutInterval = 30  // Voice: schnellere Fehler-Erkennung

        let prepTime = (CFAbsoluteTimeGetCurrent() - proxyStart) * 1000.0
        print("[OpenAI Proxy] System-Prompt gebaut in \(Int(prepTime))ms, forwarding an Ollama...")

        if isStream {
            // SSE-Streaming: Proxy Ollama SSE direkt zum Client
            let sseHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            client.write(sseHeaders)

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ttfb = (CFAbsoluteTimeGetCurrent() - proxyStart) * 1000.0
                print("[OpenAI Proxy] Ollama TTFB: \(Int(ttfb))ms, HTTP \(status)")
                guard status == 200 else {
                    client.write("data: {\"error\":\"Ollama HTTP \(status)\"}\n\n")
                    print("[OpenAI Proxy] ❌ Ollama HTTP \(status)")
                    return
                }

                var chunkCount = 0
                for try await line in bytes.lines {
                    client.write(line + "\n")
                    chunkCount += 1
                    if line.contains("[DONE]") { break }
                }
                let totalTime = (CFAbsoluteTimeGetCurrent() - proxyStart) * 1000.0
                print("[OpenAI Proxy] ✅ Stream fertig: \(chunkCount) chunks in \(Int(totalTime))ms")
            } catch {
                client.write("data: {\"error\":\"\(error.localizedDescription)\"}\n\n")
                print("[OpenAI Proxy] ❌ Stream-Fehler: \(error.localizedDescription)")
            }
        } else {
            // Non-Streaming: einfacher Proxy
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let responseBody = String(data: data, encoding: .utf8) ?? "{\"error\":{\"message\":\"Empty response\"}}"
                let totalTime = (CFAbsoluteTimeGetCurrent() - proxyStart) * 1000.0
                print("[OpenAI Proxy] ✅ Non-Stream: HTTP \(status), \(data.count) bytes in \(Int(totalTime))ms")
                client.write("HTTP/1.1 \(status == 200 ? "200 OK" : "\(status) Error")\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(responseBody.utf8.count)\r\n\r\n\(responseBody)")
            } catch {
                let errBody = "{\"error\":{\"message\":\"\(error.localizedDescription)\"}}"
                print("[OpenAI Proxy] ❌ Non-Stream-Fehler: \(error.localizedDescription)")
                client.write(httpResponse(status: "502 Bad Gateway", body: errBody))
            }
        }

        addTrace(event: "OpenAI-Proxy", detail: "model=\(model), stream=\(isStream), msgs=\(messages.count)")
    }

    // MARK: - Models

    private func handleModels() async -> String {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return jsonOK(["models": [], "active": "", "ollama_status": "offline"])
        }
        let names = models.compactMap { $0["name"] as? String }
        let active = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? names.first ?? ""
        return jsonOK(["models": names, "active": active, "ollama_status": "running"])
    }

    // MARK: - Tasks API

    private var tasksFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/tasks.json")
    }

    private func loadTasks() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: tasksFileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    private func saveTasks(_ tasks: [[String: Any]]) {
        let dir = tasksFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys]) {
            try? data.write(to: tasksFileURL)
        }
    }

    private func handleTasksPost(body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonError("Missing 'action'")
        }
        var tasks = loadTasks()
        switch action {
        case "create":
            let id = json["id"] as? String ?? UUID().uuidString.prefix(8).lowercased()
            let task: [String: Any] = [
                "id": id,
                "name": json["name"] as? String ?? "Untitled",
                "prompt": json["prompt"] as? String ?? "",
                "schedule": json["schedule"] as? String ?? "",
                "enabled": json["enabled"] as? Bool ?? true,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]
            tasks.append(task)
            saveTasks(tasks)
            addTrace(event: "Aufgabe", detail: "Erstellt: \(json["name"] as? String ?? id)")
            return jsonOK(["ok": true, "id": id])
        case "update":
            guard let id = json["id"] as? String,
                  let idx = tasks.firstIndex(where: { $0["id"] as? String == id }) else {
                return jsonError("Task not found")
            }
            var t = tasks[idx]
            if let name = json["name"] as? String { t["name"] = name }
            if let prompt = json["prompt"] as? String { t["prompt"] = prompt }
            if let schedule = json["schedule"] as? String { t["schedule"] = schedule }
            if let enabled = json["enabled"] as? Bool { t["enabled"] = enabled }
            tasks[idx] = t
            saveTasks(tasks)
            return jsonOK(["ok": true])
        case "delete":
            guard let id = json["id"] as? String else { return jsonError("Missing 'id'") }
            tasks.removeAll { $0["id"] as? String == id }
            saveTasks(tasks)
            return jsonOK(["ok": true])
        case "run":
            guard let id = json["id"] as? String,
                  let task = tasks.first(where: { $0["id"] as? String == id }) else {
                return jsonError("Task not found")
            }
            let taskName = task["name"] as? String ?? id
            let prompt = task["prompt"] as? String ?? ""
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldScheduledTaskFired"),
                    object: nil,
                    userInfo: ["taskId": id, "taskName": taskName, "prompt": prompt]
                )
            }
            addTrace(event: "TaskScheduler", detail: "Manuell gestartet: \(taskName)")
            return jsonOK(["ok": true])
        default:
            return jsonError("Unknown action '\(action)'")
        }
    }

    // MARK: - Idle Tasks (ProactiveEngine)

    private func loadIdleTasksJSON() -> String {
        let key = "kobold.proactive.idleTasksList"
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return jsonOK(["idle_tasks": []])
        }
        return jsonOK(["idle_tasks": arr])
    }

    private func saveIdleTasksToDefaults(_ tasks: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: tasks, options: []) {
            UserDefaults.standard.set(data, forKey: "kobold.proactive.idleTasksList")
        }
    }

    private func handleIdleTasksPost(body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonError("Missing 'action'")
        }
        let key = "kobold.proactive.idleTasksList"
        var tasks: [[String: Any]] = {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return arr
        }()

        switch action {
        case "create":
            let id = json["id"] as? String ?? UUID().uuidString.prefix(8).lowercased()
            let task: [String: Any] = [
                "id": id,
                "name": json["name"] as? String ?? "Untitled",
                "prompt": json["prompt"] as? String ?? "",
                "enabled": json["enabled"] as? Bool ?? true,
                "priority": json["priority"] as? String ?? "medium",
                "cooldownMinutes": json["cooldownMinutes"] as? Int ?? 30,
                "runCount": 0
            ]
            tasks.append(task)
            saveIdleTasksToDefaults(tasks)
            addTrace(event: "IdleTask", detail: "Erstellt: \(json["name"] as? String ?? id)")
            return jsonOK(["ok": true, "id": id])
        case "update":
            guard let id = json["id"] as? String,
                  let idx = tasks.firstIndex(where: { $0["id"] as? String == id }) else {
                return jsonError("Task not found")
            }
            var t = tasks[idx]
            if let name = json["name"] as? String { t["name"] = name }
            if let prompt = json["prompt"] as? String { t["prompt"] = prompt }
            if let enabled = json["enabled"] as? Bool { t["enabled"] = enabled }
            if let priority = json["priority"] as? String { t["priority"] = priority }
            if let cooldown = json["cooldownMinutes"] as? Int { t["cooldownMinutes"] = cooldown }
            tasks[idx] = t
            saveIdleTasksToDefaults(tasks)
            return jsonOK(["ok": true])
        case "delete":
            guard let id = json["id"] as? String else { return jsonError("Missing 'id'") }
            tasks.removeAll { $0["id"] as? String == id }
            saveIdleTasksToDefaults(tasks)
            return jsonOK(["ok": true])
        default:
            return jsonError("Unknown action '\(action)'")
        }
    }

    // MARK: - Task Scheduler (Cron)

    private var taskSchedulerRunning = false
    private var lastTaskCheckMinute: Int = -1

    /// Starts a background loop that checks every 60s if any scheduled task is due.
    private func startTaskScheduler() {
        guard !taskSchedulerRunning else { return }
        taskSchedulerRunning = true
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard let self else { break }
                await self.checkScheduledTasks()
            }
        }
        addTrace(event: "TaskScheduler", detail: "Started — checking every 60s")
    }

    private func checkScheduledTasks() async {
        let now = Date()
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        // Avoid double-check within the same minute
        guard minute != lastTaskCheckMinute else { return }
        lastTaskCheckMinute = minute

        let tasks = loadTasks()
        for task in tasks {
            guard task["enabled"] as? Bool == true,
                  let schedule = task["schedule"] as? String, !schedule.isEmpty,
                  let prompt = task["prompt"] as? String, !prompt.isEmpty,
                  let taskId = task["id"] as? String else { continue }

            if cronMatches(expression: schedule, date: now) {
                let taskName = task["name"] as? String ?? taskId
                addTrace(event: "TaskScheduler", detail: "Starte: \(taskName)")
                // Notify UI to execute task in dedicated task session
                // Dispatch on main thread — DaemonListener runs on background thread,
                // but SwiftUI .onReceive expects main-thread delivery for immediate processing
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("koboldScheduledTaskFired"),
                        object: nil,
                        userInfo: ["taskId": taskId, "taskName": taskName, "prompt": prompt]
                    )
                }
                // Update last_run timestamp
                var allTasks = loadTasks()
                if let idx = allTasks.firstIndex(where: { $0["id"] as? String == taskId }) {
                    allTasks[idx]["last_run"] = DaemonListener.isoFormatter.string(from: Date())
                    saveTasks(allTasks)
                }
            }
        }
    }

    /// Simple cron matcher: "min hour dom month dow" — supports *, */N, and exact values.
    private func cronMatches(expression: String, date: Date) -> Bool {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return false }
        let cal = Calendar.current
        let fields = [
            cal.component(.minute, from: date),
            cal.component(.hour, from: date),
            cal.component(.day, from: date),
            cal.component(.month, from: date),
            cal.component(.weekday, from: date) - 1 // cron: 0=Sun
        ]
        for (pattern, value) in zip(parts, fields) {
            if !cronFieldMatches(pattern: pattern, value: value) { return false }
        }
        return true
    }

    private func cronFieldMatches(pattern: String, value: Int) -> Bool {
        if pattern == "*" { return true }
        // */N step
        if pattern.hasPrefix("*/"), let step = Int(pattern.dropFirst(2)), step > 0 {
            return value % step == 0
        }
        // Comma-separated values: "1,3,5"
        let values = pattern.split(separator: ",").compactMap { Int($0) }
        if !values.isEmpty { return values.contains(value) }
        // Range: "1-5"
        if pattern.contains("-") {
            let rangeParts = pattern.split(separator: "-").compactMap { Int($0) }
            if rangeParts.count == 2 { return value >= rangeParts[0] && value <= rangeParts[1] }
        }
        return false
    }

    // MARK: - Workflows API (uses shared WorkflowDefinition Codable model)

    private var workflowsFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/workflows.json")
    }

    private func loadWorkflowDefinitions() -> [WorkflowDefinition] {
        guard let data = try? Data(contentsOf: workflowsFileURL),
              let workflows = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) else {
            return []
        }
        return workflows
    }

    private func saveWorkflowDefinitions(_ workflows: [WorkflowDefinition]) {
        let dir = workflowsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(workflows) {
            try? data.write(to: workflowsFileURL)
        }
    }

    private func handleWorkflowsPost(body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonError("Missing 'action'")
        }
        var workflows = loadWorkflowDefinitions()
        switch action {
        case "create":
            let id = json["id"] as? String ?? UUID().uuidString
            let wf = WorkflowDefinition(
                id: id,
                name: json["name"] as? String ?? "Untitled",
                description: json["description"] as? String ?? "",
                steps: json["steps"] as? String ?? "[]",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            workflows.append(wf)
            saveWorkflowDefinitions(workflows)
            addTrace(event: "Workflow", detail: "Erstellt: \(wf.name)")
            return jsonOK(["ok": true, "id": id])
        case "delete":
            guard let id = json["id"] as? String else { return jsonError("Missing 'id'") }
            workflows.removeAll { $0.id == id }
            saveWorkflowDefinitions(workflows)
            return jsonOK(["ok": true])
        default:
            return jsonError("Unknown action '\(action)'")
        }
    }

    // MARK: - A2A Protocol (Google A2A / JSON-RPC 2.0)

    /// In-memory A2A task store (cleaned up after 1h)
    private struct A2ATask {
        let id: String
        let contextId: String
        var state: String  // submitted, working, completed, failed, canceled
        var messages: [[String: Any]]
        var artifacts: [[String: Any]]
        var metadata: [String: Any]
        let createdAt: Date
        var updatedAt: Date
    }
    private var a2aTasks: [String: A2ATask] = [:]

    /// Check a granular A2A permission. Returns true only if explicitly enabled.
    private func a2aPermission(_ resource: String, _ action: String) -> Bool {
        let key = "kobold.a2a.perm.\(resource).\(action)"
        let defaults: [String: Bool] = [
            "kobold.a2a.perm.memory.read": true, "kobold.a2a.perm.memory.write": false,
            "kobold.a2a.perm.tools.read": true, "kobold.a2a.perm.tools.write": true,
            "kobold.a2a.perm.files.read": false, "kobold.a2a.perm.files.write": false,
            "kobold.a2a.perm.shell.read": false, "kobold.a2a.perm.shell.write": false,
            "kobold.a2a.perm.tasks.read": true, "kobold.a2a.perm.tasks.write": false,
            "kobold.a2a.perm.settings.read": false, "kobold.a2a.perm.settings.write": false,
            "kobold.a2a.perm.agent.read": true, "kobold.a2a.perm.agent.write": true,
        ]
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaults[key] ?? false
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// One-time migration from old flat A2A permission keys to granular ones
    private func migrateA2APermissions() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: "kobold.a2a.perm.migrated") == nil else { return }
        if ud.object(forKey: "kobold.a2a.allowMemoryRead") != nil {
            ud.set(ud.bool(forKey: "kobold.a2a.allowMemoryRead"), forKey: "kobold.a2a.perm.memory.read")
        }
        if ud.object(forKey: "kobold.a2a.allowMemoryWrite") != nil {
            ud.set(ud.bool(forKey: "kobold.a2a.allowMemoryWrite"), forKey: "kobold.a2a.perm.memory.write")
        }
        if ud.object(forKey: "kobold.a2a.allowTools") != nil {
            let v = ud.bool(forKey: "kobold.a2a.allowTools")
            ud.set(v, forKey: "kobold.a2a.perm.tools.read")
            ud.set(v, forKey: "kobold.a2a.perm.tools.write")
        }
        if ud.object(forKey: "kobold.a2a.allowFiles") != nil {
            let v = ud.bool(forKey: "kobold.a2a.allowFiles")
            ud.set(v, forKey: "kobold.a2a.perm.files.read")
            ud.set(v, forKey: "kobold.a2a.perm.files.write")
        }
        if ud.object(forKey: "kobold.a2a.allowShell") != nil {
            let v = ud.bool(forKey: "kobold.a2a.allowShell")
            ud.set(v, forKey: "kobold.a2a.perm.shell.read")
            ud.set(v, forKey: "kobold.a2a.perm.shell.write")
        }
        ud.set(true, forKey: "kobold.a2a.perm.migrated")
    }

    /// JSON-RPC 2.0 success response
    private func jsonRpcResult(id: Any?, result: [String: Any]) -> String {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { obj["id"] = id } else { obj["id"] = NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// JSON-RPC 2.0 error response
    private func jsonRpcError(id: Any?, code: Int, message: String) -> String {
        var obj: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message] as [String: Any]]
        if let id = id { obj["id"] = id } else { obj["id"] = NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Remove stale terminal A2A tasks older than 1 hour
    private func cleanupA2ATasks() {
        let staleThreshold = Date().addingTimeInterval(-3600)
        let terminal: Set<String> = ["completed", "failed", "canceled"]
        a2aTasks = a2aTasks.filter { (_, task) in
            if !terminal.contains(task.state) { return true }
            return task.updatedAt > staleThreshold
        }
    }

    // MARK: - A2A JSON-RPC Dispatcher

    private func handleA2ARPC(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rpcVersion = json["jsonrpc"] as? String, rpcVersion == "2.0",
              let method = json["method"] as? String else {
            return jsonRpcError(id: nil, code: -32600, message: "Invalid JSON-RPC 2.0 request")
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        addTrace(event: "A2A", detail: "\(method)")
        cleanupA2ATasks()

        switch method {
        case "message/send":
            guard a2aPermission("agent", "write") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: agent.write")
            }
            return await handleA2AMessageSend(id: id, params: params)

        case "tasks/get":
            guard a2aPermission("tasks", "read") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: tasks.read")
            }
            return handleA2ATaskGet(id: id, params: params)

        case "tasks/list":
            guard a2aPermission("tasks", "read") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: tasks.read")
            }
            return handleA2ATaskList(id: id, params: params)

        case "tasks/cancel":
            guard a2aPermission("tasks", "write") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: tasks.write")
            }
            return handleA2ATaskCancel(id: id, params: params)

        case "memory/read":
            guard a2aPermission("memory", "read") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: memory.read")
            }
            return await handleA2AMemoryRead(id: id, params: params)

        case "memory/write":
            guard a2aPermission("memory", "write") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: memory.write")
            }
            return await handleA2AMemoryWrite(id: id, params: params)

        case "tools/list":
            guard a2aPermission("tools", "read") else {
                return jsonRpcError(id: id, code: -32001, message: "Permission denied: tools.read")
            }
            return await handleA2AToolsList(id: id)

        default:
            return jsonRpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - A2A message/send (blocking)

    private func handleA2AMessageSend(id: Any?, params: [String: Any]) async -> String {
        guard let msgObj = params["message"] as? [String: Any],
              let parts = msgObj["parts"] as? [[String: Any]] else {
            return jsonRpcError(id: id, code: -32602, message: "Invalid params: message.parts required")
        }

        let textParts = parts.compactMap { $0["text"] as? String }
        let userMessage = textParts.joined(separator: "\n")
        guard !userMessage.isEmpty else {
            return jsonRpcError(id: id, code: -32602, message: "No text content in message parts")
        }

        let taskId = params["taskId"] as? String ?? UUID().uuidString
        let contextId = params["contextId"] as? String ?? UUID().uuidString

        a2aTasks[taskId] = A2ATask(
            id: taskId, contextId: contextId, state: "working",
            messages: [msgObj], artifacts: [], metadata: params["metadata"] as? [String: Any] ?? [:],
            createdAt: Date(), updatedAt: Date()
        )

        // Notify UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("koboldA2AClientConnected"), object: nil,
                userInfo: ["id": taskId, "name": "A2A Agent", "url": contextId]
            )
        }

        let pool = AgentWorkerPool.shared
        let agent = await pool.acquire()
        defer { Task.detached { await pool.release(agent) } }

        await agent.setSkipApproval(true)

        let agentMessage = "[A2A-REMOTE-ANFRAGE — Ein externer Agent sendet dir eine Aufgabe. Bearbeite sie und antworte mit dem response-Tool.]\n\n\(userMessage)"

        addTrace(event: "A2A Send", detail: String(userMessage.prefix(80)))

        do {
            let result = try await agent.run(userMessage: agentMessage, agentType: .general)
            let cleanOutput = Self.stripJSONForTelegram(result.finalOutput)

            let artifact: [String: Any] = [
                "id": UUID().uuidString,
                "parts": [["text": cleanOutput]],
                "metadata": ["steps": result.steps.count, "success": result.success] as [String: Any]
            ]
            a2aTasks[taskId]?.state = result.success ? "completed" : "failed"
            a2aTasks[taskId]?.artifacts.append(artifact)
            a2aTasks[taskId]?.updatedAt = Date()
            a2aTasks[taskId]?.messages.append([
                "role": "agent",
                "parts": [["text": cleanOutput]]
            ])

            return jsonRpcResult(id: id, result: buildA2ATaskJSON(taskId))
        } catch {
            a2aTasks[taskId]?.state = "failed"
            a2aTasks[taskId]?.updatedAt = Date()
            return jsonRpcError(id: id, code: -32000, message: "Agent error: \(error.localizedDescription)")
        }
    }

    // MARK: - A2A message/sendStream (SSE)

    private func handleA2AStream(client: ClientSocket, body: Data?, json: [String: Any]) async {
        let params = json["params"] as? [String: Any] ?? [:]

        guard a2aPermission("agent", "write") else {
            client.write(httpResponse(status: "403 Forbidden",
                body: "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Permission denied: agent.write\"}}"))
            return
        }

        guard let msgObj = params["message"] as? [String: Any],
              let parts = msgObj["parts"] as? [[String: Any]] else {
            client.write(httpResponse(status: "400 Bad Request",
                body: "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params\"}}"))
            return
        }

        let textParts = parts.compactMap { $0["text"] as? String }
        let userMessage = textParts.joined(separator: "\n")
        guard !userMessage.isEmpty else {
            client.write(httpResponse(status: "400 Bad Request",
                body: "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"No text\"}}"))
            return
        }

        let taskId = params["taskId"] as? String ?? UUID().uuidString
        let contextId = params["contextId"] as? String ?? UUID().uuidString

        a2aTasks[taskId] = A2ATask(
            id: taskId, contextId: contextId, state: "working",
            messages: [msgObj], artifacts: [], metadata: [:],
            createdAt: Date(), updatedAt: Date()
        )
        activeAgentStreams += 1

        let pool = AgentWorkerPool.shared
        let agent = await pool.acquire()
        defer {
            activeAgentStreams -= 1
            Task.detached { await pool.release(agent) }
        }
        await agent.setSkipApproval(true)

        // Socket options for SSE
        var yes: Int32 = 1
        setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client.fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

        let sseHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n"
        client.write(sseHeaders)
        _ = client.tryWrite("event: status\ndata: {\"taskId\":\"\(taskId)\",\"state\":\"working\"}\n\n")

        let agentMessage = "[A2A-REMOTE-ANFRAGE]\n\n\(userMessage)"
        let stream = await agent.runStreaming(userMessage: agentMessage, agentType: .general)
        var finalOutput = ""
        var stepCount = 0

        for await step in stream {
            stepCount += 1
            switch step.type {
            case .think, .toolCall, .toolResult:
                let stepType = step.type == .think ? "thinking" : (step.type == .toolCall ? "tool:\(step.toolCallName ?? "")" : "result")
                let evt: [String: Any] = [
                    "taskId": taskId, "type": stepType,
                    "content": String(step.content.prefix(2000))
                ]
                if let d = try? JSONSerialization.data(withJSONObject: evt),
                   let s = String(data: d, encoding: .utf8) {
                    let safe = s.replacingOccurrences(of: "\n", with: "\\n")
                    if !client.tryWrite("event: message\ndata: \(safe)\n\n") { return }
                }
            case .finalAnswer:
                finalOutput += step.content
            case .error:
                let evt: [String: Any] = ["taskId": taskId, "type": "error", "content": step.content]
                if let d = try? JSONSerialization.data(withJSONObject: evt),
                   let s = String(data: d, encoding: .utf8) {
                    _ = client.tryWrite("event: message\ndata: \(s.replacingOccurrences(of: "\n", with: "\\n"))\n\n")
                }
            default: break
            }
            await Task.yield()
        }

        let cleanOutput = Self.stripJSONForTelegram(finalOutput)
        let artifact: [String: Any] = [
            "taskId": taskId,
            "artifact": ["id": UUID().uuidString, "parts": [["text": cleanOutput]]] as [String: Any]
        ]
        if let d = try? JSONSerialization.data(withJSONObject: artifact),
           let s = String(data: d, encoding: .utf8) {
            _ = client.tryWrite("event: artifact\ndata: \(s.replacingOccurrences(of: "\n", with: "\\n"))\n\n")
        }

        a2aTasks[taskId]?.state = "completed"
        a2aTasks[taskId]?.updatedAt = Date()
        a2aTasks[taskId]?.artifacts.append(["id": UUID().uuidString, "parts": [["text": cleanOutput]]])
        _ = client.tryWrite("event: status\ndata: {\"taskId\":\"\(taskId)\",\"state\":\"completed\"}\n\n")
        _ = client.tryWrite("event: done\ndata: {}\n\n")

        addTrace(event: "A2A Stream", detail: "Completed: \(stepCount) steps")
    }

    // MARK: - A2A Task Helpers

    private func buildA2ATaskJSON(_ taskId: String) -> [String: Any] {
        guard let task = a2aTasks[taskId] else { return ["error": "Task not found"] }
        let fmt = ISO8601DateFormatter()
        return [
            "id": task.id, "contextId": task.contextId,
            "status": ["state": task.state],
            "messages": task.messages, "artifacts": task.artifacts,
            "metadata": task.metadata,
            "createdAt": fmt.string(from: task.createdAt),
            "updatedAt": fmt.string(from: task.updatedAt)
        ]
    }

    private func handleA2ATaskGet(id: Any?, params: [String: Any]) -> String {
        guard let taskId = params["taskId"] as? String else {
            return jsonRpcError(id: id, code: -32602, message: "Missing taskId")
        }
        guard a2aTasks[taskId] != nil else {
            return jsonRpcError(id: id, code: -32002, message: "Task not found: \(taskId)")
        }
        return jsonRpcResult(id: id, result: buildA2ATaskJSON(taskId))
    }

    private func handleA2ATaskList(id: Any?, params: [String: Any]) -> String {
        let contextId = params["contextId"] as? String
        let tasks: [[String: Any]]
        if let ctx = contextId {
            tasks = a2aTasks.values.filter { $0.contextId == ctx }.map { buildA2ATaskJSON($0.id) }
        } else {
            tasks = a2aTasks.values.map { buildA2ATaskJSON($0.id) }
        }
        return jsonRpcResult(id: id, result: ["tasks": tasks])
    }

    private func handleA2ATaskCancel(id: Any?, params: [String: Any]) -> String {
        guard let taskId = params["taskId"] as? String else {
            return jsonRpcError(id: id, code: -32602, message: "Missing taskId")
        }
        guard a2aTasks[taskId] != nil else {
            return jsonRpcError(id: id, code: -32002, message: "Task not found")
        }
        a2aTasks[taskId]?.state = "canceled"
        a2aTasks[taskId]?.updatedAt = Date()
        return jsonRpcResult(id: id, result: buildA2ATaskJSON(taskId))
    }

    // MARK: - A2A Resource Handlers

    private func handleA2AMemoryRead(id: Any?, params: [String: Any]) async -> String {
        guard let agent = agentLoop else {
            return jsonRpcError(id: id, code: -32000, message: "Agent not available")
        }
        let blocks = await agent.coreMemory.allBlocks()
        let arr = blocks.map { ["label": $0.label, "content": $0.value, "limit": $0.limit] as [String: Any] }
        return jsonRpcResult(id: id, result: ["blocks": arr])
    }

    private func handleA2AMemoryWrite(id: Any?, params: [String: Any]) async -> String {
        guard let agent = agentLoop else {
            return jsonRpcError(id: id, code: -32000, message: "Agent not available")
        }
        guard let label = params["label"] as? String else {
            return jsonRpcError(id: id, code: -32602, message: "Missing 'label'")
        }
        if let content = params["content"] as? String {
            let limit = params["limit"] as? Int ?? 2000
            await agent.coreMemory.upsert(MemoryBlock(label: label, value: content, limit: limit))
            return jsonRpcResult(id: id, result: ["ok": true])
        }
        if let del = params["delete"] as? Bool, del {
            try? await agent.coreMemory.clear(label: label)
            return jsonRpcResult(id: id, result: ["ok": true])
        }
        return jsonRpcError(id: id, code: -32602, message: "Provide 'content' or 'delete: true'")
    }

    private func handleA2AToolsList(id: Any?) async -> String {
        guard let agent = agentLoop else {
            return jsonRpcError(id: id, code: -32000, message: "Agent not available")
        }
        let tools = await agent.listToolNames()
        return jsonRpcResult(id: id, result: ["tools": tools])
    }

    // MARK: - A2A Agent Card

    private func buildAgentCard() -> [String: Any] {
        let ud = UserDefaults.standard
        let koboldName = ud.string(forKey: "kobold.koboldName") ?? "KoboldOS"

        // Build permissions summary
        var permissions: [String: Any] = [:]
        for resource in ["memory", "tools", "files", "shell", "tasks", "settings", "agent"] {
            permissions[resource] = [
                "read": a2aPermission(resource, "read"),
                "write": a2aPermission(resource, "write")
            ]
        }

        return [
            "name": koboldName,
            "description": "Native macOS AI Agent Runtime — local-first, privacy-focused",
            "version": KoboldVersion.current,
            "url": "http://localhost:\(port)/a2a",
            "provider": ["organization": "KoboldOS"],
            "capabilities": [
                "streaming": true,
                "pushNotifications": false
            ] as [String: Any],
            "defaultInputModes": ["text/plain"],
            "defaultOutputModes": ["text/plain"],
            "skills": [
                ["id": "general-chat", "name": "General Assistant", "description": "General-purpose AI assistant with tool access", "tags": ["chat"], "inputModes": ["text/plain"], "outputModes": ["text/plain"]],
                ["id": "code-assistant", "name": "Code Assistant", "description": "Programming and code generation", "tags": ["code"], "inputModes": ["text/plain"], "outputModes": ["text/plain"]],
                ["id": "web-research", "name": "Web Researcher", "description": "Web browsing and information gathering", "tags": ["web"], "inputModes": ["text/plain"], "outputModes": ["text/plain"]]
            ] as [[String: Any]],
            "securitySchemes": ["bearerAuth": ["type": "http", "scheme": "bearer"]],
            "security": [["bearerAuth": [] as [String]]],
            "x-kobold": [
                "a2aEnabled": ud.bool(forKey: "kobold.a2a.enabled"),
                "permissions": permissions,
                "agentTypes": ["general", "coder", "web"],
                "subAgents": true, "memory": true, "vision": true,
                "endpoints": ["a2a": "/a2a", "agentCard": "/.well-known/agent.json", "health": "/health"]
            ] as [String: Any]
        ] as [String: Any]
    }

    // MARK: - Checkpoint Handlers

    private func handleCheckpointsList() async -> String {
        let cps = await CheckpointStore.shared.list()
        let arr: [[String: Any]] = cps.map { cp in
            [
                "id": cp.id,
                "agentType": cp.agentType,
                "stepCount": cp.stepCount,
                "status": cp.status.rawValue,
                "userMessage": cp.userMessage,
                "createdAt": ISO8601DateFormatter().string(from: cp.createdAt)
            ]
        }
        return jsonOK(["checkpoints": arr])
    }

    private func handleCheckpointAction(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonError("Invalid JSON")
        }
        if let action = json["action"] as? String, action == "delete", let id = json["id"] as? String {
            await CheckpointStore.shared.delete(id)
            return jsonOK(["ok": true])
        }
        return jsonError("Unknown action")
    }

    private func handleCheckpointDelete(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["id"] as? String else {
            return jsonError("Missing 'id'")
        }
        await CheckpointStore.shared.delete(id)
        return jsonOK(["ok": true])
    }

    private func handleCheckpointResume(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["id"] as? String else {
            return jsonError("Missing 'id'")
        }
        guard let cp = await CheckpointStore.shared.load(id) else {
            return jsonError("Checkpoint not found")
        }
        let agent = AgentLoop()

        // Resume synchronously and collect results
        var steps: [[String: Any]] = []
        let stream = await agent.resume(checkpoint: cp)
        for await step in stream {
            steps.append([
                "step": step.stepNumber,
                "type": step.type.rawValue,
                "content": step.content
            ])
        }
        return jsonOK(["ok": true, "steps": steps])
    }

    // MARK: - Memory Version Handlers

    private func handleMemoryVersions() async -> String {
        let versions = await MemoryVersionStore.shared.log(limit: 50)
        let arr: [[String: Any]] = versions.map { v in
            [
                "id": v.id,
                "timestamp": ISO8601DateFormatter().string(from: v.timestamp),
                "message": v.message,
                "parentId": v.parentId ?? ""
            ]
        }
        return jsonOK(["versions": arr])
    }

    private func handleMemoryDiff(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let from = json["from"] as? String,
              let to = json["to"] as? String else {
            return jsonError("Missing 'from' and 'to'")
        }
        let diffs = await MemoryVersionStore.shared.diff(from: from, to: to)
        let arr: [[String: Any]] = diffs.map { d in
            [
                "label": d.label,
                "change": d.change.rawValue,
                "old": d.oldValue,
                "new": d.newValue
            ]
        }
        return jsonOK(["diffs": arr])
    }

    private func handleMemoryRollback(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["id"] as? String else {
            return jsonError("Missing 'id'")
        }
        guard let blocks = await MemoryVersionStore.shared.rollback(to: id) else {
            return jsonError("Version not found")
        }
        if let agent = agentLoop {
            for (label, content) in blocks {
                await agent.coreMemory.upsert(MemoryBlock(label: label, value: content))
            }
        }
        return jsonOK(["ok": true, "restoredBlocks": blocks.count])
    }

    // MARK: - Tagged Memory Entries Handlers

    private func handleMemoryEntries(method: String, body: Data?) async -> String {
        if method == "POST", let body {
            // Add new entry
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = json["text"] as? String, !text.isEmpty else {
                return jsonError("Missing 'text'")
            }
            let type = json["type"] as? String ?? "kurzzeit"
            let tagsRaw = json["tags"] as? [String] ?? []
            let valence = (json["valence"] as? NSNumber)?.floatValue ?? 0.0
            let arousal = (json["arousal"] as? NSNumber)?.floatValue ?? 0.5
            let linkedEntryId = json["linked_id"] as? String
            let source = json["source"] as? String
            do {
                let entry = try await taggedMemoryStore.add(
                    text: text, memoryType: type, tags: tagsRaw,
                    valence: valence, arousal: arousal,
                    linkedEntryId: linkedEntryId, source: source
                )
                return jsonOK(["ok": true, "id": entry.id])
            } catch {
                return jsonError("Failed to save: \(error.localizedDescription)")
            }
        }

        if method == "PATCH", let body {
            // Update existing entry
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = json["id"] as? String else {
                return jsonError("Missing 'id'")
            }
            let text     = json["text"] as? String
            let type     = json["type"] as? String
            let tagsRaw  = json["tags"] as? [String]
            if let updated = try? await taggedMemoryStore.update(id: id, text: text, memoryType: type, tags: tagsRaw) {
                return jsonOK(["ok": true, "id": updated.id])
            }
            return jsonError("Entry not found: \(id)")
        }

        if method == "DELETE", let body {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = json["id"] as? String else {
                return jsonError("Missing 'id'")
            }
            let deleted = try? await taggedMemoryStore.delete(id: id)
            return jsonOK(["ok": deleted ?? false])
        }

        // GET — list all entries
        let entries = await taggedMemoryStore.allEntries()
        let fmt = ISO8601DateFormatter()
        let arr: [[String: Any]] = entries.map { e in
            var dict: [String: Any] = [
                "id": e.id,
                "text": e.text,
                "type": e.memoryType,
                "tags": e.tags,
                "timestamp": fmt.string(from: e.timestamp),
                "valence": e.valence,
                "arousal": e.arousal
            ]
            if let linked = e.linkedEntryId { dict["linked_id"] = linked }
            if let source = e.source { dict["source"] = source }
            return dict
        }
        let stats = await taggedMemoryStore.stats()
        return jsonOK(["entries": arr, "total": stats.total, "byType": stats.byType, "tagCount": stats.tagCount])
    }

    private func handleMemoryEntriesSearch(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonError("Invalid body")
        }
        let query = json["query"] as? String ?? ""
        let type = json["type"] as? String
        let tags = json["tags"] as? [String]
        let limit = json["limit"] as? Int ?? 10

        do {
            let results = try await taggedMemoryStore.smartSearch(query: query, type: type, tags: tags, limit: limit)
            let fmt = ISO8601DateFormatter()
            let arr: [[String: Any]] = results.map { e in
                [
                    "id": e.id,
                    "text": e.text,
                    "type": e.memoryType,
                    "tags": e.tags,
                    "timestamp": fmt.string(from: e.timestamp)
                ]
            }
            return jsonOK(["results": arr, "count": results.count])
        } catch {
            return jsonError("Search failed: \(error.localizedDescription)")
        }
    }

    private func handleMemoryEntryTags() async -> String {
        let tags = await taggedMemoryStore.allTags()
        return jsonOK(["tags": tags])
    }

    // MARK: - HTTP Helpers

    /// Static HTTP parser — callable off-actor (no actor isolation required)
    static func parseHTTPRequestStatic(_ raw: String) -> (method: String, path: String, headers: [String: String], body: Data?) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return ("GET", "/", [:], nil) }
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        // Strip query string from path
        let rawPath = parts.count > 1 ? parts[1] : "/"
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            if let colonRange = line.range(of: ":") {
                let key = String(line[line.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Find body after blank line
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            // Trim any trailing null bytes that might come from the buffer
            let trimmed = bodyStr.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            let body = trimmed.isEmpty ? nil : trimmed.data(using: .utf8)
            return (method, path, headers, body)
        }
        return (method, path, headers, nil)
    }

    /// Ultimate safety net: If output from agent still contains raw JSON tool call syntax,
    /// extract the user-facing text via REGEX (works even with malformed JSON).
    /// Telegram users should NEVER see raw JSON.
    static func stripJSONForTelegram(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Not JSON-like → pass through immediately
        guard trimmed.hasPrefix("{") || trimmed.contains("\"tool_name\"") || trimmed.contains("\"toolname\"") else {
            return text
        }

        // Strategy 1: Valid JSON → deep extract
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let extracted = ToolCallParser.deepExtractText(json) {
            return extracted
        }

        // Strategy 2: Regex — extract "text" value from tool_args even in BROKEN JSON
        // Find "text" : "..." with proper escape handling (handles \" inside the string)
        if let extracted = regexExtractText(from: trimmed) {
            return extracted
        }

        // Strategy 3: Balanced-brace scan for tool_args sub-object, then parse just that
        if let argsText = extractToolArgsText(from: trimmed) {
            return argsText
        }

        // Not a tool-call JSON (just happens to start with {) → return as-is
        return text
    }

    /// Extracts "text" value from JSON using regex (tolerates malformed outer JSON)
    private static func regexExtractText(from text: String) -> String? {
        // Pattern: "text" : "captured content with escaped quotes"
        // Uses lazy match to find the FIRST "text" field value
        let pattern = #""text"\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[range])
        // Unescape JSON string escapes
        let unescaped = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
        guard !unescaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return unescaped
    }

    /// Extracts "text" from tool_args sub-object using balanced brace scanning
    private static func extractToolArgsText(from text: String) -> String? {
        // Find "tool_args": { or "toolargs": {
        let pattern = #""(?:tool_args|toolargs)"\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let matchRange = Range(match.range, in: text),
              let braceStart = text[matchRange].lastIndex(of: "{") else { return nil }

        // Balanced brace scan (string-aware)
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
                        // Try to parse the sub-object (much more likely to be valid)
                        if let data = argsJSON.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let t = json["text"] as? String, !t.isEmpty {
                            return t
                        }
                        // Regex fallback on the sub-object
                        return regexExtractText(from: argsJSON)
                    }
                }
            }
            pos = text.index(after: pos)
        }
        return nil
    }

    // MARK: - Settings API

    /// Whitelist aller Keys die über die WebGUI gelesen/geschrieben werden dürfen.
    private static let settingsWhitelist: Set<String> = [
        // Permissions
        "kobold.autonomyLevel",
        "kobold.perm.shell", "kobold.perm.fileWrite", "kobold.perm.network",
        "kobold.perm.confirmAdmin", "kobold.perm.playwright", "kobold.perm.screenControl",
        "kobold.perm.selfCheck", "kobold.perm.createFiles", "kobold.perm.deleteFiles",
        "kobold.perm.installPkgs", "kobold.perm.modifyMemory", "kobold.perm.notifications",
        "kobold.perm.calendar", "kobold.perm.contacts", "kobold.perm.mail",
        "kobold.perm.secrets", "kobold.perm.systemKeychain", "kobold.perm.settings",
        "kobold.shell.safeTier", "kobold.shell.normalTier", "kobold.shell.powerTier",
        "kobold.shell.customBlacklist", "kobold.shell.customAllowlist", "kobold.shell.timeout",
        "kobold.permission.virtualMouse",
        // Agent
        "kobold.ollamaModel",
        "kobold.agent.generalSteps", "kobold.agent.coderSteps", "kobold.agent.webSteps",
        "kobold.subagent.timeout", "kobold.subagent.maxConcurrent",
        "kobold.workerPool.size",
        // Personality
        "kobold.agent.tone", "kobold.agent.language", "kobold.agent.verbosity",
        "kobold.agent.soul", "kobold.agent.personality",
        "kobold.agent.behaviorRules", "kobold.agent.memoryRules", "kobold.agent.memoryPolicy",
        // Memory & Context
        "kobold.context.windowSize", "kobold.context.autoCompress", "kobold.context.threshold",
        "kobold.embedding.model",
        "kobold.memory.recallEnabled", "kobold.memory.recallInterval",
        "kobold.memory.maxSearch", "kobold.memory.maxResults",
        "kobold.memory.similarityThreshold", "kobold.memory.memorizeEnabled",
        "kobold.memory.consolidation", "kobold.memory.autoFragments", "kobold.memory.autoSolutions",
        "kobold.memory.personaLimit", "kobold.memory.humanLimit", "kobold.memory.knowledgeLimit",
        // Notifications
        "kobold.sounds.enabled", "kobold.sounds.volume",
        "kobold.notify.chatStepThreshold", "kobold.notify.taskAlways",
        "kobold.notify.workflowAlways", "kobold.notify.sound",
        "kobold.notify.systemNotifications", "kobold.notify.channel",
        // TTS / STT
        "kobold.tts.voice", "kobold.tts.rate", "kobold.tts.volume",
        "kobold.tts.autoSpeak", "kobold.tts.stripPunctuation",
        "kobold.stt.autoTranscribe", "kobold.stt.model", "kobold.stt.language",
        // ElevenLabs
        "kobold.elevenlabs.enabled", "kobold.elevenlabs.voiceId", "kobold.elevenlabs.model",
        "kobold.elevenlabs.speed", "kobold.elevenlabs.stability", "kobold.elevenlabs.similarity",
        // Recovery & Security
        "kobold.log.level", "kobold.log.verbose",
        "kobold.recovery.autoRestart", "kobold.recovery.sessionRecovery",
        "kobold.recovery.maxRetries", "kobold.recovery.healthInterval",
        "kobold.security.sandboxTools", "kobold.security.networkRestrict",
        "kobold.security.confirmDangerous", "kobold.security.confirmThreshold",
        "kobold.dev.showRawPrompts",
        "kobold.memory.autosave",
        "kobold.a2a.trustedAgents",
        // Privacy & Data
        "kobold.data.persistAfterDelete", "kobold.defaultWorkDir",
        // Display & General
        "kobold.showAdvancedStats", "kobold.autoCheckUpdates",
        "kobold.koboldName", "kobold.userName", "kobold.language",
        "kobold.chat.fontSize", "kobold.showAgentSteps",
        // Profile
        "kobold.profile.name", "kobold.profile.email", "kobold.profile.avatar",
        // Proactive
        "kobold.proactive.enabled", "kobold.proactive.interval",
        "kobold.proactive.morningBriefing", "kobold.proactive.eveningSummary",
        "kobold.proactive.errorAlerts", "kobold.proactive.systemHealth",
        "kobold.proactive.idleTasks",
        "kobold.proactive.heartbeat.enabled", "kobold.proactive.heartbeat.intervalSec",
        "kobold.proactive.heartbeat.showInDashboard", "kobold.proactive.heartbeat.logRetention",
        "kobold.proactive.heartbeat.notify",
        "kobold.proactive.idle.minIdleMinutes", "kobold.proactive.idle.maxPerHour",
        "kobold.proactive.idle.allowShell", "kobold.proactive.idle.allowNetwork",
        "kobold.proactive.idle.allowFileWrite", "kobold.proactive.idle.onlyHighPriority",
        "kobold.proactive.idle.categories",
        "kobold.proactive.idle.quietHoursStart", "kobold.proactive.idle.quietHoursEnd",
        "kobold.proactive.idle.quietHoursEnabled",
        "kobold.proactive.idle.notifyOnExecution", "kobold.proactive.idle.pauseOnUserActivity",
        "kobold.proactive.idle.telegramMinPriority",
        // WebApp (read-only for most, writable for port/autostart)
        "kobold.webapp.enabled", "kobold.webapp.autostart", "kobold.webapp.port",
        // A2A
        "kobold.a2a.enabled", "kobold.a2a.port",
        "kobold.a2a.perm.memory.read", "kobold.a2a.perm.memory.write",
        "kobold.a2a.perm.tools.read", "kobold.a2a.perm.tools.write",
        "kobold.a2a.perm.files.read", "kobold.a2a.perm.files.write",
        "kobold.a2a.perm.shell.read", "kobold.a2a.perm.shell.write",
        "kobold.a2a.perm.tasks.read", "kobold.a2a.perm.tasks.write",
        "kobold.a2a.perm.settings.read", "kobold.a2a.perm.settings.write",
        "kobold.a2a.perm.agent.read", "kobold.a2a.perm.agent.write",
        // Skills
        "kobold.skills.enabled",
        // Cloudflare (non-secret settings)
        "kobold.cloudflare.email", "kobold.cloudflare.accountId", "kobold.cloudflare.zoneId",
        "kobold.cloudflare.tunnelId", "kobold.cloudflare.tunnelUrl", "kobold.cloudflare.domain",
    ]

    /// Keys die NIEMALS über die API geschrieben werden dürfen (Secrets, Tokens, Passwörter).
    private static let settingsBlacklist: Set<String> = [
        "kobold.authToken", "kobold.apiKey",
        "kobold.webapp.username", "kobold.webapp.password",
        "kobold.telegram.token",
        "kobold.github.clientSecret", "kobold.microsoft.clientSecret",
        "kobold.google.clientSecret", "kobold.google.accessToken", "kobold.google.refreshToken",
        "kobold.slack.clientSecret", "kobold.notion.clientSecret",
        "kobold.whatsapp.clientSecret",
        "kobold.soundcloud.accessToken", "kobold.soundcloud.refreshToken",
        "kobold.email.password", "kobold.twilio.authToken",
        "kobold.uber.clientSecret", "kobold.uber.accessToken",
        "kobold.caldav.password", "kobold.mqtt.password",
        "kobold.suno.apiKey", "kobold.huggingface.apiToken",
        "kobold.a2a.token",
        "kobold.elevenlabs.apiKey",
        "kobold.cloudflare.apiKey", "kobold.cloudflare.tunnelToken",
    ]

    private func handleSettings(method: String, body: Data?) -> String {
        let ud = UserDefaults.standard

        if method == "POST", let body {
            // POST: Einzelnen Key setzen — { "key": "...", "value": ... }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let key = json["key"] as? String else {
                return jsonError("Invalid JSON — expected {key, value}")
            }
            guard Self.settingsWhitelist.contains(key) else {
                return jsonError("Key not allowed: \(key)")
            }
            guard !Self.settingsBlacklist.contains(key) else {
                return jsonError("Key is protected: \(key)")
            }
            let value = json["value"] as Any
            // Typ-aware speichern
            if let b = value as? Bool { ud.set(b, forKey: key) }
            else if let i = value as? Int { ud.set(i, forKey: key) }
            else if let d = value as? Double { ud.set(d, forKey: key) }
            else if let s = value as? String { ud.set(s, forKey: key) }
            else { ud.set(value, forKey: key) }

            addTrace(event: "Setting", detail: "\(key) geändert via WebGUI")
            return jsonOK(["ok": true, "key": key])
        }

        // GET: Alle whitelisted Settings zurückgeben
        var result: [String: Any] = [:]
        for key in Self.settingsWhitelist {
            let val = ud.object(forKey: key)
            if let v = val { result[key] = v }
        }
        // Port als Info mitsenden (readonly)
        result["kobold.port"] = ud.integer(forKey: "kobold.port")
        return jsonOK(result)
    }

    // MARK: - ElevenLabs TTS Proxy

    // MARK: - TwiML Helpers

    private func twimlError(_ message: String) -> String {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Say language=\"de-DE\">\(message)</Say></Response>"
        return twimlResponse(xml)
    }

    private func twimlOK(_ message: String) -> String {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Message>\(message)</Message></Response>"
        return twimlResponse(xml)
    }

    /// Wickelt TwiML-XML in eine korrekte HTTP-Response mit Content-Type: text/xml
    private func twimlResponse(_ xml: String) -> String {
        let bodyData = xml.data(using: .utf8) ?? Data()
        return "HTTP/1.1 200 OK\r\n" +
               "Content-Type: text/xml\r\n" +
               "Content-Length: \(bodyData.count)\r\n" +
               "Connection: close\r\n\r\n" +
               xml
    }

    /// Parst URL-encoded Form-Body (Twilio sendet application/x-www-form-urlencoded)
    private func parseFormBody(_ data: Data) -> [String: String] {
        guard let str = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in str.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                let key = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts[1].removingPercentEncoding ?? parts[1]
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Twilio SMS Webhook

    private func handleTwilioSmsWebhook(body: Data) async -> String {
        let params = parseFormBody(body)
        let from = params["From"] ?? ""
        let smsBody = params["Body"] ?? ""
        let messageSid = params["MessageSid"] ?? ""

        guard !from.isEmpty, !smsBody.isEmpty else {
            return twimlError("Ungültige Anfrage")
        }

        addTrace(event: "Twilio SMS", detail: "Von: \(from), SID: \(messageSid)")

        // Whitelist prüfen
        let whitelistStr = UserDefaults.standard.string(forKey: "kobold.twilio.whitelist") ?? ""
        let whitelist = whitelistStr.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !whitelist.isEmpty && !whitelist.contains(from) {
            addTrace(event: "Twilio SMS", detail: "Nummer \(from) nicht in Whitelist — ignoriert (keine Antwort-SMS)")
            // Keine Antwort senden (kostet!), nur App-Notification
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldTwilioBlocked"),
                    object: nil,
                    userInfo: ["from": from, "body": smsBody]
                )
            }
            // Leere TwiML-Response = keine SMS-Antwort
            return twimlResponse("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response></Response>")
        }

        // Safety-Prompt wrappen und an Agent senden
        let safetyPrompt = VoiceCallSafetyFilter.externalContactPrompt(purpose: "SMS-Konversation", source: "twilio_sms")
        let wrappedMessage = "\(safetyPrompt)\n\nEingehende SMS von \(from):\n\(smsBody)"

        // Agent-Antwort generieren (synchron, nicht SSE)
        guard let agent = agentLoop else {
            return twimlError("Agent nicht verfügbar.")
        }
        let response = await agent.run(prompt: wrappedMessage)

        // Safety-Filter auf Antwort anwenden
        let safeResponse = VoiceCallSafetyFilter.sanitize(response)
        let truncated = safeResponse.count > 1500 ? String(safeResponse.prefix(1500)) + "..." : safeResponse

        addTrace(event: "Twilio SMS Reply", detail: "An: \(from), Länge: \(truncated.count)")
        return twimlOK(truncated)
    }

    // MARK: - Twilio Voice Webhook

    private func handleTwilioVoiceWebhook(body: Data) async -> String {
        let params = parseFormBody(body)
        let callSid = params["CallSid"] ?? ""
        let from = params["From"] ?? ""
        let to = params["To"] ?? ""
        let direction = params["Direction"] ?? "inbound"

        addTrace(event: "Twilio Voice", detail: "CallSid: \(callSid), Von: \(from), Richtung: \(direction)")

        // In-App Benachrichtigung bei eingehendem Anruf
        if direction.contains("inbound") {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldTwilioIncomingCall"),
                    object: nil,
                    userInfo: ["callSid": callSid, "from": from, "to": to]
                )
            }
        }

        // Bei eingehenden Anrufen: Whitelist prüfen
        if direction.contains("inbound") {
            let whitelistStr = UserDefaults.standard.string(forKey: "kobold.twilio.whitelist") ?? ""
            let whitelist = whitelistStr.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !whitelist.isEmpty && !whitelist.contains(from) {
                addTrace(event: "Twilio Voice", detail: "Nummer \(from) nicht in Whitelist — abgelehnt")
                return twimlResponse("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Response>
                    <Say language="de-DE">Diese Nummer ist nicht autorisiert. Auf Wiederhören.</Say>
                    <Hangup/>
                </Response>
                """)
            }
        }

        // Mode-Routing: ElevenLabs ConvAI oder Native
        let voiceMode = UserDefaults.standard.string(forKey: "kobold.twilio.voiceMode") ?? "native"
        if voiceMode == "elevenlabs" {
            let elResult = await handleTwilioElevenLabsWebhook(callSid: callSid, from: from, to: to, direction: direction)
            if let twiml = elResult {
                return twimlResponse(twiml)
            }
            // Fallback auf native Pipeline bei ElevenLabs-Fehler
            addTrace(event: "Twilio Voice", detail: "ElevenLabs fehlgeschlagen → Fallback auf native Pipeline")
        }

        // Native Pipeline: eigener WebSocket-Handler (Whisper + Ollama + TTS)
        let callDirection: CallDirection = direction.contains("inbound") ? .inbound : .outbound
        // Bei ausgehenden Anrufen den echten Zweck von TwilioVoiceCallTool abrufen
        let counterpartyNumber = direction.contains("inbound") ? from : to
        let callPurpose: String
        if callDirection == .outbound,
           let pendingPurpose = await TwilioVoiceHandler.shared.consumePendingPurpose(forNumber: counterpartyNumber) {
            callPurpose = pendingPurpose
        } else {
            callPurpose = direction.contains("inbound") ? "Eingehender Anruf von \(from)" : "Ausgehender Anruf an \(to)"
        }
        await TwilioVoiceHandler.shared.registerCall(
            callSid: callSid,
            direction: callDirection,
            purpose: callPurpose,
            number: counterpartyNumber
        )

        let explicitUrl = UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? ""
        let tunnelUrl = UserDefaults.standard.string(forKey: "kobold.tunnel.url") ?? ""
        let publicUrl = explicitUrl.isEmpty ? tunnelUrl : explicitUrl
        guard !publicUrl.isEmpty else {
            print("[Twilio] FEHLER: Keine Public URL verfügbar (weder explizit noch Tunnel)")
            return twimlResponse("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Response><Say language="de-DE">Verbindungsfehler. Kein Tunnel aktiv.</Say><Hangup/></Response>
            """)
        }
        let twiml = await TwilioVoiceHandler.shared.generateTwiML(callSid: callSid, publicUrl: publicUrl)
        return twimlResponse(twiml)
    }

    // MARK: - Twilio via ElevenLabs (Register Call API)

    private func handleTwilioElevenLabsWebhook(callSid: String, from: String, to: String, direction: String) async -> String? {
        let agentId = UserDefaults.standard.string(forKey: "kobold.elevenlabs.convai.agentId") ?? ""
        let apiKey = UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""

        guard !agentId.isEmpty, !apiKey.isEmpty else {
            addTrace(event: "EL-Twilio", detail: "Agent-ID oder API-Key fehlt")
            return nil  // Fallback
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/twilio/register-call") else { return nil }

        let payload: [String: Any] = [
            "agent_id": agentId,
            "twilio_call_sid": callSid,
            "from_number": from,
            "to_number": to,
            "direction": direction.contains("inbound") ? "inbound" : "outbound"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard status == 200 else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                addTrace(event: "EL-Twilio", detail: "HTTP \(status): \(body)")
                return nil  // Fallback
            }

            // ElevenLabs gibt TwiML zurück → direkt weiterreichen
            if let twiml = String(data: data, encoding: .utf8), !twiml.isEmpty {
                addTrace(event: "EL-Twilio", detail: "Register Call OK → TwiML erhalten")
                // Rohe TwiML zurückgeben — Caller wickelt in twimlResponse()
                return twiml
            }
            return nil
        } catch {
            addTrace(event: "EL-Twilio", detail: "Fehler: \(error.localizedDescription)")
            return nil  // Fallback auf native
        }
    }

    // MARK: - Twilio Media Stream (WebSocket)

    private func handleTwilioMediaStream(client: ClientSocket) async {
        addTrace(event: "Twilio WebSocket", detail: "Media Stream verbunden")
        var streamSid = ""
        var callSid = ""
        var audioAccumulator: [Float] = []
        let silenceThreshold: Float = 0.03
        var silenceFrames = 0
        let silenceLimit = 3  // ~60ms Stille bei ~50 Frames/s → minimale Latenz

        // Längeres Socket-Timeout für WebSocket
        var tv = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        while true {
            guard let frame = client.readWebSocketFrame() else { break }

            if frame.opcode == 0x8 { break } // Close
            if frame.opcode == 0x9 { _ = client.sendWebSocketTextFrame(""); continue } // Ping→Pong

            guard frame.opcode == 0x1,
                  let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                  let event = json["event"] as? String else { continue }

            switch event {
            case "connected":
                addTrace(event: "Twilio WS", detail: "Connected")

            case "start":
                if let start = json["start"] as? [String: Any] {
                    callSid = start["callSid"] as? String ?? ""
                }
                streamSid = json["streamSid"] as? String ?? ""
                addTrace(event: "Twilio WS", detail: "Stream: \(streamSid), Call: \(callSid)")

            case "media":
                guard let media = json["media"] as? [String: Any],
                      let payload = media["payload"] as? String else { continue }

                if let samples = await TwilioVoiceHandler.shared.handleMediaEvent(callSid: callSid, payload: payload) {
                    audioAccumulator.append(contentsOf: samples)

                    // VAD: RMS-Level prüfen
                    let rms = samples.reduce(Float(0)) { $0 + $1 * $1 }
                    let level = sqrt(rms / max(Float(samples.count), 1))

                    if level > silenceThreshold { silenceFrames = 0 } else { silenceFrames += 1 }

                    // Stille erkannt → Transkribieren und Agent antworten
                    if silenceFrames >= silenceLimit && audioAccumulator.count > 1600 {
                        let audio = audioAccumulator
                        audioAccumulator.removeAll()
                        silenceFrames = 0

                        let sid = streamSid
                        let cid = callSid
                        let agentRef = agentLoop
                        Task.detached {
                            await self.processTwilioSpeech(audio: audio, streamSid: sid, callSid: cid,
                                                           client: client, agent: agentRef)
                        }
                    }
                }

            case "stop":
                addTrace(event: "Twilio WS", detail: "Stream beendet: \(streamSid)")
                // Aktiven Anruf-Zweck aufräumen
                UserDefaults.standard.removeObject(forKey: "kobold.activeCall.purpose")
                // Gesprächsverlauf VOR endCall() sichern (endCall entfernt die Session)
                let callHistory = await TwilioVoiceHandler.shared.getConversationHistory(callSid: callSid)
                let session = await TwilioVoiceHandler.shared.endCall(callSid: callSid)

                // Post-Call-Protokoll: Benachrichtigung mit Zusammenfassung
                if let session, !callHistory.isEmpty {
                    let duration = Int(Date().timeIntervalSince(session.startTime))
                    let minutes = duration / 60
                    let seconds = duration % 60
                    let msgCount = callHistory.count
                    let number = String(session.counterpartyNumber)

                    // Gesprächs-Zusammenfassung bauen
                    let transcript = callHistory.map { msg in
                        let role = msg["role"] == "user" ? "Anrufer" : "Klaus"
                        return "\(role): \(msg["content"] ?? "")"
                    }.joined(separator: "\n")
                    let summary = transcript.count > 300 ? String(transcript.prefix(300)) + "..." : transcript

                    // Kopien für Sendable-Closure
                    let infoCallSid = String(callSid)
                    let infoNumber = number
                    let infoDuration = "\(minutes)m \(seconds)s"
                    let infoSummary = summary
                    let infoMsgCount = msgCount

                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Notification.Name("koboldTwilioCallEnded"),
                            object: nil,
                            userInfo: [
                                "callSid": infoCallSid,
                                "number": infoNumber,
                                "duration": infoDuration,
                                "messageCount": infoMsgCount,
                                "summary": infoSummary
                            ]
                        )
                    }
                    addTrace(event: "Twilio Call", detail: "Anruf beendet: \(number), \(minutes)m \(seconds)s, \(msgCount) Nachrichten")
                }

            default: break
            }
        }
        client.close()
    }

    /// STT → Agent → TTS → Twilio-Pipeline
    private func processTwilioSpeech(audio: [Float], streamSid: String, callSid: String,
                                      client: ClientSocket, agent: AgentLoop?) async {
        // Float → WAV
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("twilio_\(callSid.prefix(8))_\(UUID().uuidString.prefix(4)).wav")
        guard writeFloatToWAV(samples: audio, to: tempURL) else { return }

        // Whisper STT (via sttHandler-Callback vom GUI-Modul)
        guard let stt = DaemonListener.sttHandler,
              let text = await stt(tempURL),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        try? FileManager.default.removeItem(at: tempURL)

        addTrace(event: "Twilio STT", detail: "'\(text.prefix(60))'")
        await TwilioVoiceHandler.shared.appendToConversation(callSid: callSid, role: "user", content: text)

        // Safety-Prompt + Agent (direkt ohne Tool-Loop für minimale Latenz)
        let safetyPrompt = VoiceCallSafetyFilter.externalContactPrompt(purpose: "Telefonat", source: "voice_call")
        guard let agent else { return }
        // Conversation History + Anruf-Zweck für Kontext
        let history = await TwilioVoiceHandler.shared.getConversationHistory(callSid: callSid)
        let callPurpose = await TwilioVoiceHandler.shared.getCallPurpose(callSid: callSid) ?? ""

        // Zweck-Kontext: Bei ausgehenden Anrufen mit Aufgabe → aktiv das Gespräch führen
        let purposeContext: String
        if !callPurpose.isEmpty && !callPurpose.hasPrefix("Eingehender") && !callPurpose.hasPrefix("Ausgehender") {
            purposeContext = "\n\n## DEIN AUFTRAG FÜR DIESEN ANRUF\nDu hast diesen Anruf getätigt um: \(callPurpose)\nFühre das Gespräch AKTIV. Stelle dich vor, erkläre dein Anliegen, frage nach was du brauchst. Wenn der Zweck erfüllt ist → verabschiede dich und hänge auf."
        } else {
            purposeContext = ""
        }

        let voicePrompt = "[TELEFONAT — Echtzeit-Sprachgespräch. MAXIMAL 1-2 kurze Sätze! NIEMALS mehr als 30 Wörter. Kein Markdown. Sprich wie am Telefon. Wenn das Gespräch beendet werden soll (Verabschiedung, 'tschüss', Aufgabe erledigt), füge am ENDE deiner Antwort den Marker [AUFLEGEN] hinzu.]\(purposeContext)\n\n\(safetyPrompt)\n\nAnrufer sagt: \(text)"
        if history.count > 2 {
            // Mit Konversationshistorie für natürliche Gespräche
            await agent.injectConversationHistory(history)
        }
        // num_predict: 150 → Ollama reserviert minimal KV-Cache → schnellste Antwort, verhindert Romane
        let voiceConfig = LLMProviderConfig(numPredict: 150)
        let result = try? await agent.run(userMessage: voicePrompt, agentType: .general, providerConfig: voiceConfig)
        let response = result?.finalOutput ?? ""
        let safeResponse = VoiceCallSafetyFilter.sanitize(response)

        // [AUFLEGEN]-Marker erkennen → nach Audio-Senden den Anruf beenden
        let shouldHangUp = safeResponse.contains("[AUFLEGEN]")
        let spokenResponse = safeResponse.replacingOccurrences(of: "[AUFLEGEN]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        await TwilioVoiceHandler.shared.appendToConversation(callSid: callSid, role: "assistant", content: spokenResponse)

        // TTS → μ-law für Twilio (ElevenLabs oder macOS say Fallback)
        let apiKey = UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
        let voiceId = UserDefaults.standard.string(forKey: "kobold.elevenlabs.voiceId") ?? ""
        var audioData: Data?

        if !apiKey.isEmpty, !voiceId.isEmpty,
           let ttsUrl = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream") {
            // ElevenLabs TTS (bevorzugt)
            var req = URLRequest(url: ttsUrl)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 8
            let ttsModel = UserDefaults.standard.string(forKey: "kobold.twilio.ttsModel") ?? "eleven_turbo_v2_5"
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": spokenResponse, "model_id": ttsModel, "output_format": "ulaw_8000",
                "optimize_streaming_latency": 3
            ] as [String: Any])
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                audioData = data
            }
        }

        // Fallback: macOS say → AIFF → ffmpeg → μ-law (wenn kein ElevenLabs)
        if audioData == nil {
            addTrace(event: "Twilio TTS", detail: "ElevenLabs nicht verfügbar, nutze macOS say Fallback")
            let aiffURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_\(callSid.prefix(6)).aiff")
            let ulawURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_\(callSid.prefix(6)).raw")
            defer { try? FileManager.default.removeItem(at: aiffURL); try? FileManager.default.removeItem(at: ulawURL) }
            // macOS say → AIFF
            _ = try? await AsyncProcess.run(executable: "/usr/bin/say", arguments: ["-v", "Anna", "-o", aiffURL.path, spokenResponse], timeout: 10)
            if FileManager.default.fileExists(atPath: aiffURL.path) {
                // AIFF → μ-law 8kHz raw
                _ = try? await AsyncProcess.run(executable: "/usr/bin/env",
                    arguments: ["ffmpeg", "-i", aiffURL.path, "-ar", "8000", "-ac", "1", "-f", "mulaw", "-y", ulawURL.path], timeout: 10)
                if FileManager.default.fileExists(atPath: ulawURL.path) {
                    audioData = try? Data(contentsOf: ulawURL)
                }
            }
        }

        guard let finalAudio = audioData, !finalAudio.isEmpty else {
            addTrace(event: "Twilio TTS", detail: "Kein Audio generiert — weder ElevenLabs noch say")
            return
        }

        // Audio an Twilio senden (in Chunks für sofortiges Playback)
        // Twilio empfiehlt 20ms Pakete = 160 Bytes μ-law bei 8kHz
        let chunkSize = 8000  // 1 Sekunde pro Chunk (Balance: weniger Overhead als 160B, schnellerer Start als 1 großer Frame)
        var offset = 0
        while offset < finalAudio.count {
            let end = min(offset + chunkSize, finalAudio.count)
            let chunk = finalAudio[offset..<end]
            let mediaEvent: [String: Any] = [
                "event": "media", "streamSid": streamSid,
                "media": ["payload": chunk.base64EncodedString()]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: mediaEvent),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                _ = client.sendWebSocketTextFrame(jsonStr)
            }
            offset = end
        }

        // [AUFLEGEN]: Nach Audio-Senden den Anruf über Twilio REST API beenden
        if shouldHangUp {
            addTrace(event: "Twilio Hangup", detail: "Agent beendet Anruf \(callSid)")
            // Kurz warten damit das Verabschiedungs-Audio noch gehört wird
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await Self.hangupTwilioCall(callSid: callSid)
        }
    }

    /// Beendet einen Twilio-Anruf über die REST API
    /// Gibt den Anruf-Zweck-Kontext zurück wenn ein aktiver ausgehender Anruf mit Purpose existiert.
    /// Wird im OpenAI Proxy System-Prompt verwendet (ElevenLabs Custom LLM Path).
    private static func activeCallPurposeContext() -> String {
        let purpose = UserDefaults.standard.string(forKey: "kobold.activeCall.purpose") ?? ""
        guard !purpose.isEmpty else { return "" }
        return "\n\n## DEIN AUFTRAG FÜR DIESEN ANRUF\nDu hast diesen Anruf getätigt um: \(purpose)\nFühre das Gespräch AKTIV. Stelle dich vor, erkläre dein Anliegen, frage nach was du brauchst. Wenn der Zweck erfüllt ist → verabschiede dich und hänge auf."
    }

    private static func hangupTwilioCall(callSid: String) async {
        let accountSid = UserDefaults.standard.string(forKey: "kobold.twilio.accountSid") ?? ""
        let authToken = UserDefaults.standard.string(forKey: "kobold.twilio.authToken") ?? ""
        guard !accountSid.isEmpty, !authToken.isEmpty, !callSid.isEmpty else { return }

        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Calls/\(callSid).json") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let credentials = Data("\(accountSid):\(authToken)".utf8).base64EncodedString()
        req.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "Status=completed".data(using: .utf8)
        req.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 || status == 204 {
                print("[Twilio Hangup] Anruf \(callSid) beendet")
            } else {
                print("[Twilio Hangup] Fehler: HTTP \(status)")
            }
        } catch {
            print("[Twilio Hangup] Fehler: \(error.localizedDescription)")
        }
    }

    /// Schreibt Float-Array als 16kHz mono WAV
    private func writeFloatToWAV(samples: [Float], to url: URL) -> Bool {
        let sampleRate: UInt32 = 16000
        let dataSize = UInt32(samples.count * 2)
        let fileSize = 36 + dataSize
        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20])
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let val = Int16(max(-1.0, min(1.0, s)) * 32767.0)
            pcm.append(withUnsafeBytes(of: val.littleEndian) { Data($0) })
        }
        return (try? (header + pcm).write(to: url)) != nil
    }

    // MARK: - ElevenLabs TTS Proxy

    private func handleElevenLabsVoices() async -> String {
        let apiKey = UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
        guard !apiKey.isEmpty else { return jsonError("ElevenLabs API-Key nicht konfiguriert") }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            return jsonError("URL error")
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return jsonError("ElevenLabs API Fehler: HTTP \(code)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = json["voices"] as? [[String: Any]] else {
                return jsonError("ElevenLabs: ungültige Antwort")
            }
            let mapped: [[String: Any]] = voices.compactMap { v in
                guard let id = v["voice_id"] as? String,
                      let name = v["name"] as? String else { return nil }
                let labels = v["labels"] as? [String: String] ?? [:]
                let lang = labels["language"] ?? labels["accent"] ?? "multilingual"
                let category = v["category"] as? String ?? ""
                let previewUrl = v["preview_url"] as? String ?? ""
                return ["voice_id": id, "name": name, "language": lang,
                        "category": category, "preview_url": previewUrl]
            }
            return jsonOK(["voices": mapped])
        } catch {
            return jsonError("ElevenLabs Netzwerkfehler: \(error.localizedDescription)")
        }
    }

    private func handleElevenLabsSpeak(body: Data) async -> String {
        let apiKey = UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
        guard !apiKey.isEmpty else { return jsonError("ElevenLabs API-Key nicht konfiguriert") }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else {
            return jsonError("Invalid body — expected {text, voice_id?, model_id?}")
        }
        let voiceId = json["voice_id"] as? String
            ?? UserDefaults.standard.string(forKey: "kobold.elevenlabs.voiceId")
            ?? "21m00Tcm4TlvDq8ikWAM"  // Rachel (Default)
        let modelId = json["model_id"] as? String
            ?? UserDefaults.standard.string(forKey: "kobold.elevenlabs.model")
            ?? "eleven_flash_v2_5"

        // Streaming-Endpoint mit Latenz-Optimierung (wie Desktop TTSManager)
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream?optimize_streaming_latency=4&output_format=mp3_22050_32") else {
            return jsonError("URL error")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let payload: [String: Any] = ["text": text, "model_id": modelId, "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return jsonError("ElevenLabs TTS Fehler: HTTP \(code)")
            }
            let base64 = data.base64EncodedString()
            return jsonOK(["audio": base64, "content_type": "audio/mpeg", "size": data.count])
        } catch {
            return jsonError("ElevenLabs Netzwerkfehler: \(error.localizedDescription)")
        }
    }

    private func jsonOK(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        let body = String(data: data, encoding: .utf8) ?? "{}"
        return httpResponse(status: "200 OK", body: body)
    }

    private func jsonError(_ msg: String) -> String {
        errors += 1
        return httpResponse(status: "400 Bad Request",
                            body: "{\"error\":\"\(msg)\"}")
    }

    private func httpResponse(status: String, body: String) -> String {
        let bodyData = body.data(using: .utf8) ?? Data()
        return "HTTP/1.1 \(status)\r\n" +
               "Content-Type: application/json\r\n" +
               "Content-Length: \(bodyData.count)\r\n" +
               "X-Content-Type-Options: nosniff\r\n" +
               "Connection: close\r\n\r\n" +
               body
    }
}

// MARK: - Raw TCP Socket Wrappers

#if os(macOS)
import Darwin

private class ServerSocket: @unchecked Sendable {
    let fd: Int32

    init?(port: Int) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = UInt8(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(fd); return nil }
        guard listen(fd, 128) == 0 else { Darwin.close(fd); return nil }
    }

    func accept() -> ClientSocket? {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return nil }
        return ClientSocket(fd: clientFd)
    }
}

private class ClientSocket: @unchecked Sendable {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }

    func readRequest(maxBytes: Int = 1_048_576) -> String? {
        // Set socket read timeout to 30 seconds to prevent indefinite blocking
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read the full HTTP request — loop to handle Content-Length framing
        var fullData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        // First read — get headers at minimum
        let n = recv(fd, &buffer, buffer.count - 1, 0)
        guard n > 0 else { return nil }
        fullData.append(contentsOf: buffer.prefix(n))

        // Find header/body separator
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = fullData.range(of: sep) else {
            return String(data: fullData, encoding: .utf8)
        }

        // Parse Content-Length from headers
        let headerData = fullData[fullData.startIndex..<sepRange.lowerBound]
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
                break
            }
        }

        // Reject bodies exceeding limit early
        if contentLength > maxBytes { return nil }

        // How much body do we already have?
        let headerEndIndex = fullData.index(sepRange.lowerBound, offsetBy: 4)
        let bodyAlreadyRead = fullData.count - fullData.distance(from: fullData.startIndex, to: headerEndIndex)

        // Loop-read remaining body bytes
        if contentLength > 0 && bodyAlreadyRead < contentLength {
            let remaining = contentLength - bodyAlreadyRead
            var bodyBuffer = [UInt8](repeating: 0, count: min(remaining, maxBytes))
            var readSoFar = 0
            while readSoFar < remaining {
                let nr = recv(fd, &bodyBuffer[readSoFar], bodyBuffer.count - readSoFar, 0)
                guard nr > 0 else { break }
                readSoFar += nr
            }
            fullData.append(contentsOf: bodyBuffer.prefix(readSoFar))
        }

        return String(data: fullData, encoding: .utf8)
    }

    func write(_ response: String) {
        guard let data = response.data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 { break } // Client disconnected or error — stop writing
                totalSent += sent
            }
        }
    }

    /// Write attempt that sends ALL data — returns false if client is gone (used for SSE streaming)
    func tryWrite(_ response: String) -> Bool {
        guard let data = response.data(using: .utf8) else { return false }
        return data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 { return false } // Client disconnected
                totalSent += sent
            }
            return true
        }
    }

    // MARK: - WebSocket Support (RFC 6455)

    func performWebSocketHandshake(key: String) -> Bool {
        // SHA-1 Hash der Key + Magic GUID
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic

        // SHA-1 via CommonCrypto
        guard let data = combined.data(using: .utf8) else { return false }
        var hash = [UInt8](repeating: 0, count: 20)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        let acceptKey = Data(hash).base64EncodedString()

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n" +
            "\r\n"
        write(response)
        return true
    }

    func readWebSocketFrame() -> (opcode: UInt8, payload: Data)? {
        var header = [UInt8](repeating: 0, count: 2)
        guard recv(fd, &header, 2, MSG_WAITALL) == 2 else { return nil }

        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var payloadLen = UInt64(header[1] & 0x7F)

        if payloadLen == 126 {
            var ext = [UInt8](repeating: 0, count: 2)
            guard recv(fd, &ext, 2, MSG_WAITALL) == 2 else { return nil }
            payloadLen = UInt64(ext[0]) << 8 | UInt64(ext[1])
        } else if payloadLen == 127 {
            var ext = [UInt8](repeating: 0, count: 8)
            guard recv(fd, &ext, 8, MSG_WAITALL) == 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | UInt64(ext[i]) }
        }

        // Sicherheitsgrenze: max 1MB pro Frame
        guard payloadLen <= 1_048_576 else { return nil }

        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard recv(fd, &maskKey, 4, MSG_WAITALL) == 4 else { return nil }
        }

        var payload = [UInt8](repeating: 0, count: Int(payloadLen))
        if payloadLen > 0 {
            var read = 0
            while read < Int(payloadLen) {
                let n = recv(fd, &payload[read], Int(payloadLen) - read, 0)
                guard n > 0 else { return nil }
                read += n
            }
        }

        // Demaskieren
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        return (opcode: opcode, payload: Data(payload))
    }

    func sendWebSocketTextFrame(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        var frame = Data()
        frame.append(0x81) // FIN + Text

        if data.count < 126 {
            frame.append(UInt8(data.count))
        } else if data.count < 65536 {
            frame.append(126)
            frame.append(UInt8((data.count >> 8) & 0xFF))
            frame.append(UInt8(data.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((data.count >> (i * 8)) & 0xFF))
            }
        }

        frame.append(data)
        return frame.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var totalSent = 0
            while totalSent < frame.count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), frame.count - totalSent, 0)
                if sent <= 0 { return false }
                totalSent += sent
            }
            return true
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
#elseif os(Linux)
// Linux socket implementation is in LinuxSocket.swift
#endif
