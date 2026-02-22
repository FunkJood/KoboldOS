import Foundation

/// Simple Claude Code CLI backend for coding tasks
public class ClaudeCodeBackend: @unchecked Sendable {
    private let processQueue = DispatchQueue(label: "ClaudeCodeBackend", qos: .userInitiated)

    public init() {}

    /// Execute a coding task using Claude Code CLI
    public func executeCodingTask(_ prompt: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                do {
                    let output = try self.runClaudeCommand(prompt)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run Claude Code CLI command with the given prompt
    private func runClaudeCommand(_ prompt: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        task.arguments = ["ask", "--model", "claude-sonnet-4-6", "--", prompt]

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        task.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if task.terminationStatus != 0 {
            throw NSError(domain: "ClaudeCodeBackend", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Claude Code CLI failed: \(errorOutput)"])
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if Claude Code CLI is available
    public func isAvailable() -> Bool {
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude")
    }
}