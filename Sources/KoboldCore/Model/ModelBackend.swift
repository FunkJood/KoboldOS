import Foundation

/// Protocol for different model backends
public protocol ModelBackend: Sendable {
    var type: ModelBackendType { get }
    var name: String { get }
    func generate(prompt: String, options: ModelOptions?) async throws -> String
    func healthCheck() async -> Bool
    func getModelInfo() async -> ModelInfo
}

/// Supported backend types
public enum ModelBackendType: String, CaseIterable, Sendable {
    case local = "Local"
    case ollama = "Ollama"
    case claudeCode = "Claude Code"
    case openai = "OpenAI"
    case anthropic = "Anthropic"
}

/// Model options for generation
public struct ModelOptions: Sendable {
    public let temperature: Double?
    public let maxTokens: Int?
    public let stopSequences: [String]?
    public let model: String?

    public init(temperature: Double? = nil, maxTokens: Int? = nil, stopSequences: [String]? = nil, model: String? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.model = model
    }
}

/// Model information structure
public struct ModelInfo: Sendable {
    public let name: String
    public let backendType: ModelBackendType
    public let capabilities: [String]
    public let isActive: Bool

    public init(name: String, backendType: ModelBackendType, capabilities: [String], isActive: Bool = false) {
        self.name = name
        self.backendType = backendType
        self.capabilities = capabilities
        self.isActive = isActive
    }
}