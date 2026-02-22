import Foundation

/// Ollama model backend
public struct OllamaBackend: ModelBackend {
    public let type: ModelBackendType = .ollama
    public let name: String
    private let baseURL: String

    public init(name: String = "Ollama Server", baseURL: String = "http://localhost:11434") {
        self.name = name
        self.baseURL = baseURL
    }

    public func generate(prompt: String, options: ModelOptions?) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw ModelBackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let modelName = options?.model ?? "qwen2.5:1.5b"
        let requestBody: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": options?.temperature ?? 0.7
            ].compactMapValues { $0 }
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelBackendError.requestFailed
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let responseText = json["response"] as? String {
            return responseText
        }

        throw ModelBackendError.parsingFailed
    }

    public func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    public func getModelInfo() async -> ModelInfo {
        return ModelInfo(
            name: name,
            backendType: .ollama,
            capabilities: ["text-generation", "online", "multi-model"],
            isActive: await healthCheck()
        )
    }
}

public enum ModelBackendError: Error, LocalizedError {
    case invalidURL
    case requestFailed
    case parsingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .requestFailed:
            return "Request failed"
        case .parsingFailed:
            return "Failed to parse response"
        }
    }
}