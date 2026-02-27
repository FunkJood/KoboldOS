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

    // MARK: - SSE Stream (Delegate-based)
    // URLSession.bytes(for:) buffers entire responses from raw HTTP servers on macOS.
    // Using URLSessionDataDelegate guarantees real-time incremental delivery of SSE events.

    func stream(_ path: String, body: [String: Any]) -> AsyncStream<[String: String]> {
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        let urlStr = "\(baseURL)\(path)"
        let authToken = token

        return AsyncStream { continuation in
            guard let url = URL(string: urlStr) else { continuation.finish(); return }

            let delegate = CLISSEDelegate(continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
            req.timeoutInterval = 300

            let task = session.dataTask(with: req)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
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

// MARK: - SSE Delegate (real-time event delivery)

private final class CLISSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<[String: String]>.Continuation
    private var buffer = ""
    private var finished = false

    init(continuation: AsyncStream<[String: String]>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            continuation.yield(["type": "error", "content": "HTTP \(http.statusCode)"])
            continuation.finish()
            finished = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk

        // Parse complete SSE event blocks (delimited by \n\n)
        while let range = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            for line in eventBlock.components(separatedBy: "\n") {
                if line.hasPrefix("event: done") {
                    continuation.finish()
                    finished = true
                    return
                }
                if line.hasPrefix("data: ") {
                    let jsonStr = String(line.dropFirst(6))
                    if let jsonData = jsonStr.data(using: .utf8),
                       let rawJson = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
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
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            continuation.yield(["type": "error", "content": "Verbindungsfehler: \(error.localizedDescription)"])
        }
        continuation.finish()
        finished = true
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
