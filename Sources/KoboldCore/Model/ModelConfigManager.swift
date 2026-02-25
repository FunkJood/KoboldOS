import Foundation

/// Centralized Manager for all Agent Configurations.
/// Ensures Instructor is always synced with global default.
public actor ModelConfigManager {
    public static let shared = ModelConfigManager()
    
    private let configKey = "kobold.agentConfigs"
    private let defaultModelKey = "kobold.ollamaModel"
    
    private init() {}
    
    /// Get the effective model for an agent type.
    /// If it's the Instructor or if the model is empty, use the global default.
    public func getModel(for agentId: String) -> (provider: String, model: String) {
        let globalDefault = UserDefaults.standard.string(forKey: defaultModelKey) ?? ""
        
        // Load saved configs
        let configs = loadConfigs()
        if let config = configs.first(where: { $0.id == agentId }) {
            // Instructor always follows global default OR use fallback if config model is empty
            if agentId == "instructor" || config.modelName.isEmpty {
                return (config.provider, globalDefault.isEmpty ? "qwen3-vl:235b-instruct-cloud" : globalDefault)
            }
            return (config.provider, config.modelName)
        }
        
        // Fallback for unknown agents
        return ("ollama", globalDefault.isEmpty ? "qwen3-vl:235b-instruct-cloud" : globalDefault)
    }
    
    /// Validate and save model changes.
    public func updateModel(for agentId: String, provider: String, modelName: String) {
        var configs = loadConfigs()
        if let idx = configs.firstIndex(where: { $0.id == agentId }) {
            configs[idx].provider = provider
            configs[idx].modelName = modelName
            saveConfigs(configs)
            
            // If we updated the instructor, also update the global default for consistency
            if agentId == "instructor" {
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
        AgentModelConfigInternal(id: "instructor", provider: "ollama", modelName: ""),
        AgentModelConfigInternal(id: "coder", provider: "ollama", modelName: ""),
        AgentModelConfigInternal(id: "web", provider: "ollama", modelName: ""),
        AgentModelConfigInternal(id: "utility", provider: "ollama", modelName: "")
    ]
}
