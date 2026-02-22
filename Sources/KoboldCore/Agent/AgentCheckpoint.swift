import Foundation

// MARK: - AgentCheckpoint
// Saves agent state at tool boundaries for pause/resume of long tasks.
// Inspired by LangGraph checkpoint pattern.

public struct AgentCheckpoint: Codable, Sendable {
    public let id: String
    public let agentType: String
    public let messages: [[String: String]]
    public let stepCount: Int
    public let memoryBlocks: [String: String]
    public let createdAt: Date
    public let userMessage: String
    public var status: CheckpointStatus

    public init(
        id: String = UUID().uuidString,
        agentType: String,
        messages: [[String: String]],
        stepCount: Int,
        memoryBlocks: [String: String],
        createdAt: Date = Date(),
        userMessage: String,
        status: CheckpointStatus = .paused
    ) {
        self.id = id
        self.agentType = agentType
        self.messages = messages
        self.stepCount = stepCount
        self.memoryBlocks = memoryBlocks
        self.createdAt = createdAt
        self.userMessage = userMessage
        self.status = status
    }
}

public enum CheckpointStatus: String, Codable, Sendable {
    case paused
    case completed
    case failed
}

// MARK: - CheckpointStore

public actor CheckpointStore {
    public static let shared = CheckpointStore()

    private let storeDir: URL

    init() {
        storeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/checkpoints")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    public func save(_ checkpoint: AgentCheckpoint) {
        let url = storeDir.appendingPathComponent("cp_\(checkpoint.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func load(_ id: String) -> AgentCheckpoint? {
        let url = storeDir.appendingPathComponent("cp_\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentCheckpoint.self, from: data)
    }

    public func list() -> [AgentCheckpoint] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.lastPathComponent.hasPrefix("cp_") && $0.pathExtension == "json" }
            .compactMap { url -> AgentCheckpoint? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(AgentCheckpoint.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: String) {
        let url = storeDir.appendingPathComponent("cp_\(id).json")
        try? FileManager.default.removeItem(at: url)
    }
}
