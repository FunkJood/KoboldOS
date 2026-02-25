import Foundation

// MARK: - MQTT Client Wrapper (mosquitto CLI)
// Provides a persistent subscription mechanism for MQTT topics

final class MQTTClient: @unchecked Sendable {
    static let shared = MQTTClient()

    private let lock = NSLock()
    private var _subscriptions: [String: Process] = [:]
    private var _messages: [(topic: String, payload: String, timestamp: Date)] = []

    var activeSubscriptions: [String] { lock.withLock { Array(_subscriptions.keys) } }

    var recentMessages: [(topic: String, payload: String, timestamp: Date)] {
        lock.withLock { _messages }
    }

    private init() {}

    func subscribe(topic: String, host: String, port: String = "1883", username: String = "", password: String = "") -> Bool {
        let mosquittoSub = findMosquitto("mosquitto_sub")
        guard let path = mosquittoSub else { return false }

        // Don't duplicate subscriptions
        if lock.withLock({ _subscriptions[topic] != nil }) { return true }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        var args = ["-h", host, "-p", port, "-t", topic, "-v"]
        if !username.isEmpty { args += ["-u", username] }
        if !password.isEmpty { args += ["-P", password] }
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // mosquitto_sub -v outputs: "topic payload"
            let parts = trimmed.components(separatedBy: " ")
            let msgTopic = parts.first ?? topic
            let payload = parts.dropFirst().joined(separator: " ")

            self?.lock.withLock {
                self?._messages.append((topic: msgTopic, payload: payload, timestamp: Date()))
                if (self?._messages.count ?? 0) > 500 {
                    self?._messages.removeFirst((self?._messages.count ?? 0) - 500)
                }
            }
        }

        do {
            try process.run()
            lock.withLock { _subscriptions[topic] = process }
            return true
        } catch {
            print("[MQTTClient] Subscribe error: \(error)")
            return false
        }
    }

    func unsubscribe(topic: String) {
        lock.withLock {
            if let process = _subscriptions.removeValue(forKey: topic) {
                process.terminate()
            }
        }
    }

    func unsubscribeAll() {
        lock.withLock {
            for (_, process) in _subscriptions {
                process.terminate()
            }
            _subscriptions.removeAll()
        }
    }

    func clearMessages() {
        lock.withLock { _messages.removeAll() }
    }

    private func findMosquitto(_ name: String) -> String? {
        let paths = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
