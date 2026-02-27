import Foundation

/// Centralized Manager for all Agent Configurations.
/// Ensures Instructor is always synced with global default.
public actor ModelConfigManager {
    public static let shared = ModelConfigManager()
    
    private let configKey = "kobold.agentConfigs"
    private let defaultModelKey = "kobold.ollamaModel"
    
    private init() {}
    
    /// Get the effective model for an agent type.
    /// Priority: 1) Agent-specific config model, 2) General agent model, 3) kobold.ollamaModel
    public func getModel(for agentId: String) -> (provider: String, model: String) {
        let configs = loadConfigs()
        let generalConfig = configs.first(where: { $0.id == "general" })
        let generalModel = generalConfig?.modelName ?? ""
        let globalDefault = UserDefaults.standard.string(forKey: defaultModelKey) ?? ""
        let effectiveDefault = !generalModel.isEmpty ? generalModel : globalDefault

        if let config = configs.first(where: { $0.id == agentId }) {
            let model = config.modelName.isEmpty ? effectiveDefault : config.modelName
            return (config.provider, model)
        }

        // Fallback for unknown agents — use general config
        return (generalConfig?.provider ?? "ollama", effectiveDefault)
    }
    
    /// Validate and save model changes.
    public func updateModel(for agentId: String, provider: String, modelName: String) {
        var configs = loadConfigs()
        if let idx = configs.firstIndex(where: { $0.id == agentId }) {
            configs[idx].provider = provider
            configs[idx].modelName = modelName
            saveConfigs(configs)
            
            // If we updated the general agent, also update the global default for consistency
            if agentId == "general" || agentId == "instructor" {
                UserDefaults.standard.set(modelName, forKey: defaultModelKey)
            }
        }
    }
    
    private func loadConfigs() -> [AgentModelConfigInternal] {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode([AgentModelConfigInternal].self, from: data) {
            return decoded
        }
        return AgentModelConfigInternal.defaults
    }
    
    private func saveConfigs(_ configs: [AgentModelConfigInternal]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }
}

/// Internal mirrored struct of AgentModelConfig to avoid UI dependencies in Core.
struct AgentModelConfigInternal: Codable {
    var id: String
    var provider: String
    var modelName: String
    
    static let defaults: [AgentModelConfigInternal] = [
        AgentModelConfigInternal(id: "general", provider: "ollama", modelName: ""),
        AgentModelConfigInternal(id: "coder", provider: "ollama", modelName: ""),
        AgentModelConfigInternal(id: "web", provider: "ollama", modelName: "")
    ]
}
