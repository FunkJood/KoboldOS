import Foundation

// MARK: - TaskManageTool — Agent can create, list, update, and delete scheduled tasks

public struct TaskManageTool: Tool, Sendable {

    public let name = "task_manage"
    public let description = "Create, list, update, or delete scheduled tasks"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action: create, list, update, delete",
                    enumValues: ["create", "list", "update", "delete"],
                    required: true
                ),
                "name": ToolSchemaProperty(
                    type: "string",
                    description: "Task name"
                ),
                "prompt": ToolSchemaProperty(
                    type: "string",
                    description: "Prompt to execute for this task"
                ),
                "schedule": ToolSchemaProperty(
                    type: "string",
                    description: "Cron schedule expression (e.g. '0 8 * * *' for daily 8AM)"
                ),
                "enabled": ToolSchemaProperty(
                    type: "string",
                    description: "Whether the task is enabled ('true' or 'false')"
                ),
                "id": ToolSchemaProperty(
                    type: "string",
                    description: "Task ID (for update/delete)"
                )
            ],
            required: ["action"]
        )
    }

    private var tasksFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/tasks.json")
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
            guard let prompt = arguments["prompt"], !prompt.isEmpty else {
                throw ToolError.missingRequired("prompt (required for create)")
            }
        case "update", "delete":
            guard let id = arguments["id"], !id.isEmpty else {
                throw ToolError.missingRequired("id (required for \(action))")
            }
        case "list":
            break
        default:
            throw ToolError.invalidParameter("action", "must be 'create', 'list', 'update', or 'delete'")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        var tasks = loadTasks()

        switch action {
        case "create":
            let name = arguments["name"]!
            let prompt = arguments["prompt"]!
            let schedule = arguments["schedule"] ?? "0 8 * * *"
            let enabled = arguments["enabled"] != "false"
            let task = ScheduledTask(
                id: UUID().uuidString,
                name: name,
                prompt: prompt,
                schedule: schedule,
                enabled: enabled,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            tasks.append(task)
            saveTasks(tasks)
            return "Aufgabe '\(name)' erstellt (ID: \(task.id.prefix(8))). Zeitplan: \(schedule)"

        case "list":
            if tasks.isEmpty { return "Keine Aufgaben vorhanden." }
            let lines = tasks.map { t in
                "• [\(t.enabled ? "aktiv" : "pausiert")] \(t.name) — \(t.schedule) (ID: \(t.id.prefix(8)))"
            }
            return "Aufgaben (\(tasks.count)):\n" + lines.joined(separator: "\n")

        case "update":
            let id = arguments["id"]!
            guard let idx = tasks.firstIndex(where: { $0.id.hasPrefix(id) || $0.id == id }) else {
                return "Aufgabe mit ID '\(id)' nicht gefunden."
            }
            if let name = arguments["name"] { tasks[idx].name = name }
            if let prompt = arguments["prompt"] { tasks[idx].prompt = prompt }
            if let schedule = arguments["schedule"] { tasks[idx].schedule = schedule }
            if let enabled = arguments["enabled"] { tasks[idx].enabled = enabled == "true" }
            saveTasks(tasks)
            return "Aufgabe '\(tasks[idx].name)' aktualisiert."

        case "delete":
            let id = arguments["id"]!
            guard let idx = tasks.firstIndex(where: { $0.id.hasPrefix(id) || $0.id == id }) else {
                return "Aufgabe mit ID '\(id)' nicht gefunden."
            }
            let name = tasks[idx].name
            tasks.remove(at: idx)
            saveTasks(tasks)
            return "Aufgabe '\(name)' gelöscht."

        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }

    // MARK: - Persistence

    private func loadTasks() -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: tasksFileURL),
              let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) else {
            return []
        }
        return tasks
    }

    private func saveTasks(_ tasks: [ScheduledTask]) {
        let dir = tasksFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tasks) {
            try? data.write(to: tasksFileURL)
        }
    }
}

// MARK: - ScheduledTask Model

public struct ScheduledTask: Codable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: String
    public var enabled: Bool
    public var createdAt: String

    public init(id: String, name: String, prompt: String, schedule: String, enabled: Bool, createdAt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
    }
}
