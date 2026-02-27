import ArgumentParser
import Foundation
import KoboldCore

// MARK: - InteractiveChatCommand
// Default subcommand: `kobold` starts an interactive chat REPL.

struct InteractiveChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interactive",
        abstract: "Start interactive chat session (default when running 'kobold')"
    )

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Option(name: .long, help: "Agent type (general, coder, web)") var agent: String = "general"
    @Option(name: .long, help: "Load existing session by ID") var session: String?
    @Flag(name: .long, help: "Auto-start daemon if not running") var autoDaemon: Bool = true

    mutating func run() async throws {
        let client = DaemonClient(port: port, token: token)
        let sessionManager = CLISessionManager()
        let slashHandler = SlashCommandHandler(client: client, sessionManager: sessionManager)
        var currentAgentType = agent

        // Print banner
        print(TerminalFormatter.banner())

        // Check daemon health, auto-start if needed
        let healthy = await client.isHealthy()
        if !healthy {
            if autoDaemon {
                print(TerminalFormatter.info("Daemon nicht erreichbar, starte in-process..."))
                let listener = DaemonListener(port: port, authToken: token)
                Task.detached { await listener.start() }
                // Wait for daemon to come up
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if await client.isHealthy() { break }
                }
                if await client.isHealthy() {
                    print(TerminalFormatter.success("Daemon gestartet auf Port \(port)"))
                } else {
                    print(TerminalFormatter.error("Daemon konnte nicht gestartet werden"))
                    return
                }
            } else {
                print(TerminalFormatter.error("Daemon nicht erreichbar. Starte mit: kobold daemon --port \(port)"))
                return
            }
        } else {
            print(TerminalFormatter.success("Verbunden mit Daemon auf Port \(port)"))
        }

        // Load or create session
        if let sessionId = session {
            if let s = await sessionManager.loadSession(id: sessionId) {
                print(TerminalFormatter.info("Session '\(s.title)' geladen (\(s.messageCount) Nachrichten)"))
            } else {
                print(TerminalFormatter.warning("Session '\(sessionId)' nicht gefunden, erstelle neue"))
                let _ = await sessionManager.newSession()
            }
        } else {
            let s = await sessionManager.newSession()
            print(TerminalFormatter.info("Neue Session: \(s.id)"))
        }

        // MARK: - REPL Loop

        // Bridge readLine() to async via a dedicated thread
        let inputStream = AsyncStream<String> { continuation in
            let thread = Thread {
                while true {
                    print(TerminalFormatter.prompt(), terminator: "")
                    fflush(stdout)
                    guard let line = readLine(strippingNewline: true) else {
                        // EOF (Ctrl+D)
                        continuation.finish()
                        return
                    }
                    continuation.yield(line)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        // Setup Ctrl+C handler
        // streamCancelled reserved for future SIGINT handling
        signal(SIGINT) { _ in
            // Will be handled in the loop
        }

        for await line in inputStream {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Slash commands
            if trimmed.hasPrefix("/") {
                // Special: /agent <type> changes agent type
                if trimmed.hasPrefix("/agent ") {
                    let parts = trimmed.components(separatedBy: .whitespaces)
                    if parts.count > 1 {
                        currentAgentType = parts[1]
                        print(TerminalFormatter.success("Agent-Typ: \(currentAgentType)"))
                        continue
                    }
                }

                let shouldContinue = await slashHandler.handle(trimmed)
                if !shouldContinue { break }
                continue
            }

            // Send message to agent stream
            await sessionManager.addMessage(role: "user", content: trimmed)

            let body: [String: Any] = [
                "message": trimmed,
                "agent_type": currentAgentType
            ]

            print("") // spacing
            var finalAnswer = ""
            var lastConfidence: Double?
            var receivedAnyStep = false

            let stream = client.stream("/agent/stream", body: body)
            for await step in stream {
                receivedAnyStep = true
                SSEStreamParser.displayStep(step)

                if step["type"] == "finalAnswer" {
                    finalAnswer = step["content"] ?? ""
                }
                if step["type"] == "error" {
                    let errContent = step["content"] ?? "Unbekannter Fehler"
                    print(TerminalFormatter.error("Agent-Fehler: \(errContent)"))
                }
                if let cStr = step["confidence"], let c = Double(cStr) {
                    lastConfidence = c
                }
            }

            if !receivedAnyStep {
                print(TerminalFormatter.error("Keine Antwort vom Agent. Mögliche Ursachen:"))
                print(TerminalFormatter.error("  - Ollama nicht gestartet (ollama serve)"))
                print(TerminalFormatter.error("  - Kein Modell geladen (/model <name>)"))
                print(TerminalFormatter.error("  - Daemon-Verbindung unterbrochen"))
            } else if finalAnswer.isEmpty && !receivedAnyStep {
                print(TerminalFormatter.warning("Agent hat keine finale Antwort generiert."))
            }

            if !finalAnswer.isEmpty {
                await sessionManager.addMessage(role: "assistant", content: finalAnswer)
            }

            if let c = lastConfidence {
                print(TerminalFormatter.confidence(c))
            }

            print("") // spacing after response
        }

        // Save on exit
        await sessionManager.saveSession()
        print(TerminalFormatter.info("Session gespeichert. Auf Wiedersehen!"))
    }
}
