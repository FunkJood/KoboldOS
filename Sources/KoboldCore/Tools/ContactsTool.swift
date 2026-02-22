import Foundation
import Contacts

// MARK: - ContactsTool
// Search and read contacts via Apple Contacts framework.

public struct ContactsTool: Tool, @unchecked Sendable {
    public let name = "contacts"
    public let description = "Kontakte durchsuchen (search) oder auflisten (list_recent)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "search | list_recent", required: true),
                "query": ToolSchemaProperty(type: "string", description: "Suchbegriff (Name)"),
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

        switch action {
        case "search":
            return try searchContacts(arguments)
        case "list_recent":
            return try listRecent()
        default:
            return "Unbekannte Aktion: \(action). Verfügbar: search, list_recent"
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
}
