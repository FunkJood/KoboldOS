import Foundation

// MARK: - QdrantService
// REST-Client für Qdrant-Vektordatenbank (localhost:6333).
// Wird von EmbeddingStore als optionales Backend genutzt.
// Bei 18k+ Einträgen ist HNSW-Index deutlich schneller als linearer vDSP-Scan.

public actor QdrantService {

    public static let shared = QdrantService()

    private let collectionName = "kobold_memories"
    private var isReachable = false
    private var lastHealthCheck: Date = .distantPast

    // MARK: - Configuration

    private var baseURL: String {
        let url = UserDefaults.standard.string(forKey: "kobold.qdrant.url") ?? "http://localhost:6333"
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    public nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kobold.qdrant.enabled")
    }

    private init() {}

    // MARK: - Health Check

    /// Prüft ob Qdrant erreichbar ist (max alle 30s gecached)
    public func checkHealth() async -> Bool {
        // Cache für 30 Sekunden
        if Date().timeIntervalSince(lastHealthCheck) < 30 { return isReachable }

        guard let url = URL(string: "\(baseURL)/healthz") else {
            isReachable = false
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3  // Schneller Timeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            isReachable = ok
            lastHealthCheck = Date()
            if ok { print("[Qdrant] Verbunden: \(baseURL)") }
            return ok
        } catch {
            isReachable = false
            lastHealthCheck = Date()
            return false
        }
    }

    // MARK: - Collection Management

    /// Erstellt die Collection falls sie nicht existiert (768-dim Cosine, HNSW-Index)
    public func ensureCollection(vectorSize: Int = 768) async -> Bool {
        guard isEnabled else { return false }
        guard await checkHealth() else { return false }

        // Prüfe ob Collection existiert
        if let url = URL(string: "\(baseURL)/collections/\(collectionName)") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                print("[Qdrant] Collection '\(collectionName)' existiert")
                return true
            }
        }

        // Erstelle Collection
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "vectors": [
                "size": vectorSize,
                "distance": "Cosine"
            ],
            "on_disk_payload": true  // RAM-effizient bei vielen Einträgen
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                print("[Qdrant] Collection '\(collectionName)' erstellt (dim=\(vectorSize))")
                // Payload-Indizes für schnelle Filterung erstellen
                await createPayloadIndex(field: "type", schema: "keyword")
                await createPayloadIndex(field: "tags", schema: "keyword")
                return true
            } else {
                print("[Qdrant] Collection-Erstellung fehlgeschlagen: HTTP \(status)")
                return false
            }
        } catch {
            print("[Qdrant] Collection-Erstellung Fehler: \(error.localizedDescription)")
            return false
        }
    }

    private func createPayloadIndex(field: String, schema: String) async {
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)/index") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        let body: [String: Any] = ["field_name": field, "field_schema": schema]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Upsert

    /// Speichert einen Vektor mit Payload in Qdrant
    public func upsert(id: String, vector: [Float], text: String,
                       memoryType: String, tags: [String]) async -> Bool {
        guard isEnabled, isReachable else { return false }
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)/points") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let point: [String: Any] = [
            "id": id,
            "vector": vector,
            "payload": [
                "text": text,
                "type": memoryType,
                "tags": tags,
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ] as [String: Any]
        ]
        let body: [String: Any] = ["points": [point]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Batch-Upsert für initiale Migration
    public func upsertBatch(points: [(id: String, vector: [Float], text: String,
                                       memoryType: String, tags: [String])]) async -> Bool {
        guard isEnabled, isReachable else { return false }
        guard !points.isEmpty else { return true }
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)/points") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30  // Batch braucht mehr Zeit

        let pointDicts: [[String: Any]] = points.map { point in
            [
                "id": point.id,
                "vector": point.vector,
                "payload": [
                    "text": point.text,
                    "type": point.memoryType,
                    "tags": point.tags,
                    "updated_at": ISO8601DateFormatter().string(from: Date())
                ] as [String: Any]
            ]
        }
        let body: [String: Any] = ["points": pointDicts]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok { print("[Qdrant] Batch-Upsert: \(points.count) Punkte") }
            return ok
        } catch {
            print("[Qdrant] Batch-Upsert Fehler: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Search

    /// Semantische Suche via HNSW-Index — O(log n) statt O(n)
    public func search(queryVector: [Float], limit: Int = 5,
                       typeFilter: String? = nil,
                       scoreThreshold: Float = 0.3) async -> [QdrantSearchHit] {
        guard isEnabled, isReachable else { return [] }
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)/points/query") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        var body: [String: Any] = [
            "query": queryVector,
            "limit": limit,
            "with_payload": true,
            "with_vector": false,
            "score_threshold": scoreThreshold
        ]

        // Optionaler Typ-Filter
        if let type = typeFilter {
            body["filter"] = [
                "must": [
                    ["key": "type", "match": ["value": type]]
                ]
            ]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let points = result["points"] as? [[String: Any]] else { return [] }

            return points.compactMap { point -> QdrantSearchHit? in
                guard let id = point["id"] as? String,
                      let score = point["score"] as? Double,
                      let payload = point["payload"] as? [String: Any],
                      let text = payload["text"] as? String else { return nil }
                let type = payload["type"] as? String ?? ""
                let tags = payload["tags"] as? [String] ?? []
                return QdrantSearchHit(id: id, text: text, score: Float(score),
                                       memoryType: type, tags: tags)
            }
        } catch {
            return []
        }
    }

    // MARK: - Delete

    /// Löscht einen Punkt aus Qdrant
    public func delete(id: String) async -> Bool {
        guard isEnabled, isReachable else { return false }
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)/points/delete") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        let body: [String: Any] = ["points": [id]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Collection Stats

    /// Gibt die Anzahl der Vektoren in der Collection zurück
    public func pointCount() async -> Int {
        guard isEnabled, isReachable else { return 0 }
        guard let url = URL(string: "\(baseURL)/collections/\(collectionName)") else { return 0 }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let count = result["points_count"] as? Int else { return 0 }
            return count
        } catch {
            return 0
        }
    }
}

// MARK: - QdrantSearchHit

public struct QdrantSearchHit: Sendable {
    public let id: String
    public let text: String
    public let score: Float
    public let memoryType: String
    public let tags: [String]
}
