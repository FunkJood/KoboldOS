#if os(macOS)
import Foundation

// MARK: - TTSTool (Text-to-Speech via Notification → UI handles AVSpeechSynthesizer)

public struct TTSTool: Tool {
    public let name = "speak"
    public let description = "Lies Text laut vor (Text-to-Speech). Nutze dies wenn der Nutzer 'lies vor', 'sag mir', 'vorlesen' oder ähnliches sagt."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "text": ToolSchemaProperty(type: "string", description: "Der Text der vorgelesen werden soll", required: true),
            "voice": ToolSchemaProperty(type: "string", description: "Stimme/Sprache, z.B. 'de-DE', 'en-US'. Standard: Systemsprache"),
            "rate": ToolSchemaProperty(type: "string", description: "Geschwindigkeit 0.1-1.0. Standard: 0.5"),
        ], required: ["text"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let text = arguments["text"], !text.isEmpty else {
            throw ToolError.missingRequired("text")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let text = arguments["text"] ?? ""
        let voice = arguments["voice"]
        let rate = arguments["rate"]

        var userInfo: [String: String] = ["text": text]
        if let voice = voice { userInfo["voice"] = voice }
        if let rate = rate { userInfo["rate"] = rate }

        // Post notification to UI — TTSManager in KoboldOSControlPanel handles playback
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("koboldTTSSpeak"),
                object: nil,
                userInfo: userInfo
            )
        }

        let wordCount = text.split(separator: " ").count
        return "Text wird vorgelesen (\(wordCount) Wörter)."
    }
}

#elseif os(Linux)
import Foundation

public struct TTSTool: Tool {
    public let name = "speak"
    public let description = "Text-to-Speech (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low
    public var schema: ToolSchema { ToolSchema(properties: ["text": ToolSchemaProperty(type: "string", description: "Text", required: true)], required: ["text"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String {
        return "Text-to-Speech ist auf Linux deaktiviert."
    }
}
#endif
