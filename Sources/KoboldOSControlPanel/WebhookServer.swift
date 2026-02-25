import Foundation
import Network

// MARK: - Webhook Server (NWListener für eingehende HTTP Webhooks)

final class WebhookServer: @unchecked Sendable {
    static let shared = WebhookServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _isRunning = false
    private var _port: UInt16 = 0
    private var _receivedWebhooks: [(timestamp: Date, path: String, method: String, headers: [String: String], body: String)] = []
    private var _registeredPaths: Set<String> = []

    var isRunning: Bool { lock.withLock { _isRunning } }
    var port: UInt16 { lock.withLock { _port } }

    var receivedWebhooks: [(timestamp: Date, path: String, method: String, headers: [String: String], body: String)] {
        lock.withLock { _receivedWebhooks }
    }

    var registeredPaths: Set<String> {
        get { lock.withLock { _registeredPaths } }
    }

    private init() {
        // Restore registered paths from UserDefaults
        if let paths = UserDefaults.standard.stringArray(forKey: "kobold.webhook.paths") {
            _registeredPaths = Set(paths)
        }
    }

    func registerPath(_ path: String) {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        lock.withLock { _ = _registeredPaths.insert(normalized) }
        UserDefaults.standard.set(Array(registeredPaths), forKey: "kobold.webhook.paths")
    }

    func unregisterPath(_ path: String) {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        lock.withLock { _ = _registeredPaths.remove(normalized) }
        UserDefaults.standard.set(Array(registeredPaths), forKey: "kobold.webhook.paths")
    }

    // MARK: - Start/Stop

    func start(port: UInt16 = 0) -> Bool {
        stop()
        let targetPort = port > 0 ? port : UInt16(UserDefaults.standard.integer(forKey: "kobold.webhook.port"))
        let actualPort = targetPort > 0 ? targetPort : 8089

        do {
            let params = NWParameters.tcp
            let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: actualPort)!)
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[WebhookServer] Listening on port \(actualPort)")
                case .failed(let err):
                    print("[WebhookServer] Failed: \(err)")
                    self?.lock.withLock { self?._isRunning = false }
                default: break
                }
            }
            nwListener.start(queue: .global(qos: .utility))
            self.listener = nwListener
            lock.withLock {
                _isRunning = true
                _port = actualPort
            }
            return true
        } catch {
            print("[WebhookServer] Start error: \(error)")
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock {
            _isRunning = false
            _port = 0
        }
    }

    func clearReceived() {
        lock.withLock { _receivedWebhooks.removeAll() }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = request.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                self.sendResponse(connection: connection, status: 400, body: "Bad Request")
                return
            }

            let parts = firstLine.components(separatedBy: " ")
            let method = parts.first ?? "GET"
            let path = parts.count > 1 ? parts[1] : "/"

            // Parse headers
            var headers: [String: String] = [:]
            var headerEnd = false
            var bodyStart = 0
            for (i, line) in lines.enumerated() {
                if line.isEmpty {
                    headerEnd = true
                    bodyStart = i + 1
                    break
                }
                if i > 0, let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }

            let body = headerEnd && bodyStart < lines.count ? lines[bodyStart...].joined(separator: "\r\n") : ""

            // Store webhook
            self.lock.withLock {
                self._receivedWebhooks.append((
                    timestamp: Date(),
                    path: path,
                    method: method,
                    headers: headers,
                    body: body
                ))
                // Keep max 1000 webhooks
                if self._receivedWebhooks.count > 1000 {
                    self._receivedWebhooks.removeFirst(self._receivedWebhooks.count - 1000)
                }
            }

            print("[WebhookServer] Received \(method) \(path)")
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}")
        }
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : "Error"
        let bodyData = body.data(using: .utf8)!
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let response = header.data(using: .utf8)! + bodyData
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
