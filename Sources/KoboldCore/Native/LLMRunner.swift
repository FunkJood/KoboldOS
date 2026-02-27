import Foundation

// MARK: - LLMResponse (with optional token usage)

/// Response from LLM generation that includes content + optional token usage stats
public struct LLMResponse: Sendable {
    public let content: String
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(content: String, promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.content = content
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// Total tokens (prompt + completion) if both are available
    public var totalTokens: Int? {
        guard let p = promptTokens, let c = completionTokens else { return nil }
        return p + c
    }
}

// MARK: - LLMProviderConfig (per-agent provider override)

/// Configuration for a specific LLM provider, passed per-request from GUI → DaemonListener → AgentLoop → LLMRunner
public struct LLMProviderConfig: Sendable {
    public let provider: String      // "ollama", "openai", "anthropic", "groq"
    public let model: String         // e.g. "gpt-4o", "claude-sonnet-4-20250514", or "" for default
    public let apiKey: String        // API key for cloud providers
    public let temperature: Double   // 0.0 - 1.0

    public init(provider: String = "ollama", model: String = "", apiKey: String = "", temperature: Double = 0.7) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
    }

    /// Whether this config targets a cloud provider that needs an API key
    public var isCloudProvider: Bool {
        provider != "ollama" && provider != "llama-server"
    }
}

// MARK: - LLMBackendType

public enum LLMBackendType: String, Sendable, CaseIterable {
    case ollama      = "Ollama"
    case llamaServer = "Llama Server"  // llama.cpp HTTP server (OpenAI-compat API)
    case openai      = "OpenAI"
    case anthropic   = "Anthropic"
    case groq        = "Groq"
    case none        = "None"
}

// MARK: - LLMRunner (Ollama-first, llama-server fallback)

