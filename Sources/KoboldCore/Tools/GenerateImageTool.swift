#if os(macOS)
import Foundation

// MARK: - GenerateImageTool (Stable Diffusion via Notification → UI handles generation)

public struct GenerateImageTool: Tool {
    public let name = "generate_image"
    public let description = "Generiere ein Bild mit Stable Diffusion lokal auf dem Mac. Das Bild wird auf dem Desktop gespeichert und im Chat angezeigt."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "prompt": ToolSchemaProperty(type: "string", description: "Bildbeschreibung auf Englisch, z.B. 'a beautiful sunset over mountains, oil painting style'", required: true),
            "negative_prompt": ToolSchemaProperty(type: "string", description: "Was NICHT im Bild sein soll, z.B. 'ugly, blurry, text'"),
            "steps": ToolSchemaProperty(type: "string", description: "Anzahl Schritte (10-100, Standard: 30). Mehr = bessere Qualität, langsamer"),
            "guidance_scale": ToolSchemaProperty(type: "string", description: "Wie stark der Prompt befolgt wird (1.0-20.0, Standard: 7.5)"),
            "seed": ToolSchemaProperty(type: "string", description: "Seed für Reproduzierbarkeit (Zahl). Standard: zufällig"),
        ], required: ["prompt"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let prompt = arguments["prompt"], !prompt.isEmpty else {
            throw ToolError.missingRequired("prompt")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        return "Bildgenerierung ist in dieser Version deaktiviert. Das Feature wird in einem zukünftigen Update wieder verfügbar sein."
    }
}

#elseif os(Linux)
import Foundation

public struct GenerateImageTool: Tool {
    public let name = "generate_image"
    public let description = "Bildgenerierung (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["prompt": ToolSchemaProperty(type: "string", description: "Prompt", required: true)], required: ["prompt"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String {
        return "Bildgenerierung ist auf Linux deaktiviert."
    }
}
#endif
