#if os(macOS)
import Foundation
import EventKit

// MARK: - CalendarTool (macOS implementation)
public struct CalendarTool: Tool, @unchecked Sendable {
    public let name = "calendar"
    public let description = "Kalender-Events und Erinnerungen verwalten (list_events, create_event, search_events, list_reminders, create_reminder)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "list_events | create_event | search_events | list_reminders | create_reminder", required: true),
                "title": ToolSchemaProperty(type: "string", description: "Titel des Events/Erinnerung"),
                "start": ToolSchemaProperty(type: "string", description: "Startdatum ISO 8601 (2026-02-22T14:00:00)"),
                "end": ToolSchemaProperty(type: "string", description: "Enddatum ISO 8601"),
                "days": ToolSchemaProperty(type: "string", description: "Tage voraus für list_events (Standard: 7)"),
                "query": ToolSchemaProperty(type: "string", description: "Suchbegriff"),
                "notes": ToolSchemaProperty(type: "string", description: "Notizen/Beschreibung"),
                "location": ToolSchemaProperty(type: "string", description: "Ort"),
            ],
            required: ["action"]
        )
    }

    private let store = EKEventStore()

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard permissionEnabled("kobold.perm.calendar") else {
            return "Kalender-Zugriff ist in den Einstellungen deaktiviert. Bitte unter Einstellungen → Berechtigungen aktivieren."
        }
        let action = arguments["action"] ?? ""

        switch action {
        case "list_events":
            return try await listEvents(arguments)
        case "create_event":
            return try await createEvent(arguments)
        case "search_events":
            return try await searchEvents(arguments)
        case "list_reminders":
            return try await listReminders()
        case "create_reminder":
            return try await createReminder(arguments)
        default:
            return "Unbekannte Aktion: \(action). Verfügbar: list_events, create_event, search_events, list_reminders, create_reminder"
        }
    }

    // MARK: - Access

    private func requestCalendarAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await store.requestAccess(to: .event)
        }
    }

    private func requestReminderAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToReminders()
        } else {
            return try await store.requestAccess(to: .reminder)
        }
    }

    // MARK: - Events

    private func listEvents(_ args: [String: String]) async throws -> String {
        guard try await requestCalendarAccess() else {
            return "Kein Zugriff auf Kalender. Bitte in Systemeinstellungen → Datenschutz → Kalender erlauben."
        }

        let days = Int(args["days"] ?? "7") ?? 7
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        if events.isEmpty { return "Keine Events in den nächsten \(days) Tagen." }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short; fmt.locale = Locale(identifier: "de_DE")

        var out = "Events der nächsten \(days) Tage (\(events.count)):\n\n"
        for event in events.prefix(30) {
            out += "- \(event.title ?? "Ohne Titel")\n"
            out += "  \(fmt.string(from: event.startDate)) - \(fmt.string(from: event.endDate))\n"
            if let loc = event.location, !loc.isEmpty { out += "  Ort: \(loc)\n" }
            if let notes = event.notes, !notes.isEmpty { out += "  Notiz: \(String(notes.prefix(80)))\n" }
        }
        return out
    }

    private func createEvent(_ args: [String: String]) async throws -> String {
        guard try await requestCalendarAccess() else { return "Kein Zugriff auf Kalender." }
        guard let title = args["title"], !title.isEmpty else { return "Titel fehlt." }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = store.defaultCalendarForNewEvents

        let iso = ISO8601DateFormatter()

        if let s = args["start"], let d = iso.date(from: s) { event.startDate = d }
        else { event.startDate = Date().addingTimeInterval(3600) }

        if let e = args["end"], let d = iso.date(from: e) { event.endDate = d }
        else { event.endDate = event.startDate.addingTimeInterval(3600) }

        if let n = args["notes"] { event.notes = n }
        if let l = args["location"] { event.location = l }

        try store.save(event, span: .thisEvent)

        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short; fmt.locale = Locale(identifier: "de_DE")
        return "Event erstellt: \"\(title)\" am \(fmt.string(from: event.startDate))"
    }

    private func searchEvents(_ args: [String: String]) async throws -> String {
        guard try await requestCalendarAccess() else { return "Kein Zugriff auf Kalender." }
        guard let query = args["query"], !query.isEmpty else { return "Suchbegriff fehlt." }

        let start = Calendar.current.date(byAdding: .month, value: -3, to: Date())!
        let end = Calendar.current.date(byAdding: .month, value: 3, to: Date())!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches = store.events(matching: predicate).filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.notes ?? "").localizedCaseInsensitiveContains(query)
        }

        if matches.isEmpty { return "Keine Events gefunden für: \"\(query)\"" }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short; fmt.locale = Locale(identifier: "de_DE")

        var out = "\(matches.count) Events für \"\(query)\":\n"
        for e in matches.prefix(20) {
            out += "- \(e.title ?? "") — \(fmt.string(from: e.startDate))\n"
        }
        return out
    }

    // MARK: - Reminders

    private func listReminders() async throws -> String {
        guard try await requestReminderAccess() else { return "Kein Zugriff auf Erinnerungen." }

        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { cont in
            store.fetchReminders(matching: predicate) { result in
                nonisolated(unsafe) let items = result ?? []
                cont.resume(returning: items)
            }
        }

        let incomplete = reminders.filter { !$0.isCompleted }
        if incomplete.isEmpty { return "Keine offenen Erinnerungen." }

        var out = "Offene Erinnerungen (\(incomplete.count)):\n"
        for r in incomplete.prefix(30) {
            out += "- \(r.title ?? "Ohne Titel")"
            if let due = r.dueDateComponents, let date = Calendar.current.date(from: due) {
                let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.locale = Locale(identifier: "de_DE")
                out += " (fällig: \(fmt.string(from: date)))"
            }
            out += "\n"
        }
        return out
    }

    private func createReminder(_ args: [String: String]) async throws -> String {
        guard try await requestReminderAccess() else { return "Kein Zugriff auf Erinnerungen." }
        guard let title = args["title"], !title.isEmpty else { return "Titel fehlt." }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let n = args["notes"] { reminder.notes = n }
        if let d = args["start"], let date = ISO8601DateFormatter().date(from: d) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }

        try store.save(reminder, commit: true)
        return "Erinnerung erstellt: \"\(title)\""
    }
}

#elseif os(Linux)
import Foundation

// MARK: - CalendarTool (Linux implementation - placeholder)
public struct CalendarTool: Tool, Sendable {
    public let name = "calendar"
    public let description = "Kalender-Events und Erinnerungen verwalten (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "list_events | create_event | search_events | list_reminders | create_reminder", required: true)
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        return "Kalender-Funktionen sind auf Linux deaktiviert. Verwenden Sie eine externe Kalenderlösung."
    }
}
#endif