import Foundation

// MARK: - TeamsTool (Agent-Teams verwalten)

public struct TeamsTool: Tool, Sendable {
    public let name = "teams"
    public let description = "Agent-Teams verwalten: list_teams, create_team, update_team, delete_team, add_member, remove_member"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(type: "string", description: "list_teams | create_team | update_team | delete_team | add_member | remove_member", required: true),
                "team_id": ToolSchemaProperty(type: "string", description: "Team-ID (für update/delete/add_member/remove_member)"),
                "name": ToolSchemaProperty(type: "string", description: "Team-Name (für create/update)"),
                "description": ToolSchemaProperty(type: "string", description: "Team-Beschreibung"),
                "routing": ToolSchemaProperty(type: "string", description: "Routing-Modus: sequential | leader | round-robin"),
                "member_name": ToolSchemaProperty(type: "string", description: "Agent-Name des Mitglieds (für add_member/remove_member)"),
                "member_role": ToolSchemaProperty(type: "string", description: "Rolle des Mitglieds (z.B. 'coder', 'web', 'reviewer')"),
                "member_prompt": ToolSchemaProperty(type: "string", description: "System-Prompt des Mitglieds"),
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let daemonPort = UserDefaults.standard.integer(forKey: "kobold.daemon.port")
        let port = daemonPort > 0 ? daemonPort : 8080
        let baseURL = "http://localhost:\(port)"
        let token = UserDefaults.standard.string(forKey: "kobold.authToken") ?? ""

        switch action {
        case "list_teams":
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let teams = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return String(data: data, encoding: .utf8) ?? "Keine Daten"
            }
            if teams.isEmpty { return "Keine Teams angelegt." }
            return formatTeams(teams)

        case "create_team":
            guard let name = arguments["name"], !name.isEmpty else { return "Fehlend: 'name'" }
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["action": "create", "name": name]
            if let desc = arguments["description"] { body["description"] = desc }
            if let routing = arguments["routing"] { body["routing"] = routing }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Team erstellt"

        case "update_team":
            guard let teamId = arguments["team_id"], !teamId.isEmpty else { return "Fehlend: 'team_id'" }
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["action": "update", "id": teamId]
            if let name = arguments["name"] { body["name"] = name }
            if let desc = arguments["description"] { body["description"] = desc }
            if let routing = arguments["routing"] { body["routing"] = routing }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Team aktualisiert"

        case "delete_team":
            guard let teamId = arguments["team_id"], !teamId.isEmpty else { return "Fehlend: 'team_id'" }
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "delete", "id": teamId])
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Team gelöscht"

        case "add_member":
            guard let teamId = arguments["team_id"], !teamId.isEmpty else { return "Fehlend: 'team_id'" }
            guard let memberName = arguments["member_name"], !memberName.isEmpty else { return "Fehlend: 'member_name'" }
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var memberData: [String: Any] = ["name": memberName, "role": arguments["member_role"] ?? "general"]
            if let prompt = arguments["member_prompt"] { memberData["systemPrompt"] = prompt }
            let body: [String: Any] = ["action": "update", "id": teamId, "add_member": memberData]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Mitglied hinzugefügt"

        case "remove_member":
            guard let teamId = arguments["team_id"], !teamId.isEmpty else { return "Fehlend: 'team_id'" }
            guard let memberName = arguments["member_name"], !memberName.isEmpty else { return "Fehlend: 'member_name'" }
            guard let url = URL(string: "\(baseURL)/teams") else { return "Ungültige URL" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "action": "update", "id": teamId, "remove_member": memberName
            ] as [String: Any])
            let (respData, _) = try await URLSession.shared.data(for: req)
            return String(data: respData, encoding: .utf8) ?? "Mitglied entfernt"

        default:
            return "Unbekannte Aktion: \(action). Verfügbar: list_teams, create_team, update_team, delete_team, add_member, remove_member"
        }
    }

    private func formatTeams(_ teams: [[String: Any]]) -> String {
        var out = "\(teams.count) Teams:\n\n"
        for team in teams {
            let name = team["name"] as? String ?? "?"
            let desc = team["description"] as? String ?? ""
            let routing = team["routing"] as? String ?? "sequential"
            let members = team["members"] as? [[String: Any]] ?? []
            out += "**\(name)** [\(routing)]\n"
            if !desc.isEmpty { out += "  \(desc)\n" }
            if members.isEmpty {
                out += "  Keine Mitglieder\n"
            } else {
                for m in members {
                    let mName = m["name"] as? String ?? "?"
                    let mRole = m["role"] as? String ?? ""
                    out += "  - \(mName) (\(mRole))\n"
                }
            }
            out += "\n"
        }
        return out
    }
}
