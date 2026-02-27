import Foundation
import SwiftUI
import KoboldCore

/// Extension to RuntimeViewModel for improved stability and error handling
extension RuntimeViewModel {

    /// Executes a task with timeout monitoring and error handling
    func executeTaskWithMonitoring<T: Sendable>(
        timeout: TimeInterval = 30.0,
        operation: @Sendable @escaping () async throws -> T
    ) async -> Result<T, Error> {
        let task = Task<T, Error> {
            try await operation()
        }

        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
            throw CancellationError()
        }

        do {
            let result = try await task.result.get()
            timeoutTask.cancel()
            return .success(result)
        } catch {
            task.cancel()
            timeoutTask.cancel()
            if error is CancellationError {
                DaemonLog.shared.add("Task timed out after \(timeout)s", category: .system)
                return .failure(RuntimeError.timeout)
            } else {
                DaemonLog.shared.add("Task failed: \(error)", category: .system)
                return .failure(error)
            }
        }
    }

    /// Improved session saving with better error handling
    func saveSessionsWithRetry(maxRetries: Int = 3) {
        let snapshot = sessions
        let url = sessionsURL

        Task.detached(priority: .utility) {
            var retryCount = 0

            while retryCount < maxRetries {
                do {
                    // Deduplicate off main thread
                    var seen = Set<UUID>()
                    let deduped = snapshot.filter { seen.insert($0.id).inserted }

                    // Ensure directory exists
                    let dir = url.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                    // Encode and write data with proper error handling
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(deduped)
                    try data.write(to: url, options: .atomic)

                    return
                } catch {
                    retryCount += 1
                    if retryCount < maxRetries {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
    }

    /// Custom error types for runtime issues
    enum RuntimeError: Error, LocalizedError {
        case timeout
        case sessionConflict
        case storageError(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Operation timed out"
            case .sessionConflict:
                return "Session conflict detected"
            case .storageError(let message):
                return "Storage error: \(message)"
            }
        }
    }
}

// MARK: - Team Persistence & Execution

extension RuntimeViewModel {

    var teamsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/teams.json")
    }

    private var teamMessagesDirExt: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/team_messages")
    }

    func loadTeams() {
        guard let data = try? Data(contentsOf: teamsURL) else { return }
        do {
            let loaded = try JSONDecoder().decode([AgentTeam].self, from: data)
            teams = loaded
        } catch {
            print("[Teams] Failed to decode teams: \(error)")
        }
    }

    func saveTeams() {
        let snapshot = teams
        let url = teamsURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    func loadTeamMessages(for teamId: UUID) {
        let url = teamMessagesDir.appendingPathComponent("\(teamId.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let loaded = try JSONDecoder().decode([GroupMessage].self, from: data)
            teamMessages[teamId] = loaded
        } catch {
            print("[Teams] Failed to decode team messages: \(error)")
        }
    }

    func saveTeamMessages(for teamId: UUID) {
        guard let msgs = teamMessages[teamId] else { return }
        let snapshot = msgs
        let url = teamMessagesDir.appendingPathComponent("\(teamId.uuidString).json")
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    func sendTeamAgentMessage(prompt: String, profile: String) async -> String {
        guard let url = URL(string: baseURL + "/agent") else { return "URL-Fehler" }

        let provider = "ollama"
        let agentModel = await ModelConfigManager.shared.getModel(for: profile)
        let model = agentModel.model
        let apiKey = UserDefaults.standard.string(forKey: "kobold.provider.\(provider).key") ?? ""

        let payload: [String: Any] = [
            "message": prompt,
            "agent_type": profile,
            "provider": provider,
            "model": model,
            "api_key": apiKey,
            "temperature": 0.7
        ]

        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 300

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return "HTTP-Fehler \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["output"] as? String ?? json["response"] as? String ?? String(data: data, encoding: .utf8) ?? "Keine Antwort"
            }
            return String(data: data, encoding: .utf8) ?? "Keine Antwort"
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }
}