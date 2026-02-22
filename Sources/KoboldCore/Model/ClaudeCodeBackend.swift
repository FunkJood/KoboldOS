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

    /// Run Claude Code CLI command (non-blocking pipe reads)
    private func runClaudeCommand(_ prompt: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        task.arguments = ["ask", "--model", "claude-sonnet-4-6", "--", prompt]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        // Collect pipe data asynchronously to avoid deadlocks
        final class PipeCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _data = Data()
            func append(_ chunk: Data) { lock.lock(); _data.append(chunk); lock.unlock() }
            var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
        }
        let stdoutCollector = PipeCollector()
        let stderrCollector = PipeCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutCollector.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrCollector.append(chunk)
        }

        try task.run()
        task.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let output = String(data: stdoutCollector.data, encoding: .utf8) ?? ""
        let errorOutput = String(data: stderrCollector.data, encoding: .utf8) ?? ""

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