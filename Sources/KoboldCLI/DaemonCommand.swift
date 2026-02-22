import ArgumentParser
import Foundation
import KoboldCore

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Start the KoboldOS daemon HTTP server"
    )

    @Option(name: .long, help: "Port to listen on") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Flag(name: .long, help: "Enable verbose logging") var verbose: Bool = false

    mutating func run() async throws {
        print("🐲 KoboldOS Daemon v0.2.3")
        print("   Port: \(port)")
        print("   Token: \(token.prefix(8))...")
        print("   PID: \(ProcessInfo.processInfo.processIdentifier)")
        print("")

        // Start daemon server
        let listener = DaemonListener(port: port, authToken: token)
        await listener.start()

        print("✅ Daemon running on port \(port)")
        print("   Press Ctrl+C to stop.")

        // Keep alive
        while true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
