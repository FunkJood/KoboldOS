import Foundation

// MARK: - DaemonClient
// Shared HTTP client for all CLI commands to communicate with KoboldOS daemon.

struct DaemonClient: Sendable {
    let baseURL: String
    let token: String

    init(port: Int = 8080, token: String = "kobold-secret") {
        self.baseURL = "http://localhost:\(port)"
        self.token = token
    }

    // MARK: - GET

    func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw DaemonClientError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DaemonClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DaemonClientError.httpError(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DaemonClientError.invalidJSON
        }
        return json
    }

    // MARK: - POST

    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw DaemonClientError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DaemonClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DaemonClientError.httpError(http.statusCode, body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DaemonClientError.invalidJSON
        }
        return json
    }

    // MARK: - SSE Stream

    func stream(_ path: String, body: [String: Any]) -> AsyncStream<[String: String]> {
        // Serialize body upfront to avoid sending [String: Any] across isolation
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        let urlStr = "\(baseURL)\(path)"
        let authToken = token

        return AsyncStream { continuation in
            Task {
                do {
                    guard let url = URL(string: urlStr) else { continuation.finish(); return }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = bodyData
                    req.timeoutInterval = 300

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        continuation.yield(["type": "error", "content": "Keine Antwort vom Daemon"])
                        continuation.finish()
                        return
                    }
                    guard http.statusCode == 200 else {
                        // Versuche Body zu lesen für bessere Fehlermeldung
                        var bodyChunks: [UInt8] = []
                        for try await byte in bytes { bodyChunks.append(byte); if bodyChunks.count > 500 { break } }
                        let errBody = String(bytes: bodyChunks, encoding: .utf8) ?? ""
                        continuation.yield(["type": "error", "content": "HTTP \(http.statusCode): \(errBody)"])
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("event: done") {
                            continuation.finish()
                            return
                        }
                        if line.hasPrefix("event: error") {
                            // Nächste data:-Zeile enthält den Fehler
                            continue
                        }
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            // Parse JSON to [String: String] for Sendable safety
                            if let data = jsonStr.data(using: .utf8),
                               let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                var safe: [String: String] = [:]
                                for (k, v) in rawJson {
                                    if let s = v as? String { safe[k] = s }
                                    else if let b = v as? Bool { safe[k] = b ? "true" : "false" }
                                    else if let n = v as? NSNumber { safe[k] = "\(n)" }
                                    else { safe[k] = "\(v)" }
                                }
                                continuation.yield(safe)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(["type": "error", "content": "Verbindungsfehler: \(error.localizedDescription)"])
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Health Check

    func isHealthy() async -> Bool {
        do {
            let result = try await get("/health")
            return result["status"] as? String == "ok"
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum DaemonClientError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case invalidJSON
    case daemonUnreachable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from daemon"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidJSON: return "Could not parse JSON response"
        case .daemonUnreachable: return "Daemon is not reachable. Start with: kobold daemon"
        }
    }
}
