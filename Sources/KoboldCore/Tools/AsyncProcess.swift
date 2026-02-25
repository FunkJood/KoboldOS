import Foundation

/// Async-safe process runner that avoids blocking `waitUntilExit()`.
/// Uses `terminationHandler` + DispatchSource timeout (same pattern as AppleScriptTool).
public enum AsyncProcess {

    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    /// Run an external process without blocking the caller.
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workdir: String? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let wd = workdir, !wd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Prevent 64KB pipe buffer deadlock by reading asynchronously while process runs
        final class DataBox: @unchecked Sendable {
            private var data = Data()
            private let lock = NSLock()
            func append(_ newData: Data) { lock.lock(); defer { lock.unlock() }; data.append(newData) }
            func extractAndAppend(_ remaining: Data) -> String {
                lock.lock()
                data.append(remaining)
                let str = String(data: data, encoding: .utf8) ?? ""
                lock.unlock()
                return str
            }
        }
        
        let outBox = DataBox()
        let errBox = DataBox()

        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { outBox.append(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { errBox.append(d) }
        }

        // Use the same UnsafeMutablePointer pattern as AppleScriptTool.runOsascript
        // which already compiles and works in this project's Swift 6 mode
        nonisolated(unsafe) let resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        resumed.initialize(to: false)

        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard !resumed.pointee else { return }
                resumed.pointee = true
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                continuation.resume(throwing: ToolError.timeout)
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()
                guard !resumed.pointee else {
                    resumed.deinitialize(count: 1)
                    resumed.deallocate()
                    return
                }
                resumed.pointee = true

                // Close handlers and combine collected chunks with any remaining data
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let outStr = outBox.extractAndAppend(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                let errStr = errBox.extractAndAppend(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(returning: Result(
                    stdout: outStr,
                    stderr: errStr,
                    exitCode: proc.terminationStatus
                ))
                resumed.deinitialize(count: 1)
                resumed.deallocate()
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                guard !resumed.pointee else {
                    resumed.deinitialize(count: 1)
                    resumed.deallocate()
                    return
                }
                resumed.pointee = true
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                resumed.deinitialize(count: 1)
                resumed.deallocate()
            }
        }
    }
}
