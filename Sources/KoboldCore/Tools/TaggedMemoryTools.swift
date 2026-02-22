import Foundation

// MARK: - Tagged Memory Tools
// New tag-based memory system: individual small memories with type + tags for fast search/filter

// MARK: - memory_save

public struct MemorySaveTool: Tool {
    public let name = "memory_save"
    public let description = "Save a single memory with type and tags. Prefer this over core_memory_append for new memories."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "text": ToolSchemaProperty(type: "string", description: "The memory content to save", required: true),
                "type": ToolSchemaProperty(type: "string", description: "Memory type: 'langzeit', 'kurzzeit', or 'wissen'", required: true),
                "tags": ToolSchemaProperty(type: "string", description: "Comma-separated tags, e.g. 'coding,python,snippet'", required: false)
            ],
            required: ["text", "type"]
        )
    }

    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func validate(arguments: [String: String]) throws {
        guard let text = arguments["text"], !text.isEmpty else {
            throw ToolError.missingRequired("text")
        }
        guard let type = arguments["type"], !type.isEmpty else {
            throw ToolError.missingRequired("type")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let text = arguments["text"] ?? ""
        let type = arguments["type"] ?? "kurzzeit"
        let tagsStr = arguments["tags"] ?? ""
        let tags = tagsStr.isEmpty ? [] : tagsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let entry = try await store.add(text: text, memoryType: type, tags: tags)
        let tagDisplay = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
        return "✓ Gespeichert (\(type))\(tagDisplay): \(text.prefix(60))... [ID: \(entry.id.prefix(8))]"
    }
}

// MARK: - memory_recall

public struct MemoryRecallTool: Tool {
    public let name = "memory_recall"
    public let description = "Search memories by query, type, or tags. Returns relevant memories sorted by relevance."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "query": ToolSchemaProperty(type: "string", description: "Search text (leave empty to browse by type/tags)", required: false),
                "type": ToolSchemaProperty(type: "string", description: "Filter by type: 'langzeit', 'kurzzeit', 'wissen'", required: false),
                "tags": ToolSchemaProperty(type: "string", description: "Filter by tags (comma-separated)", required: false)
            ],
            required: []
        )
    }

    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func validate(arguments: [String: String]) throws {}

    public func execute(arguments: [String: String]) async throws -> String {
        let query = arguments["query"] ?? ""
        let type = arguments["type"]
        let tagsStr = arguments["tags"] ?? ""
        let tags: [String]? = tagsStr.isEmpty ? nil : tagsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let results = try await store.smartSearch(query: query, type: type, tags: tags, limit: 10)
        if results.isEmpty {
            return "Keine Erinnerungen gefunden."
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM.yy"

        return results.enumerated().map { i, entry in
            let tagStr = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ", "))]"
            return "[\(i + 1)] (\(entry.memoryType)) \(entry.text)\(tagStr) — \(fmt.string(from: entry.timestamp)) [ID: \(entry.id.prefix(8))]"
        }.joined(separator: "\n")
    }
}

// MARK: - memory_forget

public struct MemoryForgetTool: Tool {
    public let name = "memory_forget"
    public let description = "Delete a single memory by its ID."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "id": ToolSchemaProperty(type: "string", description: "Memory ID (or first 8 characters)", required: true)
            ],
            required: ["id"]
        )
    }

    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func validate(arguments: [String: String]) throws {
        guard let id = arguments["id"], !id.isEmpty else {
            throw ToolError.missingRequired("id")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let idPrefix = arguments["id"] ?? ""

        // Support partial IDs (first 8 chars)
        let allEntries = await store.allEntries()
        guard let match = allEntries.first(where: { $0.id.hasPrefix(idPrefix) || $0.id == idPrefix }) else {
            return "Keine Erinnerung mit ID '\(idPrefix)' gefunden."
        }

        let deleted = try await store.delete(id: match.id)
        return deleted ? "✓ Erinnerung gelöscht: \(match.text.prefix(40))..." : "Fehler beim Löschen."
    }
}
