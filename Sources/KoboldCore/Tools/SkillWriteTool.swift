import Foundation

// MARK: - SkillWriteTool — Agent can create, list, and delete skills

public struct SkillWriteTool: Tool, Sendable {

    public let name = "skill_write"
    public let description = "Create, list, or delete agent skills (markdown files)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action: create, list, delete",
                    enumValues: ["create", "list", "delete"],
                    required: true
                ),
                "name": ToolSchemaProperty(
                    type: "string",
                    description: "Skill name (for create/delete)"
                ),
                "content": ToolSchemaProperty(
                    type: "string",
                    description: "Skill content in markdown (for create)"
                )
            ],
            required: ["action"]
        )
    }

    private var skillsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        switch action {
        case "create":
            guard let name = arguments["name"], !name.isEmpty else {
                throw ToolError.missingRequired("name (required for create)")
            }
            guard let content = arguments["content"], !content.isEmpty else {
                throw ToolError.missingRequired("content (required for create)")
            }
            // Sanitize filename
            if name.contains("/") || name.contains("..") || name.contains("\\") {
                throw ToolError.invalidParameter("name", "must not contain /, \\, or ..")
            }
        case "delete":
            guard let name = arguments["name"], !name.isEmpty else {
                throw ToolError.missingRequired("name (required for delete)")
            }
            if name.contains("/") || name.contains("..") || name.contains("\\") {
                throw ToolError.invalidParameter("name", "must not contain /, \\, or ..")
            }
        case "list":
            break
        default:
            throw ToolError.invalidParameter("action", "must be 'create', 'list', or 'delete'")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let fm = FileManager.default
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        switch action {
        case "create":
            let name = arguments["name"]!
            let content = arguments["content"]!
            let sanitized = name.replacingOccurrences(of: " ", with: "_")
            let fileURL = skillsDir.appendingPathComponent("\(sanitized).md")
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            // Auto-enable the new skill
            await SkillLoader.shared.setEnabled(sanitized, enabled: true)

            return "Skill '\(sanitized)' erstellt und aktiviert: \(fileURL.path)"

        case "list":
            let skills = await SkillLoader.shared.loadSkills()
            if skills.isEmpty { return "Keine Skills vorhanden." }
            let lines = skills.map { "• \($0.name) [\($0.isEnabled ? "aktiv" : "inaktiv")]" }
            return "Skills (\(skills.count)):\n" + lines.joined(separator: "\n")

        case "delete":
            let name = arguments["name"]!
            let sanitized = name.replacingOccurrences(of: " ", with: "_")
            let fileURL = skillsDir.appendingPathComponent("\(sanitized).md")
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
                await SkillLoader.shared.setEnabled(sanitized, enabled: false)
                return "Skill '\(sanitized)' gelöscht."
            } else {
                return "Skill '\(sanitized)' nicht gefunden."
            }

        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }
}
