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
    private let blockedInjection = [
        "`",        // backtick subshell
        "$(", "${", // variable/command substitution
        ":(){",     // fork bomb
        ":(){ :|: &};",
        "\n", "\r", // newline injection
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

    // ── Normal tier: adds filesystem + git ──
    private let normalTierAllowlist = [
        "grep", "find", "sort", "uniq", "cut", "tr",
        "mkdir", "rmdir", "touch", "cp", "mv", "ln",
        "git", "open", "pbcopy", "pbpaste",
        "xattr", "mdls", "mdfind", "ditto",
    ]

    public init() {}

    // MARK: - Tier Logic

    private var isPowerTier: Bool {
        let useTierToggles = UserDefaults.standard.object(forKey: "kobold.shell.safeTier") != nil
        if useTierToggles {
            return UserDefaults.standard.bool(forKey: "kobold.shell.powerTier")
        }
        let level = min(max(UserDefaults.standard.integer(forKey: "kobold.autonomyLevel"), 1), 3)
        return level >= 3
    }

    private var isNormalTier: Bool {
        let useTierToggles = UserDefaults.standard.object(forKey: "kobold.shell.safeTier") != nil
        if useTierToggles {
            return UserDefaults.standard.bool(forKey: "kobold.shell.normalTier")
        }
        let level = min(max(UserDefaults.standard.integer(forKey: "kobold.autonomyLevel"), 1), 3)
        return level >= 2
    }

    private var isSafeTier: Bool {
        let useTierToggles = UserDefaults.standard.object(forKey: "kobold.shell.safeTier") != nil
        if useTierToggles {
            return UserDefaults.standard.bool(forKey: "kobold.shell.safeTier")
        }
        return true // safe tier always on in legacy mode
    }

    private var customBlacklist: [String] {
        let raw = UserDefaults.standard.string(forKey: "kobold.shell.customBlacklist") ?? ""
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
        let timeout = min(Double(timeoutStr) ?? 30.0, 120.0)

        try validateCommand(command)

        return try await runCommand(command, workdir: workdir, timeout: timeout)
    }

    private func validateCommand(_ command: String) throws {
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

        // For safe/normal tiers, also block shell operators (pipes, redirects, chaining)
        let restrictedOperators = ["&&", "||", ";;", "|", ">", ">>", "<", "<<", ";"]
        for op in restrictedOperators {
            if command.contains(op) {
                throw ToolError.unauthorized("Operator '\(op)' requires Power-Tier")
            }
        }

        // Build allowlist from active tiers
        var allowed: [String] = []
        if isSafeTier { allowed += safeTierAllowlist }
        if isNormalTier { allowed += normalTierAllowlist }

        let isAllowed = allowed.contains { firstBinary == $0 || firstWord.hasSuffix("/\($0)") }
        if !isAllowed {
            throw ToolError.unauthorized(
                "Command '\(firstBinary)' not in tier allowlist. Enable Power-Tier for unrestricted access."
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

            // Timeout
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
                continuation.resume(throwing: ToolError.timeout)
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let exitCode = proc.terminationStatus

                var output = "$ \(command)\n"
                if !stdout.isEmpty { output += stdout }
                if !stderr.isEmpty { output += "[stderr] \(stderr)" }
                output += "\n[exit: \(exitCode)]"

                if exitCode == 0 || !stdout.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: ToolError.executionFailed(stderr.isEmpty ? "Exit code \(exitCode)" : stderr))
                }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.resume(throwing: ToolError.executionFailed(error.localizedDescription))
            }
        }
    }
}
