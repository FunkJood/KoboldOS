import ArgumentParser
import Foundation

struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage agent memory blocks",
        subcommands: [MemoryList.self, MemoryGet.self, MemorySet.self, MemoryDelete.self, MemorySnapshot.self, MemoryLog.self, MemoryDiff.self, MemoryRollback.self],
        defaultSubcommand: MemoryList.self
    )
}

struct MemoryList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all memory blocks")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Flag(name: .long, help: "JSON output") var json: Bool = false

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.get("/memory")
        guard let blocks = result["blocks"] as? [[String: Any]] else {
            print(TerminalFormatter.error("Keine Memory-Blöcke gefunden"))
            return
        }

        if json {
            let data = try JSONSerialization.data(withJSONObject: blocks, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            let headers = ["Label", "Zeichen", "Limit", "%"]
            let rows: [[String]] = blocks.map { b in
                let label = b["label"] as? String ?? "?"
                let content = b["content"] as? String ?? ""
                let limit = b["limit"] as? Int ?? 0
                let pct = limit > 0 ? Int(Double(content.count) / Double(limit) * 100) : 0
                return [label, "\(content.count)", "\(limit)", "\(pct)%"]
            }
            print(TerminalFormatter.table(headers: headers, rows: rows))
        }
    }
}

struct MemoryGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a specific memory block")

    @Argument(help: "Block label") var label: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.get("/memory")
        guard let blocks = result["blocks"] as? [[String: Any]] else { return }
        if let block = blocks.first(where: { $0["label"] as? String == label }) {
            let content = block["content"] as? String ?? ""
            let limit = block["limit"] as? Int ?? 0
            print("[\(label)] (\(content.count)/\(limit) chars)")
            print(content)
        } else {
            print(TerminalFormatter.error("Block '\(label)' nicht gefunden"))
        }
    }
}

struct MemorySet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a memory block's content")

    @Argument(help: "Block label") var label: String
    @Argument(help: "Content to set") var content: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/memory/update", body: ["label": label, "content": content])
        print(TerminalFormatter.success("Memory-Block '\(label)' aktualisiert"))
    }
}

struct MemoryDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Clear a memory block")

    @Argument(help: "Block label") var label: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/memory/update", body: ["label": label, "content": ""])
        print(TerminalFormatter.success("Memory-Block '\(label)' geleert"))
    }
}

struct MemorySnapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Create a memory snapshot")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/memory/snapshot", body: [:])
        print(TerminalFormatter.success("Memory-Snapshot erstellt"))
    }
}

struct MemoryLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "Show memory version history")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Option(name: .long, help: "Number of versions to show") var limit: Int = 20

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.get("/memory/versions?limit=\(limit)")
        guard let versions = result["versions"] as? [[String: Any]] else {
            print(TerminalFormatter.info("Keine Versionen vorhanden"))
            return
        }
        let headers = ["ID", "Datum", "Nachricht"]
        let rows = versions.map { v -> [String] in
            [
                String((v["id"] as? String ?? "?").prefix(8)),
                v["timestamp"] as? String ?? "?",
                String((v["message"] as? String ?? "").prefix(40))
            ]
        }
        print(TerminalFormatter.table(headers: headers, rows: rows))
    }
}

struct MemoryDiff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "Show diff between two memory versions")

    @Argument(help: "First version ID") var from: String
    @Argument(help: "Second version ID") var to: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let result = try await client.post("/memory/diff", body: ["from": from, "to": to])
        if let diffs = result["diffs"] as? [[String: Any]] {
            for d in diffs {
                let label = d["label"] as? String ?? "?"
                let change = d["change"] as? String ?? "unchanged"
                print(TerminalFormatter.info("[\(label)] \(change)"))
                if let old = d["old"] as? String, !old.isEmpty {
                    print("  - \(old)")
                }
                if let new = d["new"] as? String, !new.isEmpty {
                    print("  + \(new)")
                }
            }
        } else {
            print(TerminalFormatter.info("Kein Diff verfügbar"))
        }
    }
}

struct MemoryRollback: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rollback", abstract: "Rollback memory to a specific version")

    @Argument(help: "Version ID") var versionId: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/memory/rollback", body: ["id": versionId])
        print(TerminalFormatter.success("Memory auf Version '\(String(versionId.prefix(8)))' zurückgesetzt"))
    }
}
