import Foundation
import Accelerate

// MARK: - EmbeddedEntry

public struct EmbeddedEntry: Codable, Sendable {
    public let id: String
    public let text: String
    public let embedding: [Float]
    public let memoryType: String
    public let memoryTypes: [String]
    public let tags: [String]
    public let updatedAt: Date

    public init(id: String, text: String, embedding: [Float],
                memoryType: String, memoryTypes: [String]? = nil, tags: [String], updatedAt: Date = Date()) {
        self.id = id; self.text = text; self.embedding = embedding
        self.memoryType = memoryType; self.memoryTypes = memoryTypes ?? [memoryType]
        self.tags = tags; self.updatedAt = updatedAt
    }

    // Backward-compat decoding
    enum CodingKeys: String, CodingKey {
        case id, text, embedding, memoryType, memoryTypes, tags, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        embedding = try c.decode([Float].self, forKey: .embedding)
        let primary = try c.decode(String.self, forKey: .memoryType)
        memoryType = primary
        memoryTypes = try c.decodeIfPresent([String].self, forKey: .memoryTypes) ?? [primary]
        tags = try c.decode([String].self, forKey: .tags)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
                       memoryType: String, memoryTypes: [String]? = nil, tags: [String]) {
        let types = memoryTypes ?? [memoryType]
        entries[id] = EmbeddedEntry(id: id, text: text, embedding: embedding,
                                    memoryType: memoryType, memoryTypes: types, tags: tags)
        scheduleSave()

        // Qdrant-Sync (Fire & Forget — blockiert nicht den Hauptpfad)
        Task.detached(priority: .utility) {
            await QdrantService.shared.upsert(id: id, vector: embedding, text: text,
                                               memoryType: memoryType, memoryTypes: types, tags: tags)
        }
        print("[EmbeddingStore] embedded: \(id.prefix(8))… dim=\(embedding.count)")
    }

    // MARK: - Delete

    public func delete(id: String) {
        entries.removeValue(forKey: id)
        scheduleSave()

        // Qdrant-Sync
        Task.detached(priority: .utility) {
            await QdrantService.shared.delete(id: id)
        }
    }

    // MARK: - Semantic Search

    /// Returns top-K entries ranked by cosine similarity.
    /// Nutzt Qdrant HNSW-Index wenn verfügbar (O(log n)), sonst vDSP-Fallback (O(n)).
    public func search(queryEmbedding: [Float], limit: Int = 5,
                       typeFilter: String? = nil) async -> [EmbeddingSearchHit] {
        // Qdrant-Pfad: HNSW-Index für schnelle Suche bei großen Datenmengen
        if QdrantService.shared.isEnabled {
            let qdrantHits = await QdrantService.shared.search(
                queryVector: queryEmbedding, limit: limit, typeFilter: typeFilter)
            if !qdrantHits.isEmpty {
                let hits = qdrantHits.map {
                    EmbeddingSearchHit(id: $0.id, text: $0.text, score: $0.score,
                                       tags: $0.tags, memoryType: $0.memoryType)
                }
                if let best = hits.first {
                    print("[RAG] Qdrant HNSW hits: \(hits.count), score: \(String(format: "%.2f", best.score))")
                }
                return hits
            }
        }

        // vDSP-Fallback: Linearer Scan (gut bis ~10k Einträge)
        guard !entries.isEmpty else { return [] }

        var scored: [(EmbeddedEntry, Float)] = []
        for entry in entries.values {
            guard entry.embedding.count == queryEmbedding.count else { continue }
            // Optionaler Typ-Filter
            if let typeFilter, entry.memoryType != typeFilter { continue }
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
            print("[RAG] vDSP fallback hits: \(hits.count), score: \(String(format: "%.2f", best.score))")
        }
        return Array(hits)
    }

    // MARK: - Re-embed missing entries

    /// Called at startup: embeds all MemoryEntry objects that have no vector yet.
    /// Caller should pass `await memoryStore.allEntries()` after the store has loaded.
    /// Synchronisiert auch bestehende Embeddings nach Qdrant wenn aktiviert.
    public func reembedMissing(entries allMemories: [MemoryEntry]) async {
        let existing = Set(entries.keys)
        let missing = allMemories.filter { !existing.contains($0.id) }

        if missing.isEmpty {
            print("[EmbeddingStore] reembedMissing: all \(existing.count) entries already embedded")
        } else {
            print("[EmbeddingStore] reembedMissing: embedding \(missing.count) entries…")
            for entry in missing {
                if let emb = await EmbeddingRunner.shared.embed(entry.text) {
                    upsert(id: entry.id, text: entry.text, embedding: emb,
                           memoryType: entry.memoryType, memoryTypes: entry.memoryTypes, tags: entry.tags)
                }
            }
            print("[EmbeddingStore] reembedMissing: done")
        }

        // Qdrant-Sync: Bestehende Embeddings nach Qdrant migrieren wenn nötig
        await syncToQdrantIfNeeded()
    }

    /// Migriert alle lokalen Embeddings nach Qdrant (einmalig beim Start)
    private func syncToQdrantIfNeeded() async {
        guard QdrantService.shared.isEnabled else { return }
        guard await QdrantService.shared.ensureCollection(vectorSize: entries.values.first?.embedding.count ?? 768) else {
            print("[EmbeddingStore] Qdrant nicht erreichbar — nutze vDSP-Fallback")
            return
        }

        let qdrantCount = await QdrantService.shared.pointCount()
        let localCount = entries.count

        // Nur migrieren wenn Qdrant deutlich weniger Einträge hat
        guard qdrantCount < localCount - 5 else {
            print("[EmbeddingStore] Qdrant synced (\(qdrantCount)/\(localCount))")
            return
        }

        print("[EmbeddingStore] Qdrant-Migration: \(qdrantCount) → \(localCount) Einträge…")

        // Batch-Upsert in Gruppen von 100
        let allEntries = Array(entries.values)
        let batchSize = 100
        for start in stride(from: 0, to: allEntries.count, by: batchSize) {
            let end = min(start + batchSize, allEntries.count)
            let batch = allEntries[start..<end].map { entry in
                (id: entry.id, vector: entry.embedding, text: entry.text,
                 memoryType: entry.memoryType, memoryTypes: entry.memoryTypes, tags: entry.tags)
            }
            let _ = await QdrantService.shared.upsertBatch(points: batch)
        }
        print("[EmbeddingStore] Qdrant-Migration abgeschlossen")
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
