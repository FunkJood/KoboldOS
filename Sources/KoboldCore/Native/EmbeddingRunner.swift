import Foundation

// MARK: - EmbeddingRunner
// Sends text to Ollama's embedding API and returns a [Float] vector.
// Falls back gracefully when the embedding model is not available.

public actor EmbeddingRunner {

    public static let shared = EmbeddingRunner()

    private var modelName: String {
        UserDefaults.standard.string(forKey: "kobold.embedding.model") ?? "nomic-embed-text"
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    /// Returns a normalised float vector for `text`, or `nil` on failure.
    public func embed(_ text: String) async -> [Float]? {
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: "http://localhost:11434/api/embeddings") else { return nil }

        let body: [String: String] = ["model": modelName, "prompt": text]
        guard let bodyData = try? JSONEncoder().encode(body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[EmbeddingRunner] HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEmb = json["embedding"] as? [Double] else {
                print("[EmbeddingRunner] Unexpected response shape")
                return nil
            }
            return rawEmb.map { Float($0) }
        } catch {
            print("[EmbeddingRunner] Request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Quick health-check — tries to embed a single word and returns true on success.
    public func isAvailable() async -> Bool {
        let result = await embed("test")
        return result != nil
    }
}
