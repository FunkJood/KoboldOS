#if os(macOS)
import Foundation
import Security

// MARK: - SecretsTool (macOS)
/// Lets the agent access KoboldOS-stored secrets and optionally search the macOS system Keychain.
/// Gated by kobold.perm.secrets (default: false) and kobold.perm.systemKeychain (default: false).
public struct SecretsTool: Tool {
    public let name = "secrets"
    public let description = "Manage stored secrets (passwords, API keys). Actions: list, get, set, delete, search_keychain."
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Action to perform", enumValues: ["list", "get", "set", "delete", "search_keychain"], required: true),
            "key": ToolSchemaProperty(type: "string", description: "Secret key name (required for get/set/delete)"),
            "value": ToolSchemaProperty(type: "string", description: "Secret value to store (required for set)"),
            "service": ToolSchemaProperty(type: "string", description: "Service/domain to search in system Keychain (for search_keychain, e.g. 'github.com')")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        let needsKey = ["get", "set", "delete"]
        if needsKey.contains(action) {
            guard let key = arguments["key"], !key.isEmpty else {
                throw ToolError.missingRequired("key")
            }
            if action == "set" {
                guard let value = arguments["value"], !value.isEmpty else {
                    throw ToolError.missingRequired("value")
                }
                _ = value // suppress unused warning
            }
            _ = key
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        guard permissionEnabled("kobold.perm.secrets", defaultValue: true) else {
            return "Fehler: Secret-Zugriff ist in den Einstellungen deaktiviert. Aktiviere 'Secrets & Passwörter' unter Einstellungen → Berechtigungen."
        }

        let action = arguments["action"] ?? ""
        let key = arguments["key"] ?? ""

        switch action {
        case "list":
            let keys = await SecretStore.shared.allKeys()
            if keys.isEmpty {
                return "Keine Secrets gespeichert. Nutze action=set um ein Secret zu speichern."
            }
            return "Gespeicherte Secrets (\(keys.count)):\n" + keys.map { "• \($0)" }.joined(separator: "\n")

        case "get":
            if let value = await SecretStore.shared.get(key) {
                return value
            }
            return "Fehler: Secret '\(key)' nicht gefunden. Nutze action=list um verfügbare Keys zu sehen."

        case "set":
            let value = arguments["value"] ?? ""
            await SecretStore.shared.set(value, forKey: key)
            return "Secret '\(key)' gespeichert."

        case "delete":
            await SecretStore.shared.delete(key)
            return "Secret '\(key)' gelöscht."

        case "search_keychain":
            guard permissionEnabled("kobold.perm.systemKeychain", defaultValue: false) else {
                return "Fehler: System-Schlüsselbund-Zugriff ist deaktiviert. Aktiviere 'System-Schlüsselbund' unter Einstellungen → Berechtigungen."
            }
            let service = arguments["service"] ?? ""
            return searchSystemKeychain(service: service.isEmpty ? nil : service)

        default:
            return "Fehler: Unbekannte Aktion '\(action)'. Verfügbar: list, get, set, delete, search_keychain"
        }
    }

    // MARK: - System Keychain Search

    /// Search the macOS login Keychain for internet/generic passwords matching a service string.
    private func searchSystemKeychain(service: String?) -> String {
        var results: [(service: String, account: String, password: String)] = []

        // Search generic passwords (apps, tools)
        results.append(contentsOf: searchKeychainClass(kSecClassGenericPassword, service: service))
        // Search internet passwords (Safari, browsers)
        results.append(contentsOf: searchKeychainClass(kSecClassInternetPassword, service: service))

        if results.isEmpty {
            if let svc = service {
                return "Keine Keychain-Einträge für '\(svc)' gefunden."
            }
            return "Keine Keychain-Einträge gefunden (oder Zugriff verweigert)."
        }

        let header = service != nil
            ? "Keychain-Einträge für '\(service!)' (\(results.count)):"
            : "Keychain-Einträge (\(results.count)):"

        let lines = results.prefix(20).map { entry in
            "• \(entry.service) — Account: \(entry.account) — Passwort: \(entry.password)"
        }

        var output = header + "\n" + lines.joined(separator: "\n")
        if results.count > 20 {
            output += "\n... und \(results.count - 20) weitere Einträge"
        }
        return output
    }

    private func searchKeychainClass(_ secClass: CFString, service: String?) -> [(service: String, account: String, password: String)] {
        var query: [String: Any] = [
            kSecClass as String: secClass,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        if let service = service, !service.isEmpty {
            // For generic passwords: kSecAttrService
            // For internet passwords: kSecAttrServer
            if secClass == kSecClassInternetPassword {
                query[kSecAttrServer as String] = service
            } else {
                query[kSecAttrService as String] = service
            }
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            let svc: String
            if secClass == kSecClassInternetPassword {
                svc = item[kSecAttrServer as String] as? String ?? "(unbekannt)"
            } else {
                svc = item[kSecAttrService as String] as? String ?? "(unbekannt)"
            }
            let account = item[kSecAttrAccount as String] as? String ?? "(kein Account)"
            let password: String
            if let data = item[kSecValueData as String] as? Data {
                password = String(data: data, encoding: .utf8) ?? "(binary)"
            } else {
                password = "(nicht lesbar)"
            }
            return (service: svc, account: account, password: password)
        }
    }
}

#elseif os(Linux)
import Foundation

// MARK: - SecretsTool (Linux placeholder)
public struct SecretsTool: Tool {
    public let name = "secrets"
    public let description = "Manage stored secrets (passwords, API keys)"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Action", required: true)
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {}

    public func execute(arguments: [String: String]) async throws -> String {
        return "Secret-Verwaltung ist auf Linux eingeschränkt. Nutze Umgebungsvariablen oder die config-Datei."
    }
}
#endif
