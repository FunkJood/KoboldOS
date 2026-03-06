#if os(macOS)
import Foundation

// MARK: - Trading Activity Log
// Zentraler Event-Buffer: Engine schreibt, Dashboard liest.
// Persistiert in JSON-Datei für Überlebung über App-Restarts.

public actor TradingActivityLog {
    public static let shared = TradingActivityLog()

    public struct Entry: Sendable, Codable {
        public let timestamp: Date
        public let message: String
        public let type: EntryType

        public enum EntryType: String, Sendable, Codable {
            case analysis   // Indikator-Berechnungen, Candle-Fetch
            case signal     // Strategie-Signale (auch verworfene)
            case trade      // Ausgeführte Orders
            case risk       // Risk-Check Ergebnisse
            case regime     // Regime-Änderungen
            case info       // Allgemeine Infos (Cycle-Summary etc.)
            case error      // Fehler (API-Errors etc.)
            case agent      // KI-Agent Entscheidungen
        }
    }

    private var entries: [Entry] = []
    private let maxEntries = 1000
    private let logFile: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        logFile = appSupport.appendingPathComponent("trading_log.json")

        // Lade gespeicherte Logs
        if let data = try? Data(contentsOf: logFile),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            // Nur Einträge der letzten 48 Stunden behalten
            let cutoff = Date().addingTimeInterval(-48 * 3600)
            entries = saved.filter { $0.timestamp > cutoff }.suffix(maxEntries).map { $0 }
        }
    }

    public func add(_ message: String, type: Entry.EntryType = .info) {
        let entry = Entry(timestamp: Date(), message: message, type: type)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        scheduleSave()
    }

    public func getRecent(limit: Int = 100) -> [Entry] {
        Array(entries.suffix(limit))
    }

    public func getAll() -> [Entry] {
        entries
    }

    public func clear() {
        entries.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s Debounce
            guard !Task.isCancelled else { return }
            await persistToDisk()
        }
    }

    private func persistToDisk() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: logFile, options: .atomic)
        }
    }

    /// Sofort speichern (für App-Exit)
    public func flush() {
        persistToDisk()
    }
}
#endif
