import ArgumentParser
import Foundation

struct TraceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Execution trace and determinism audit",
        subcommands: [TraceList.self, TraceGet.self, TraceHash.self],
        defaultSubcommand: TraceList.self
    )
}

// MARK: - kobold trace list
struct TraceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent execution traces"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"
    @Option(name: [.short, .long], help: "Number of entries to show") var count: Int = 20
    @Flag(name: .long, help: "Output as JSON") var json: Bool = false

    func run() async throws {
        let url = URL(string: endpoint + "/trace")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            fputs("❌ Daemon not reachable at \(endpoint)\n", stderr)
            throw ExitCode.failure
        }
        if json {
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print(String(data: data, encoding: .utf8) ?? "No trace data")
            return
        }
        let timeline = decoded["timeline"] as? [[String: Any]] ?? []
        let determinismHash = decoded["determinism_hash"] as? String ?? "(none)"
        let stepCount = decoded["step_count"] as? Int ?? 0

        print("KOBOLDOS — EXECUTION TRACE (last \(count))")
        print("═════════════════════════════════════════")
        print("Steps:  \(stepCount)")
        print("Hash:   \(determinismHash)")
        print("")
        let entries = Array(timeline.suffix(count))
        if entries.isEmpty {
            print("  No trace entries yet. Start a chat to generate traces.")
        } else {
            for (i, entry) in entries.enumerated() {
                let event = entry["event"] as? String ?? "?"
                let detail = entry["detail"] as? String ?? ""
                let ts = entry["timestamp"] as? String ?? ""
                let idx = String(format: "%3d", i + 1)
                print("\(idx). [\(ts)] \(event) — \(detail)")
            }
        }
    }
}

// MARK: - kobold trace get <id>
struct TraceGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get full trace data (JSON)"
    )
    @Argument(help: "Trace step index (0-based)") var traceIndex: Int = 0
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        let url = URL(string: endpoint + "/trace")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timeline = decoded["timeline"] as? [[String: Any]] else {
            fputs("❌ Could not parse trace data\n", stderr)
            throw ExitCode.failure
        }
        guard traceIndex < timeline.count else {
            fputs("❌ Trace index \(traceIndex) out of range (have \(timeline.count) entries)\n", stderr)
            throw ExitCode.failure
        }
        let entry = timeline[traceIndex]
        let prettyData = try JSONSerialization.data(withJSONObject: entry, options: .prettyPrinted)
        print(String(data: prettyData, encoding: .utf8) ?? "{}")
    }
}

// MARK: - kobold trace hash
struct TraceHash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hash",
        abstract: "Show determinism hash for reproducibility audit"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        let url = URL(string: endpoint + "/trace")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            fputs("❌ Daemon not reachable\n", stderr)
            throw ExitCode.failure
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("❌ Could not parse trace data\n", stderr)
            throw ExitCode.failure
        }
        let hash = decoded["determinism_hash"] as? String ?? "(unavailable)"
        let stepCount = decoded["step_count"] as? Int ?? 0
        print("KOBOLDOS — DETERMINISM HASH")
        print("════════════════════════════")
        print("Hash:   \(hash)")
        print("Steps:  \(stepCount)")
        print("")
        print("This hash can be used to verify reproducibility of agent runs.")
    }
}