public actor LLMRunner {
    public enum State: Sendable {
        case unloaded
        case loading
        case ready
        case busy
        case error(String)
    }

    public static let shared = LLMRunner()

    private var state: State = .unloaded
    private var ollamaModel: String = ""
    public private(set) var activeBackend: LLMBackendType = .none

    // llama-server defaults (llama.cpp --server listens on 8081 by default)
    private var llamaServerURL: String = "http://localhost:8081"

    // Dedicated URLSession — NOT .shared, so parallel workers don't serialize on one connection pool
    private let httpSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    public init() {
        Task { await self.autoDetect() }
    }

    public func getState() -> State { state }
    public func getActiveBackend() -> LLMBackendType { activeBackend }

    // MARK: - Auto-detect available backend

    public func autoDetect() async {
        // 1. Try Ollama
        if await isOllamaAvailable() {
            state = .ready
            activeBackend = .ollama
            print("[LLMRunner] Backend: Ollama (\(ollamaModel))")
            return
        }
        // 2. Try llama-server (llama.cpp HTTP server)
        if await isLlamaServerAvailable() {
            state = .ready
            activeBackend = .llamaServer
            print("[LLMRunner] Backend: llama-server at \(llamaServerURL)")
            return
        }
        // 3. Nothing available
        state = .unloaded
        activeBackend = .none
        print("[LLMRunner] No LLM backend available")
    }

    private func isOllamaAvailable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await httpSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]],
              !models.isEmpty else {
            return false
        }
        let names = models.compactMap { $0["name"] as? String }

        // Priority: 1) General agent config model, 2) kobold.ollamaModel, 3) First available
        var chosen = ""
        if let configData = UserDefaults.standard.data(forKey: "kobold.agentConfigs"),
           let jsonArray = try? JSONSerialization.jsonObject(with: configData) as? [[String: Any]],
           let generalConfig = jsonArray.first(where: { ($0["id"] as? String) == "general" }),
           let generalModel = generalConfig["modelName"] as? String,
           !generalModel.isEmpty {
            chosen = generalModel
        }
        if chosen.isEmpty {
            chosen = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? ""
        }
        if chosen.isEmpty {
            chosen = names.first ?? ""
        }
        ollamaModel = chosen
        if !chosen.isEmpty { UserDefaults.standard.set(chosen, forKey: "kobold.ollamaModel") }
        print("[LLMRunner] Ollama model: \(ollamaModel) (available: \(names.count), source: \(chosen == names.first ? "first-available" : "agent-config"))")
        return !ollamaModel.isEmpty
    }

    private func isLlamaServerAvailable() async -> Bool {
        let port = UserDefaults.standard.integer(forKey: "kobold.llamaServerPort")
        llamaServerURL = "http://localhost:\(port == 0 ? 8081 : port)"
        guard let url = URL(string: llamaServerURL + "/health"),
              let (data, _) = try? await httpSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let s = json["status"] as? String ?? ""
        return s == "ok" || s == "loading model"
    }

    // MARK: - Generate (auto-select backend)

    public func generate(prompt: String) async throws -> String {
        let resp = try await generateWithTokens(messages: [["role": "user", "content": prompt]])
        return resp.content
    }

    public func generate(messages: [[String: String]]) async throws -> String {
        let resp = try await generateWithTokens(messages: messages)
        return resp.content
    }

    /// Generate and return full LLMResponse including token usage
    public func generateWithTokens(messages: [[String: String]]) async throws -> LLMResponse {
        if case .error = state { await autoDetect() }
        if case .unloaded = state { await autoDetect() }

        switch activeBackend {
        case .ollama:
            return try await generateWithOllama(messages: messages)
        case .llamaServer:
            return try await generateWithLlamaServer(messages: messages)
        case .openai, .anthropic, .groq:
            return try await generateWithOllama(messages: messages)
        case .none:
            throw LLMError.generationFailed("""
                No LLM backend available. Options:
                1. Install Ollama: brew install ollama && ollama serve && ollama pull llama3.2
                2. Run llama-server: llama-server -m model.gguf --port 8081
                """)
        }
    }

    // MARK: - Ollama /api/chat

    private func generateWithOllama(messages: [[String: String]]) async throws -> LLMResponse {
        guard let url = URL(string: "http://localhost:11434/api/chat") else {
            throw LLMError.generationFailed("Invalid Ollama URL")
        }
        if ollamaModel.isEmpty {
            // Auto-detect if model got lost
            await autoDetect()
            if ollamaModel.isEmpty {
                throw LLMError.generationFailed("No Ollama model set — please select a model in Settings")
            }
        }

        // Read context window size from settings (set by GUI → kobold.context.windowSize)
        // num_ctx tells Ollama how large the KV-cache should be; without this it uses the
        // model's compiled default (often 2k–32k) regardless of what the user configured.
        let storedCtx = UserDefaults.standard.integer(forKey: "kobold.context.windowSize")
        let effectiveCtx = storedCtx > 0 ? storedCtx : 32768
        let ollamaOptions: [String: Any] = ["num_predict": 16384, "num_ctx": effectiveCtx]

        let body: [String: Any] = [
            "model": ollamaModel,
            "messages": messages,
            "stream": false,
            "options": ollamaOptions
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMError.generationFailed("Could not serialize request body")
        }

        // Retry-Logik: Bei HTTP 500 bis zu 2 Retries mit Exponential Backoff + Jitter
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                let baseDelay: UInt64 = UInt64(attempt) * 2_000_000_000 // 2s, 4s
                let jitter = UInt64.random(in: 0...500_000_000) // 0-500ms Jitter
                print("[LLMRunner] Ollama Retry \(attempt)/2 nach \(attempt * 2)s + Jitter...")
                try await Task.sleep(nanoseconds: baseDelay + jitter)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = httpBody
            req.timeoutInterval = 120

            do {
                let startTime = Date()
                print("[LLMRunner] Ollama POST attempt=\(attempt) model=\(ollamaModel) msgCount=\(messages.count) bodySize=\(httpBody.count)bytes")
                let (data, resp) = try await httpSession.data(for: req)
                let elapsed = Date().timeIntervalSince(startTime)
                print("[LLMRunner] Ollama response in \(String(format: "%.1f", elapsed))s dataSize=\(data.count)bytes")

                // Check HTTP status first
                if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode != 200 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
                    print("[LLMRunner] Ollama HTTP \(httpResp.statusCode): \(bodyStr)")

                    // Bei 500er-Fehler: Retry
                    if httpResp.statusCode >= 500 && attempt < 2 {
                        lastError = LLMError.generationFailed("Ollama HTTP \(httpResp.statusCode)")
                        continue
                    }

                    // Benutzerfreundliche Fehlermeldung
                    if httpResp.statusCode >= 500 {
                        throw LLMError.generationFailed(
                            "Ollama-Fehler: Modell antwortet nicht (HTTP \(httpResp.statusCode)). " +
                            "Ist Ollama gestartet? Versuche: ollama serve && ollama pull \(ollamaModel)"
                        )
                    }
                    throw LLMError.generationFailed("Ollama HTTP \(httpResp.statusCode): \(String(bodyStr.prefix(200)))")
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let raw = String(data: data, encoding: .utf8) ?? "binary"
                    print("[LLMRunner] Ollama non-JSON response: \(raw.prefix(300))")
                    throw LLMError.generationFailed("Ollama returned non-JSON response")
                }

                // Check for Ollama error field
                if let errorMsg = json["error"] as? String {
                    print("[LLMRunner] Ollama error: \(errorMsg)")
                    // Bei "model not found" kein Retry
                    if errorMsg.contains("not found") {
                        throw LLMError.generationFailed("Ollama: Modell '\(ollamaModel)' nicht gefunden. Installiere mit: ollama pull \(ollamaModel)")
                    }
                    // Bei anderen Fehlern Retry
                    if attempt < 2 {
                        lastError = LLMError.generationFailed("Ollama: \(errorMsg)")
                        continue
                    }
                    throw LLMError.generationFailed("Ollama: \(errorMsg)")
                }

                guard let msg = json["message"] as? [String: Any],
                      let content = msg["content"] as? String else {
                    print("[LLMRunner] Unexpected Ollama response structure: \(json.keys)")
                    throw LLMError.generationFailed("Invalid Ollama response (missing message.content)")
                }
                // Extract Ollama token usage: prompt_eval_count, eval_count
                let promptTokens = json["prompt_eval_count"] as? Int
                let completionTokens = json["eval_count"] as? Int
                return LLMResponse(content: content, promptTokens: promptTokens, completionTokens: completionTokens)
            } catch let error as LLMError {
                throw error
            } catch {
                // Netzwerk-Fehler: Bei Connection Refused hilfreiche Meldung
                if attempt < 2 {
                    lastError = error
                    continue
                }
                let desc = error.localizedDescription
                if desc.contains("Connection refused") || desc.contains("Could not connect") {
                    throw LLMError.generationFailed(
                        "Ollama nicht erreichbar. Starte Ollama mit: ollama serve"
                    )
                }
                throw LLMError.generationFailed("Ollama-Verbindungsfehler: \(desc)")
            }
        }

        throw lastError ?? LLMError.generationFailed("Ollama: Unbekannter Fehler nach 3 Versuchen")
    }

    // MARK: - llama-server /v1/chat/completions (OpenAI-compatible)

    private func generateWithLlamaServer(messages: [[String: String]]) async throws -> LLMResponse {
        guard let url = URL(string: llamaServerURL + "/v1/chat/completions") else {
            throw LLMError.generationFailed("Invalid llama-server URL: \(llamaServerURL)")
        }

        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 8192,
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, _) = try await httpSession.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.generationFailed("Invalid llama-server response")
        }
        // Extract OpenAI-compatible usage from llama-server
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int
        let completionTokens = usage?["completion_tokens"] as? Int
        return LLMResponse(content: content, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    // MARK: - Generate with Provider Config

    /// Generate using a provider config (used by AgentLoop for per-agent backends)
    public func generate(messages: [[String: String]], config: LLMProviderConfig) async throws -> String {
        let resp = try await generateWithTokens(messages: messages, config: config)
        return resp.content
    }

    /// Generate with tokens using a provider config
    public func generateWithTokens(messages: [[String: String]], config: LLMProviderConfig) async throws -> LLMResponse {
        return try await generateWithTokens(messages: messages, provider: config.provider, model: config.model, apiKey: config.apiKey)
    }

    // MARK: - Multi-Provider Generate

    /// Generate with explicit provider, model, and API key (for per-agent cloud backends)
    public func generate(messages: [[String: String]], provider: String, model: String, apiKey: String) async throws -> String {
        let resp = try await generateWithTokens(messages: messages, provider: provider, model: model, apiKey: apiKey)
        return resp.content
    }

    /// Generate with tokens from explicit provider
    public func generateWithTokens(messages: [[String: String]], provider: String, model: String, apiKey: String) async throws -> LLMResponse {
        print("[LLMRunner] Cloud provider=\(provider) model=\(model) msgCount=\(messages.count) keyLen=\(apiKey.count)")
        switch provider.lowercased() {
        case "openai":
            return try await generateWithOpenAI(messages: messages, model: model, apiKey: apiKey)
        case "anthropic":
            return try await generateWithAnthropic(messages: messages, model: model, apiKey: apiKey)
        case "groq":
            return try await generateWithGroq(messages: messages, model: model, apiKey: apiKey)
        default:
            return try await generateWithTokens(messages: messages)
        }
    }

    // MARK: - OpenAI /v1/chat/completions

    private func generateWithOpenAI(messages: [[String: String]], model: String, apiKey: String) async throws -> LLMResponse {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw LLMError.generationFailed("Invalid OpenAI URL")
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o" : model,
            "messages": messages,
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.generationFailed("OpenAI HTTP \(code): \(errBody.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.generationFailed("Invalid OpenAI response")
        }
        // Extract OpenAI usage: usage.prompt_tokens, usage.completion_tokens
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int
        let completionTokens = usage?["completion_tokens"] as? Int
        return LLMResponse(content: content, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    // MARK: - Anthropic /v1/messages

    private func generateWithAnthropic(messages: [[String: String]], model: String, apiKey: String) async throws -> LLMResponse {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.generationFailed("Invalid Anthropic URL")
        }
        // Separate system message from user/assistant messages
        var systemPrompt = ""
        var apiMessages: [[String: String]] = []
        for m in messages {
            if m["role"] == "system" {
                systemPrompt += (systemPrompt.isEmpty ? "" : "\n") + (m["content"] ?? "")
            } else {
                apiMessages.append(m)
            }
        }
        var body: [String: Any] = [
            "model": model.isEmpty ? "claude-sonnet-4-20250514" : model,
            "max_tokens": 8192,
            "messages": apiMessages
        ]
        if !systemPrompt.isEmpty { body["system"] = systemPrompt }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.generationFailed("Anthropic HTTP \(code): \(errBody.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.generationFailed("Invalid Anthropic response")
        }
        // Extract Anthropic usage: usage.input_tokens, usage.output_tokens
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["input_tokens"] as? Int
        let completionTokens = usage?["output_tokens"] as? Int
        return LLMResponse(content: text, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    // MARK: - Groq /v1/chat/completions (OpenAI-compatible)

    private func generateWithGroq(messages: [[String: String]], model: String, apiKey: String) async throws -> LLMResponse {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw LLMError.generationFailed("Invalid Groq URL")
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? "llama-3.3-70b-versatile" : model,
            "messages": messages,
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.generationFailed("Groq HTTP \(code): \(errBody.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.generationFailed("Invalid Groq response")
        }
        // Extract Groq usage (OpenAI-compatible)
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int
        let completionTokens = usage?["completion_tokens"] as? Int
        return LLMResponse(content: content, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    // MARK: - Model management

    public func setModel(_ name: String) {
        ollamaModel = name
        UserDefaults.standard.set(name, forKey: "kobold.ollamaModel")
        state = .ready
    }

    public func setLlamaServerPort(_ port: Int) async {
        UserDefaults.standard.set(port, forKey: "kobold.llamaServerPort")
        llamaServerURL = "http://localhost:\(port)"
        await autoDetect()
    }

    public func setBackend(_ backend: LLMBackendType) async {
        activeBackend = backend
        if backend == .ollama && !ollamaModel.isEmpty { state = .ready }
        else if backend == .llamaServer { state = await isLlamaServerAvailable() ? .ready : .error("llama-server not reachable") }
    }

    public func autoLoad() async {
        await autoDetect()
    }

    public func unload() {
        state = .unloaded
        activeBackend = .none
        ollamaModel = ""
    }

    // MARK: - Helpers for UI

    public func listOllamaModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await httpSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }
}

// MARK: - LLMError

public enum LLMError: Error, LocalizedError {
    case fileNotFound(String)
    case loadFailed(String)
    case notReady
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):  return "Model file not found: \(path)"
        case .loadFailed(let msg):     return "Model load failed: \(msg)"
        case .notReady:                return "LLM not ready"
        case .generationFailed(let m): return "Generation failed: \(m)"
        }
    }
}
