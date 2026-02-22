import Foundation

// MARK: - CLISessionManager
// Manages persistent chat sessions for the interactive CLI.
// Sessions stored under ~/Library/Application Support/KoboldOS/cli_sessions/

struct CLISession: Codable {
    let id: String
    var title: String
    let createdAt: Date
    var messages: [CLIMessage]

    var messageCount: Int { messages.count }
}

struct CLIMessage: Codable {
    let role: String      // "user" or "assistant"
    let content: String
    let timestamp: Date
}

actor CLISessionManager {
    private var currentSession: CLISession?
    private var saveTask: Task<Void, Never>?

    private let sessionsDir: URL
    private let indexURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/cli_sessions")
        self.sessionsDir = dir
        self.indexURL = dir.appendingPathComponent("sessions_index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Session Lifecycle

    func newSession() -> CLISession {
        let session = CLISession(
            id: UUID().uuidString.prefix(8).lowercased().description,
            title: "Neue Session",
            createdAt: Date(),
            messages: []
        )
        currentSession = session
        saveIndex()
        return session
    }

    func loadSession(id: String) -> CLISession? {
        let url = sessionsDir.appendingPathComponent("session_\(id).json")
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder.kobold.decode(CLISession.self, from: data) else {
            return nil
        }
        currentSession = session
        return session
    }

    func getCurrentSession() -> CLISession? {
        currentSession
    }

    // MARK: - Messages

    func addMessage(role: String, content: String) {
        guard currentSession != nil else { return }
        let msg = CLIMessage(role: role, content: content, timestamp: Date())
        currentSession!.messages.append(msg)

        // Auto-title from first user message
        if role == "user" && currentSession!.title == "Neue Session" {
            let preview = String(content.prefix(40))
            currentSession!.title = preview
        }

        debouncedSave()
    }

    // MARK: - Save / Load

    func saveSession() {
        guard let session = currentSession else { return }
        let url = sessionsDir.appendingPathComponent("session_\(session.id).json")
        if let data = try? JSONEncoder.kobold.encode(session) {
            try? data.write(to: url, options: .atomic)
        }
        saveIndex()
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s debounce
            guard !Task.isCancelled else { return }
            saveSession()
        }
    }

    func listSessions() -> [(id: String, title: String, date: String, count: Int)] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder.kobold.decode([SessionIndexEntry].self, from: data) else {
            return []
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.map { (id: $0.id, title: $0.title, date: fmt.string(from: $0.createdAt), count: $0.messageCount) }
    }

    func deleteSession(id: String) {
        let url = sessionsDir.appendingPathComponent("session_\(id).json")
        try? FileManager.default.removeItem(at: url)
        if currentSession?.id == id { currentSession = nil }
        // Update index
        var entries = loadIndex()
        entries.removeAll { $0.id == id }
        saveIndex(entries: entries)
    }

    func clearCurrentSession() {
        currentSession?.messages.removeAll()
        saveSession()
    }

    // MARK: - Export

    func exportMarkdown(path: String?) -> String? {
        guard let session = currentSession else { return nil }
        var md = "# \(session.title)\n\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        for msg in session.messages {
            let time = fmt.string(from: msg.timestamp)
            let prefix = msg.role == "user" ? "**You** [\(time)]" : "**Kobold** [\(time)]"
            md += "\(prefix)\n\(msg.content)\n\n---\n\n"
        }

        if let path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try? md.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        return md
    }

    // MARK: - Index

    private struct SessionIndexEntry: Codable {
        let id: String
        let title: String
        let createdAt: Date
        let messageCount: Int
    }

    private func loadIndex() -> [SessionIndexEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder.kobold.decode([SessionIndexEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveIndex(entries: [SessionIndexEntry]? = nil) {
        let idx: [SessionIndexEntry]
        if let entries {
            idx = entries
        } else {
            // Rebuild from all session files
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
            idx = files
                .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "json" }
                .compactMap { url -> SessionIndexEntry? in
                    guard let data = try? Data(contentsOf: url),
                          let session = try? JSONDecoder.kobold.decode(CLISession.self, from: data) else { return nil }
                    return SessionIndexEntry(id: session.id, title: session.title, createdAt: session.createdAt, messageCount: session.messageCount)
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
        if let data = try? JSONEncoder.kobold.encode(idx) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

// MARK: - JSON Coding Helpers

private extension JSONEncoder {
    static let kobold: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let kobold: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
