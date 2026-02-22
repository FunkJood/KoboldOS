import Foundation

/// Represents a message that can be sent between agents
public struct AgentMessage: Codable, Sendable {
    public let id: String
    public let sender: String
    public let recipient: String
    public let content: String
    public let messageType: MessageType
    public let timestamp: Date
    public let priority: MessagePriority
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        sender: String,
        recipient: String,
        content: String,
        messageType: MessageType = .request,
        timestamp: Date = Date(),
        priority: MessagePriority = .normal,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sender = sender
        self.recipient = recipient
        self.content = content
        self.messageType = messageType
        self.timestamp = timestamp
        self.priority = priority
        self.metadata = metadata
    }
}

/// Type of message being sent
public enum MessageType: String, Codable, Sendable {
    case request      // Request for action or information
    case response     // Response to a request
    case broadcast    // Broadcast to multiple agents
    case notification // Notification of an event
    case task         // Task assignment
    case result       // Task result
}

/// Priority level of the message
public enum MessagePriority: String, Codable, Sendable {
    case low    // Can be processed when convenient
    case normal // Standard priority
    case high   // Should be processed soon
    case urgent // Must be processed immediately
}

/// Message envelope for secure transmission
public struct MessageEnvelope: Codable, Sendable {
    public let message: AgentMessage
    public let signature: String
    public let timestamp: Date

    public init(message: AgentMessage, signature: String) {
        self.message = message
        self.signature = signature
        self.timestamp = Date()
    }

    /// Verify the message signature
    public func verifySignature(with publicKey: String) -> Bool {
        // In a real implementation, this would verify the cryptographic signature
        // For now, we'll return true as a placeholder
        return true
    }
}