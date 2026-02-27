import ArgumentParser
import Foundation

struct CardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "card",
        abstract: "View or discover A2A agent cards",
        subcommands: [CardShow.self, CardDiscover.self],
        defaultSubcommand: CardShow.self
    )
}

private struct CardShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show this agent's card")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080

    mutating func run() async throws {
        _ = DaemonClient(port: port, token: "")
        // Agent card is public (no auth needed), use direct URL fetch
        guard let url = URL(string: "http://localhost:\(port)/.well-known/agent.json") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: pretty, encoding: .utf8) ?? "{}")
            } else {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
        } catch {
            print(TerminalFormatter.error("Agent Card nicht verfügbar: \(error.localizedDescription)"))
        }
    }
}

private struct CardDiscover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "discover", abstract: "Discover another agent's card")

    @Argument(help: "Base URL of the remote agent (e.g. http://192.168.1.5:8080)") var url: String

    mutating func run() async throws {
        let cardURL = url.hasSuffix("/") ? "\(url).well-known/agent.json" : "\(url)/.well-known/agent.json"
        guard let fetchURL = URL(string: cardURL) else {
            print(TerminalFormatter.error("Ungültige URL: \(url)"))
            return
        }

        var req = URLRequest(url: fetchURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                print(TerminalFormatter.error("Agent Card nicht gefunden"))
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                print(TerminalFormatter.success("Agent Card gefunden:"))
                print(String(data: pretty, encoding: .utf8) ?? "{}")
            }
        } catch {
            print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
        }
    }
}
