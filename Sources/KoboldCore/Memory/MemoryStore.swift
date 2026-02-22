import Foundation

// MARK: - SnapshotInfo

public struct SnapshotInfo: Sendable, Codable {
    public let id: String
    public let createdAt: Date
    public let description: String
    public let entryCount: Int

    public init(id: String, createdAt: Date, description: String, entryCount: Int) {
        self.id = id
        self.createdAt = createdAt
        self.description = description
        self.entryCount = entryCount
    }
}

// MARK: - MemoryEntry

public struct MemoryEntry: Sendable, Codable {
    public let id: String
    public let text: String
    public let timestamp: Date
    public let tags: [String]

    public init(id: String = UUID().uuidString, text: String, timestamp: Date = Date(), tags: [String] = []) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.tags = tags
    }
}

// MARK: - MemoryStore
// Primary: ChromaDB at localhost:8008
// Fallback: Local JSON files in ~/Library/Application Support/KoboldOS/Memory/

public actor MemoryStore {

    private let chromaURL = URL(string: "http://127.0.0.1:8008")!
    private var localEntries: [MemoryEntry] = []
    private var useChroma: Bool = false

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/Memory")
    }

    private var snapshotsDirectory: URL {
        storageDirectory.appendingPathComponent("snapshots")
    }

    private var localEntriesURL: URL {
        storageDirectory.appendingPathComponent("entries.json")
    }

    public init(agentID: String? = nil, sessionID: String? = nil) {
        // Non-async init — load entries via task
        Task { await self.loadFromDisk() }
    }

    private func loadFromDisk() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("KoboldOS/Memory/entries.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        localEntries = entries
    }

    // MARK: - Setup

    public func checkChroma() async {
        useChroma = await health()
    }

    // MARK: - Add

    public func add(text: String, tags: [String] = []) async throws {
        if useChroma {
            try await addToChroma(text: text)
        } else {
            let entry = MemoryEntry(text: text, tags: tags)
            localEntries.append(entry)
            try saveLocalEntries()
        }
    }

    // MARK: - Search

    public func search(query: String, nResults: Int = 3) async throws -> [String] {
        if useChroma {
            return try await searchChroma(query: query, nResults: nResults)
        }
        return searchLocal(query: query, limit: nResults)
    }

    // MARK: - Snapshot System

    public func createSnapshot(description: String = "") async throws -> String {
        let id = UUID().uuidString
        let info = SnapshotInfo(
            id: id,
            createdAt: Date(),
            description: description.isEmpty ? "Snapshot \(id.prefix(8))" : description,
            entryCount: localEntries.count
        )

        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)

        let snapshotData = SnapshotData(info: info, entries: localEntries)
        let snapshotURL = snapshotsDirectory.appendingPathComponent("\(id).json")
        let data = try JSONEncoder().encode(snapshotData)
        try data.write(to: snapshotURL)

        print("[MemoryStore] Created snapshot: \(id) (\(localEntries.count) entries)")
        return id
    }

    public func restoreSnapshot(_ id: String) async throws {
        let snapshotURL = snapshotsDirectory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(SnapshotData.self, from: data) else {
            throw MemoryError.snapshotNotFound(id)
        }
        localEntries = snapshot.entries
        try saveLocalEntries()
        print("[MemoryStore] Restored snapshot: \(id)")
    }

    public func listSnapshots() async -> [SnapshotInfo] {
        let fm = FileManager.default
        try? fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SnapshotInfo? in
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(SnapshotData.self, from: data) else { return nil }
                return snapshot.info
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func deleteSnapshot(_ id: String) async throws {
        let url = snapshotsDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MemoryError.snapshotNotFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - ChromaDB

    private func addToChroma(text: String) async throws {
        var request = URLRequest(url: chromaURL.appendingPathComponent("/memory/add"))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MemoryError.addFailed
        }
    }

    private func searchChroma(query: String, nResults: Int) async throws -> [String] {
        var request = URLRequest(url: chromaURL.appendingPathComponent("/memory/search"))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "n_results": nResults])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MemoryError.searchFailed
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [String] ?? []
    }

    private func searchLocal(query: String, limit: Int) -> [String] {
        let q = query.lowercased()
        return localEntries
            .filter { $0.text.lowercased().contains(q) }
            .prefix(limit)
            .map { $0.text }
    }

    private func saveLocalEntries() throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(localEntries)
        try data.write(to: localEntriesURL)
    }

    // MARK: - Health

    public func health() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8008/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    public func getLocalEntryCount() -> Int { localEntries.count }
}

// MARK: - Private Types

private struct SnapshotData: Codable {
    let info: SnapshotInfo
    let entries: [MemoryEntry]
}

// MARK: - MemoryError

public enum MemoryError: Error, LocalizedError {
    case addFailed, searchFailed
    case snapshotNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .addFailed: return "Failed to add to memory"
        case .searchFailed: return "Memory search failed"
        case .snapshotNotFound(let id): return "Snapshot not found: \(id)"
        }
    }
}
