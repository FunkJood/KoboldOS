import Foundation

// MARK: - VectorSearch (In-App TF-IDF Cosine Similarity)
// Pure Swift semantic-like search — no external dependencies.

public struct VectorSearch: Sendable {

    /// Tokenize text into normalized words
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }  // drop single chars
    }

    /// Build term frequency vector for a document
    static func termFrequency(_ tokens: [String]) -> [String: Double] {
        guard !tokens.isEmpty else { return [:] }
        var freq: [String: Double] = [:]
        for token in tokens {
            freq[token, default: 0] += 1
        }
        let total = Double(tokens.count)
        return freq.mapValues { $0 / total }
    }

    /// Compute IDF (inverse document frequency) across a corpus
    static func inverseDocumentFrequency(corpus: [[String: Double]]) -> [String: Double] {
        let n = Double(corpus.count)
        guard n > 0 else { return [:] }
        var docCount: [String: Double] = [:]
        for doc in corpus {
            for term in doc.keys {
                docCount[term, default: 0] += 1
            }
        }
        return docCount.mapValues { log(n / $0) + 1.0 }
    }

    /// Compute TF-IDF vector for a document given IDF weights
    static func tfidf(tf: [String: Double], idf: [String: Double]) -> [String: Double] {
        var vector: [String: Double] = [:]
        for (term, freq) in tf {
            vector[term] = freq * (idf[term] ?? 1.0)
        }
        return vector
    }

    /// Cosine similarity between two sparse vectors
    static func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0

        let allKeys = Set(a.keys).union(b.keys)
        for key in allKeys {
            let va = a[key] ?? 0
            let vb = b[key] ?? 0
            dotProduct += va * vb
            normA += va * va
            normB += vb * vb
        }

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dotProduct / denom
    }

    /// Search entries by semantic similarity using TF-IDF cosine similarity.
    /// Returns indices sorted by relevance (highest first).
    public static func search(
        query: String,
        entries: [String],
        limit: Int = 5,
        minScore: Double = 0.05
    ) -> [(index: Int, score: Double)] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty, !entries.isEmpty else { return [] }

        // Build TF vectors for all documents + query
        let entryTFs = entries.map { termFrequency(tokenize($0)) }
        let queryTF = termFrequency(queryTokens)

        // Compute IDF across corpus (entries + query as extra doc)
        let corpus = entryTFs + [queryTF]
        let idf = inverseDocumentFrequency(corpus: corpus)

        // Compute TF-IDF vectors
        let queryVec = tfidf(tf: queryTF, idf: idf)
        let entryVecs = entryTFs.map { tfidf(tf: $0, idf: idf) }

        // Score each entry
        var scored: [(index: Int, score: Double)] = []
        for (i, vec) in entryVecs.enumerated() {
            let score = cosineSimilarity(queryVec, vec)
            if score >= minScore {
                scored.append((index: i, score: score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
