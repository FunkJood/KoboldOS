import ArgumentParser
import Foundation

struct TaskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "Manage scheduled tasks",
        subcommands: [TaskList.self, TaskCreate.self, TaskDelete.self, TaskToggle.self],
        defaultSubcommand: TaskList.self
    )
}

private struct TaskList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all tasks")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Flag(name: .long, help: "JSON output") var json: Bool = false

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.get("/tasks")
        guard let tasks = result["tasks"] as? [[String: Any]] else {
            print(TerminalFormatter.info("Keine Tasks vorhanden"))
            return
        }

        if json {
            let data = try JSONSerialization.data(withJSONObject: tasks, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            if tasks.isEmpty {
                print(TerminalFormatter.info("Keine Tasks vorhanden"))
                return
            }
            let headers = ["ID", "Name", "Schedule", "Aktiv"]
            let rows = tasks.map { t -> [String] in
                [
                    t["id"] as? String ?? "?",
                    t["name"] as? String ?? "?",
                    t["schedule"] as? String ?? "-",
                    (t["enabled"] as? Bool ?? false) ? "ja" : "nein"
                ]
            }
            print(TerminalFormatter.table(headers: headers, rows: rows))
        }
    }
}

private struct TaskCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new task")

    @Option(name: .long, help: "Task name") var name: String
    @Option(name: .long, help: "Task prompt") var prompt: String
    @Option(name: .long, help: "Cron schedule (optional)") var schedule: String = ""
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let body: [String: Any] = [
            "action": "create",
            "name": name,
            "prompt": prompt,
            "schedule": schedule,
            "enabled": true
        ]
        let result = try await client.post("/tasks", body: body)
        let id = result["id"] as? String ?? "?"
        print(TerminalFormatter.success("Task erstellt: \(id) (\(name))"))
    }
}

private struct TaskDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a task")

    @Argument(help: "Task ID") var id: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/tasks", body: ["action": "delete", "id": id])
        print(TerminalFormatter.success("Task '\(id)' gelöscht"))
    }
}

private struct TaskToggle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Enable or disable a task")

    @Argument(help: "Task ID") var id: String
    @Option(name: .long, help: "Enable (true/false)") var enabled: Bool
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let body: [String: Any] = ["action": "update", "id": id, "enabled": enabled]
        let _ = try await client.post("/tasks", body: body)
        print(TerminalFormatter.success("Task '\(id)' \(enabled ? "aktiviert" : "deaktiviert")"))
    }
}
