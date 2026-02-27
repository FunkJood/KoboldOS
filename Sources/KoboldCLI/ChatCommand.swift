import ArgumentParser
import Foundation

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Send a single message to the KoboldOS agent (non-interactive)"
    )

    @Argument(help: "Message to send") var message: String
    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Option(name: .long, help: "Agent type (general, coder, web)") var agent: String = "general"

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)

        guard await client.isHealthy() else {
            print("Fehler: Daemon nicht erreichbar auf Port \(port)")
            throw ExitCode.failure
        }

        let body: [String: Any] = [
            "message": message,
            "agent_type": agent,
            "provider": "ollama"
        ]

        var finalAnswer = ""

        for await event in client.stream("/agent/stream", body: body) {
            if let answer = event["final_answer"], !answer.isEmpty {
                finalAnswer = answer
            }
            if event["type"] == "error" {
                let content = event["content"] ?? "Unbekannter Fehler"
                print("Fehler: \(content)")
                throw ExitCode.failure
            }
        }

        if finalAnswer.isEmpty {
            print("Keine Antwort vom Agent erhalten.")
        } else {
            print(finalAnswer)
        }
    }
}
