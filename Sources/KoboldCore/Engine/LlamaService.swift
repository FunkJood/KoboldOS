import Foundation

// MARK: - LlamaMessage (Letta-style message blocks)

public struct LlamaMessage: Sendable, Identifiable, Codable {
    public let id: String
    public let role: LlamaRole
    public let content: String
    public let timestamp: Date

    public init(id: String = UUID().uuidString, role: LlamaRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

public enum LlamaRole: String, Sendable, Codable {
    case system, user, assistant

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "KoboldOS"
        }
    }
}

// MARK: - LlamaService (ObservableObject for SwiftUI, wraps LLMRunner)

@MainActor
public final class LlamaService: ObservableObject {

    @Published public var isLoading: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var currentResponse: String = ""
    @Published public var conversationHistory: [LlamaMessage] = []
    @Published public var errorMessage: String? = nil
    @Published public var systemInfo: String = "KoboldOS LLM Service"
    @Published public var activeModel: String = "Not loaded"

    private let agentLoop: AgentLoop?
    private var persistencePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/chat_history.json")
    }

    public init() {
        // AgentLoop is async so we initialize it lazily
        self.agentLoop = nil
        Task { await self.setup() }
    }

    private nonisolated func makeAgentLoop() async -> AgentLoop {
        await AgentLoop()
    }

    private func setup() async {
        // Try to load GGUF model
        await loadModel()
        // Load chat history
        loadHistory()
        updateModelInfo()
    }

    // MARK: - Model Loading

    public func loadModel(path: String? = nil) async {
        isLoading = true
        errorMessage = nil

        let modelPath = path ?? autoDiscoverModel()

        if let mp = modelPath {
            // Load via LLMRunner (Ollama-first, GGUF auto-discovery)
            await LLMRunner.shared.autoLoad()
            let state = await LLMRunner.shared.getState()
            switch state {
            case .ready:
                isModelLoaded = true
                activeModel = URL(fileURLWithPath: mp).lastPathComponent
                systemInfo = "Model: \(activeModel)"
            case .error(let msg):
                errorMessage = msg
                isModelLoaded = false
                activeModel = await detectOllamaModel() ?? "No model"
                systemInfo = activeModel == "No model" ? "No LLM backend available" : "Ollama: \(activeModel)"
            default:
                activeModel = await detectOllamaModel() ?? "No model"
                isModelLoaded = activeModel != "No model"
                systemInfo = isModelLoaded ? "Ollama: \(activeModel)" : "No LLM backend"
            }
        } else {
            // No local model — try Ollama
            activeModel = await detectOllamaModel() ?? "No model"
            isModelLoaded = activeModel != "No model"
            systemInfo = isModelLoaded ? "Ollama: \(activeModel)" : "No LLM backend — install Ollama"
        }

        isLoading = false
    }

    private func autoDiscoverModel() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("KoboldOS/Models")
        let localModels = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models")

        for dir in [modelsDir.path, localModels.path] {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                if let gguf = files.first(where: { $0.hasSuffix(".gguf") }) {
                    return dir + "/" + gguf
                }
            }
        }
        return nil
    }

    private func detectOllamaModel() async -> String? {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]],
              let first = models.first,
              let name = first["name"] as? String else { return nil }
        return name
    }

    private func updateModelInfo() {
        Task {
            let state = await LLMRunner.shared.getState()
            switch state {
            case .ready: systemInfo = "Model ready (llama.cpp)"
            case .busy: systemInfo = "Model busy..."
            case .loading: systemInfo = "Loading model..."
            case .unloaded:
                if let m = await detectOllamaModel() {
                    systemInfo = "Ollama: \(m)"
                } else {
                    systemInfo = "No model loaded"
                }
            case .error(let e): systemInfo = "Error: \(e)"
            }
        }
    }

    // MARK: - Send Message (real LLM, no simulation)

    public func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        currentResponse = ""
        errorMessage = nil

        // Add user message
        let userMsg = LlamaMessage(role: .user, content: text)
        conversationHistory.append(userMsg)

        do {
            // Build conversation prompt
            let prompt = buildPrompt()
            let response = try await LLMRunner.shared.generate(prompt: prompt)
            currentResponse = response

            // Add assistant response
            let assistantMsg = LlamaMessage(role: .assistant, content: response)
            conversationHistory.append(assistantMsg)

            // Persist history
            saveHistory()
        } catch {
            errorMessage = error.localizedDescription
            let errMsg = LlamaMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
            conversationHistory.append(errMsg)
        }

        isLoading = false
    }

    // MARK: - Send with Agent Loop (tool calls enabled)

    public func sendWithAgent(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        currentResponse = ""
        errorMessage = nil

        let userMsg = LlamaMessage(role: .user, content: text)
        conversationHistory.append(userMsg)

        // Use agent loop for tool-call-enabled responses
        let loop = await makeAgentLoop()
        let response = await loop.run(prompt: text)

        currentResponse = response
        let assistantMsg = LlamaMessage(role: .assistant, content: response)
        conversationHistory.append(assistantMsg)

        saveHistory()
        isLoading = false
    }

    // MARK: - Prompt Building (Letta-style memory compilation)

    private func buildPrompt() -> String {
        // Use last 20 messages to stay within context
        let recent = conversationHistory.suffix(20)
        return recent.map { msg in
            switch msg.role {
            case .system:    return "System: \(msg.content)"
            case .user:      return "User: \(msg.content)"
            case .assistant: return "Assistant: \(msg.content)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - History Persistence (max 100 messages)

    public func clearHistory() {
        conversationHistory = []
        try? FileManager.default.removeItem(at: persistencePath)
    }

    private func saveHistory() {
        let toSave = Array(conversationHistory.suffix(100))
        let dir = persistencePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(toSave) {
            try? data.write(to: persistencePath)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: persistencePath),
              let history = try? JSONDecoder().decode([LlamaMessage].self, from: data) else { return }
        conversationHistory = history
        print("[LlamaService] Loaded \(history.count) messages from history")
    }

    // MARK: - Ollama Model List

    public func listOllamaModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    public func isOllamaRunning() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        return (try? await URLSession.shared.data(from: url)) != nil
    }
}
