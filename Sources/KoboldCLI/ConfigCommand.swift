import ArgumentParser
import Foundation

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage KoboldOS configuration",
        subcommands: [ConfigList.self, ConfigGet.self, ConfigSet.self],
        defaultSubcommand: ConfigList.self
    )
}

private struct ConfigList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all configuration values")

    mutating func run() async throws {
        let defaults = UserDefaults.standard
        let knownKeys = [
            "kobold.ollamaModel",
            "kobold.autonomyLevel",
            "kobold.agentType",
            "kobold.hasOnboarded",
            "kobold.perm.selfCheck",
            "kobold.skills.enabled",
            "kobold.persona.name",
            "kobold.persona.personality",
            "kobold.persona.language",
            "kobold.persona.primaryUse",
            "kobold.persona.agentName",
            "kobold.activeSessionId"
        ]

        let headers = ["Key", "Value"]
        var rows: [[String]] = []
        for key in knownKeys {
            if let val = defaults.object(forKey: key) {
                rows.append([key, "\(val)"])
            }
        }

        if rows.isEmpty {
            print(TerminalFormatter.info("Keine Konfiguration gesetzt"))
        } else {
            print(TerminalFormatter.table(headers: headers, rows: rows))
        }
    }
}

private struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get a configuration value")

    @Argument(help: "Configuration key") var key: String

    mutating func run() async throws {
        if let val = UserDefaults.standard.object(forKey: key) {
            print("\(val)")
        } else {
            print(TerminalFormatter.error("Key '\(key)' nicht gesetzt"))
        }
    }
}

private struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a configuration value")

    @Argument(help: "Configuration key") var key: String
    @Argument(help: "Value to set") var value: String

    mutating func run() async throws {
        let defaults = UserDefaults.standard

        // Type inference: bool, int, or string
        if value.lowercased() == "true" {
            defaults.set(true, forKey: key)
        } else if value.lowercased() == "false" {
            defaults.set(false, forKey: key)
        } else if let intVal = Int(value) {
            defaults.set(intVal, forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }

        print(TerminalFormatter.success("\(key) = \(value)"))
    }
}
