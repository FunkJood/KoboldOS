import Foundation

// MARK: - SettingsReadTool
/// Lets the agent read and write its own settings (kobold.* UserDefaults keys).
/// Gated by kobold.perm.settings (default: true).
public struct SettingsReadTool: Tool {
    public let name = "settings"
    public let description = "Read or change KoboldOS settings. Actions: get (read a setting), set (change a setting), list (show all kobold.* settings)."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Action to perform", enumValues: ["get", "set", "list"], required: true),
            "key": ToolSchemaProperty(type: "string", description: "Setting key (for get/set, e.g. 'kobold.perm.secrets')"),
            "value": ToolSchemaProperty(type: "string", description: "New value (for set). Use 'true'/'false' for booleans, numbers as strings.")
        ], required: ["action"])
    }

    public init() {}

    /// Keys the agent must NEVER read (security-sensitive).
    private static let blacklist: Set<String> = [
        "kobold.auth.token"
    ]

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        if action == "get" || action == "set" {
            guard let key = arguments["key"], !key.isEmpty else {
                throw ToolError.missingRequired("key")
            }
            _ = key
        }
        if action == "set" {
            guard let value = arguments["value"], !value.isEmpty else {
                throw ToolError.missingRequired("value")
            }
            _ = value
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        guard permissionEnabled("kobold.perm.settings", defaultValue: true) else {
            return "Fehler: Einstellungszugriff ist deaktiviert. Aktiviere 'Einstellungen lesen/ändern' unter Einstellungen → Berechtigungen."
        }

        let action = arguments["action"] ?? ""

        switch action {
        case "list":
            return listKoboldSettings()

        case "get":
            let key = arguments["key"] ?? ""
            return getSettingValue(key: key)

        case "set":
            let key = arguments["key"] ?? ""
            let value = arguments["value"] ?? ""
            return setSettingValue(key: key, value: value)

        default:
            return "Fehler: Unbekannte Aktion '\(action)'. Verfügbar: get, set, list"
        }
    }

    // MARK: - List

    private func listKoboldSettings() -> String {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        let koboldKeys = dict.keys.filter { $0.hasPrefix("kobold.") }.sorted()

        if koboldKeys.isEmpty {
            return "Keine kobold.*-Einstellungen gefunden."
        }

        let lines = koboldKeys.compactMap { key -> String? in
            if Self.blacklist.contains(key) { return "• \(key) = [geschützt]" }
            let val = defaults.object(forKey: key)
            return "• \(key) = \(stringValue(val))"
        }

        return "KoboldOS-Einstellungen (\(koboldKeys.count)):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Get

    private func getSettingValue(key: String) -> String {
        if Self.blacklist.contains(key) {
            return "Fehler: Zugriff auf '\(key)' ist aus Sicherheitsgründen gesperrt."
        }
        guard key.hasPrefix("kobold.") else {
            return "Fehler: Nur kobold.*-Einstellungen können gelesen werden. Key '\(key)' hat kein 'kobold.'-Prefix."
        }
        let val = UserDefaults.standard.object(forKey: key)
        if val == nil {
            return "Einstellung '\(key)' ist nicht gesetzt (Standard-Wert wird verwendet)."
        }
        return "\(key) = \(stringValue(val))"
    }

    // MARK: - Set

    private func setSettingValue(key: String, value: String) -> String {
        if Self.blacklist.contains(key) {
            return "Fehler: '\(key)' darf nicht geändert werden."
        }
        guard key.hasPrefix("kobold.") else {
            return "Fehler: Nur kobold.*-Einstellungen können geändert werden. Key '\(key)' hat kein 'kobold.'-Prefix."
        }

        let defaults = UserDefaults.standard

        // Parse value type
        switch value.lowercased() {
        case "true":
            defaults.set(true, forKey: key)
        case "false":
            defaults.set(false, forKey: key)
        default:
            if let intVal = Int(value) {
                defaults.set(intVal, forKey: key)
            } else if let doubleVal = Double(value) {
                defaults.set(doubleVal, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }

        return "Einstellung '\(key)' auf '\(value)' gesetzt."
    }

    // MARK: - Helpers

    private func stringValue(_ val: Any?) -> String {
        switch val {
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return "\(i)"
        case let d as Double: return "\(d)"
        case let s as String: return "\"\(s)\""
        case let a as [Any]: return "[\(a.count) items]"
        case let dict as [String: Any]: return "{\(dict.count) keys}"
        default: return String(describing: val ?? "nil")
        }
    }
}
