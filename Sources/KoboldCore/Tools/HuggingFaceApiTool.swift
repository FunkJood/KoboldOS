#if os(macOS)
import Foundation

// MARK: - HuggingFace API Tool (Token-based, no OAuth)
public struct HuggingFaceApiTool: Tool {
    public let name = "huggingface_api"
    public let description = "HuggingFace API: AI-Inference ausführen, Modelle suchen und Modell-Infos abrufen"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: inference, search_models, model_info", enumValues: ["inference", "search_models", "model_info"], required: true),
            "model": ToolSchemaProperty(type: "string", description: "Modell-ID, z.B. 'meta-llama/Llama-2-7b-chat-hf' oder 'stabilityai/stable-diffusion-xl-base-1.0'"),
            "input": ToolSchemaProperty(type: "string", description: "Input-Text für Inference oder Suchbegriff für search_models"),
            "params": ToolSchemaProperty(type: "string", description: "Zusätzliche Parameter als JSON-Objekt, z.B. {\"max_new_tokens\": 200}")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let model = arguments["model"] ?? ""
        let input = arguments["input"] ?? ""
        let paramsStr = arguments["params"]

        let token = UserDefaults.standard.string(forKey: "kobold.huggingface.apiToken") ?? ""
        guard !token.isEmpty else {
            return "Error: Kein HuggingFace API-Token konfiguriert. Bitte unter Einstellungen → Verbindungen → HuggingFace eintragen."
        }

        switch action {
        case "inference":
            guard !model.isEmpty else { return "Error: 'model' Parameter wird für Inference benötigt." }
            guard !input.isEmpty else { return "Error: 'input' Parameter wird für Inference benötigt." }
            return await runInference(model: model, input: input, params: paramsStr, token: token)

        case "search_models":
            let query = input.isEmpty ? model : input
            return await searchModels(query: query, token: token)

        case "model_info":
            guard !model.isEmpty else { return "Error: 'model' Parameter wird für model_info benötigt." }
            return await getModelInfo(model: model, token: token)

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: inference, search_models, model_info"
        }
    }

    private func runInference(model: String, input: String, params: String?, token: String) async -> String {
        guard let url = URL(string: "https://api-inference.huggingface.co/models/\(model)") else {
            return "Error: Ungültige Modell-ID"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = ["inputs": input]
        if let paramsStr = params, !paramsStr.isEmpty,
           let paramsData = paramsStr.data(using: .utf8),
           let paramsObj = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            body["parameters"] = paramsObj
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Error: JSON-Serialisierung fehlgeschlagen"
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 {
                return "Error: HTTP \(status): \(responseStr)"
            }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func searchModels(query: String, token: String) async -> String {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ]

        guard let url = components.url else { return "Error: URL-Fehler" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func getModelInfo(model: String, token: String) async -> String {
        guard let url = URL(string: "https://huggingface.co/api/models/\(model)") else {
            return "Error: Ungültige Modell-ID"
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(8192), encoding: .utf8) ?? "(empty)"
            if status >= 400 { return "Error: HTTP \(status): \(responseStr)" }
            return responseStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct HuggingFaceApiTool: Tool {
    public let name = "huggingface_api"
    public let description = "HuggingFace API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "HuggingFace API ist auf Linux deaktiviert." }
}
#endif
