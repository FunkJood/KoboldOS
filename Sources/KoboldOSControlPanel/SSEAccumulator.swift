import Foundation

// MARK: - SSEAccumulator
// Thread-safe actor that processes SSE events from /agent/stream off the MainActor.
// Batches ThinkingEntry steps for periodic UI flush (every 300ms) and accumulates
// the complete result for final application after the stream ends.

actor SSEAccumulator {

    // MARK: - Flush Result (periodic 300ms batch)

    struct FlushResult: Sendable {
        let steps: [ThinkingEntry]
        let toolStepCount: Int
        let contextPromptTokens: Int?
        let contextCompletionTokens: Int?
        let contextUsagePercent: Double?
        let contextWindowSize: Int?
        let thoughtNotifications: [String]
        let toolNotifications: [String]
    }

    // MARK: - Final Result (after stream ends)

    struct FinalResult: Sendable {
        let finalAnswer: String
        let thinkingSteps: [ThinkingEntry]
        let checklistActions: [(action: String, items: [String]?, index: Int?)]
        let error: String?
        let interactiveMessages: [(text: String, options: [InteractiveOption])]
        let embedMessages: [(path: String, caption: String)]
        let toolStepCount: Int
        let confidence: Double?
    }

    // MARK: - Accumulated State

    private var pendingSteps: [ThinkingEntry] = []
    private var allThinkingSteps: [ThinkingEntry] = []
    private var totalToolStepCount: Int = 0
    private var finalAnswerParts: [String] = []
    private var lastConfidence: Double? = nil
    private var errorMessage: String? = nil
    private var _isDone: Bool = false

    // Context info (latest values)
    private var promptTokens: Int? = nil
    private var completionTokens: Int? = nil
    private var usagePercent: Double? = nil
    private var windowSize: Int? = nil

    // Pending context info for next flush
    private var pendingPromptTokens: Int? = nil
    private var pendingCompletionTokens: Int? = nil
    private var pendingUsagePercent: Double? = nil
    private var pendingWindowSize: Int? = nil

    // Notifications queued for next flush
    private var pendingThoughtNotifications: [String] = []
    private var pendingToolNotifications: [String] = []

    // Checklist, interactive, embed accumulation
    private var checklistActions: [(action: String, items: [String]?, index: Int?)] = []
    private var interactiveMessages: [(text: String, options: [InteractiveOption])] = []
    private var embedMessages: [(path: String, caption: String)] = []

    // MARK: - Process Event

    func processEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        let content = json["content"] as? String ?? ""
        let tool = json["tool"] as? String ?? ""
        let success = json["success"] as? Bool ?? true
        let subAgent = json["subAgent"] as? String
        let confidence = json["confidence"] as? Double

        switch type {
        case "think":
            let entry = ThinkingEntry(type: .thought, content: content, toolName: "", success: true)
            pendingSteps.append(entry)
            let preview = content.count > 100 ? String(content.prefix(97)) + "..." : content
            pendingThoughtNotifications.append(preview)

        case "toolCall":
            totalToolStepCount += 1
            let entry = ThinkingEntry(type: .toolCall, content: content, toolName: tool, success: true)
            pendingSteps.append(entry)
            pendingToolNotifications.append(tool)
            // Detect checklist tool calls
            if tool == "checklist" {
                parseChecklistAction(content)
            }

        case "toolResult":
            let entry = ThinkingEntry(type: .toolResult, content: content, toolName: tool, success: success)
            pendingSteps.append(entry)

        case "finalAnswer":
            finalAnswerParts.append(content)
            if let c = confidence { lastConfidence = c }

        case "error":
            errorMessage = content

        case "subAgentSpawn":
            let name = subAgent ?? "unknown"
            let entry = ThinkingEntry(type: .subAgentSpawn, content: content, toolName: name, success: true)
            pendingSteps.append(entry)

        case "subAgentResult":
            let name = subAgent ?? "unknown"
            let entry = ThinkingEntry(type: .subAgentResult, content: content, toolName: name, success: success)
            pendingSteps.append(entry)

        case "checkpoint":
            let entry = ThinkingEntry(type: .agentStep, content: "Checkpoint: \(json["checkpointId"] as? String ?? "")", toolName: "", success: true)
            pendingSteps.append(entry)

        case "context_info":
            if let pt = json["prompt_tokens"] as? Int { promptTokens = pt; pendingPromptTokens = pt }
            if let ct = json["completion_tokens"] as? Int { completionTokens = ct; pendingCompletionTokens = ct }
            if let pct = json["usage_percent"] as? Double { usagePercent = pct; pendingUsagePercent = pct }
            if let ws = json["context_window"] as? Int { windowSize = ws; pendingWindowSize = ws }

        default:
            if !content.isEmpty {
                let entry = ThinkingEntry(type: .agentStep, content: content, toolName: "", success: true)
                pendingSteps.append(entry)
            }
        }
    }

    // MARK: - Set Error

    func setError(_ msg: String) {
        errorMessage = msg
    }

    func markDone() {
        _isDone = true
    }

    var isDone: Bool {
        _isDone
    }

    // MARK: - Pending Step Count

    var pendingStepCount: Int {
        pendingSteps.count
    }

    // MARK: - Take Pending Flush (called every 300ms)

    func takePendingFlush() -> FlushResult {
        let steps = pendingSteps
        pendingSteps = []
        allThinkingSteps.append(contentsOf: steps)

        let thoughts = pendingThoughtNotifications
        pendingThoughtNotifications = []
        let tools = pendingToolNotifications
        pendingToolNotifications = []

        let pt = pendingPromptTokens; pendingPromptTokens = nil
        let ct = pendingCompletionTokens; pendingCompletionTokens = nil
        let pct = pendingUsagePercent; pendingUsagePercent = nil
        let ws = pendingWindowSize; pendingWindowSize = nil

        return FlushResult(
            steps: steps,
            toolStepCount: totalToolStepCount,
            contextPromptTokens: pt,
            contextCompletionTokens: ct,
            contextUsagePercent: pct,
            contextWindowSize: ws,
            thoughtNotifications: thoughts,
            toolNotifications: tools
        )
    }

    // MARK: - Take Final Result (called once after stream ends)

    func takeFinalResult() -> FinalResult {
        // Include any unflushed pending steps
        allThinkingSteps.append(contentsOf: pendingSteps)
        pendingSteps = []

        return FinalResult(
            finalAnswer: finalAnswerParts.joined(),
            thinkingSteps: allThinkingSteps,
            checklistActions: checklistActions,
            error: errorMessage,
            interactiveMessages: interactiveMessages,
            embedMessages: embedMessages,
            toolStepCount: totalToolStepCount,
            confidence: lastConfidence
        )
    }

    // MARK: - Private Helpers

    private func parseChecklistAction(_ argsJSON: String) {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let action = args["action"] as? String ?? "set"
        let itemsStr = args["items"] as? String
        let items = itemsStr?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let index: Int?
        if let indexStr = args["index"] as? String {
            index = Int(indexStr)
        } else if let indexInt = args["index"] as? Int {
            index = indexInt
        } else {
            index = nil
        }
        checklistActions.append((action: action, items: items, index: index))
    }
}
