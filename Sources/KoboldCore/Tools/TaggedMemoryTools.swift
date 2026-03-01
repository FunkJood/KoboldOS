import Foundation

// MARK: - Tagged Memory Tools
// New tag-based memory system: individual small memories with type + tags for fast search/filter

// MARK: - memory_save

public struct MemorySaveTool: Tool {
    public let name = "memory_save"
    public let description = "Save a single memory with type, tags, and emotional weight. Types: 'kurzzeit' (temporary), 'langzeit' (permanent), 'wissen' (knowledge), 'lösungen' (solutions that worked), 'fehler' (errors to avoid). For errors use negative valence, for solutions use positive valence and link to the error ID."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "text": ToolSchemaProperty(type: "string", description: "The memory content to save", required: true),
                "type": ToolSchemaProperty(type: "string", description: "Memory type: 'kurzzeit', 'langzeit', 'wissen', 'lösungen', or 'fehler'", required: true),
                "tags": ToolSchemaProperty(type: "string", description: "Comma-separated tags, e.g. 'coding,python,snippet'", required: false),
                "valence": ToolSchemaProperty(type: "string", description: "Emotional weight: -1.0 (negative/error) to +1.0 (positive/success). Default 0.0", required: false),
                "arousal": ToolSchemaProperty(type: "string", description: "Importance: 0.0 (low) to 1.0 (critical). Default 0.5", required: false),
                "linked_id": ToolSchemaProperty(type: "string", description: "Link to related memory ID (e.g. link a solution to its error)", required: false)
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
        let valence = Float(arguments["valence"] ?? "0.0") ?? 0.0
        let arousal = Float(arguments["arousal"] ?? "0.5") ?? 0.5
        let linkedId = arguments["linked_id"]

        let entry = try await store.add(
            text: text, memoryType: type, tags: tags,
            valence: valence, arousal: arousal,
            linkedEntryId: linkedId, source: "agent"
        )
        let tagDisplay = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
        let valenceDisplay = valence != 0.0 ? " V=\(String(format: "%.1f", valence))" : ""
        return "✓ Gespeichert (\(type))\(tagDisplay)\(valenceDisplay): \(text.prefix(60))... [ID: \(entry.id.prefix(8))]"
    }
}

// MARK: - memory_recall

public struct MemoryRecallTool: Tool {
    public let name = "memory_recall"
    public let description = "Search memories by query, type, or tags. Returns relevant memories sorted by emotional relevance. High-valence errors and solutions surface faster."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "query": ToolSchemaProperty(type: "string", description: "Search text (leave empty to browse by type/tags)", required: false),
                "type": ToolSchemaProperty(type: "string", description: "Filter by type: 'kurzzeit', 'langzeit', 'wissen', 'lösungen', 'fehler'", required: false),
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

        let results = try await store.emotionalSearch(query: query, type: type, tags: tags, limit: 10)

        // Gesamtstatistik für den Agenten (damit er weiß wie viele Erinnerungen existieren)
        let allEntries = await store.allEntries()
        let typeCounts = Dictionary(grouping: allEntries, by: { $0.memoryType }).mapValues { $0.count }
        let statsStr = typeCounts.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        let header = "📊 Gesamt: \(allEntries.count) Erinnerungen (\(statsStr))"

        if results.isEmpty {
            return "\(header)\nKeine passenden Erinnerungen für diese Suche gefunden."
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM.yy"

        let resultLines = results.enumerated().map { i, entry in
            let tagStr = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ", "))]"
            let valenceIcon = entry.valence > 0.3 ? "+" : entry.valence < -0.3 ? "!" : ""
            let linkedStr = entry.linkedEntryId != nil ? " → \(entry.linkedEntryId!.prefix(8))" : ""
            return "[\(i + 1)] \(valenceIcon)(\(entry.memoryType)) \(entry.text)\(tagStr)\(linkedStr) — \(fmt.string(from: entry.timestamp)) [ID: \(entry.id.prefix(8))]"
        }.joined(separator: "\n")
        return "\(header)\n\(resultLines)"
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
