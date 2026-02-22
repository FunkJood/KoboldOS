import ArgumentParser
import Foundation

struct WorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Manage workflows",
        subcommands: [WorkflowList.self, WorkflowCreate.self, WorkflowDelete.self, WorkflowRun.self],
        defaultSubcommand: WorkflowList.self
    )
}

private struct WorkflowList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all workflows")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Flag(name: .long, help: "JSON output") var json: Bool = false

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.get("/workflows")
        guard let workflows = result["workflows"] as? [[String: Any]] else {
            print(TerminalFormatter.info("Keine Workflows vorhanden"))
            return
        }

        if json {
            let data = try JSONSerialization.data(withJSONObject: workflows, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            if workflows.isEmpty {
                print(TerminalFormatter.info("Keine Workflows vorhanden"))
                return
            }
            let headers = ["ID", "Name", "Beschreibung"]
            let rows = workflows.map { w -> [String] in
                [
                    w["id"] as? String ?? "?",
                    w["name"] as? String ?? "?",
                    String((w["description"] as? String ?? "").prefix(40))
                ]
            }
            print(TerminalFormatter.table(headers: headers, rows: rows))
        }
    }
}

private struct WorkflowCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new workflow")

    @Option(name: .long, help: "Workflow name") var name: String
    @Option(name: .long, help: "Description") var description: String = ""
    @Option(name: .long, help: "Path to steps JSON file") var stepsFile: String?
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        var steps = "[]"
        if let path = stepsFile {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            steps = (try? String(contentsOf: url, encoding: .utf8)) ?? "[]"
        }
        let body: [String: Any] = [
            "action": "create",
            "name": name,
            "description": description,
            "steps": steps
        ]
        let result = try await client.post("/workflows", body: body)
        let id = result["id"] as? String ?? "?"
        print(TerminalFormatter.success("Workflow erstellt: \(id) (\(name))"))
    }
}

private struct WorkflowDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a workflow")

    @Argument(help: "Workflow ID") var id: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/workflows", body: ["action": "delete", "id": id])
        print(TerminalFormatter.success("Workflow '\(id)' gelöscht"))
    }
}

private struct WorkflowRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Execute a workflow's steps sequentially")

    @Argument(help: "Workflow ID") var id: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)

        // Fetch the workflow
        let result = try await client.get("/workflows")
        guard let workflows = result["workflows"] as? [[String: Any]],
              let workflow = workflows.first(where: { $0["id"] as? String == id }) else {
            print(TerminalFormatter.error("Workflow '\(id)' nicht gefunden"))
            return
        }

        let name = workflow["name"] as? String ?? "?"
        let stepsStr = workflow["steps"] as? String ?? "[]"
        guard let stepsData = stepsStr.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: stepsData) as? [[String: Any]] else {
            print(TerminalFormatter.error("Ungültige Workflow-Steps"))
            return
        }

        print(TerminalFormatter.info("Workflow '\(name)' wird ausgeführt (\(steps.count) Schritte)..."))

        for (i, step) in steps.enumerated() {
            let agent = step["agent"] as? String ?? "general"
            let prompt = step["prompt"] as? String ?? ""
            print(TerminalFormatter.info("  Schritt \(i + 1)/\(steps.count): \(agent) — \(String(prompt.prefix(50)))"))

            let body: [String: String] = ["message": prompt, "agent_type": agent]
            let stream = client.stream("/agent/stream", body: body)
            for await event in stream {
                SSEStreamParser.displayStep(event)
            }
            print("")
        }

        print(TerminalFormatter.success("Workflow '\(name)' abgeschlossen"))
    }
}
