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

// MARK: - MemoryEntry (Tag-based individual memories)

public struct MemoryEntry: Sendable, Codable {
    public let id: String
    public var text: String
    public var memoryType: String   // "kurzzeit", "langzeit", "wissen"
    public let timestamp: Date
    public var tags: [String]

    public init(id: String = UUID().uuidString, text: String, memoryType: String = "kurzzeit", timestamp: Date = Date(), tags: [String] = []) {
        self.id = id
        self.text = text
        self.memoryType = memoryType
        self.timestamp = timestamp
        self.tags = tags
    }

    // Backward-compatible decoding (old entries without memoryType)
    enum CodingKeys: String, CodingKey {
        case id, text, memoryType, timestamp, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        memoryType = try container.decodeIfPresent(String.self, forKey: .memoryType) ?? "kurzzeit"
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

// MARK: - MemoryStore
// Fully local — all data stored in ~/Library/Application Support/KoboldOS/Memory/

public actor MemoryStore {

    private var localEntries: [MemoryEntry] = []

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/Memory")
    }

    private var snapshotsDirectory: URL {
        storageDirectory.appendingPathComponent("snapshots")
    }

    private var legacyEntriesURL: URL {
        storageDirectory.appendingPathComponent("entries.json")
    }

    private func entryURL(_ id: String) -> URL {
        storageDirectory.appendingPathComponent("\(id).json")
    }

    public init(agentID: String? = nil, sessionID: String? = nil) {
        Task { await self.loadFromDisk() }
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        // Migrate legacy entries.json → individual files
        if fm.fileExists(atPath: legacyEntriesURL.path),
           let data = try? Data(contentsOf: legacyEntriesURL),
           let legacy = try? JSONDecoder().decode([MemoryEntry].self, from: data) {
            for entry in legacy {
                if let singleData = try? JSONEncoder().encode(entry) {
                    try? singleData.write(to: entryURL(entry.id))
                }
            }
            try? fm.removeItem(at: legacyEntriesURL)
            print("[MemoryStore] migrated \(legacy.count) entries to individual files")
        }

        // Load all individual entry files
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        localEntries = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MemoryEntry? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(MemoryEntry.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Add

    public func add(text: String, memoryType: String = "kurzzeit", tags: [String] = []) async throws -> MemoryEntry {
        let entry = MemoryEntry(text: text, memoryType: memoryType, tags: tags)
        localEntries.append(entry)
        try saveEntry(entry)
        // Async embedding — does not block the caller
        let capturedEntry = entry
        Task.detached(priority: .utility) {
            if let emb = await EmbeddingRunner.shared.embed(capturedEntry.text) {
                await EmbeddingStore.shared.upsert(
                    id: capturedEntry.id, text: capturedEntry.text,
                    embedding: emb, memoryType: capturedEntry.memoryType, tags: capturedEntry.tags
                )
            }
        }
        return entry
    }

    // MARK: - Update

    public func update(id: String, text: String? = nil, memoryType: String? = nil, tags: [String]? = nil) async throws -> MemoryEntry? {
        guard let index = localEntries.firstIndex(where: { $0.id == id }) else { return nil }
        if let text = text { localEntries[index].text = text }
        if let memoryType = memoryType { localEntries[index].memoryType = memoryType }
        if let tags = tags { localEntries[index].tags = tags }
        try saveEntry(localEntries[index])
        // Re-embed updated entry
        let capturedEntry = localEntries[index]
        Task.detached(priority: .utility) {
            if let emb = await EmbeddingRunner.shared.embed(capturedEntry.text) {
                await EmbeddingStore.shared.upsert(
                    id: capturedEntry.id, text: capturedEntry.text,
                    embedding: emb, memoryType: capturedEntry.memoryType, tags: capturedEntry.tags
                )
            }
        }
        return localEntries[index]
    }

    // MARK: - Delete

    public func delete(id: String) async throws -> Bool {
        let countBefore = localEntries.count
        localEntries.removeAll { $0.id == id }
        if localEntries.count < countBefore {
            deleteEntryFile(id: id)
            let capturedID = id
            Task.detached(priority: .utility) {
                await EmbeddingStore.shared.delete(id: capturedID)
            }
            return true
        }
        return false
    }

    // MARK: - Search (TF-IDF cosine similarity — semantic-like)

    public func search(query: String, nResults: Int = 3) async throws -> [String] {
        guard !localEntries.isEmpty else { return [] }
        let texts = localEntries.map { $0.text + " " + $0.tags.joined(separator: " ") }
        let results = VectorSearch.search(query: query, entries: texts, limit: nResults)
        return results.map { localEntries[$0.index].text }
    }

    // MARK: - Smart Search (by query, type, and/or tags)

    public func smartSearch(query: String = "", type: String? = nil, tags: [String]? = nil, limit: Int = 5) async throws -> [MemoryEntry] {
        var candidates = localEntries

        // Filter by type
        if let type = type, !type.isEmpty {
            candidates = candidates.filter { $0.memoryType == type }
        }

        // Filter by tags (any match)
        if let tags = tags, !tags.isEmpty {
            let searchTags = Set(tags.map { $0.lowercased() })
            candidates = candidates.filter { entry in
                let entryTags = Set(entry.tags.map { $0.lowercased() })
                return !searchTags.isDisjoint(with: entryTags)
            }
        }

        guard !candidates.isEmpty else { return [] }

        // If no query, return most recent
        if query.isEmpty {
            return Array(candidates.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
        }

        // TF-IDF search on candidates
        let texts = candidates.map { $0.text + " " + $0.tags.joined(separator: " ") + " " + $0.memoryType }
        let results = VectorSearch.search(query: query, entries: texts, limit: limit)
        return results.map { candidates[$0.index] }
    }

    // MARK: - Get All Entries

    public func allEntries() async -> [MemoryEntry] {
        localEntries.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Get by Type

    public func entriesByType(_ type: String) async -> [MemoryEntry] {
        localEntries.filter { $0.memoryType == type }.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Get All Tags

    public func allTags() async -> [String: Int] {
        var tagCounts: [String: Int] = [:]
        for entry in localEntries {
            for tag in entry.tags {
                tagCounts[tag.lowercased(), default: 0] += 1
            }
        }
        return tagCounts
    }

    // MARK: - Stats

    public func stats() async -> (total: Int, byType: [String: Int], tagCount: Int) {
        var byType: [String: Int] = [:]
        var allTags: Set<String> = []
        for entry in localEntries {
            byType[entry.memoryType, default: 0] += 1
            for tag in entry.tags { allTags.insert(tag.lowercased()) }
        }
        return (total: localEntries.count, byType: byType, tagCount: allTags.count)
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

    // MARK: - Persistence (individual files per entry)

    /// Save a single entry to its own JSON file.
    private func saveEntry(_ entry: MemoryEntry) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: entryURL(entry.id))
    }

    /// Remove a single entry file.
    private func deleteEntryFile(id: String) {
        try? FileManager.default.removeItem(at: entryURL(id))
    }

    // Legacy helper — kept for Snapshot restore which writes all entries at once
    private func saveLocalEntries() throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        for entry in localEntries {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: entryURL(entry.id))
        }
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
