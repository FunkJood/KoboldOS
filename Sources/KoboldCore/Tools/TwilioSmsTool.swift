#if os(macOS)
import Foundation

// MARK: - Twilio SMS Tool (AccountSID + AuthToken)
public struct TwilioSmsTool: Tool {
    public let name = "sms_send"
    public let description = "SMS senden über Twilio API"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: send", enumValues: ["send"], required: true),
            "to": ToolSchemaProperty(type: "string", description: "Empfänger-Telefonnummer im E.164 Format, z.B. +491701234567", required: true),
            "body": ToolSchemaProperty(type: "string", description: "SMS-Text (max 1600 Zeichen)", required: true),
            "from": ToolSchemaProperty(type: "string", description: "Absender-Nummer (optional, nutzt Standard-Nummer wenn leer)")
        ], required: ["action", "to", "body"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let to = arguments["to"], !to.isEmpty else {
            throw ToolError.missingRequired("to")
        }
        guard let body = arguments["body"], !body.isEmpty else {
            throw ToolError.missingRequired("body")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let to = arguments["to"] ?? ""
        let body = arguments["body"] ?? ""
        let from = arguments["from"] ?? ""

        let d = UserDefaults.standard
        let accountSid = d.string(forKey: "kobold.twilio.accountSid") ?? ""
        let authToken = d.string(forKey: "kobold.twilio.authToken") ?? ""
        let defaultFrom = d.string(forKey: "kobold.twilio.fromNumber") ?? ""

        guard !accountSid.isEmpty, !authToken.isEmpty else {
            return "Error: Twilio nicht konfiguriert. Bitte AccountSID und AuthToken unter Einstellungen → Verbindungen → Twilio eintragen."
        }

        let sender = from.isEmpty ? defaultFrom : from
        guard !sender.isEmpty else {
            return "Error: Keine Absender-Nummer konfiguriert. Bitte 'from' angeben oder Standard-Nummer in den Einstellungen setzen."
        }

        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Messages.json") else {
            return "Error: Ungültige AccountSID"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let credentials = "\(accountSid):\(authToken)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let bodyParts = [
            "To=\(to.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? to)",
            "From=\(sender.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sender)",
            "Body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body)"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(4096), encoding: .utf8) ?? "(empty)"

            if status >= 400 {
                return "Error: HTTP \(status): \(responseStr)"
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sid"] as? String {
                return "SMS gesendet! SID: \(sid), An: \(to)"
            }
            return "SMS gesendet an \(to)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct TwilioSmsTool: Tool {
    public let name = "sms_send"
    public let description = "SMS senden über Twilio (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Twilio SMS ist auf Linux deaktiviert." }
}
#endif
