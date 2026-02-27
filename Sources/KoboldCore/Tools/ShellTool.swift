import Foundation

// MARK: - ShellTool — Blacklist-based shell execution with tier system

public struct ShellTool: Tool, Sendable {

    public let name = "shell"
    public let description = "Execute shell commands (blacklist-based security)"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "command": ToolSchemaProperty(
                    type: "string",
                    description: "Shell command to execute",
                    required: true
                ),
                "workdir": ToolSchemaProperty(
                    type: "string",
                    description: "Working directory (optional)"
                ),
                "timeout": ToolSchemaProperty(
                    type: "string",
                    description: "Timeout in seconds (max 120, default 30)"
                )
            ],
            required: ["command"]
        )
    }

    // ── Blacklisted commands (NEVER allowed, regardless of tier) ──
    private let blacklistedCommands = [
        "rm -rf /", "rm -rf ~", "rm -rf /*",
        "mkfs", "dd if=", "fdisk",
        "shutdown", "reboot", "halt", "poweroff",
        "launchctl unload", "systemsetup",
        "dscl", "dseditgroup",
        "security delete-keychain",
        "csrutil", "nvram",
        "diskutil eraseDisk", "diskutil eraseVolume",
    ]

    // ── Blacklisted binaries (never executable) ──
    private let blacklistedBinaries = [
        "sudo", "su", "doas", "pkexec",
        "passwd", "chpasswd", "useradd", "userdel", "usermod",
        "visudo",
    ]

    // ── Blocked injection patterns ──
    // H2: \n und \r entfernt — blockierte ALLE mehrzeiligen Befehle (false positive)
    private let blockedInjection = [
        "`",        // backtick subshell
        "$(", "${", // variable/command substitution
        ":(){",     // fork bomb
        ":(){ :|: &};",
    ]

    // ── Blocked sensitive paths ──
    private let blockedPaths = [
        "/etc/passwd", "/etc/shadow", "/etc/sudoers",
        "/private/etc/", "~/.ssh/id_", "~/.gnupg/",
        "/System/", "/usr/sbin/",
    ]

    // ── Safe tier: read-only, info commands only ──
    private let safeTierAllowlist = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo",
        "whoami", "date", "uname", "stat", "file", "diff",
        "md5", "shasum", "df", "du", "which", "type",
        "printenv", "env", "hostname", "uptime", "sw_vers",
    ]

    // ── Normal tier: adds filesystem + git + dev tools ──
    // H4: Erweitert um gängige Utilities (sed, awk, python3, brew, swift, etc.)
    private let normalTierAllowlist = [
        "grep", "find", "sort", "uniq", "cut", "tr",
        "mkdir", "rmdir", "touch", "cp", "mv", "ln",
        "git", "open", "pbcopy", "pbpaste",
        "xattr", "mdls", "mdfind", "ditto",
        "sed", "awk", "python3", "pip3", "npm", "node",
        "brew", "zip", "unzip", "tar", "curl", "wget",
        "chmod", "chown", "xcode-select", "swift", "swiftc",
        "xcrun", "xcodebuild", "make", "cmake",
    ]

    public init() {}

    // MARK: - Tier Logic

    // Autonomy level is the PRIMARY control. Tier toggles can ADDITIONALLY enable tiers.
    // Level 1 = Safe only, Level 2 = Safe+Normal, Level 3 = Power (all allowed)
    private var autonomyLevel: Int {
        let raw = UserDefaults.standard.integer(forKey: "kobold.autonomyLevel")
        // raw == 0 bedeutet: nie gesetzt → Default Normal (2), nicht Safe (1)
        let level = raw == 0 ? 2 : raw
        return min(max(level, 1), 3)
    }

    private var isPowerTier: Bool {
        if autonomyLevel >= 3 { return true }
        return UserDefaults.standard.bool(forKey: "kobold.shell.powerTier")
    }

    private var isNormalTier: Bool {
        if autonomyLevel >= 2 { return true }
        return UserDefaults.standard.bool(forKey: "kobold.shell.normalTier")
    }

    private var isSafeTier: Bool {
        return true // safe tier always on
    }

    private var customBlacklist: [String] {
        let raw = UserDefaults.standard.string(forKey: "kobold.shell.customBlacklist") ?? ""
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var customAllowlist: [String] {
        let raw = UserDefaults.standard.string(forKey: "kobold.shell.customAllowlist") ?? ""
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Validation

    public func validate(arguments: [String: String]) throws {
        guard let cmd = arguments["command"], !cmd.isEmpty else {
            throw ToolError.missingRequired("command")
        }
        try validateCommand(cmd)
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let command = arguments["command"] ?? ""
        let workdir = arguments["workdir"] ?? NSTemporaryDirectory()
        let timeoutStr = arguments["timeout"] ?? "30"
        let hardCap = Double(UserDefaults.standard.integer(forKey: "kobold.shell.timeout"))
        let maxTimeout = hardCap > 0 ? hardCap : 60.0
        let timeout = min(Double(timeoutStr) ?? 60.0, maxTimeout)

        try validateCommand(command)

        return try await runCommand(command, workdir: workdir, timeout: timeout)
    }

    private func validateCommand(_ command: String) throws {
        // 0. Check global shell permission (default: enabled)
        guard permissionEnabled("kobold.perm.shell") else {
            throw ToolError.unauthorized("Shell-Zugriff ist in den Einstellungen deaktiviert.")
        }

        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        let firstWord = trimmed.components(separatedBy: " ").first ?? ""
        let firstBinary = firstWord.components(separatedBy: "/").last ?? firstWord

        // 1. Always block injection patterns
        for pattern in blockedInjection {
            if command.contains(pattern) {
                throw ToolError.unauthorized("Blocked injection pattern in command")
            }
        }

        // 2. Always block sensitive paths
        for path in blockedPaths {
            if command.contains(path) {
                throw ToolError.pathViolation("Access to '\(path)' is blocked")
            }
        }

        // 3. Always block blacklisted commands
        for blk in blacklistedCommands {
            if lowered.contains(blk.lowercased()) {
                throw ToolError.unauthorized("Command '\(blk)' is permanently blacklisted")
            }
        }

        // 4. Always block blacklisted binaries
        if blacklistedBinaries.contains(firstBinary) {
            throw ToolError.unauthorized("Binary '\(firstBinary)' is permanently blacklisted")
        }

        // 5. Check custom blacklist
        for blk in customBlacklist {
            if firstBinary == blk || lowered.contains(blk.lowercased()) {
                throw ToolError.unauthorized("Command '\(blk)' is in your custom blacklist")
            }
        }

        // 6. Tier-based access
        if isPowerTier {
            // Power tier: everything passes that survived the blacklist above
            // Also allow pipes and chaining for power users
            return
        }

        // H3: Operatoren nur in Safe-Tier blockiert (vorher: auch Normal-Tier)
        // Normal-Tier braucht Pipes/Redirects für praktische Aufgaben (grep | sort, echo > file)
        if autonomyLevel < 2 {
            let restrictedOperators = ["&&", "||", ";;", "|", ">", ">>", "<", "<<", ";"]
            for op in restrictedOperators {
                if command.contains(op) {
                    throw ToolError.unauthorized("Operator '\(op)' requires Normal or Power-Tier")
                }
            }
        }

        // Build allowlist from active tiers + custom allowlist
        var allowed: [String] = []
        if isSafeTier { allowed += safeTierAllowlist }
        if isNormalTier { allowed += normalTierAllowlist }
        allowed += customAllowlist  // User-defined extra allowed commands

        let isAllowed = allowed.contains { firstBinary == $0 || firstWord.hasSuffix("/\($0)") }
        if !isAllowed {
            throw ToolError.unauthorized(
                "Command '\(firstBinary)' nicht erlaubt. Aktiviere Power-Tier oder füge es zur Whitelist hinzu."
            )
        }
    }

    // MARK: - Execution

    private func runCommand(_ command: String, workdir: String, timeout: TimeInterval) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            // Sanitize environment and set enhanced PATH
            var env = ProcessInfo.processInfo.environment
            let removeKeys = ["LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"]
            for key in removeKeys { env.removeValue(forKey: key) }

            // Enhanced PATH: bundled tools → downloaded Python → Homebrew → system
            var paths: [String] = []
            if let bundleBin = Bundle.main.executableURL?.deletingLastPathComponent().path {
                paths.append(bundleBin)
            }
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let pythonBin = appSupport?.appendingPathComponent("KoboldOS/python/bin").path,
               FileManager.default.fileExists(atPath: pythonBin) {
                paths.append(pythonBin)
            }
            paths += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            env["PATH"] = paths.joined(separator: ":")

            process.environment = env

            // Set working directory
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let resolvedDir = workdir.hasPrefix("~/") ? home + workdir.dropFirst(1) : workdir
            if FileManager.default.fileExists(atPath: resolvedDir) {
                process.currentDirectoryURL = URL(fileURLWithPath: resolvedDir)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Collect output data incrementally to avoid readDataToEndOfFile() blocking
            nonisolated(unsafe) var stdoutData = Data()
            nonisolated(unsafe) var stderrData = Data()
            let dataLock = NSLock()

            let maxOutputBytes = 2_000_000 // 2MB cap — generous for large outputs

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    dataLock.lock()
                    if stdoutData.count < maxOutputBytes {
                        stdoutData.append(chunk.prefix(maxOutputBytes - stdoutData.count))
                    }
                    dataLock.unlock()
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    dataLock.lock()
                    if stderrData.count < maxOutputBytes {
                        stderrData.append(chunk.prefix(maxOutputBytes - stderrData.count))
                    }
                    dataLock.unlock()
                }
            }

            // Thread-safe guard against double-resume (timeout + terminationHandler race)
            let resumeLock = NSLock()
            nonisolated(unsafe) var hasResumed = false

            @Sendable func tryResume(_ block: () -> Void) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                block()
            }

            // Timeout
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
                // Give a brief moment for output handlers to flush
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    tryResume { continuation.resume(throwing: ToolError.timeout) }
                }
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()
                // Give a brief moment for output handlers to flush remaining data
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    dataLock.lock()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    dataLock.unlock()

                    let exitCode = proc.terminationStatus

                    var output = "$ \(command)\n"
                    if !stdout.isEmpty { output += stdout }
                    if !stderr.isEmpty { output += "[stderr] \(stderr)" }
                    output += "\n[exit: \(exitCode)]"

                    tryResume {
                        if exitCode == 0 || !stdout.isEmpty {
                            continuation.resume(returning: output)
                        } else {
                            continuation.resume(throwing: ToolError.executionFailed(stderr.isEmpty ? "Exit code \(exitCode)" : stderr))
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                tryResume { continuation.resume(throwing: ToolError.executionFailed(error.localizedDescription)) }
            }
        }
    }
}
