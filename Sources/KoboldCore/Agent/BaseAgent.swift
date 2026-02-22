import Foundation

/// Base agent class that can communicate via the message bus
open class BaseAgent: @unchecked Sendable, AgentEndpoint {
    public let id: String
    public let name: String
    public private(set) var isActive: Bool = false
    private let messageBus: AgentMessageBus
    private var capabilities: Set<AgentCapability> = []
    private var messageHandlers: [MessageType: (AgentMessage) async throws -> String] = [:]

    public init(id: String, name: String, messageBus: AgentMessageBus) {
        self.id = id
        self.name = name
        self.messageBus = messageBus
    }

    /// Start the agent
    public func start() async {
        isActive = true
        await messageBus.registerAgent(id: id, endpoint: self)
        // Agent started
    }

    /// Stop the agent
    public func stop() async {
        isActive = false
        await messageBus.unregisterAgent(id: id)
        // Agent stopped
    }

    /// Add a capability to the agent
    public func addCapability(_ capability: AgentCapability) {
        capabilities.insert(capability)
    }

    /// Check if agent has a specific capability
    public func hasCapability(_ capability: AgentCapability) -> Bool {
        return capabilities.contains(capability)
    }

    /// Register a message handler for a specific message type
    public func registerHandler(for messageType: MessageType, handler: @escaping (AgentMessage) async throws -> String) {
        messageHandlers[messageType] = handler
    }

    /// Send a message to another agent
    public func sendMessage(to recipient: String, content: String, type: MessageType = .request, priority: MessagePriority = .normal) async throws {
        let message = AgentMessage(
            sender: id,
            recipient: recipient,
            content: content,
            messageType: type,
            priority: priority
        )
        try await messageBus.sendMessage(message)
    }

    /// Broadcast a message to all agents
    public func broadcastMessage(content: String, type: MessageType = .broadcast) async {
        let message = AgentMessage(
            sender: id,
            recipient: "broadcast",
            content: content,
            messageType: type
        )
        await messageBus.broadcastMessage(message)
    }

    /// Receive a message (called by the message bus)
    public func receiveMessage(_ message: AgentMessage) async throws {
        guard isActive else {
            throw AgentError.agentNotActive
        }

        // Message received, process via handler

        // Handle the message based on its type
        if let handler = messageHandlers[message.messageType] {
            let responseContent = try await handler(message)
            let response = AgentMessage(
                sender: id,
                recipient: message.sender,
                content: responseContent,
                messageType: .response,
                priority: .normal
            )
            try await messageBus.sendMessage(response)
        } else {
            // Default handling
            let responseContent = await handleDefaultMessage(message)
            let response = AgentMessage(
                sender: id,
                recipient: message.sender,
                content: responseContent,
                messageType: .response,
                priority: .normal
            )
            try await messageBus.sendMessage(response)
        }
    }

    /// Receive a signed message envelope
    public func receiveMessage(_ envelope: MessageEnvelope) async throws {
        guard isActive else {
            throw AgentError.agentNotActive
        }

        // Verify the signature (in a real implementation)
        guard envelope.verifySignature(with: "public_key_placeholder") else {
            throw AgentError.authenticationFailed
        }

        try await receiveMessage(envelope.message)
    }

    /// Default message handling
    open func handleDefaultMessage(_ message: AgentMessage) async -> String {
        switch message.messageType {
        case .request:
            return "Understood your request: \(message.content)"
        case .notification:
            return "Acknowledged notification"
        case .task:
            return "Task received, will process: \(message.content)"
        default:
            return "Message received: \(message.content)"
        }
    }

    /// Get agent information
    public func getInfo() -> AgentInfo {
        return AgentInfo(
            id: id,
            name: name,
            isActive: isActive,
            capabilities: Array(capabilities)
        )
    }
}

/// Agent capabilities
public enum AgentCapability: String, CaseIterable, Sendable {
    case coding = "Coding"
    case research = "Research"
    case analysis = "Analysis"
    case communication = "Communication"
    case planning = "Planning"
    case execution = "Execution"
    case webBrowsing = "Web Browsing"
    case fileOperations = "File Operations"
    case toolUsage = "Tool Usage"
}

/// Agent information structure
public struct AgentInfo: Sendable {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let capabilities: [AgentCapability]

    public init(id: String, name: String, isActive: Bool, capabilities: [AgentCapability]) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.capabilities = capabilities
    }
}

/// Agent error types
public enum AgentError: Error, LocalizedError {
    case agentNotActive
    case authenticationFailed
    case messageHandlingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .agentNotActive:
            return "Agent is not active"
        case .authenticationFailed:
            return "Authentication failed"
        case .messageHandlingFailed(let reason):
            return "Message handling failed: \(reason)"
        }
    }
}