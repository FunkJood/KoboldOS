import ArgumentParser
import Foundation
import KoboldCore

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Start the KoboldOS daemon HTTP server"
    )

    @Option(name: .long, help: "Port to listen on") var port: Int = 8080
    @Option(name: .long, help: "Auth token (auto-detected from GUI if omitted)") var token: String = ""
    @Flag(name: .long, help: "Enable verbose logging") var verbose: Bool = false

    mutating func run() async throws {
        let resolvedToken = token.isEmpty ? DaemonClient.resolveToken() : token
        print("🐲 KoboldOS Daemon v\(KoboldVersion.current)")
        print("   Port: \(port)")
        print("   Token: \(resolvedToken.prefix(8))...")
        print("   PID: \(ProcessInfo.processInfo.processIdentifier)")
        print("")

        // Start daemon server
        let listener = DaemonListener(port: port, authToken: resolvedToken)
        await listener.start()

        print("✅ Daemon running on port \(port)")
        print("   Press Ctrl+C to stop.")

        // Keep alive
        while true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
