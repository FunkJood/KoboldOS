import Foundation

// MARK: - Archival Memory Tools (Letta/MemGPT-style)
// When core memory blocks are full, content is archived to persistent storage.
// Agent can search and insert into archival memory.

public struct ArchivalMemorySearchTool: Tool {
    public let name = "archival_memory_search"
    public let description = "Search archival memory for older information that was archived from core memory. Use when you need to recall something that may have been archived."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "query": ToolSchemaProperty(type: "string", description: "Search query", required: true),
                "label": ToolSchemaProperty(type: "string", description: "Optional: filter by original memory label", required: false)
            ],
            required: ["query"]
        )
    }

    private let store: ArchivalMemoryStore

    public init(store: ArchivalMemoryStore) {
        self.store = store
    }

    public func validate(arguments: [String: String]) throws {
        guard let query = arguments["query"], !query.isEmpty else {
            throw ToolError.missingRequired("query")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let query = arguments["query"] ?? ""
        let label = arguments["label"]
        let results = await store.search(query: query, label: label)
        if results.isEmpty {
            return "Keine archivierten Einträge gefunden für: \(query)"
        }
        return results.enumerated().map { i, entry in
            "[\(i + 1)] [\(entry.label)] \(entry.content)"
        }.joined(separator: "\n")
    }
}

public struct ArchivalMemoryInsertTool: Tool {
    public let name = "archival_memory_insert"
    public let description = "Insert information into archival memory for long-term storage. Use when core memory is full."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "label": ToolSchemaProperty(type: "string", description: "Category label", required: true),
                "content": ToolSchemaProperty(type: "string", description: "Content to archive", required: true)
            ],
            required: ["label", "content"]
        )
    }

    private let store: ArchivalMemoryStore

    public init(store: ArchivalMemoryStore) {
        self.store = store
    }

    public func validate(arguments: [String: String]) throws {
        guard let content = arguments["content"], !content.isEmpty else {
            throw ToolError.missingRequired("content")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let label = arguments["label"] ?? "general"
        let content = arguments["content"] ?? ""
        await store.insert(label: label, content: content)
        let count = await store.count()
        return "✓ Archiviert unter '\(label)' (Archiv: \(count) Einträge)"
    }
}

// MARK: - ArchivalMemoryStore

public struct ArchivalEntry: Codable, Sendable {
    public let id: String
    public let label: String
    public let content: String
    public let timestamp: Date
}

public actor ArchivalMemoryStore {
    public static let shared = ArchivalMemoryStore()

    private var entries: [ArchivalEntry] = []
    private let storeURL: URL

    init() {
        storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Memory/archival_memory.json")
        // Load is called from nonisolated init — read file synchronously
        if let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([ArchivalEntry].self, from: data) {
                entries = loaded
            }
        }
    }

    public func insert(label: String, content: String) {
        let entry = ArchivalEntry(
            id: UUID().uuidString,
            label: label,
            content: content,
            timestamp: Date()
        )
        entries.append(entry)
        saveToDisk()
    }

    public func search(query: String, label: String? = nil) -> [ArchivalEntry] {
        let queryLower = query.lowercased()
        return entries.filter { entry in
            let matchesLabel = label == nil || entry.label == label
            let matchesQuery = entry.content.lowercased().contains(queryLower) ||
                               entry.label.lowercased().contains(queryLower)
            return matchesLabel && matchesQuery
        }
    }

    public func count() -> Int {
        entries.count
    }

    public func allEntries() -> [ArchivalEntry] {
        entries.sorted { $0.timestamp > $1.timestamp }
    }

    public func totalSize() -> Int {
        entries.reduce(0) { $0 + $1.content.count }
    }

    private func saveToDisk() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ArchivalEntry].self, from: data) {
            entries = loaded
        }
    }
}
