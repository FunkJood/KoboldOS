import ArgumentParser
import Foundation
import KoboldCore

struct SecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage secrets in the Keychain",
        subcommands: [SecretList.self, SecretSet.self, SecretGet.self, SecretDelete.self],
        defaultSubcommand: SecretList.self
    )
}

private struct SecretList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all stored secret keys")

    mutating func run() async throws {
        let keys = await SecretStore.shared.allKeys()
        if keys.isEmpty {
            print(TerminalFormatter.info("Keine Secrets gespeichert"))
            return
        }
        let headers = ["Key", "Status"]
        let rows = keys.map { [$0, "********"] }
        print(TerminalFormatter.table(headers: headers, rows: rows))
    }
}

private struct SecretSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Store a secret (value entered without echo)")

    @Argument(help: "Secret key name") var key: String

    mutating func run() async throws {
        // Read value without echo
        print("Wert für '\(key)': ", terminator: "")
        fflush(stdout)

        // Disable echo
        var term = termios()
        tcgetattr(STDIN_FILENO, &term)
        var noEcho = term
        noEcho.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &noEcho)

        let value = readLine(strippingNewline: true) ?? ""

        // Restore echo
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
        print("") // newline after hidden input

        guard !value.isEmpty else {
            print(TerminalFormatter.error("Leerer Wert, abgebrochen"))
            return
        }

        await SecretStore.shared.set(value, forKey: key)
        print(TerminalFormatter.success("Secret '\(key)' gespeichert"))
    }
}

private struct SecretGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Retrieve a secret")

    @Argument(help: "Secret key name") var key: String
    @Flag(name: .long, help: "Show value in cleartext") var reveal: Bool = false

    mutating func run() async throws {
        guard let value = await SecretStore.shared.get(key) else {
            print(TerminalFormatter.error("Secret '\(key)' nicht gefunden"))
            return
        }
        if reveal {
            print(value)
        } else {
            let masked = String(value.prefix(2)) + String(repeating: "*", count: max(0, value.count - 2))
            print(masked)
        }
    }
}

private struct SecretDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a secret")

    @Argument(help: "Secret key name") var key: String

    mutating func run() async throws {
        await SecretStore.shared.delete(key)
        print(TerminalFormatter.success("Secret '\(key)' gelöscht"))
    }
}
