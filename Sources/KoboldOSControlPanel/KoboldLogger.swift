import Foundation

/// G1: Konsolidiertes Logging-System in ~/Library/Application Support/KoboldOS/logs/
/// Alle Logs (debug, crash, tools, build, performance) in einem Ordner.
/// Shorthand-Funktionen: klog(), kcrit(), ktool(), kbuild(), kperf()
final class KoboldLogger: @unchecked Sendable {
    static let shared = KoboldLogger()

    private let queue = DispatchQueue(label: "kobold.logger", qos: .utility)
    private let debugHandle: FileHandle?
    private let toolsHandle: FileHandle?
    private let buildHandle: FileHandle?
    private let perfHandle: FileHandle?

    private let debugURL: URL
    private let prevDebugURL: URL
    private let crashURL: URL
    private let toolsURL: URL
    private let buildURL: URL
    private let perfURL: URL

    let logDir: URL       // ~/Library/Application Support/KoboldOS/logs/
    let baseDir: URL      // ~/Library/Application Support/KoboldOS/

    private let startTime = Date()
    private let maxLogSize: UInt64 = 20_000_000  // 20MB max before rotation

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("KoboldOS")
        logDir = baseDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // G1: Migration — alte Logs aus Hauptordner in logs/ verschieben (einmalig)
        KoboldLogger.migrateOldLogs(baseDir: baseDir, logDir: logDir)

        // Log-Dateien
        debugURL = logDir.appendingPathComponent("debug.log")
        prevDebugURL = logDir.appendingPathComponent("debug.prev.log")
        crashURL = logDir.appendingPathComponent("crash.log")
        toolsURL = logDir.appendingPathComponent("tools.log")
        buildURL = logDir.appendingPathComponent("build.log")
        perfURL = logDir.appendingPathComponent("performance.log")

        // Rotate debug log: preserve previous
        if FileManager.default.fileExists(atPath: debugURL.path) {
            try? FileManager.default.removeItem(at: prevDebugURL)
            try? FileManager.default.moveItem(at: debugURL, to: prevDebugURL)
        }

        // Create/open all log files
        func openLog(_ url: URL) -> FileHandle? {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            return handle
        }

        FileManager.default.createFile(atPath: debugURL.path, contents: nil)
        debugHandle = try? FileHandle(forWritingTo: debugURL)
        debugHandle?.seekToEndOfFile()
        toolsHandle = openLog(toolsURL)
        buildHandle = openLog(buildURL)
        perfHandle = openLog(perfURL)

        // Header für debug.log
        let header = """
        === KoboldOS Debug Log ===
        Started: \(ISO8601DateFormatter().string(from: Date()))
        PID: \(ProcessInfo.processInfo.processIdentifier)
        Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB
        LogDir: \(logDir.path)
        ================================

        """
        if let data = header.data(using: .utf8) {
            debugHandle?.write(data)
        }

