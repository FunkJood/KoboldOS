import Foundation

// MARK: - WorkflowManageTool — Agent can create, list, and delete workflow definitions

public struct WorkflowManageTool: Tool, Sendable {

    public let name = "workflow_manage"
    public let description = "Create, list, or delete workflow definitions"
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
                    description: "Workflow name"
                ),
                "description": ToolSchemaProperty(
                    type: "string",
                    description: "Workflow description"
                ),
                "steps": ToolSchemaProperty(
                    type: "string",
                    description: "JSON array of workflow step objects [{\"agent\":\"coder\",\"prompt\":\"...\"}]"
                ),
                "id": ToolSchemaProperty(
                    type: "string",
                    description: "Workflow ID (for delete)"
                )
            ],
            required: ["action"]
        )
    }

    private var workflowsFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/workflows.json")
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
        case "delete":
            guard let id = arguments["id"], !id.isEmpty else {
                throw ToolError.missingRequired("id (required for delete)")
            }
        case "list":
            break
        default:
            throw ToolError.invalidParameter("action", "must be 'create', 'list', or 'delete'")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        var workflows = loadWorkflows()

        switch action {
        case "create":
            let name = arguments["name"]!
            let desc = arguments["description"] ?? ""
            let stepsJSON = arguments["steps"] ?? "[]"
            let workflow = WorkflowDefinition(
                id: UUID().uuidString,
                name: name,
                description: desc,
                steps: stepsJSON,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            workflows.append(workflow)
            saveWorkflows(workflows)
            return "Workflow '\(name)' erstellt (ID: \(workflow.id.prefix(8)))."

        case "list":
            if workflows.isEmpty { return "Keine Workflows vorhanden." }
            let lines = workflows.map { w in
                "• \(w.name) — \(w.description.isEmpty ? "Keine Beschreibung" : w.description) (ID: \(w.id.prefix(8)))"
            }
            return "Workflows (\(workflows.count)):\n" + lines.joined(separator: "\n")

        case "delete":
            let id = arguments["id"]!
            guard let idx = workflows.firstIndex(where: { $0.id.hasPrefix(id) || $0.id == id }) else {
                return "Workflow mit ID '\(id)' nicht gefunden."
            }
            let name = workflows[idx].name
            workflows.remove(at: idx)
            saveWorkflows(workflows)
            return "Workflow '\(name)' gelöscht."

        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }

    // MARK: - Persistence

    private func loadWorkflows() -> [WorkflowDefinition] {
        guard let data = try? Data(contentsOf: workflowsFileURL),
              let workflows = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) else {
            return []
        }
        return workflows
    }

    private func saveWorkflows(_ workflows: [WorkflowDefinition]) {
        let dir = workflowsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(workflows) {
            try? data.write(to: workflowsFileURL)
        }
    }
}

// MARK: - WorkflowDefinition Model

public struct WorkflowDefinition: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var steps: String  // JSON array string
    public var createdAt: String

    public init(id: String, name: String, description: String, steps: String, createdAt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.createdAt = createdAt
    }
}
