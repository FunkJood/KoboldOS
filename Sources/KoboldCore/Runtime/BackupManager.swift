import Foundation

// MARK: - BackupManager
// Creates and restores backups of KoboldOS data (sessions, memory, configs).

public actor BackupManager {
    public static let shared = BackupManager()

    private let fm = FileManager.default

    private var koboldDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS")
    }

    private var backupsDir: URL {
        koboldDir.appendingPathComponent("Backups")
    }

    // MARK: - Backup Categories

    public struct BackupCategories: Sendable {
        public var memories: Bool
        public var secrets: Bool
        public var chats: Bool
        public var skills: Bool
        public var settings: Bool
        public var tasks: Bool
        public var workflows: Bool

        public init(memories: Bool = true, secrets: Bool = true, chats: Bool = true,
                    skills: Bool = true, settings: Bool = true, tasks: Bool = true, workflows: Bool = true) {
            self.memories = memories
            self.secrets = secrets
            self.chats = chats
            self.skills = skills
            self.settings = settings
            self.tasks = tasks
            self.workflows = workflows
        }

        public static let all = BackupCategories()
    }

    // MARK: - Create Backup

    /// Creates a dated backup folder containing selected data categories.
    /// Returns the URL of the created backup folder.
    public func createBackup(categories: BackupCategories = .all) throws -> URL {
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = formatter.string(from: Date())
        let backupDir = backupsDir.appendingPathComponent("backup_\(dateStr)")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var itemsToCopy: [String] = []

        if categories.memories {
            itemsToCopy.append("memory_blocks.json")
        }
        if categories.secrets {
            itemsToCopy.append("Agents") // contains API keys in agent configs
        }
        if categories.chats {
            itemsToCopy.append(contentsOf: ["Sessions", "chat_sessions.json", "chat_history.json"])
        }
        if categories.skills {
            itemsToCopy.append("Skills")
        }
        if categories.settings {
            itemsToCopy.append("model_configs.json")
        }
        if categories.tasks {
            itemsToCopy.append("tasks.json")
        }
        if categories.workflows {
            itemsToCopy.append(contentsOf: ["workflows.json", "workflow_canvas.json"])
        }

        for item in itemsToCopy {
            let src = koboldDir.appendingPathComponent(item)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: backupDir.appendingPathComponent(item))
            }
        }

        // Save a manifest
        let manifest: [String: Any] = [
            "created": dateStr,
            "version": "1.0",
            "items": itemsToCopy.filter { fm.fileExists(atPath: koboldDir.appendingPathComponent($0).path) }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? data.write(to: backupDir.appendingPathComponent("manifest.json"))
        }

        return backupDir
    }

    // MARK: - List Backups

    public func listBackups() -> [BackupEntry] {
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return dirs
            .filter { $0.hasDirectoryPath }
            .compactMap { url -> BackupEntry? in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = attrs?[.creationDate] as? Date ?? Date()
                return BackupEntry(url: url, name: url.lastPathComponent, createdAt: date)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Restore Backup

    public func restoreBackup(_ backupURL: URL) throws {
        guard fm.fileExists(atPath: backupURL.path) else {
            throw BackupError.backupNotFound
        }

        let items = try fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)
        for item in items where item.lastPathComponent != "manifest.json" {
            let dest = koboldDir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: item, to: dest)
        }
    }

    // MARK: - Delete Backup

    public func deleteBackup(_ backupURL: URL) throws {
        try fm.removeItem(at: backupURL)
    }
}

// MARK: - Supporting Types

public struct BackupEntry: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let createdAt: Date

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

public enum BackupError: Error, LocalizedError {
    case backupNotFound
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .backupNotFound:        return "Backup-Ordner nicht gefunden."
        case .writeFailed(let msg): return "Schreibfehler: \(msg)"
        }
    }
}
