import ArgumentParser
import Foundation

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check daemon health status"
    )

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        do {
            let result = try await client.get("/health")
            let status = result["status"] as? String ?? "unknown"
            let version = result["version"] as? String ?? "?"
            let pid = result["pid"] as? Int ?? 0
            let uptime = result["uptime"] as? Int ?? 0

            let headers = ["Feld", "Wert"]
            let rows = [
                ["Status", status],
                ["Version", version],
                ["PID", "\(pid)"],
                ["Uptime", formatUptime(uptime)]
            ]
            print(TerminalFormatter.table(headers: headers, rows: rows))

            if status == "ok" {
                throw ExitCode.success
            } else {
                throw ExitCode.failure
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            print(TerminalFormatter.error("Daemon nicht erreichbar: \(error.localizedDescription)"))
            throw ExitCode.failure
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
