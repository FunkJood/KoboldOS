import ArgumentParser
import Foundation
import KoboldCore

#if WEB_GUI
// Import the WebAppServer from WebGUI target
#if canImport(WebGUI)
import WebGUI
#endif

struct WebCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "web",
        abstract: "Start KoboldOS with integrated Web GUI"
    )

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Web GUI port") var webPort: Int = 8081
    @Option(name: .long, help: "Username for web auth") var username: String = "admin"
    @Option(name: .long, help: "Password for web auth") var password: String = "admin"
    @Option(name: .long, help: "Auth token for daemon") var token: String = "kobold-secret"

    mutating func run() async throws {
        print("🌐 Starting KoboldOS with Web GUI...")
        print("   Daemon port: \(port)")
        print("   Web GUI port: \(webPort)")
        print("   Username: \(username)")
        print("   Password: \(password)")
        print("   Token: \(token.prefix(8))...")

        // Start the daemon
        let daemonListener = DaemonListener(port: port, authToken: token)
        Task { await daemonListener.start() }

        // Start the web server
        #if canImport(WebGUI)
        let webServer = WebAppServer.shared
        webServer.start(port: webPort, daemonPort: port, daemonToken: token, username: username, password: password)
        #endif

        print("✅ KoboldOS Web GUI running!")
        print("   Web Interface: http://localhost:\(webPort)")
        print("   Daemon API: http://localhost:\(port)")
        print("   Press Ctrl+C to stop.")

        // Keep alive
        while true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
#endif