import Foundation

// MARK: - DaemonListener
// Minimal HTTP server for KoboldOS daemon API

public actor DaemonListener {
    private let port: Int
    private let authToken: String
    private var agentLoop: AgentLoop?
    private let taggedMemoryStore = MemoryStore()

    // Metrics
    private var chatRequests = 0
    private var toolCalls = 0
    private var errors = 0
    private var tokensTotal = 0
    private var startTime = Date()

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

    // Connection limits
    private var activeConnections = 0
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

    /// B1: Shutdown-Flag für graceful termination
    private var isRunning = true

    public init(port: Int, authToken: String) {
        self.port = port
        self.authToken = authToken
        self.agentLoop = AgentLoop()
    }

    public func start() async {
        print("🌐 DaemonListener starting on :\(port)")
        isRunning = true
        startTaskScheduler()
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
        for await client in clientStream {
            let canAccept = self.canAcceptConnection()
            guard canAccept else {
                client.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                client.close()
                continue
            }
            Task.detached(priority: .userInitiated) {
                await self.incrementConnections()
                await self.handleConnection(client)
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

    private func handleConnection(_ client: ClientSocket) async {
        let requestStart = CFAbsoluteTimeGetCurrent()
        guard let raw = client.readRequest(maxBytes: bodyLimitBytes) else { return }
        let (method, path, headers, body) = parseHTTPRequest(raw)

        // Body size check
        if let b = body, b.count > bodyLimitBytes {
            client.write(httpResponse(status: "413 Payload Too Large", body: "{\"error\":\"Body exceeds 10MB limit\"}"))
            return
        }

        // Auth check — /health and /.well-known/agent.json are public
        if path != "/health" && path != "/.well-known/agent.json" {
            let authHeader = headers["authorization"] ?? ""
            // Case-insensitive "Bearer " prefix removal
            let provided: String
            if authHeader.lowercased().hasPrefix("bearer ") {
                provided = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else {
                provided = authHeader
            }
            if !authToken.isEmpty && provided != authToken {
                client.write(httpResponse(status: "401 Unauthorized", body: "{\"error\":\"Invalid or missing auth token\"}"))
                return
            }
        }

        // Rate limiting
        if isRateLimited(path: path) {
            client.write(httpResponse(status: "429 Too Many Requests", body: "{\"error\":\"Rate limit exceeded (\(rateLimitMax)/min)\"}"))
            return
        }

        // SSE streaming endpoint — writes directly to socket, does NOT return a single response
        if path == "/agent/stream" && method == "POST" {
            await handleAgentStream(client: client, body: body)
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
                "version": "0.3.3",
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "uptime": Int(Date().timeIntervalSince(startTime))
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

        case "/tasks":
            if method == "POST", let body {
                return handleTasksPost(body: body)
            }
            return jsonOK(["tasks": loadTasks()])

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

        default:
            return httpResponse(status: "404 Not Found", body: "{\"error\":\"Not found\"}")
        }
    }

    // MARK: - Agent Handler

    private func handleAgent(body: Data) async -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["message"] as? String else {
            return agentError("Ungültige Anfrage — 'message' Feld fehlt")
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

            addTrace(event: "Antwort", detail: String(result.finalOutput.prefix(60)))

            return jsonOK([
                "output": result.finalOutput,
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

        // Extract conversation history from payload (sent by RuntimeViewModel)
        let conversationHistory: [[String: String]]
        if let history = json["conversation_history"] as? [[String: String]] {
            conversationHistory = history
        } else {
            conversationHistory = []
        }

        chatRequests += 1

        // Acquire a worker from the pool — suspends if all workers are busy.
        // Each worker has its own LLMRunner to enable true Ollama parallelism
        // (requires OLLAMA_NUM_PARALLEL ≥ pool size on the Ollama side).
        let pool = AgentWorkerPool.shared
        let poolStatus = await pool.statusDescription
        print("[Daemon] SSE: acquiring worker (pool: \(poolStatus))")
        let agent = await pool.acquire()
        // Release worker back to pool when SSE is done (whether success, error, or disconnect)
        // Using a detached task avoids holding the DaemonListener actor during the async release
        defer {
            Task.detached { await pool.release(agent) }
        }

        // Send a "waiting" event if the pool was saturated (user sees feedback in UI)
        let waitCount = await pool.waitingRequestCount
        if waitCount > 0 {
            let waitEvent = "event: step\ndata: {\"type\":\"waiting\",\"content\":\"⏳ Warte auf freien Worker (\(waitCount + 1) in Warteschlange)...\",\"tool\":\"pool\"}\n\n"
            _ = client.tryWrite(waitEvent)
        }

        // CRITICAL: Inject conversation history so the agent knows what was discussed
        if !conversationHistory.isEmpty {
            await agent.injectConversationHistory(conversationHistory)
        }

        let modelDisplay = model.isEmpty ? (UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "default") : model
        print("[Daemon] SSE START: \"\(String(message.prefix(60)))\" type=\(agentTypeStr) provider=\(provider) model=\(modelDisplay) history=\(conversationHistory.count) msgs pool=\(await pool.statusDescription)")

        addTrace(event: "SSE Start", detail: "[\(agentTypeStr)] \(modelDisplay) — \(String(message.prefix(60)))")
        addTrace(event: "Model", detail: "\(provider)/\(modelDisplay) (Kontext: \(conversationHistory.count) Msgs)")

        // Write SSE headers — Connection: close tells URLSession the response ends at EOF
        // (no Content-Length or chunked needed). This prevents URLSession from buffering.
        let sseHeaders = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "X-Accel-Buffering: no\r\n" +
            "X-Content-Type-Options: nosniff\r\n\r\n"
        client.write(sseHeaders)

        // Set SO_NOSIGPIPE to prevent crashes on client disconnect
        var yes: Int32 = 1
        setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Disable Nagle's algorithm for instant SSE delivery (no TCP buffering)
        setsockopt(client.fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Heartbeat: send immediate event to confirm SSE connection is live
        // URLSession needs at least one data frame to start delivering bytes.lines
        _ = client.tryWrite("event: step\ndata: {\"type\":\"think\",\"content\":\"Verbunden, Agent startet...\",\"tool\":\"\",\"success\":true,\"step\":0}\n\n")

        // Stream steps with provider config
        let providerConfig = LLMProviderConfig(provider: provider, model: model, apiKey: apiKey, temperature: temperature)
        print("[Daemon] SSE → runStreaming starting...")
        let stream = await agent.runStreaming(userMessage: message, agentType: type, providerConfig: providerConfig)
        print("[Daemon] SSE → stream created, iterating steps...")
        var stepCount = 0
        for await step in stream {
            if step.type == .toolCall {
                toolCalls += 1
                addTrace(event: "Tool: \(step.toolCallName ?? "unknown")", detail: String(step.content.prefix(60)))
            }
            // Include checkpoint steps in SSE for UI visibility
            // Escape literal newlines in JSON to prevent SSE event injection
            let safeJSON = step.toJSON().replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            let eventData = "event: step\ndata: \(safeJSON)\n\n"
            // Detect client disconnect — stop streaming if write fails
            if !client.tryWrite(eventData) {
                print("[Daemon] SSE CLIENT DISCONNECTED after \(stepCount) steps — aborting stream")
                addTrace(event: "SSE aborted", detail: "Client disconnected after \(stepCount) steps")
                return
            }
            stepCount += 1
            // CRITICAL: Yield after each step to prevent actor starvation.
            // Without this, rapid SSE steps monopolize the DaemonListener actor
            // and starve /metrics, /health, and other concurrent requests.
            await Task.yield()
        }

        print("[Daemon] SSE DONE: \(stepCount) steps streamed")
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
        print("[TaskScheduler] Started — checking every 60s")
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
                NotificationCenter.default.post(
                    name: Notification.Name("koboldScheduledTaskFired"),
                    object: nil,
                    userInfo: ["taskId": taskId, "taskName": taskName, "prompt": prompt]
                )
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

    // MARK: - A2A Agent Card

    private func buildAgentCard() -> [String: Any] {
        [
            "name": "KoboldOS",
            "version": "0.3.3",
            "description": "Native macOS AI Agent Runtime — local-first, privacy-focused",
            "capabilities": [
                "streaming": true,
                "tools": ["shell", "file", "browser", "http", "applescript", "notify_user", "calculator",
                          "core_memory_read", "core_memory_append", "core_memory_replace",
                          "archival_memory_search", "archival_memory_insert",
                          "calendar", "contacts",
                          "call_subordinate", "delegate_parallel"],
                "agent_types": ["general", "coder", "web"],
                "memory": true,
                "sub_agents": true,
                "vision": true,
                "checkpoints": true,
                "memory_versioning": true
            ] as [String: Any],
            "authentication": ["type": "bearer"],
            "endpoints": [
                "agent": "/agent",
                "stream": "/agent/stream",
                "chat": "/chat",
                "health": "/health",
                "memory": "/memory",
                "tasks": "/tasks",
                "workflows": "/workflows",
                "checkpoints": "/checkpoints",
                "card": "/.well-known/agent.json"
            ]
        ]
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
            do {
                let entry = try await taggedMemoryStore.add(text: text, memoryType: type, tags: tagsRaw)
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
            [
                "id": e.id,
                "text": e.text,
                "type": e.memoryType,
                "tags": e.tags,
                "timestamp": fmt.string(from: e.timestamp)
            ]
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

    private func parseHTTPRequest(_ raw: String) -> (method: String, path: String, headers: [String: String], body: Data?) {
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

    func close() {
        Darwin.close(fd)
    }
}
#elseif os(Linux)
// Linux socket implementation is in LinuxSocket.swift
#endif
