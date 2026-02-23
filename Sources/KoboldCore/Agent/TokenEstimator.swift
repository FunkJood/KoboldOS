import Foundation

// MARK: - ContextSize

/// Supported context window sizes for LLM providers
public enum ContextSize: Int, Sendable, CaseIterable, Identifiable {
    case tiny   = 4096
    case small  = 8192
    case medium = 16384
    case large  = 32768
    case xl     = 65536
    case xxl    = 131072

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .tiny:   return "4K"
        case .small:  return "8K"
        case .medium: return "16K"
        case .large:  return "32K"
        case .xl:     return "64K"
        case .xxl:    return "128K"
        }
    }
}

// MARK: - TokenEstimator

/// Fast heuristic-based token estimator (~3.5 chars per token for English/German mixed content).
/// Used when API doesn't return usage data.
public struct TokenEstimator: Sendable {
    /// Average characters per token (conservative estimate for mixed lang content)
    private static let charsPerToken: Double = 3.5

    /// Estimate token count for a single string
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(text.count) / charsPerToken)))
    }

    /// Estimate token count for an array of chat messages
    public static func estimateTokens(messages: [[String: String]]) -> Int {
        var total = 0
        for msg in messages {
            // Each message has ~4 tokens overhead (role, formatting)
            total += 4
            if let content = msg["content"] {
                total += estimateTokens(content)
            }
            if let role = msg["role"] {
                total += estimateTokens(role)
            }
        }
        // Base overhead for the chat format
        total += 2
        return total
    }

    /// Calculate usage percentage given estimated tokens and context window size
    public static func usagePercent(estimatedTokens: Int, contextSize: Int) -> Double {
        guard contextSize > 0 else { return 0 }
        return min(1.0, Double(estimatedTokens) / Double(contextSize))
    }
}

// MARK: - ContextInfo

/// Snapshot of current context window usage, emitted to UI via SSE
public struct ContextInfo: Sendable, Encodable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let contextWindowSize: Int
    public let usagePercent: Double
    public let isEstimated: Bool  // true = heuristic, false = from API

    public init(promptTokens: Int, completionTokens: Int, contextWindowSize: Int, isEstimated: Bool) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
        self.contextWindowSize = contextWindowSize
        self.usagePercent = contextWindowSize > 0
            ? min(1.0, Double(promptTokens + completionTokens) / Double(contextWindowSize))
            : 0
        self.isEstimated = isEstimated
    }

    public func toJSON() -> String {
        let obj: [String: Any] = [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": totalTokens,
            "context_window": contextWindowSize,
            "usage_percent": usagePercent,
            "is_estimated": isEstimated
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
