import Foundation

// MARK: - Self Awareness Tool
// Gibt dem Agenten Bewusstsein über sich selbst als KoboldOS und den aktuellen App-Zustand.
// Der Agent kann: Settings lesen/ändern, UI-State abfragen, auf Änderungen reagieren.

public struct SelfAwarenessTool: Tool {
    public let name = "self_awareness"
    public let description = """
        KoboldOS Selbst-Bewusstsein: Du bist Kobold, ein Agent der in KoboldOS lebt. \
        Mit diesem Tool kannst du deinen eigenen Zustand abfragen und Einstellungen lesen/ändern. \
        Actions: get_state (App-Zustand), read_setting (Einstellung lesen), \
        write_setting (Einstellung ändern, braucht Berechtigung), \
        get_active_tab (welchen Tab sieht der User), get_sessions (Chat/Task/Workflow Sessions), \
        get_notifications (ausstehende Benachrichtigungen), observe_changes (letzte Änderungen).
        """
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion: get_state, read_setting, write_setting, get_active_tab, get_sessions, get_notifications, observe_changes",
                    enumValues: ["get_state", "read_setting", "write_setting", "get_active_tab", "get_sessions", "get_notifications", "observe_changes"],
                    required: true
                ),
                "key": ToolSchemaProperty(
                    type: "string",
                    description: "UserDefaults Key für read_setting/write_setting (z.B. 'kobold.agent.name', 'kobold.personality.soul')"
                ),
                "value": ToolSchemaProperty(
                    type: "string",
                    description: "Neuer Wert für write_setting"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {
        case "get_state":
            return getAppState()

        case "read_setting":
            guard let key = arguments["key"], !key.isEmpty else {
                throw ToolError.missingRequired("key")
            }
            return readSetting(key: key)

        case "write_setting":
            guard permissionEnabled("kobold.permission.selfModify", defaultValue: false) else {
                return "[Selbst-Modifikation ist deaktiviert. Der User muss diese Berechtigung in Einstellungen → Apps aktivieren.]"
            }
            guard let key = arguments["key"], !key.isEmpty else {
                throw ToolError.missingRequired("key")
            }
            guard let value = arguments["value"] else {
                throw ToolError.missingRequired("value")
            }
            return await writeSetting(key: key, value: value)

        case "get_active_tab":
            return await getActiveTab()

        case "get_sessions":
            return await getSessions()

        case "get_notifications":
            return await getNotifications()

        case "observe_changes":
            return getRecentChanges()

        default:
            return "[Unbekannte Aktion: \(action)]"
        }
    }

    // MARK: - State

    private func getAppState() -> String {
        let version = "v0.3.4 Alpha"
        let agentName = UserDefaults.standard.string(forKey: "kobold.agent.name") ?? "Kobold"
        let personality = UserDefaults.standard.string(forKey: "kobold.personality.soul") ?? "(Standard)"
        let model = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "unbekannt"
        let heartbeat = UserDefaults.standard.bool(forKey: "kobold.proactive.heartbeatEnabled")
        let terminalPerm = UserDefaults.standard.bool(forKey: "kobold.permission.appTerminal")
        let browserPerm = UserDefaults.standard.bool(forKey: "kobold.permission.appBrowser")

        return """
        === KoboldOS State ===
        Version: \(version)
        Agent-Name: \(agentName)
        Persönlichkeit: \(String(personality.prefix(100)))
        Modell: \(model)
        Heartbeat: \(heartbeat ? "aktiv" : "inaktiv")
        Berechtigungen:
          Terminal-Steuerung: \(terminalPerm ? "ja" : "nein")
          Browser-Steuerung: \(browserPerm ? "ja" : "nein")
        """
    }

    private func readSetting(key: String) -> String {
        // Safety: Nur kobold.* Keys erlauben
        guard key.hasPrefix("kobold.") else {
            return "[Nur kobold.* Keys sind erlaubt]"
        }

        if let val = UserDefaults.standard.string(forKey: key) {
            return "\(key) = \(val)"
        } else if UserDefaults.standard.object(forKey: key) != nil {
            let val = UserDefaults.standard.bool(forKey: key)
            return "\(key) = \(val)"
        } else {
            return "\(key) = (nicht gesetzt)"
        }
    }

    private func writeSetting(key: String, value: String) async -> String {
        guard key.hasPrefix("kobold.") else {
            return "[Nur kobold.* Keys sind erlaubt]"
        }

        // Blockliste für sicherheitskritische Keys
        let blocked = ["kobold.authToken", "kobold.port", "kobold.permission."]
        for b in blocked {
            if key.hasPrefix(b) {
                return "[Sicherheitskritischer Key '\(key)' kann nicht vom Agent geändert werden]"
            }
        }

        await MainActor.run {
            // Boolean-Erkennung
            if value.lowercased() == "true" || value.lowercased() == "false" {
                UserDefaults.standard.set(value.lowercased() == "true", forKey: key)
            } else if let intVal = Int(value) {
                UserDefaults.standard.set(intVal, forKey: key)
            } else {
                UserDefaults.standard.set(value, forKey: key)
            }

            // Notify about the change
            NotificationCenter.default.post(
                name: Notification.Name("koboldSettingChanged"),
                object: nil,
                userInfo: ["key": key, "value": value, "by": "agent"]
            )
        }

        return "Einstellung geändert: \(key) = \(value)"
    }

    private func getActiveTab() async -> String {
        // The active tab is tracked via NotificationCenter — we read the last known state
        let tab = UserDefaults.standard.string(forKey: "kobold.ui.activeTab") ?? "unknown"
        let subTab = UserDefaults.standard.string(forKey: "kobold.ui.activeAppSubTab") ?? ""
        var result = "Aktiver Tab: \(tab)"
        if !subTab.isEmpty { result += " (Sub-Tab: \(subTab))" }
        return result
    }

    private func getSessions() async -> String {
        var result = "=== Sessions ===\n"
        let resultId = UUID().uuidString
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldSelfAwareness"),
                object: nil,
                userInfo: ["action": "get_sessions", "result_id": resultId]
            )
        }
        // Für synchrone Antwort direkt aus UserDefaults lesen
        let chatCount = UserDefaults.standard.integer(forKey: "kobold.stats.sessionCount")
        let taskCount = UserDefaults.standard.integer(forKey: "kobold.stats.taskSessionCount")
        let workflowCount = UserDefaults.standard.integer(forKey: "kobold.stats.workflowSessionCount")
        result += "Chat-Sessions: \(chatCount)\n"
        result += "Task-Sessions: \(taskCount)\n"
        result += "Workflow-Sessions: \(workflowCount)\n"
        return result
    }

    private func getNotifications() async -> String {
        let resultId = UUID().uuidString
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldSelfAwareness"),
                object: nil,
                userInfo: ["action": "get_notifications", "result_id": resultId]
            )
        }
        let result = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: 5)
        return result ?? "Keine ausstehenden Benachrichtigungen."
    }

    private func getRecentChanges() -> String {
        // Read from a change log that's maintained by the settings observers
        let changes = UserDefaults.standard.stringArray(forKey: "kobold.recentChanges") ?? []
        if changes.isEmpty {
            return "Keine kürzlichen Änderungen beobachtet."
        }
        return "Letzte Änderungen:\n" + changes.suffix(10).joined(separator: "\n")
    }
}
