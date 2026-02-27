#if os(macOS)
import Foundation

// MARK: - Email Tool (SMTP via /usr/bin/curl, IMAP read support)
public struct EmailTool: Tool {
    public let name = "email"
    public let description = "E-Mail senden und empfangen über SMTP/IMAP (curl-basiert)"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: send, list_inbox, read_mail, search", enumValues: ["send", "list_inbox", "read_mail", "search"], required: true),
            "to": ToolSchemaProperty(type: "string", description: "Empfänger-Adresse (für send)"),
            "subject": ToolSchemaProperty(type: "string", description: "Betreff (für send)"),
            "body": ToolSchemaProperty(type: "string", description: "E-Mail-Text (für send)"),
            "uid": ToolSchemaProperty(type: "string", description: "E-Mail UID (für read_mail)"),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff (für search)"),
            "limit": ToolSchemaProperty(type: "string", description: "Max. Anzahl Ergebnisse (Standard: 10)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private struct EmailConfig {
        let smtpHost: String
        let smtpPort: String
        let imapHost: String
        let imapPort: String
        let email: String
        let password: String
        let useTLS: Bool
    }

    private func loadConfig() -> EmailConfig? {
        let d = UserDefaults.standard
        guard let email = d.string(forKey: "kobold.email.address"), !email.isEmpty,
              let password = d.string(forKey: "kobold.email.password"), !password.isEmpty else {
            return nil
        }
        return EmailConfig(
            smtpHost: d.string(forKey: "kobold.email.smtpHost") ?? "smtp.gmail.com",
            smtpPort: d.string(forKey: "kobold.email.smtpPort") ?? "587",
            imapHost: d.string(forKey: "kobold.email.imapHost") ?? "imap.gmail.com",
            imapPort: d.string(forKey: "kobold.email.imapPort") ?? "993",
            email: email,
            password: password,
            useTLS: d.bool(forKey: "kobold.email.useTLS") || !d.dictionaryRepresentation().keys.contains("kobold.email.useTLS")
        )
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        guard let config = loadConfig() else {
            return "Error: E-Mail nicht konfiguriert. Bitte unter Einstellungen → Verbindungen → E-Mail die Zugangsdaten eintragen."
        }

        switch action {
        case "send":
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' Parameter fehlt." }
            guard let subject = arguments["subject"], !subject.isEmpty else { return "Error: 'subject' Parameter fehlt." }
            let body = arguments["body"] ?? ""
            return await sendEmail(config: config, to: to, subject: subject, body: body)

        case "list_inbox":
            let limit = Int(arguments["limit"] ?? "10") ?? 10
            return await listInbox(config: config, limit: limit)

        case "read_mail":
            guard let uid = arguments["uid"], !uid.isEmpty else { return "Error: 'uid' Parameter fehlt." }
            return await readMail(config: config, uid: uid)

        case "search":
            guard let query = arguments["query"], !query.isEmpty else { return "Error: 'query' Parameter fehlt." }
            let limit = Int(arguments["limit"] ?? "10") ?? 10
            return await searchMail(config: config, query: query, limit: limit)

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: send, list_inbox, read_mail, search"
        }
    }

    // MARK: - Send via SMTP (curl)

    private func sendEmail(config: EmailConfig, to: String, subject: String, body: String) async -> String {
        let message = """
        From: \(config.email)
        To: \(to)
        Subject: \(subject)
        Content-Type: text/plain; charset=UTF-8
        MIME-Version: 1.0

        \(body)
        """

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("kobold_email_\(UUID().uuidString).eml")
        do {
            try message.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            return "Error: Temporäre Datei konnte nicht erstellt werden: \(error)"
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let smtpURL = "smtp\(config.useTLS ? "s" : "")://\(config.smtpHost):\(config.smtpPort)"
        let args = [
            "/usr/bin/curl", "--silent", "--show-error",
            "--max-time", "15", "--connect-timeout", "5",
            "--url", smtpURL,
            "--ssl-reqd",
            "--mail-from", config.email,
            "--mail-rcpt", to,
            "--user", "\(config.email):\(config.password)",
            "--upload-file", tempFile.path
        ]

        return await runProcess(args: args, successMessage: "E-Mail gesendet an \(to): \(subject)")
    }

    // MARK: - IMAP Operations (curl)

    private func listInbox(config: EmailConfig, limit: Int) async -> String {
        let imapURL = "imaps://\(config.imapHost):\(config.imapPort)/INBOX"
        let args = [
            "/usr/bin/curl", "--silent", "--show-error",
            "--max-time", "15", "--connect-timeout", "5",
            "--url", "\(imapURL);MAILINDEX=1:\(limit)",
            "--user", "\(config.email):\(config.password)",
            "-X", "FETCH 1:\(limit) (FLAGS BODY[HEADER.FIELDS (FROM SUBJECT DATE)])"
        ]

        let result = await runProcess(args: args, successMessage: nil)
        if result.hasPrefix("Error:") { return result }
        if result.isEmpty { return "Posteingang ist leer." }
        return "Posteingang (letzte \(limit)):\n\(String(result.prefix(8192)))"
    }

    private func readMail(config: EmailConfig, uid: String) async -> String {
        let imapURL = "imaps://\(config.imapHost):\(config.imapPort)/INBOX;UID=\(uid)"
        let args = [
            "/usr/bin/curl", "--silent", "--show-error",
            "--max-time", "15", "--connect-timeout", "5",
            "--url", imapURL,
            "--user", "\(config.email):\(config.password)"
        ]

        let result = await runProcess(args: args, successMessage: nil)
        if result.hasPrefix("Error:") { return result }
        return String(result.prefix(8192))
    }

    private func searchMail(config: EmailConfig, query: String, limit: Int) async -> String {
        let imapURL = "imaps://\(config.imapHost):\(config.imapPort)/INBOX"
        let args = [
            "/usr/bin/curl", "--silent", "--show-error",
            "--max-time", "15", "--connect-timeout", "5",
            "--url", imapURL,
            "--user", "\(config.email):\(config.password)",
            "-X", "SEARCH SUBJECT \"\(query)\""
        ]

        let result = await runProcess(args: args, successMessage: nil)
        if result.hasPrefix("Error:") { return result }
        if result.isEmpty { return "Keine E-Mails gefunden für: \(query)" }
        return "Suchergebnisse für '\(query)':\n\(String(result.prefix(8192)))"
    }

    // MARK: - Process Helper

    private func runProcess(args: [String], successMessage: String?) async -> String {
        do {
            let result = try await AsyncProcess.run(
                executable: args[0],
                arguments: Array(args.dropFirst()),
                timeout: 30
            )
            if result.exitCode != 0 {
                return "Error: curl fehlgeschlagen (\(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)"
            }
            return successMessage ?? result.stdout
        } catch is ToolError {
            return "Error: Timeout — curl hat nicht rechtzeitig geantwortet"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct EmailTool: Tool {
    public let name = "email"
    public let description = "E-Mail senden/empfangen (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "E-Mail ist auf Linux deaktiviert." }
}
#endif
