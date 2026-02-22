import ArgumentParser
import Foundation

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Send a message to the KoboldOS agent"
    )

    @Argument(help: "Message to send") var message: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"

    mutating func run() async throws {
        guard let url = URL(string: "http://localhost:\(port)/agent") else {
            throw ValidationError("Invalid URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "message": message,
            "agent_type": "general"
        ])

        print("→ \(message)")
        print("")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("❌ Daemon returned error")
            return
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let output = json["output"] as? String {
            print("🐲 \(output)")
        } else {
            print("❌ Could not parse response")
        }
    }
}
