#if os(macOS)
import Foundation

// MARK: - WhatsApp Business API Tool (Meta Graph API)
public struct WhatsAppApiTool: Tool {
    public let name = "whatsapp_api"
    public let description = "WhatsApp Business API: Textnachrichten, Templates und Bilder senden"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: send_text, send_template, send_image, raw", enumValues: ["send_text", "send_template", "send_image", "raw"], required: true),
            "to": ToolSchemaProperty(type: "string", description: "Empfänger-Telefonnummer (E.164 Format, z.B. 491701234567)"),
            "text": ToolSchemaProperty(type: "string", description: "Nachrichtentext für send_text"),
            "template_name": ToolSchemaProperty(type: "string", description: "Template-Name für send_template"),
            "template_language": ToolSchemaProperty(type: "string", description: "Template-Sprache (Standard: de)"),
            "image_url": ToolSchemaProperty(type: "string", description: "Bild-URL für send_image"),
            "caption": ToolSchemaProperty(type: "string", description: "Bildunterschrift für send_image"),
            "endpoint": ToolSchemaProperty(type: "string", description: "API-Endpunkt für raw"),
            "method": ToolSchemaProperty(type: "string", description: "HTTP-Methode für raw", enumValues: ["GET", "POST"]),
            "body": ToolSchemaProperty(type: "string", description: "JSON-Body für raw")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private func getCredentials() -> (token: String, phoneNumberId: String)? {
        let d = UserDefaults.standard
        let token = d.string(forKey: "kobold.whatsapp.accessToken") ?? ""
        let phoneId = d.string(forKey: "kobold.whatsapp.phoneNumberId") ?? ""
        guard !token.isEmpty, !phoneId.isEmpty else { return nil }
        return (token, phoneId)
    }

    private func whatsappRequest(endpoint: String, method: String = "POST", body: String? = nil) async -> String {
        guard let creds = getCredentials() else {
            return "Error: WhatsApp nicht konfiguriert. Bitte unter Einstellungen → Verbindungen → WhatsApp anmelden und Phone Number ID eintragen."
        }

        let urlStr = endpoint.hasPrefix("http") ? endpoint : "https://graph.facebook.com/v18.0/\(creds.phoneNumberId)\(endpoint)"
        guard let url = URL(string: urlStr) else { return "Error: Ungültige URL: \(urlStr)" }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let body = body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }

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

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {
        case "send_text":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt." }
            guard let text = arguments["text"], !text.isEmpty else { return "Error: 'text' Parameter fehlt." }
            let body = """
            {"messaging_product":"whatsapp","to":"\(escapeJson(to))","type":"text","text":{"body":"\(escapeJson(text))"}}
            """
            return await whatsappRequest(endpoint: "/messages", body: body)

        case "send_template":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt." }
            guard let templateName = arguments["template_name"], !templateName.isEmpty else { return "Error: 'template_name' Parameter fehlt." }
            let lang = arguments["template_language"] ?? "de"
            let body = """
            {"messaging_product":"whatsapp","to":"\(escapeJson(to))","type":"template","template":{"name":"\(escapeJson(templateName))","language":{"code":"\(lang)"}}}
            """
            return await whatsappRequest(endpoint: "/messages", body: body)

        case "send_image":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt." }
            guard let imageUrl = arguments["image_url"], !imageUrl.isEmpty else { return "Error: 'image_url' Parameter fehlt." }
            let caption = arguments["caption"] ?? ""
            var imageObj = "{\"link\":\"\(escapeJson(imageUrl))\""
            if !caption.isEmpty { imageObj += ",\"caption\":\"\(escapeJson(caption))\"" }
            imageObj += "}"
            let body = """
            {"messaging_product":"whatsapp","to":"\(escapeJson(to))","type":"image","image":\(imageObj)}
            """
            return await whatsappRequest(endpoint: "/messages", body: body)

        case "raw":
            guard let endpoint = arguments["endpoint"], !endpoint.isEmpty else { return "Error: 'endpoint' Parameter fehlt." }
            let method = arguments["method"] ?? "GET"
            return await whatsappRequest(endpoint: endpoint, method: method, body: arguments["body"])

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    private func escapeJson(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

#elseif os(Linux)
import Foundation

public struct WhatsAppApiTool: Tool {
    public let name = "whatsapp_api"
    public let description = "WhatsApp API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "WhatsApp API ist auf Linux deaktiviert." }
}
#endif
