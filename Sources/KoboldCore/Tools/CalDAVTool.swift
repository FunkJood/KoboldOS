#if os(macOS)
import Foundation

// MARK: - CalDAV Tool (WebDAV/HTTP Kalender-Zugriff)
public struct CalDAVTool: Tool {
    public let name = "caldav"
    public let description = "CalDAV: Kalender auflisten, Termine anzeigen, erstellen und löschen (WebDAV-kompatibel)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: list_calendars, list_events, create_event, delete_event", enumValues: ["list_calendars", "list_events", "create_event", "delete_event"], required: true),
            "calendar_path": ToolSchemaProperty(type: "string", description: "Kalender-Pfad (relativ zum Server-URL)"),
            "title": ToolSchemaProperty(type: "string", description: "Titel für create_event"),
            "start": ToolSchemaProperty(type: "string", description: "Startzeit für create_event (ISO 8601, z.B. 2026-03-01T10:00:00)"),
            "end": ToolSchemaProperty(type: "string", description: "Endzeit für create_event (ISO 8601)"),
            "location": ToolSchemaProperty(type: "string", description: "Ort für create_event"),
            "description": ToolSchemaProperty(type: "string", description: "Beschreibung für create_event"),
            "event_uid": ToolSchemaProperty(type: "string", description: "Event UID für delete_event"),
            "days": ToolSchemaProperty(type: "string", description: "Zeitraum in Tagen für list_events (Standard: 30)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private struct CalDAVConfig {
        let serverURL: String
        let username: String
        let password: String
    }

    private func loadConfig() -> CalDAVConfig? {
        let d = UserDefaults.standard
        guard let server = d.string(forKey: "kobold.caldav.serverURL"), !server.isEmpty,
              let user = d.string(forKey: "kobold.caldav.username"), !user.isEmpty,
              let pass = d.string(forKey: "kobold.caldav.password"), !pass.isEmpty else {
            return nil
        }
        return CalDAVConfig(serverURL: server, username: user, password: pass)
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        guard let config = loadConfig() else {
            return "Error: CalDAV nicht konfiguriert. Bitte unter Einstellungen → Verbindungen → CalDAV Server-URL, Benutzername und Passwort eintragen."
        }

        switch action {
        case "list_calendars":
            return await listCalendars(config: config)

        case "list_events":
            let calPath = arguments["calendar_path"] ?? ""
            let days = Int(arguments["days"] ?? "30") ?? 30
            return await listEvents(config: config, calendarPath: calPath, days: days)

        case "create_event":
            guard let title = arguments["title"], !title.isEmpty else { return "Error: 'title' Parameter fehlt." }
            guard let start = arguments["start"], !start.isEmpty else { return "Error: 'start' Parameter fehlt." }
            guard let end = arguments["end"], !end.isEmpty else { return "Error: 'end' Parameter fehlt." }
            let calPath = arguments["calendar_path"] ?? ""
            let location = arguments["location"] ?? ""
            let description = arguments["description"] ?? ""
            return await createEvent(config: config, calendarPath: calPath, title: title, start: start, end: end, location: location, description: description)

        case "delete_event":
            guard let uid = arguments["event_uid"], !uid.isEmpty else { return "Error: 'event_uid' Parameter fehlt." }
            let calPath = arguments["calendar_path"] ?? ""
            return await deleteEvent(config: config, calendarPath: calPath, uid: uid)

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    // MARK: - CalDAV Operations via curl

    private func davRequest(config: CalDAVConfig, path: String, method: String, body: String?, contentType: String = "application/xml; charset=utf-8", depth: String? = nil) async -> String {
        let baseURL = config.serverURL.hasSuffix("/") ? String(config.serverURL.dropLast()) : config.serverURL
        let fullURL = path.isEmpty ? baseURL : "\(baseURL)/\(path)"

        var args = [
            "/usr/bin/curl", "--silent", "--show-error",
            "-X", method,
            "--url", fullURL,
            "--user", "\(config.username):\(config.password)",
            "-H", "Content-Type: \(contentType)"
        ]

        if let depth = depth {
            args += ["-H", "Depth: \(depth)"]
        }

        if let body = body {
            args += ["-d", body]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = Array(args.dropFirst())

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                return "Error: CalDAV-Anfrage fehlgeschlagen: \(errStr.isEmpty ? outStr : errStr)"
            }
            return outStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func listCalendars(config: CalDAVConfig) async -> String {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:cs="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <cs:supported-calendar-component-set/>
          </d:prop>
        </d:propfind>
        """

        let result = await davRequest(config: config, path: "", method: "PROPFIND", body: body, depth: "1")
        if result.hasPrefix("Error:") { return result }

        // Simple extraction of calendar names from XML
        var calendars: [String] = []
        let lines = result.components(separatedBy: "<d:displayname>")
        for line in lines.dropFirst() {
            if let endIdx = line.range(of: "</d:displayname>") {
                let name = String(line[line.startIndex..<endIdx.lowerBound])
                if !name.isEmpty { calendars.append(name) }
            }
        }

        if calendars.isEmpty { return "Keine Kalender gefunden. Prüfe Server-URL und Zugangsdaten." }
        return "Kalender (\(calendars.count)):\n" + calendars.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private func listEvents(config: CalDAVConfig, calendarPath: String, days: Int) async -> String {
        let now = Date()
        let future = Calendar.current.date(byAdding: .day, value: days, to: now)!
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withFullTime]

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data/>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="\(dateFormatter.string(from: now))" end="\(dateFormatter.string(from: future))"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """

        let result = await davRequest(config: config, path: calendarPath, method: "REPORT", body: body, depth: "1")
        if result.hasPrefix("Error:") { return result }
        return "Termine (nächste \(days) Tage):\n\(String(result.prefix(8192)))"
    }

    private func createEvent(config: CalDAVConfig, calendarPath: String, title: String, start: String, end: String, location: String, description: String) async -> String {
        let uid = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let dtStart = start.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").prefix(15) + "Z"
        let dtEnd = end.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").prefix(15) + "Z"

        var ical = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//KoboldOS//CalDAV//DE
        BEGIN:VEVENT
        UID:\(uid)
        DTSTAMP:\(now.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").prefix(15))Z
        DTSTART:\(dtStart)
        DTEND:\(dtEnd)
        SUMMARY:\(title)
        """
        if !location.isEmpty { ical += "\nLOCATION:\(location)" }
        if !description.isEmpty { ical += "\nDESCRIPTION:\(description)" }
        ical += "\nEND:VEVENT\nEND:VCALENDAR"

        let path = calendarPath.isEmpty ? "\(uid).ics" : "\(calendarPath)/\(uid).ics"
        let result = await davRequest(config: config, path: path, method: "PUT", body: ical, contentType: "text/calendar; charset=utf-8")
        if result.hasPrefix("Error:") { return result }
        return "Termin erstellt: \(title) (UID: \(uid))"
    }

    private func deleteEvent(config: CalDAVConfig, calendarPath: String, uid: String) async -> String {
        let path = calendarPath.isEmpty ? "\(uid).ics" : "\(calendarPath)/\(uid).ics"
        let result = await davRequest(config: config, path: path, method: "DELETE", body: nil)
        if result.hasPrefix("Error:") { return result }
        return "Termin gelöscht: \(uid)"
    }
}

#elseif os(Linux)
import Foundation

public struct CalDAVTool: Tool {
    public let name = "caldav"
    public let description = "CalDAV (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "CalDAV ist auf Linux deaktiviert." }
}
#endif