        installCrashHandlers()
    }

    // MARK: - Migration (einmalig)

    private static func migrateOldLogs(baseDir: URL, logDir: URL) {
        let migrations: [(String, String)] = [
            ("kobold_debug.log", "debug.log"),
            ("kobold_debug.prev.log", "debug.prev.log"),
            ("kobold_crash.log", "crash.log"),
            ("daemon.log", "daemon.log"),
        ]
        for (old, new) in migrations {
            let oldURL = baseDir.appendingPathComponent(old)
            let newURL = logDir.appendingPathComponent(new)
            if FileManager.default.fileExists(atPath: oldURL.path) && !FileManager.default.fileExists(atPath: newURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }
    }

    // MARK: - Debug Logging

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(elapsed)s] [\(fileName):\(line)] \(message)\n"
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = entry.data(using: .utf8) {
                self.debugHandle?.write(data)
            }
            self.checkRotation(handle: self.debugHandle, url: self.debugURL)
        }
    }

    /// Log with forced flush (for right before potential crash/freeze)
    func critical(_ message: String, file: String = #file, line: Int = #line) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        let fileName = (file as NSString).lastPathComponent
        let entry = "⚠️ CRIT [\(elapsed)s] [\(fileName):\(line)] \(message)\n"
        queue.async { [weak self] in
            if let data = entry.data(using: .utf8) {
                self?.debugHandle?.write(data)
                self?.debugHandle?.synchronizeFile()
            }
        }
    }

    /// Log session lifecycle events
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

    // MARK: - Tool Logging (G2)

    /// Log tool executions with name, duration, success, input/output
    func tool(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            if let data = entry.data(using: .utf8) {
                self.toolsHandle?.write(data)
            }
            self.checkRotation(handle: self.toolsHandle, url: self.toolsURL)
        }
        // Auch ins Debug-Log (kürzer)
        log("TOOL \(String(message.prefix(200)))", file: file, line: line)
    }

    // MARK: - Build Logging (G3)

    /// Log build/compile output
    func build(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            if let data = entry.data(using: .utf8) {
                self.buildHandle?.write(data)
            }
            self.checkRotation(handle: self.buildHandle, url: self.buildURL)
        }
        log("BUILD \(String(message.prefix(200)))", file: file, line: line)
    }

    // MARK: - Performance Logging (G4)

    /// Log performance/freeze diagnostics (only when kobold.debug.perfLog is enabled)
    func perf(_ message: String, file: String = #file, line: Int = #line) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        let entry = "[\(elapsed)s] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            if let data = entry.data(using: .utf8) {
                self.perfHandle?.write(data)
            }
            self.checkRotation(handle: self.perfHandle, url: self.perfURL)
        }
    }

    // MARK: - Log Reading

    func readLog(lastLines: Int = 200) -> String {
        readFile(debugURL, lastLines: lastLines, fallback: "[Log leer]")
    }

    func readPrevLog(lastLines: Int = 200) -> String {
        readFile(prevDebugURL, lastLines: lastLines, fallback: "[Kein vorheriges Log]")
    }

    func readCrashLog() -> String {
        guard let data = try? Data(contentsOf: crashURL),
              let content = String(data: data, encoding: .utf8) else { return "[Kein Crash-Log]" }
        return content
    }

    func readToolsLog(lastLines: Int = 100) -> String {
        readFile(toolsURL, lastLines: lastLines, fallback: "[Kein Tool-Log]")
    }

    func readBuildLog(lastLines: Int = 100) -> String {
        readFile(buildURL, lastLines: lastLines, fallback: "[Kein Build-Log]")
    }

    func readPerfLog(lastLines: Int = 100) -> String {
        readFile(perfURL, lastLines: lastLines, fallback: "[Kein Performance-Log]")
    }

    func diagnosticSummary() -> String {
        var summary = "=== KoboldOS Diagnostic Summary ===\n"
        summary += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        summary += "Uptime: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s\n"
        summary += "LogDir: \(logDir.path)\n\n"

        let crash = readCrashLog()
        if crash != "[Kein Crash-Log]" {
            summary += "--- CRASH LOG (previous session) ---\n\(crash)\n\n"
        }

        let prev = readPrevLog(lastLines: 50)
        if prev != "[Kein vorheriges Log]" {
            summary += "--- PREVIOUS SESSION (last 50 lines) ---\n\(prev)\n\n"
        }

        summary += "--- CURRENT SESSION (last 100 lines) ---\n\(readLog(lastLines: 100))\n\n"
        summary += "--- TOOLS (last 50 lines) ---\n\(readToolsLog(lastLines: 50))\n\n"
        summary += "--- BUILD (last 50 lines) ---\n\(readBuildLog(lastLines: 50))\n"
        return summary
    }

    var logPath: String { debugURL.path }

    // MARK: - Helpers

    private func readFile(_ url: URL, lastLines: Int, fallback: String) -> String {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return fallback }
        let lines = content.components(separatedBy: "\n")
        return lines.suffix(lastLines).joined(separator: "\n")
    }

    private func checkRotation(handle: FileHandle?, url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        if let data = try? Data(contentsOf: url) {
            let keep = data.suffix(2_000_000)
            try? keep.write(to: url, options: .atomic)
            handle?.seekToEndOfFile()
        }
    }

    // MARK: - Crash Handlers

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let msg = """
            === UNCAUGHT EXCEPTION ===
            Time: \(ISO8601DateFormatter().string(from: Date()))
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack: \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))
            """
            let crashURL = KoboldLogger.shared.logDir.appendingPathComponent("crash.log")
            try? msg.data(using: .utf8)?.write(to: crashURL, options: .atomic)
            KoboldLogger.shared.critical("CRASH: \(exception.name.rawValue) — \(exception.reason ?? "?")")
        }

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
                let crashURL = KoboldLogger.shared.logDir.appendingPathComponent("crash.log")
                try? msg.data(using: .utf8)?.write(to: crashURL, options: .atomic)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    deinit {
        debugHandle?.closeFile()
        toolsHandle?.closeFile()
        buildHandle?.closeFile()
        perfHandle?.closeFile()
    }
}

// MARK: - Shorthand Functions

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
func ktool(_ msg: String, file: String = #file, line: Int = #line) {
    KoboldLogger.shared.tool(msg, file: file, line: line)
}
func kbuild(_ msg: String, file: String = #file, line: Int = #line) {
    KoboldLogger.shared.build(msg, file: file, line: line)
}
func kperf(_ msg: String, file: String = #file, line: Int = #line) {
    KoboldLogger.shared.perf(msg, file: file, line: line)
}
