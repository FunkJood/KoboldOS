import ArgumentParser
import Foundation

struct MetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Show runtime metrics (token count, latency, tool calls, etc.)"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"
    @Flag(name: .long, help: "Output as raw JSON") var json: Bool = false
    @Flag(name: .long, help: "Watch mode: refresh every 2 seconds") var watch: Bool = false

    func run() async throws {
        if watch {
            print("Watching metrics (Ctrl+C to stop)...")
            while true {
                try await printMetrics(json: json)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                print("\u{1B}[H\u{1B}[2J", terminator: "") // clear screen
            }
        } else {
            try await printMetrics(json: json)
        }
    }

    private func printMetrics(json: Bool) async throws {
        let url = URL(string: endpoint + "/metrics")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            fputs("❌ Daemon not reachable at \(endpoint)\n", stderr)
            throw ExitCode.failure
        }
        if json {
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print(String(data: data, encoding: .utf8) ?? "No data")
            return
        }
        let uptime = m["uptime"] as? Int ?? 0
        let chatReqs = m["chat_requests"] as? Int ?? 0
        let toolCalls = m["tool_calls"] as? Int ?? 0
        let errors = m["errors"] as? Int ?? 0
        let tokenTotal = m["token_total"] as? Int ?? 0
        let avgLatency = m["avg_latency_ms"] as? Double ?? 0
        let cacheHits = m["cache_hits"] as? Int ?? 0
        let backend = m["backend"] as? String ?? "unknown"

        let uptimeStr = formatUptime(uptime)
        func row(_ label: String, _ value: String) {
            let padded = (label + ":").padding(toLength: 22, withPad: " ", startingAt: 0)
            print("  \(padded) \(value)")
        }
        print("KOBOLDOS — RUNTIME METRICS")
        print("═══════════════════════════════════")
        row("Uptime",        uptimeStr)
        row("Backend",       backend)
        row("Chat requests", "\(chatReqs)")
        row("Tool calls",    "\(toolCalls)")
        row("Errors",        "\(errors)")
        row("Total tokens",  "\(tokenTotal)")
        row("Avg latency",   "\(String(format: "%.1f", avgLatency)) ms")
        row("Cache hits",    "\(cacheHits)")
        print("───────────────────────────────────")
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
