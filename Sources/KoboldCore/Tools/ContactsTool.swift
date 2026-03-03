#if os(macOS)
import Foundation
import Contacts

// MARK: - ContactsTool (macOS implementation)
public struct ContactsTool: Tool, @unchecked Sendable {
    public let name = "contacts"
    public let description = "Apple-Kontakte durchsuchen (search, list_recent) und CRM verwalten (crm_list, crm_create, crm_update, crm_delete, crm_search)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "search | list_recent | crm_list | crm_create | crm_update | crm_delete | crm_search", required: true),
                "query": ToolSchemaProperty(type: "string", description: "Suchbegriff (Name oder Text)"),
                "collection": ToolSchemaProperty(type: "string", description: "CRM-Sammlung: contacts | companies | deals | activities (für crm_* Aktionen)"),
                "data": ToolSchemaProperty(type: "string", description: "JSON-String mit Feldern für crm_create/crm_update (z.B. '{\"firstName\":\"Max\",\"lastName\":\"Muster\",\"email\":\"max@test.de\"}')", required: false),
                "id": ToolSchemaProperty(type: "string", description: "ID für crm_update/crm_delete"),
            ],
            required: ["action"]
        )
    }

    private let store = CNContactStore()

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard permissionEnabled("kobold.perm.contacts", defaultValue: false) else {
            return "Kontakte-Zugriff ist in den Einstellungen deaktiviert. Bitte unter Einstellungen → Berechtigungen aktivieren."
        }
        let action = arguments["action"] ?? ""

        // Check authorization status FIRST — only request if never asked before
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .denied, .restricted:
            return "Kein Zugriff auf Kontakte. Bitte in Systemeinstellungen → Datenschutz → Kontakte erlauben."
        case .notDetermined:
            // First time: request access (triggers system dialog once)
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestAccess(for: .contacts)
            } else {
                granted = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(for: .contacts) { ok, err in
                        if let err { cont.resume(throwing: err) }
                        else { cont.resume(returning: ok) }
                    }
                }
            }
            guard granted else {
                return "Kein Zugriff auf Kontakte. Bitte in Systemeinstellungen → Datenschutz → Kontakte erlauben."
            }
        case .authorized:
            break // Already granted — no dialog needed
        @unknown default:
            break
        }

        switch action {
        case "search":
            return try searchContacts(arguments)
        case "list_recent":
            return try listRecent()
        case "crm_list", "crm_create", "crm_update", "crm_delete", "crm_search":
            return try await crmAction(action: action, arguments: arguments)
        default:
            return "Unbekannte Aktion: \(action). Verfügbar: search, list_recent, crm_list, crm_create, crm_update, crm_delete, crm_search"
        }
    }

    private func searchContacts(_ args: [String: String]) throws -> String {
        guard let query = args["query"], !query.isEmpty else { return "Suchbegriff (query) fehlt." }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

        if contacts.isEmpty { return "Keine Kontakte gefunden für: \"\(query)\"" }

        var out = "\(contacts.count) Kontakte für \"\(query)\":\n\n"
        for c in contacts.prefix(15) { out += formatContact(c) }
        return out
    }

    private func listRecent() throws -> String {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .familyName

        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, stop in
            contacts.append(contact)
            if contacts.count >= 20 { stop.pointee = true }
        }

        if contacts.isEmpty { return "Keine Kontakte." }

        var out = "Kontakte (\(contacts.count)):\n"
        for c in contacts {
            let name = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
            let phone = c.phoneNumbers.first?.value.stringValue ?? ""
            let email = (c.emailAddresses.first?.value as String?) ?? ""
            out += "- \(name)"
            if !phone.isEmpty { out += " | \(phone)" }
            if !email.isEmpty { out += " | \(email)" }
            out += "\n"
        }
        return out
    }

    private func formatContact(_ c: CNContact) -> String {
        var out = "- \(c.givenName) \(c.familyName)\n"
        if !c.organizationName.isEmpty { out += "  Firma: \(c.organizationName)\n" }
        for p in c.phoneNumbers { out += "  Tel: \(p.value.stringValue)\n" }
        for e in c.emailAddresses { out += "  Email: \(e.value as String)\n" }
        if let b = c.birthday, let d = Calendar.current.date(from: b) {
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.locale = Locale(identifier: "de_DE")
            out += "  Geburtstag: \(fmt.string(from: d))\n"
        }
        return out + "\n"
    }

    // MARK: - CRM Actions (via Daemon API)

    private func crmAction(action: String, arguments: [String: String]) async throws -> String {
        let collection = arguments["collection"] ?? "contacts"
        let daemonPort = UserDefaults.standard.integer(forKey: "kobold.daemon.port")
        let port = daemonPort > 0 ? daemonPort : 8080
        let baseURL = "http://localhost:\(port)"

        // Bearer token from settings
        let token = UserDefaults.standard.string(forKey: "kobold.auth.token") ?? ""

        switch action {
        case "crm_list":
            guard let url = URL(string: "\(baseURL)/\(collection)") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return String(data: data, encoding: .utf8) ?? "Keine Daten"
            }
            if json.isEmpty { return "Keine \(collection) gefunden." }
            return formatCRMList(json, collection: collection)

        case "crm_create":
            guard let dataStr = arguments["data"], !dataStr.isEmpty else { return "Fehlend: 'data' (JSON-String mit Feldern)" }
            guard let url = URL(string: "\(baseURL)/\(collection)") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Parse and wrap data
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any] else {
                return "Ungültiges JSON in 'data'"
            }
            var body = parsed
            body["action"] = "create"
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Erstellt"

        case "crm_update":
            guard let id = arguments["id"], !id.isEmpty else { return "Fehlend: 'id'" }
            guard let dataStr = arguments["data"], !dataStr.isEmpty else { return "Fehlend: 'data' (JSON-String mit zu ändernden Feldern)" }
            guard let url = URL(string: "\(baseURL)/\(collection)") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard var body = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any] else {
                return "Ungültiges JSON in 'data'"
            }
            body["action"] = "update"
            body["id"] = id
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Aktualisiert"

        case "crm_delete":
            guard let id = arguments["id"], !id.isEmpty else { return "Fehlend: 'id'" }
            guard let url = URL(string: "\(baseURL)/\(collection)") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "delete", "id": id])
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Gelöscht"

        case "crm_search":
            let query = arguments["query"] ?? ""
            guard !query.isEmpty else { return "Fehlend: 'query' (Suchbegriff)" }
            guard let url = URL(string: "\(baseURL)/\(collection)?search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return String(data: data, encoding: .utf8) ?? "Keine Daten"
            }
            if json.isEmpty { return "Keine Ergebnisse für '\(query)' in \(collection)." }
            return formatCRMList(json, collection: collection)

        default:
            return "Unbekannte CRM-Aktion: \(action)"
        }
    }

    private func formatCRMList(_ items: [[String: Any]], collection: String) -> String {
        var out = "\(items.count) \(collection):\n\n"
        for item in items.prefix(20) {
            switch collection {
            case "contacts":
                let first = item["firstName"] as? String ?? ""
                let last = item["lastName"] as? String ?? ""
                let email = item["email"] as? String ?? ""
                let status = item["status"] as? String ?? ""
                out += "- \(first) \(last)"
                if !email.isEmpty { out += " | \(email)" }
                if !status.isEmpty { out += " [\(status)]" }
                out += "\n"
            case "companies":
                let name = item["name"] as? String ?? "?"
                let industry = item["industry"] as? String ?? ""
                out += "- \(name)"
                if !industry.isEmpty { out += " (\(industry))" }
                out += "\n"
            case "deals":
                let title = item["title"] as? String ?? "?"
                let value = item["value"] as? Double ?? 0
                let stage = item["stage"] as? String ?? ""
                out += "- \(title) — \(String(format: "%.0f€", value)) [\(stage)]\n"
            case "activities":
                let type = item["type"] as? String ?? "?"
                let desc = item["description"] as? String ?? ""
                out += "- [\(type)] \(desc.prefix(60))\n"
            default:
                let id = item["id"] as? String ?? "?"
                out += "- \(id): \(item.description.prefix(80))\n"
            }
        }
        if items.count > 20 { out += "... und \(items.count - 20) weitere\n" }
        return out
    }
}

#elseif os(Linux)
import Foundation

// MARK: - ContactsTool (Linux implementation - placeholder)
public struct ContactsTool: Tool, Sendable {
    public let name = "contacts"
    public let description = "Kontakte durchsuchen (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "search | list_recent", required: true)
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        return "Kontakte-Funktionen sind auf Linux deaktiviert. Verwenden Sie eine externe Kontaktverwaltung."
    }
}
#endif