import Foundation
import Accelerate

// MARK: - EmbeddedEntry

public struct EmbeddedEntry: Codable, Sendable {
    public let id: String
    public let text: String
    public let embedding: [Float]
    public let memoryType: String
    public let tags: [String]
    public let updatedAt: Date

    public init(id: String, text: String, embedding: [Float],
                memoryType: String, tags: [String], updatedAt: Date = Date()) {
        self.id = id; self.text = text; self.embedding = embedding
        self.memoryType = memoryType; self.tags = tags; self.updatedAt = updatedAt
    }
}

// MARK: - SearchHit

public struct EmbeddingSearchHit: Sendable {
    public let id: String
    public let text: String
    public let score: Float
    public let tags: [String]
    public let memoryType: String
}

// MARK: - EmbeddingStore

public actor EmbeddingStore {

    public static let shared = EmbeddingStore()

    private var entries: [String: EmbeddedEntry] = [:]
    private var saveWorkItem: DispatchWorkItem?

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/Memory/embeddings.json")
    }

    public init() {
        Task { await self.loadFromDisk() }
    }

    // MARK: - Upsert

    public func upsert(id: String, text: String, embedding: [Float],
                       memoryType: String, tags: [String]) {
        entries[id] = EmbeddedEntry(id: id, text: text, embedding: embedding,
                                    memoryType: memoryType, tags: tags)
        scheduleSave()
        print("[EmbeddingStore] embedded: \(id.prefix(8))… dim=\(embedding.count)")
    }

    // MARK: - Delete

    public func delete(id: String) {
        entries.removeValue(forKey: id)
        scheduleSave()
    }

    // MARK: - Semantic Search

    /// Returns top-K entries ranked by cosine similarity to `queryEmbedding`.
    public func search(queryEmbedding: [Float], limit: Int = 5) -> [EmbeddingSearchHit] {
        guard !entries.isEmpty else { return [] }

        var scored: [(EmbeddedEntry, Float)] = []
        for entry in entries.values {
            guard entry.embedding.count == queryEmbedding.count else { continue }
            let score = cosineSimilarity(queryEmbedding, entry.embedding)
            scored.append((entry, score))
        }

        let topK = scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        let hits = topK.map { (entry, score) in
            EmbeddingSearchHit(id: entry.id, text: entry.text, score: score,
                               tags: entry.tags, memoryType: entry.memoryType)
        }
        if let best = hits.first {
            print("[RAG] semantic hits: \(hits.count), score: \(String(format: "%.2f", best.score))")
        }
        return Array(hits)
    }

    // MARK: - Re-embed missing entries

    /// Called at startup: embeds all MemoryEntry objects that have no vector yet.
    /// Caller should pass `await memoryStore.allEntries()` after the store has loaded.
    public func reembedMissing(entries allMemories: [MemoryEntry]) async {
        let existing = Set(entries.keys)
        let missing = allMemories.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else {
            print("[EmbeddingStore] reembedMissing: all \(existing.count) entries already embedded")
            return
        }
        print("[EmbeddingStore] reembedMissing: embedding \(missing.count) entries…")
        for entry in missing {
            if let emb = await EmbeddingRunner.shared.embed(entry.text) {
                upsert(id: entry.id, text: entry.text, embedding: emb,
                       memoryType: entry.memoryType, tags: entry.tags)
            }
        }
        print("[EmbeddingStore] reembedMissing: done")
    }

    // MARK: - Entry count

    public func entryCount() -> Int { entries.count }

    // MARK: - Disk persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: EmbeddedEntry].self, from: data) else { return }
        entries = decoded
    }

    /// P12: Encoding auf Actor-Thread, Disk-Write via Task.detached (große Float-Arrays = CPU-intensiv)
    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = storeURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// Debounced save — max once every 2 seconds.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.saveToDisk() }
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: - vDSP cosine similarity

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_svesq(a, 1, &magA, n)
        vDSP_svesq(b, 1, &magB, n)
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
