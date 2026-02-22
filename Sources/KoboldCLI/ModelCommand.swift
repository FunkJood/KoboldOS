import ArgumentParser
import Foundation

struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage AI models (Ollama + GGUF)",
        subcommands: [ListModels.self, SetModel.self, StatusModel.self],
        defaultSubcommand: ListModels.self
    )
}

// MARK: - kobold model list
struct ListModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all available models"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"
    @Flag(name: .long, help: "Output as JSON") var json: Bool = false

    func run() async throws {
        let url = URL(string: endpoint + "/models")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            fputs("❌ Daemon not reachable at \(endpoint)\n", stderr)
            throw ExitCode.failure
        }
        if json {
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("❌ Could not parse response\n", stderr)
            throw ExitCode.failure
        }

        let active = decoded["active"] as? String ?? "(unknown)"
        let models = decoded["models"] as? [String] ?? []
        let ollamaStatus = decoded["ollama_status"] as? String ?? "unknown"
        let ggufCount = decoded["gguf_count"] as? Int ?? 0

        print("KOBOLDOS — MODELS")
        print("═══════════════════════════════")
        print("Active:       \(active)")
        print("Ollama:       \(ollamaStatus)")
        print("GGUF models:  \(ggufCount)")
        print("")
        if models.isEmpty {
            print("  No models found. Run: ollama pull qwen2.5:1.5b")
        } else {
            print("Available:")
            for m in models {
                let marker = m == active ? " ◀ active" : ""
                print("  • \(m)\(marker)")
            }
        }
    }
}

// MARK: - kobold model set <name>
struct SetModel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the active model"
    )
    @Argument(help: "Model name (e.g. qwen2.5:1.5b)") var modelName: String
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        let url = URL(string: endpoint + "/model/set")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelName])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            print("✅ Active model set to: \(modelName)")
        } else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            fputs("❌ Failed to set model: \(body)\n", stderr)
            throw ExitCode.failure
        }
    }
}

// MARK: - kobold model status
struct StatusModel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show current model and cache status"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        // Fetch /models and /metrics in parallel
        async let modelsReq = URLSession.shared.data(from: URL(string: endpoint + "/models")!)
        async let metricsReq = URLSession.shared.data(from: URL(string: endpoint + "/metrics")!)
        let (modelsData, _) = try await modelsReq
        let (metricsData, _) = try await metricsReq

        let models = (try? JSONSerialization.jsonObject(with: modelsData) as? [String: Any]) ?? [:]
        let metrics = (try? JSONSerialization.jsonObject(with: metricsData) as? [String: Any]) ?? [:]

        let active = models["active"] as? String ?? "(none)"
        let ollamaStatus = models["ollama_status"] as? String ?? "unknown"
        let cachedCount = models["cached_count"] as? Int ?? 0
        let maxCached = models["max_cached"] as? Int ?? 3
        let tokenTotal = metrics["token_total"] as? Int ?? 0
        let chatRequests = metrics["chat_requests"] as? Int ?? 0

        print("KOBOLDOS — MODEL STATUS")
        print("════════════════════════")
        print("Active model: \(active)")
        print("Ollama:       \(ollamaStatus)")
        print("Cache:        \(cachedCount)/\(maxCached) models loaded")
        print("Tokens used:  \(tokenTotal)")
        print("Chat calls:   \(chatRequests)")
    }
}
