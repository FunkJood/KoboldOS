import ArgumentParser
import Foundation
import KoboldCore

struct SkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Manage agent skills",
        subcommands: [SkillList.self, SkillImport.self, SkillToggle.self, SkillDelete.self],
        defaultSubcommand: SkillList.self
    )
}

private struct SkillList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all skills")

    mutating func run() async throws {
        let skills = await SkillLoader.shared.loadSkills()
        if skills.isEmpty {
            print(TerminalFormatter.info("Keine Skills vorhanden"))
            return
        }
        let headers = ["Name", "Status", "Größe"]
        let rows = skills.map { s -> [String] in
            [s.name, s.isEnabled ? "aktiv" : "inaktiv", "\(s.content.count) Z"]
        }
        print(TerminalFormatter.table(headers: headers, rows: rows))
    }
}

private struct SkillImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import a skill from a .md file")

    @Argument(help: "Path to .md skill file") var path: String

    mutating func run() async throws {
        let srcURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            print(TerminalFormatter.error("Datei nicht gefunden: \(path)"))
            return
        }
        let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let destURL = skillsDir.appendingPathComponent(srcURL.lastPathComponent)
        try FileManager.default.copyItem(at: srcURL, to: destURL)

        let name = srcURL.deletingPathExtension().lastPathComponent
        await SkillLoader.shared.setEnabled(name, enabled: true)
        print(TerminalFormatter.success("Skill '\(name)' importiert und aktiviert"))
    }
}

private struct SkillToggle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Enable or disable a skill")

    @Argument(help: "Skill name") var name: String
    @Option(name: .long, help: "Enable (true/false)") var enabled: Bool

    mutating func run() async throws {
        await SkillLoader.shared.setEnabled(name, enabled: enabled)
        print(TerminalFormatter.success("Skill '\(name)' \(enabled ? "aktiviert" : "deaktiviert")"))
    }
}

private struct SkillDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a skill")

    @Argument(help: "Skill name") var name: String

    mutating func run() async throws {
        let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
        let fileURL = skillsDir.appendingPathComponent("\(name).md")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print(TerminalFormatter.error("Skill '\(name)' nicht gefunden"))
            return
        }
        try FileManager.default.removeItem(at: fileURL)
        await SkillLoader.shared.setEnabled(name, enabled: false)
        print(TerminalFormatter.success("Skill '\(name)' gelöscht"))
    }
}
