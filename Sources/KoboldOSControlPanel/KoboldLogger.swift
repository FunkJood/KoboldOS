import Foundation

/// File-based diagnostic logger for freeze/crash investigation.
/// Writes to ~/Library/Application Support/KoboldOS/kobold_debug.log
/// Previous log preserved as kobold_debug.prev.log
/// Read with: cat ~/Library/Application\ Support/KoboldOS/kobold_debug.log
final class KoboldLogger: @unchecked Sendable {
    static nonisolated(unsafe) let shared = KoboldLogger()

    private let queue = DispatchQueue(label: "kobold.logger", qos: .utility)
    private let fileHandle: FileHandle?
    private let logURL: URL
    private let prevLogURL: URL
    private let crashLogURL: URL
    let logDir: URL
    private let startTime = Date()
    private let maxLogSize: UInt64 = 20_000_000  // 20MB max before rotation

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDir = appSupport.appendingPathComponent("KoboldOS")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logURL = logDir.appendingPathComponent("kobold_debug.log")
        prevLogURL = logDir.appendingPathComponent("kobold_debug.prev.log")
        crashLogURL = logDir.appendingPathComponent("kobold_crash.log")

        // Rotate: preserve previous log before truncating
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.removeItem(at: prevLogURL)
            try? FileManager.default.moveItem(at: logURL, to: prevLogURL)
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()

        let header = """
        === KoboldOS Debug Log ===
        Started: \(ISO8601DateFormatter().string(from: Date()))
        PID: \(ProcessInfo.processInfo.processIdentifier)
        Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB
        ================================

        """
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }

        // Install crash/signal handlers
        installCrashHandlers()
    }

    // MARK: - Logging Methods

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(elapsed)s] [\(fileName):\(line)] \(message)\n"
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = entry.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
            self.checkRotation()
        }
    }

    /// Log with forced flush (for right before potential crash/freeze)
    /// Uses async dispatch to avoid blocking the calling thread (especially MainActor).
    func critical(_ message: String, file: String = #file, line: Int = #line) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        let fileName = (file as NSString).lastPathComponent
        let entry = "⚠️ CRIT [\(elapsed)s] [\(fileName):\(line)] \(message)\n"
        queue.async { [weak self] in
            if let data = entry.data(using: .utf8) {
                self?.fileHandle?.write(data)
                self?.fileHandle?.synchronizeFile()
            }
        }
    }

    /// Log session lifecycle events with structured data
    func session(_ event: String, sessionId: UUID, extra: [String: Any] = [:], file: String = #file, line: Int = #line) {
        let id = sessionId.uuidString.prefix(8)
        let extraStr = extra.isEmpty ? "" : " " + extra.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log("SESSION[\(id)] \(event)\(extraStr)", file: file, line: line)
    }

    /// Log agent state changes
    func agent(_ event: String, sessionId: UUID, extra: [String: Any] = [:], file: String = #file, line: Int = #line) {
        let id = sessionId.uuidString.prefix(8)
        let extraStr = extra.isEmpty ? "" : " " + extra.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log("AGENT[\(id)] \(event)\(extraStr)", file: file, line: line)
    }

    // MARK: - Log Reading (for diagnostics)

    /// Read the current log contents (last N lines)
    func readLog(lastLines: Int = 200) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let content = String(data: data, encoding: .utf8) else { return "[Log leer]" }
        let lines = content.components(separatedBy: "\n")
        let tail = lines.suffix(lastLines)
        return tail.joined(separator: "\n")
    }

    /// Read the previous session's log
    func readPrevLog(lastLines: Int = 200) -> String {
        guard let data = try? Data(contentsOf: prevLogURL),
              let content = String(data: data, encoding: .utf8) else { return "[Kein vorheriges Log]" }
        let lines = content.components(separatedBy: "\n")
        let tail = lines.suffix(lastLines)
        return tail.joined(separator: "\n")
    }

    /// Read crash log if it exists
    func readCrashLog() -> String {
        guard let data = try? Data(contentsOf: crashLogURL),
              let content = String(data: data, encoding: .utf8) else { return "[Kein Crash-Log]" }
        return content
    }

    /// Get a diagnostic summary combining all logs
    func diagnosticSummary() -> String {
        var summary = "=== KoboldOS Diagnostic Summary ===\n"
        summary += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        summary += "Uptime: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s\n\n"

        let crash = readCrashLog()
        if crash != "[Kein Crash-Log]" {
            summary += "--- CRASH LOG (previous session) ---\n\(crash)\n\n"
        }

        let prev = readPrevLog(lastLines: 50)
        if prev != "[Kein vorheriges Log]" {
            summary += "--- PREVIOUS SESSION (last 50 lines) ---\n\(prev)\n\n"
        }

        summary += "--- CURRENT SESSION (last 100 lines) ---\n\(readLog(lastLines: 100))\n"
        return summary
    }

    var logPath: String { logURL.path }

    // MARK: - Rotation

    private func checkRotation() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        // Truncate to last 2MB
        if let data = try? Data(contentsOf: logURL) {
            let keep = data.suffix(2_000_000)
            try? keep.write(to: logURL, options: .atomic)
            fileHandle?.seekToEndOfFile()
        }
    }

    // MARK: - Crash Handlers

    private func installCrashHandlers() {
        // Write crash marker on uncaught exceptions
        NSSetUncaughtExceptionHandler { exception in
            let msg = """
            === UNCAUGHT EXCEPTION ===
            Time: \(ISO8601DateFormatter().string(from: Date()))
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack: \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))
            """
            let crashURL = KoboldLogger.shared.crashLogURL
            try? msg.data(using: .utf8)?.write(to: crashURL, options: .atomic)
            KoboldLogger.shared.critical("CRASH: \(exception.name.rawValue) — \(exception.reason ?? "?")")
        }

        // Signal handlers for SIGABRT, SIGSEGV, SIGBUS
        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL] {
            signal(sig) { signum in
                let sigName: String
                switch signum {
                case SIGABRT: sigName = "SIGABRT"
                case SIGSEGV: sigName = "SIGSEGV"
                case SIGBUS:  sigName = "SIGBUS"
                case SIGFPE:  sigName = "SIGFPE"
                case SIGILL:  sigName = "SIGILL"
                default:      sigName = "SIG\(signum)"
                }
                let msg = """
                === SIGNAL CRASH ===
                Time: \(ISO8601DateFormatter().string(from: Date()))
                Signal: \(sigName) (\(signum))
                PID: \(ProcessInfo.processInfo.processIdentifier)
                """
                let crashURL = KoboldLogger.shared.logDir.appendingPathComponent("kobold_crash.log")
                try? msg.data(using: .utf8)?.write(to: crashURL, options: .atomic)
                // Re-raise to get default behavior (core dump etc.)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}

/// Shorthand
func klog(_ msg: String, file: String = #file, line: Int = #line) {
    KoboldLogger.shared.log(msg, file: file, line: line)
}
func kcrit(_ msg: String, file: String = #file, line: Int = #line) {
    KoboldLogger.shared.critical(msg, file: file, line: line)
}
func ksession(_ event: String, _ sessionId: UUID, _ extra: [String: Any] = [:], file: String = #file, line: Int = #line) {
    KoboldLogger.shared.session(event, sessionId: sessionId, extra: extra, file: file, line: line)
}
func kagent(_ event: String, _ sessionId: UUID, _ extra: [String: Any] = [:], file: String = #file, line: Int = #line) {
    KoboldLogger.shared.agent(event, sessionId: sessionId, extra: extra, file: file, line: line)
}
