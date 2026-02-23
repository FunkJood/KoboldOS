import Foundation

// MARK: - SubCoordinateTeamTool
// Allows the main agent to delegate a question/task to a Team (Beratungsgremium).
// The team runs its full discourse model (R1 Analysis → R2 Discussion → R3 Synthesis)
// and returns the synthesized result.

public struct SubCoordinateTeamTool: Tool, Sendable {
    public let name = "coordinate_team"
    public let description = "Übergib eine Frage oder Aufgabe an ein Team-Beratungsgremium. Das Team diskutiert in 3 Runden (Analyse → Diskussion → Synthese) und gibt eine konsolidierte Antwort zurück."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "team_name": ToolSchemaProperty(
                    type: "string",
                    description: "Name des Teams das die Aufgabe bearbeiten soll (z.B. 'Code-Review Team', 'Strategie Team'). Bei leer wird das erste verfügbare Team gewählt.",
                    required: false
                ),
                "question": ToolSchemaProperty(
                    type: "string",
                    description: "Die Frage oder Aufgabe die das Team diskutieren soll",
                    required: true
                ),
                "context": ToolSchemaProperty(
                    type: "string",
                    description: "Zusätzlicher Kontext für das Team (Code-Snippets, Hintergrund-Info etc.)",
                    required: false
                )
            ],
            required: ["question"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard let question = arguments["question"], !question.isEmpty else {
            throw ToolError.missingRequired("question")
        }

        let teamName = arguments["team_name"] ?? ""
        let context = arguments["context"] ?? ""

        // Post notification to trigger team discussion in RuntimeViewModel
        let resultId = UUID().uuidString
        let semaphore = TeamResultWaiter.shared

        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldCoordinateTeam"),
                object: nil,
                userInfo: [
                    "team_name": teamName,
                    "question": question,
                    "context": context,
                    "result_id": resultId
                ]
            )
        }

        // Wait for result (max 5 minutes)
        let result = await semaphore.waitForResult(id: resultId, timeout: 300)
        return result ?? "Team-Diskussion konnte nicht abgeschlossen werden (Timeout)."
    }
}

// MARK: - TeamResultWaiter
// Thread-safe async waiter for team discussion results

public actor TeamResultWaiter {
    public static let shared = TeamResultWaiter()

    private var results: [String: String] = [:]
    private var continuations: [String: CheckedContinuation<String?, Never>] = [String: CheckedContinuation<String?, Never>]()
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    public func waitForResult(id: String, timeout: TimeInterval) async -> String? {
        // Check if result already arrived
        if let result = results.removeValue(forKey: id) {
            return result
        }

        // Wait with timeout
        return await withCheckedContinuation { continuation in
            self.continuations[id] = continuation
            self.timeoutTasks[id] = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = self.continuations.removeValue(forKey: id) {
                    cont.resume(returning: nil)
                }
                self.timeoutTasks.removeValue(forKey: id)
            }
        }
    }

    public func deliverResult(id: String, result: String) {
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: result)
        } else {
            results[id] = result
        }
    }
}
