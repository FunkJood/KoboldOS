import Foundation

/// Manages multiple model backends
public actor BackendManager {
    private var backends: [ModelBackendType: ModelBackend] = [:]
    private var activeBackend: ModelBackendType?

    public init() async {
        // Initialize with default backends
        await setupDefaultBackends()
    }

    private func setupDefaultBackends() async {
        // Local backend (placeholder)
        backends[.local] = LocalModelBackend(name: "Local GGUF Models", modelPath: "")

        // Ollama backend
        backends[.ollama] = OllamaBackend()

        // Claude Code backend (handled separately via ClaudeCodeBackend actor)
        // backends[.claudeCode] = ClaudeCodeBackend()
    }

    /// Register a new backend
    public func registerBackend(_ backend: ModelBackend) {
        backends[backend.type] = backend
    }

    /// Get backend by type
    public func getBackend(type: ModelBackendType) -> ModelBackend? {
        return backends[type]
    }

    /// Set active backend
    public func setActiveBackend(type: ModelBackendType) {
        activeBackend = type
    }

    /// Get active backend
    public func getActiveBackend() -> ModelBackend? {
        guard let type = activeBackend else { return backends[.ollama] }
        return backends[type]
    }

    /// Generate response using active backend
    public func generate(prompt: String, options: ModelOptions? = nil) async throws -> String {
        guard let backend = getActiveBackend() else {
            throw BackendError.noActiveBackend
        }
        return try await backend.generate(prompt: prompt, options: options)
    }

    /// Check health of all backends
    public func checkAllHealth() async -> [ModelBackendType: Bool] {
        var healthStatus: [ModelBackendType: Bool] = [:]
        for (type, backend) in backends {
            healthStatus[type] = await backend.healthCheck()
        }
        return healthStatus
    }

    /// Get info for all backends
    public func getAllBackendInfo() async -> [ModelInfo] {
        var infos: [ModelInfo] = []
        for (_, backend) in backends {
            infos.append(await backend.getModelInfo())
        }
        return infos
    }

    /// Get available backend types
    public func getAvailableBackends() -> [ModelBackendType] {
        return Array(backends.keys).sorted { $0.rawValue < $1.rawValue }
    }
}

public enum BackendError: Error, LocalizedError {
    case noActiveBackend
    case backendNotAvailable(ModelBackendType)

    public var errorDescription: String? {
        switch self {
        case .noActiveBackend:
            return "No active backend selected"
        case .backendNotAvailable(let type):
            return "Backend \(type.rawValue) is not available"
        }
    }
}