import ArgumentParser
import Foundation

struct CheckpointCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoint",
        abstract: "Manage agent checkpoints (pause/resume)",
        subcommands: [CheckpointList.self, CheckpointResume.self, CheckpointDelete.self],
        defaultSubcommand: CheckpointList.self
    )
}

private struct CheckpointList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved checkpoints")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        do {
            let result = try await client.get("/checkpoints")
            guard let cps = result["checkpoints"] as? [[String: Any]], !cps.isEmpty else {
                print(TerminalFormatter.info("Keine Checkpoints vorhanden"))
                return
            }
            let headers = ["ID", "Agent-Typ", "Schritte", "Status", "Nachricht"]
            let rows = cps.map { cp -> [String] in
                [
                    String((cp["id"] as? String ?? "?").prefix(8)),
                    cp["agentType"] as? String ?? "?",
                    "\(cp["stepCount"] as? Int ?? 0)",
                    cp["status"] as? String ?? "?",
                    String((cp["userMessage"] as? String ?? "").prefix(30))
                ]
            }
            print(TerminalFormatter.table(headers: headers, rows: rows))
        } catch {
            print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
        }
    }
}

private struct CheckpointResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume a checkpoint")

    @Argument(help: "Checkpoint ID") var id: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        print(TerminalFormatter.info("Checkpoint '\(String(id.prefix(8)))' wird fortgesetzt..."))

        let stream = client.stream("/checkpoints/resume/stream", body: ["id": id])
        for await step in stream {
            SSEStreamParser.displayStep(step)
        }

        print(TerminalFormatter.success("Checkpoint abgeschlossen"))
    }
}

private struct CheckpointDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a checkpoint")

    @Argument(help: "Checkpoint ID") var id: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/checkpoints/delete", body: ["id": id])
        print(TerminalFormatter.success("Checkpoint '\(String(id.prefix(8)))' gelöscht"))
    }
}
