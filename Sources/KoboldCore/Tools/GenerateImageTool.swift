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
        let prompt = arguments["prompt"] ?? ""
        let negativePrompt = arguments["negative_prompt"]
        let steps = arguments["steps"]
        let guidanceScale = arguments["guidance_scale"]
        let seed = arguments["seed"]

        let callbackId = UUID().uuidString

        var userInfo: [String: String] = [
            "prompt": prompt,
            "callback_id": callbackId,
        ]
        if let negativePrompt = negativePrompt { userInfo["negative_prompt"] = negativePrompt }
        if let steps = steps { userInfo["steps"] = steps }
        if let guidanceScale = guidanceScale { userInfo["guidance_scale"] = guidanceScale }
        if let seed = seed { userInfo["seed"] = seed }

        // Post notification to UI — ImageGenManager handles generation
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("koboldImageGenerate"),
                object: nil,
                userInfo: userInfo
            )
        }

        // Wait for result (up to 5 minutes)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var observer: NSObjectProtocol?
            let timeout = DispatchWorkItem {
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                continuation.resume(returning: "Error: Bildgenerierung hat zu lange gedauert (Timeout). Bitte prüfe ob ein Stable Diffusion Model in den Einstellungen geladen ist.")
            }

            observer = NotificationCenter.default.addObserver(
                forName: Notification.Name("koboldImageGenResult"),
                object: nil, queue: .main
            ) { notif in
                guard let resultCallbackId = notif.userInfo?["callback_id"] as? String,
                      resultCallbackId == callbackId else { return }

                timeout.cancel()
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }

                if let path = notif.userInfo?["path"] as? String,
                   notif.userInfo?["success"] as? String == "true" {
                    continuation.resume(returning: "Bild erfolgreich generiert!\nDateipfad: \(path)\n\n![Generated Image](\(path))")
                } else {
                    let error = notif.userInfo?["error"] as? String ?? "Unbekannter Fehler"
                    continuation.resume(returning: "Error: Bildgenerierung fehlgeschlagen — \(error)")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)
        }

        return result
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
