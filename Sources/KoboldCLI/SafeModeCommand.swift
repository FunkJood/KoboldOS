import ArgumentParser
import Foundation

struct SafeModeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safe-mode",
        abstract: "Safe mode control (crash protection)",
        subcommands: [SafeModeStatus.self, SafeModeEnable.self, SafeModeReset.self],
        defaultSubcommand: SafeModeStatus.self
    )
}

// MARK: - kobold safe-mode status
struct SafeModeStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show safe mode status and crash count"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"
    @Flag(name: .long, help: "Output as JSON") var json: Bool = false

    func run() async throws {
        let url = URL(string: endpoint + "/safe-mode")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            fputs("❌ Daemon not reachable at \(endpoint)\n", stderr)
            throw ExitCode.failure
        }
        if json {
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print(String(data: data, encoding: .utf8) ?? "No data")
            return
        }
        let active = decoded["active"] as? Bool ?? false
        let crashCount = decoded["crash_count"] as? Int ?? 0
        let threshold = decoded["threshold"] as? Int ?? 3
        let indicator = active ? "⚠️  ACTIVE" : "✅ Inactive"
        print("KOBOLDOS — SAFE MODE")
        print("════════════════════")
        print("Status:       \(indicator)")
        print("Crash count:  \(crashCount)/\(threshold)")
        if active {
            print("")
            print("System is in restricted mode.")
            print("Run 'kobold safe-mode reset' to restore normal operation.")
        }
    }
}

// MARK: - kobold safe-mode enable
struct SafeModeEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Manually activate safe mode"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        let url = URL(string: endpoint + "/safe-mode-enable")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            print("⚠️  Safe mode enabled")
            print("Tools and memory writes are now restricted.")
        } else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            fputs("❌ Failed to enable safe mode: \(body)\n", stderr)
            throw ExitCode.failure
        }
    }
}

// MARK: - kobold safe-mode reset
struct SafeModeReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset crash counter and disable safe mode"
    )
    @Option(name: .long, help: "Daemon endpoint") var endpoint: String = "http://localhost:8080"

    func run() async throws {
        let url = URL(string: endpoint + "/safe-mode-reset")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            print("✅ Safe mode reset — normal operation restored")
            print("Crash counter: 0")
        } else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            fputs("❌ Reset failed: \(body)\n", stderr)
            throw ExitCode.failure
        }
    }
}
