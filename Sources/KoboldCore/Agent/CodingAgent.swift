import Foundation

/// Specialized coding agent that leverages Claude Code for development tasks
public class CodingAgent: @unchecked Sendable, BaseAgent {
    private let claudeCodePath: String
    private var codingTasks: [String: CodingTask] = [:]

    public init(id: String, name: String, messageBus: AgentMessageBus, claudeCodePath: String = "claude") {
        self.claudeCodePath = claudeCodePath
        super.init(id: id, name: name, messageBus: messageBus)
        addCapability(.coding)
        addCapability(.toolUsage)
        addCapability(.execution)

        // Register handlers for coding-specific messages
        registerHandler(for: .task) { [weak self] message in
            guard let self = self else { return "Agent not available" }
            return try await self.handleCodingTask(message)
        }

        registerHandler(for: .request) { [weak self] message in
            guard let self = self else { return "Agent not available" }
            return try await self.handleCodingRequest(message)
        }
    }

    /// Handle coding tasks
    private func handleCodingTask(_ message: AgentMessage) async throws -> String {
        print("CodingAgent \(name) handling task: \(message.content)")

        // Parse the coding task
        let task = CodingTask(from: message.content)
        codingTasks[message.id] = task

        // Execute the task based on its type
        let result: String
        switch task.type {
        case .codeGeneration:
            result = try await generateCode(task.description)
        case .codeReview:
            result = try await reviewCode(task.description)
        case .bugFixing:
            result = try await fixBugs(task.description)
        case .refactoring:
            result = try await refactorCode(task.description)
        case .documentation:
            result = try await generateDocumentation(task.description)
        }

        // Update task status
        if var task = codingTasks[message.id] {
            task.status = .completed
            task.result = result
            codingTasks[message.id] = task
        }

        return result
    }

    /// Handle coding requests
    private func handleCodingRequest(_ message: AgentMessage) async throws -> String {
        print("CodingAgent \(name) handling request: \(message.content)")

        // Use Claude Code to process the request
        return try await executeClaudeCode(message.content)
    }

    /// Override default message handling
    override public func handleDefaultMessage(_ message: AgentMessage) async -> String {
        switch message.messageType {
        case .task:
            do {
                return try await handleCodingTask(message)
            } catch {
                return "Failed to handle coding task: \(error.localizedDescription)"
            }
        case .request:
            do {
                return try await handleCodingRequest(message)
            } catch {
                return "Failed to handle coding request: \(error.localizedDescription)"
            }
        default:
            return await super.handleDefaultMessage(message)
        }
    }

    /// Generate code using Claude Code
    private func generateCode(_ description: String) async throws -> String {
        let prompt = """
        Generate code for the following requirements:
        \(description)

        Please provide clean, well-documented code with proper error handling.
        """

        return try await executeClaudeCode(prompt)
    }

    /// Review code using Claude Code
    private func reviewCode(_ code: String) async throws -> String {
        let prompt = """
        Review the following code and provide feedback:
        \(code)

        Please identify:
        1. Potential bugs or issues
        2. Code quality improvements
        3. Performance optimizations
        4. Security considerations
        """

        return try await executeClaudeCode(prompt)
    }

    /// Fix bugs using Claude Code
    private func fixBugs(_ description: String) async throws -> String {
        let prompt = """
        Fix the bugs in the following code:
        \(description)

        Please provide:
        1. Explanation of the issues found
        2. Corrected code
        3. Explanation of the fixes
        """

        return try await executeClaudeCode(prompt)
    }

    /// Refactor code using Claude Code
    private func refactorCode(_ code: String) async throws -> String {
        let prompt = """
        Refactor the following code to improve its quality:
        \(code)

        Please focus on:
        1. Improving readability
        2. Reducing complexity
        3. Following best practices
        4. Maintaining functionality
        """

        return try await executeClaudeCode(prompt)
    }

    /// Generate documentation using Claude Code
    private func generateDocumentation(_ code: String) async throws -> String {
        let prompt = """
        Generate documentation for the following code:
        \(code)

        Please provide:
        1. Function/class descriptions
        2. Parameter explanations
        3. Return value descriptions
        4. Usage examples
        """

        return try await executeClaudeCode(prompt)
    }

    /// Execute Claude Code CLI command
    private func executeClaudeCode(_ prompt: String) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")

        // Escape the prompt for shell safety
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "\(claudeCodePath) \"\(escapedPrompt)\""

        task.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: stdoutData, encoding: .utf8) {
                    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedOutput
                }
            } else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorOutput = String(data: stderrData, encoding: .utf8) {
                    throw CodingAgentError.claudeCodeError(errorOutput)
                }
            }
        } catch {
            throw CodingAgentError.executionFailed(error)
        }

        throw CodingAgentError.unknownError
    }

    /// Get coding task status
    public func getTaskStatus(taskId: String) -> CodingTask.Status? {
        return codingTasks[taskId]?.status
    }

    /// Get all coding tasks
    public func getAllTasks() -> [CodingTask] {
        return Array(codingTasks.values)
    }
}

/// Coding task structure
public struct CodingTask: Sendable {
    public enum TaskType: String, Sendable {
        case codeGeneration = "Code Generation"
        case codeReview = "Code Review"
        case bugFixing = "Bug Fixing"
        case refactoring = "Refactoring"
        case documentation = "Documentation"
    }

    public enum Status: String, Sendable {
        case pending = "Pending"
        case inProgress = "In Progress"
        case completed = "Completed"
        case failed = "Failed"
    }

    public let id: String
    public let type: TaskType
    public let description: String
    public private(set) var status: Status
    public private(set) var result: String?

    public init(id: String = UUID().uuidString, type: TaskType, description: String) {
        self.id = id
        self.type = type
        self.description = description
        self.status = .pending
        self.result = nil
    }

    public init(from content: String) {
        self.id = UUID().uuidString
        self.type = .codeGeneration // Default type
        self.description = content
        self.status = .pending
        self.result = nil

        // Try to parse task type from content
        if content.lowercased().contains("review") {
            self.type = .codeReview
        } else if content.lowercased().contains("bug") || content.lowercased().contains("fix") {
            self.type = .bugFixing
        } else if content.lowercased().contains("refactor") {
            self.type = .refactoring
        } else if content.lowercased().contains("document") {
            self.type = .documentation
        }
    }
}

/// Coding agent error types
public enum CodingAgentError: Error, LocalizedError {
    case claudeCodeError(String)
    case executionFailed(Error)
    case unknownError

    public var errorDescription: String? {
        switch self {
        case .claudeCodeError(let error):
            return "Claude Code error: \(error)"
        case .executionFailed(let error):
            return "Execution failed: \(error)"
        case .unknownError:
            return "Unknown error occurred"
        }
    }
}