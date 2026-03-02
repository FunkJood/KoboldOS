import ArgumentParser
import Foundation

struct CardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "card",
        abstract: "View or discover A2A agent cards",
        subcommands: [CardShow.self, CardDiscover.self, CardSend.self],
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

private struct CardSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Send a message to a remote A2A agent")

    @Argument(help: "Base URL of the remote agent (e.g. http://192.168.1.5:8080)") var url: String
    @Argument(help: "Message to send") var message: String
    @Option(name: .long, help: "Bearer token for authentication") var token: String = ""
    @Option(name: .long, help: "Existing task ID for conversation") var taskId: String?

    mutating func run() async throws {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let endpoint = URL(string: "\(base)/a2a") else {
            print(TerminalFormatter.error("Ungültige URL: \(url)"))
            return
        }

        var params: [String: Any] = [
            "message": [
                "role": "user",
                "parts": [["text": message]]
            ]
        ]
        if let tid = taskId { params["taskId"] = tid }

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "message/send",
            "params": params
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: rpcBody) else {
            print(TerminalFormatter.error("JSON-Serialisierung fehlgeschlagen"))
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = bodyData
        req.timeoutInterval = 300

        print(TerminalFormatter.info("Sende Nachricht an \(base) ..."))

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard status == 200 else {
                let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                print(TerminalFormatter.error("HTTP \(status): \(body)"))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print(String(data: data.prefix(4096), encoding: .utf8) ?? "(keine Daten)")
                return
            }

            if let error = json["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unbekannter Fehler"
                let code = error["code"] as? Int ?? -1
                print(TerminalFormatter.error("A2A Fehler [\(code)]: \(msg)"))
                return
            }

            if let result = json["result"] as? [String: Any] {
                let state = (result["status"] as? [String: Any])?["state"] as? String ?? "unknown"
                let tid = result["id"] as? String ?? "—"
                print(TerminalFormatter.success("Task \(tid) (\(state))"))

                if let artifacts = result["artifacts"] as? [[String: Any]] {
                    let texts = artifacts.flatMap { artifact -> [String] in
                        let parts = artifact["parts"] as? [[String: Any]] ?? []
                        return parts.compactMap { $0["text"] as? String }
                    }
                    if !texts.isEmpty {
                        print("\n\(texts.joined(separator: "\n"))")
                    }
                }

                if let tid2 = result["id"] as? String {
                    print(TerminalFormatter.info("\nTask-ID: \(tid2) (für Folgefragen: --task-id \(tid2))"))
                }
            } else {
                if let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                    print(String(data: pretty, encoding: .utf8) ?? "{}")
                }
            }
        } catch {
            print(TerminalFormatter.error("Verbindung fehlgeschlagen: \(error.localizedDescription)"))
        }
    }
}
