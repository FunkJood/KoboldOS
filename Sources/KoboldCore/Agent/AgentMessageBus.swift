import Foundation

/// Central message bus for inter-agent communication
public actor AgentMessageBus {
    private var agents: [String: AgentEndpoint] = [:]
    private var messageQueue: [AgentMessage] = []
    private var observers: [MessageObserver] = []
    private let maxQueueSize: Int
    private let logger: MessageLogger

    public init(maxQueueSize: Int = 1000) {
        self.maxQueueSize = maxQueueSize
        self.logger = MessageLogger()
    }

    /// Register an agent with the message bus
    public func registerAgent(id: String, endpoint: AgentEndpoint) async {
        agents[id] = endpoint
        await logger.log("Agent \(id) registered with message bus")
    }

    /// Unregister an agent from the message bus
    public func unregisterAgent(id: String) async {
        agents.removeValue(forKey: id)
        await logger.log("Agent \(id) unregistered from message bus")
    }

    /// Send a message to a specific agent
    public func sendMessage(_ message: AgentMessage) async throws {
        guard let recipient = agents[message.recipient] else {
            logger.log("Recipient \(message.recipient) not found", level: .warning)
            throw MessageBusError.recipientNotFound
        }

        // Log the message
        logger.log("Sending message from \(message.sender) to \(message.recipient): \(message.content.prefix(50))...")

        // Add to queue if high priority or queue is not empty
        if message.priority == .urgent || !messageQueue.isEmpty {
            messageQueue.append(message)
            if messageQueue.count > maxQueueSize {
                messageQueue.removeFirst()
                logger.log("Message queue overflow, oldest message removed", level: .warning)
            }
        }

        // Send the message
        do {
            try await recipient.receiveMessage(message)
            logger.log("Message delivered successfully")
        } catch {
            logger.log("Failed to deliver message: \(error)", level: .error)
            throw MessageBusError.deliveryFailed(error)
        }
    }

    /// Broadcast a message to all agents
    public func broadcastMessage(_ message: AgentMessage) async {
        logger.log("Broadcasting message from \(message.sender): \(message.content.prefix(50))...")

        for (agentId, endpoint) in agents {
            if agentId != message.sender { // Don't send to sender
                do {
                    try await endpoint.receiveMessage(message)
                } catch {
                    logger.log("Failed to deliver broadcast to \(agentId): \(error)", level: .error)
                }
            }
        }
    }

    /// Send a message with authentication
    public func sendMessage(_ message: AgentMessage, from senderKey: String) async throws {
        // Sign the message
        let signature = signMessage(message, with: senderKey)
        let envelope = MessageEnvelope(message: message, signature: signature)

        // Verify recipient exists
        guard let recipient = agents[message.recipient] else {
            throw MessageBusError.recipientNotFound
        }

        // Send the envelope
        try await recipient.receiveMessage(envelope)
    }

    /// Process queued messages
    public func processQueuedMessages() async {
        while !messageQueue.isEmpty {
            let message = messageQueue.removeFirst()
            do {
                try await sendMessage(message)
            } catch {
                logger.log("Failed to process queued message: \(error)", level: .error)
                // Re-queue urgent messages
                if message.priority == .urgent {
                    messageQueue.insert(message, at: 0)
                }
            }
        }
    }

    /// Add an observer for message events
    public func addObserver(_ observer: MessageObserver) {
        observers.append(observer)
    }

    /// Remove an observer
    public func removeObserver(_ observer: MessageObserver) {
        observers.removeAll { $0.id == observer.id }
    }

    /// Get statistics about the message bus
    public func getStatistics() -> MessageBusStats {
        return MessageBusStats(
            registeredAgents: agents.count,
            queuedMessages: messageQueue.count,
            totalMessagesSent: logger.getMessageCount()
        )
    }

    /// Private helper methods
    private func signMessage(_ message: AgentMessage, with key: String) -> String {
        // In a real implementation, this would create a cryptographic signature
        // For now, we'll return a placeholder
        return "signed_with_\(key)"
    }
}

/// Protocol for agent endpoints that can receive messages
public protocol AgentEndpoint: Sendable {
    func receiveMessage(_ message: AgentMessage) async throws
    func receiveMessage(_ envelope: MessageEnvelope) async throws
}

/// Observer protocol for monitoring message bus events
public protocol MessageObserver: Sendable {
    var id: String { get }
    func onMessageSent(_ message: AgentMessage) async
    func onMessageReceived(_ message: AgentMessage) async
    func onMessageError(_ error: Error, message: AgentMessage) async
}

/// Logger for message bus events
public actor MessageLogger {
    private var logs: [MessageLogEntry] = []
    private let maxLogs: Int = 5000

    public init() {}

    public func log(_ message: String, level: LogLevel = .info) {
        let entry = MessageLogEntry(
            timestamp: Date(),
            level: level,
            message: message
        )

        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst()
        }

        // Print to console for debugging
        print("[MessageBus] \(level.rawValue.uppercased()): \(message)")
    }

    public func getLogs(since: Date? = nil) -> [MessageLogEntry] {
        if let sinceDate = since {
            return logs.filter { $0.timestamp > sinceDate }
        }
        return logs
    }

    public func getMessageCount() -> Int {
        return logs.count
    }

    public func clearLogs() {
        logs.removeAll()
    }
}

/// Message bus error types
public enum MessageBusError: Error, LocalizedError {
    case recipientNotFound
    case deliveryFailed(Error)
    case authenticationFailed
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .recipientNotFound:
            return "Recipient agent not found"
        case .deliveryFailed(let error):
            return "Failed to deliver message: \(error)"
        case .authenticationFailed:
            return "Message authentication failed"
        case .invalidMessage:
            return "Invalid message format"
        }
    }
}

/// Data structures
public struct MessageBusStats: Sendable {
    public let registeredAgents: Int
    public let queuedMessages: Int
    public let totalMessagesSent: Int

    public init(registeredAgents: Int, queuedMessages: Int, totalMessagesSent: Int) {
        self.registeredAgents = registeredAgents
        self.queuedMessages = queuedMessages
        self.totalMessagesSent = totalMessagesSent
    }
}

public struct MessageLogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    public init(timestamp: Date, level: LogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}