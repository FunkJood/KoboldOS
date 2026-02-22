import Foundation

/// Local model backend: connects to llama-server (llama.cpp HTTP server)
/// Run: llama-server -m /path/to/model.gguf --port 8081
public struct LocalModelBackend: ModelBackend {
    public let type: ModelBackendType = .local
    public let name: String
    private let serverURL: String
    private let modelPath: String

    public init(name: String, modelPath: String, serverPort: Int = 8081) {
        self.name = name
        self.modelPath = modelPath
        self.serverURL = "http://localhost:\(serverPort)"
    }

    // MARK: - Generate via llama-server OpenAI-compatible API

    public func generate(prompt: String, options: ModelOptions?) async throws -> String {
        guard let url = URL(string: serverURL + "/v1/chat/completions") else {
            throw LocalBackendError.serverNotRunning("Invalid URL: \(serverURL)")
        }

        let maxTokens = options?.maxTokens ?? 2048
        let temperature = options?.temperature ?? 0.7

        let body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LocalBackendError.invalidResponse("Cannot parse llama-server response")
        }
        return content
    }

    // MARK: - Health: check if llama-server is reachable

    public func healthCheck() async -> Bool {
        guard let url = URL(string: serverURL + "/health"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let status = json["status"] as? String ?? ""
        return status == "ok" || status == "loading model"
    }

    public func getModelInfo() async -> ModelInfo {
        let isHealthy = await healthCheck()
        return ModelInfo(
            name: isHealthy ? name : "\(name) (offline)",
            backendType: .local,
            capabilities: ["text-generation", "offline", "private", "GGUF"],
            isActive: isHealthy
        )
    }
}

// MARK: - How to start llama-server

public enum LocalBackendError: Error, LocalizedError {
    case serverNotRunning(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning(let url):
            return """
            llama-server not reachable at \(url).
            Start it with: llama-server -m /path/to/model.gguf --port 8081
            Install: brew install llama.cpp
            """
        case .invalidResponse(let msg):
            return "llama-server response error: \(msg)"
        }
    }
}
