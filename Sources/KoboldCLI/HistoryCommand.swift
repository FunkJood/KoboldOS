import ArgumentParser
import Foundation

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Manage conversation history",
        subcommands: [HistoryClear.self],
        defaultSubcommand: HistoryClear.self
    )
}

private struct HistoryClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear agent conversation history")

    @Option(name: .long, help: "Daemon port") var port: Int = 8080
    @Option(name: .long, help: "Auth token") var token: String = "kobold-secret"
    @Flag(name: .long, help: "Skip confirmation") var force: Bool = false

    mutating func run() async throws {
        if !force {
            print("Konversationshistorie wirklich löschen? (j/n) ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), answer.lowercased().hasPrefix("j") else {
                print(TerminalFormatter.info("Abgebrochen"))
                return
            }
        }

        let client = DaemonClient(port: port, token: token)
        let _ = try await client.post("/history/clear", body: [:])
        print(TerminalFormatter.success("Konversationshistorie gelöscht"))
    }
}
