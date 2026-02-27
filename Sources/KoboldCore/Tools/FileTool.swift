import Foundation

// MARK: - FileTool — Safe file system operations with path jail

public struct FileTool: Tool, Sendable {

    public let name = "file"
    public let description = "Read, write, list, or check files within allowed directories"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action: read, write, list, exists, delete",
                    enumValues: ["read", "write", "list", "exists", "delete"],
                    required: true
                ),
                "path": ToolSchemaProperty(
                    type: "string",
                    description: "File or directory path (relative to home or absolute within allowed dirs)",
                    required: true
                ),
                "content": ToolSchemaProperty(
                    type: "string",
                    description: "Content to write (for write action)"
                )
            ],
            required: ["action", "path"]
        )
    }

    // Allowed base directories: entire home dir + /tmp + NSTemporaryDirectory
    private static let allowedBases: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home,                       // Full home directory access
            "/tmp",                     // System temp
            NSTemporaryDirectory()      // App-specific temp (/var/folders/...)
        ]
    }()

    // Blocked paths — sensitive system and user data that should never be accessed
    private let blockedPatterns = [
        "/etc/", "/usr/", "/bin/", "/sbin/", "/sys/",
        "/proc/", "/dev/", "/root/",
        ".ssh/", "id_rsa", "id_ed25519",       // SSH keys
        "shadow", "sudoers",                     // System auth
        "/Keychains/", "login.keychain",         // macOS Keychain
        "/.gnupg/",                              // GPG keys
        "/Cookies/", "Cookies.binarycookies"     // Browser cookies
    ]

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        guard let path = arguments["path"], !path.isEmpty else {
            throw ToolError.missingRequired("path")
        }
        let validActions = ["read", "write", "list", "exists", "delete"]
        if !validActions.contains(action) {
            throw ToolError.invalidParameter("action", "must be one of: \(validActions.joined(separator: ", "))")
        }
        if action == "write" && (arguments["content"] == nil) {
            throw ToolError.missingRequired("content")
        }
        // Validate path security at validate-time so bad paths fail fast
        _ = try resolvePath(path)
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let rawPath = arguments["path"] ?? ""
        let content = arguments["content"] ?? ""

        let resolvedPath = try resolvePath(rawPath)

        switch action {
        case "read":
            return try readFile(at: resolvedPath)
        case "write":
            guard permissionEnabled("kobold.perm.fileWrite") else {
                throw ToolError.unauthorized("Dateischreiben ist in den Einstellungen deaktiviert.")
            }
            guard permissionEnabled("kobold.perm.createFiles") || FileManager.default.fileExists(atPath: resolvedPath) else {
                throw ToolError.unauthorized("Dateien erstellen ist in den Einstellungen deaktiviert.")
            }
            return try await writeFile(at: resolvedPath, content: content)
        case "list":
            return try listDirectory(at: resolvedPath)
        case "exists":
            let exists = FileManager.default.fileExists(atPath: resolvedPath)
            return exists ? "exists: true" : "exists: false"
        case "delete":
            guard permissionEnabled("kobold.perm.deleteFiles", defaultValue: false) else {
                throw ToolError.unauthorized("Dateien löschen ist in den Einstellungen deaktiviert.")
            }
            return try deleteFile(at: resolvedPath)
        default:
            throw ToolError.invalidParameter("action", "unknown action: \(action)")
        }
    }

    // MARK: - Path Security

    private func resolvePath(_ raw: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Expand ~ and resolve
        var expanded = raw
        if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst(1)
        } else if expanded.hasPrefix("~") {
            expanded = home
        } else if !expanded.hasPrefix("/") {
            // Relative to KoboldOS app support
            let appSupport = home + "/Library/Application Support/KoboldOS"
            expanded = appSupport + "/" + expanded
        }

        // Canonicalize to prevent traversal
        let canonical = (expanded as NSString).standardizingPath

        // Check for traversal patterns
        if canonical.contains("/../") || canonical.hasSuffix("/..") || canonical.contains("..") {
            throw ToolError.pathViolation("Directory traversal detected: \(raw)")
        }

        // Check blocked patterns
        for pattern in blockedPatterns {
            if canonical.lowercased().contains(pattern.lowercased()) {
                throw ToolError.pathViolation("Access to '\(pattern)' is blocked")
            }
        }

        // Verify it's in an allowed base
        let allowed = Self.allowedBases.contains { canonical.hasPrefix($0) }
        if !allowed {
            let bases = Self.allowedBases.map { "• \($0)" }.joined(separator: "\n")
            throw ToolError.pathViolation(
                "Path '\(canonical)' is outside allowed directories:\n\(bases)"
            )
        }

        // Check for symlink escape
        let url = URL(fileURLWithPath: canonical)
        let resolved = url.resolvingSymlinksInPath()
        if resolved.path != canonical {
            let resolvedStr = resolved.path
            let allowed2 = Self.allowedBases.contains { resolvedStr.hasPrefix($0) }
            if !allowed2 {
                throw ToolError.pathViolation("Symlink escapes allowed directory: \(raw)")
            }
        }

        return canonical
    }

    // MARK: - File Operations

    private func readFile(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.executionFailed("File not found: \(path)")
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            throw ToolError.executionFailed("'\(path)' is a directory. Use action=list.")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int) ?? 0
        if size > 10 * 1024 * 1024 { // 10MB limit
            throw ToolError.executionFailed("File too large (\(size / 1024)KB > 10MB limit)")
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        return "File: \(path)\nSize: \(size) bytes\n---\n\(content)"
    }

    private func writeFile(at path: String, content: String) async throws -> String {
        if content.utf8.count > 5 * 1024 * 1024 { // 5MB limit
            throw ToolError.executionFailed("Content too large (> 5MB limit)")
        }

        let fileName = (path as NSString).lastPathComponent
        let isNewFile = !FileManager.default.fileExists(atPath: path)
        let oldContent: String? = isNewFile ? nil : try? String(contentsOfFile: path, encoding: .utf8)

        // Create parent directories if needed
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // H1: Atomic write — removeItem vor moveItem damit Overwrite funktioniert
        let tmp = path + ".tmp.\(UUID().uuidString)"
        try content.write(toFile: tmp, atomically: false, encoding: .utf8)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: path)

        let newLines = content.components(separatedBy: "\n")
        var output = "Written \(content.utf8.count) bytes to: \(path)"

        // Generate diff for UI display (Claude Code-style)
        if let old = oldContent {
            let diff = await generateUnifiedDiff(old: old, new: content, fileName: fileName)
            if !diff.isEmpty {
                output += "\n__DIFF__\n\(diff)"
            }
        } else {
            // New file — show first lines as additions
            let preview = newLines.prefix(30).map { "+\($0)" }.joined(separator: "\n")
            let more = newLines.count > 30 ? "\n@@ ... +\(newLines.count - 30) more lines @@" : ""
            output += "\n__DIFF__\n+++ b/\(fileName) (new file, \(newLines.count) lines)\n\(preview)\(more)"
        }

        return output
    }

    // MARK: - Unified Diff Generator (for Claude Code-style display)

    private func generateUnifiedDiff(old: String, new: String, fileName: String) async -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        if oldLines == newLines { return "" }

        // Use system /usr/bin/diff for reliable unified output (runs in <1ms)
        let tmpDir = NSTemporaryDirectory()
        let id = UUID().uuidString
        let oldFile = tmpDir + "kobold_diff_a_\(id)"
        let newFile = tmpDir + "kobold_diff_b_\(id)"
        defer {
            try? FileManager.default.removeItem(atPath: oldFile)
            try? FileManager.default.removeItem(atPath: newFile)
        }

        guard let _ = try? old.write(toFile: oldFile, atomically: true, encoding: .utf8),
              let _ = try? new.write(toFile: newFile, atomically: true, encoding: .utf8) else {
            return ""
        }

        guard let result = try? await AsyncProcess.run(
            executable: "/usr/bin/diff",
            arguments: ["-u", "-U3",
                        "--label", "a/\(fileName)",
                        "--label", "b/\(fileName)",
                        oldFile, newFile],
            timeout: 10
        ) else { return "" }

        let diffOutput = result.stdout
        guard !diffOutput.isEmpty else { return "" }

        // Limit output to prevent huge diffs from bloating the chat
        let lines = diffOutput.components(separatedBy: "\n")
        if lines.count > 120 {
            return lines.prefix(120).joined(separator: "\n") + "\n@@ ... \(lines.count - 120) more diff lines @@"
        }
        return diffOutput
    }

    private func listDirectory(at path: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.executionFailed("Not a directory: \(path)")
        }

        let items = try FileManager.default.contentsOfDirectory(atPath: path)
        let lines = items.sorted().map { item -> String in
            let fullPath = path + "/" + item
            var isItemDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isItemDir)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
            let size = (attrs?[.size] as? Int) ?? 0
            let type_str = isItemDir.boolValue ? "[DIR]" : "[FILE \(size)B]"
            return "\(type_str) \(item)"
        }

        return "Directory: \(path)\n\(lines.joined(separator: "\n"))"
    }

    private func deleteFile(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.executionFailed("File not found: \(path)")
        }

        // H5: Nur Systemdateien schützen — User-Dateien in erlaubten Verzeichnissen sind OK
        let isInAllowedDir = Self.allowedBases.contains(where: { path.hasPrefix($0) })
        if !isInAllowedDir && (path.hasSuffix(".swift") || path.hasSuffix(".app")) {
            throw ToolError.unauthorized("Cannot delete code/app files outside allowed directories")
        }

        try FileManager.default.removeItem(atPath: path)
        return "Deleted: \(path)"
    }
}
