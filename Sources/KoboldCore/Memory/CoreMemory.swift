import Foundation

// MARK: - MemoryBlock (Letta-style always-in-context memory)
// Reference: https://github.com/letta-ai/letta — letta/schemas/block.py

public struct MemoryBlock: Sendable, Codable, Identifiable {
    public let id: String
    public var label: String        // "persona", "human", "project", "task"
    public var value: String        // editable content
    public var limit: Int           // max characters (enforced by agent)
    public var description: String  // tells the agent what this block is for
    public var readOnly: Bool       // agent cannot modify if true

    public var isOverLimit: Bool { value.count > limit }
    public var charCount: Int { value.count }
    public var usagePercent: Double { min(1.0, Double(charCount) / Double(limit)) }

    public init(
        id: String = UUID().uuidString,
        label: String,
        value: String = "",
        limit: Int = 2000,
        description: String = "",
        readOnly: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.limit = limit
        self.description = description
        self.readOnly = readOnly
    }
}

public enum BlockMemoryError: Error, LocalizedError, Sendable {
    case blockNotFound(String)
    case blockReadOnly(String)
    case overLimit(String)

    public var errorDescription: String? {
        switch self {
        case .blockNotFound(let l): return "Memory block '\(l)' not found"
        case .blockReadOnly(let l): return "Memory block '\(l)' is read-only"
        case .overLimit(let l):     return "Memory block '\(l)' would exceed character limit"
        }
    }
}

// MARK: - CoreMemory Actor (Letta-style)

public actor CoreMemory {

    private var blocks: [String: MemoryBlock] = [:]
    private let persistenceURL: URL

    public init(agentID: String = "default") {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        self.persistenceURL = appSupport
            .appendingPathComponent("KoboldOS/Memory/core_memory_\(agentID).json")
        // Seed default blocks
        self.blocks = Self.makeDefaultBlocks()
        Task { await self.load() }
    }

    // MARK: - Default Blocks

    private static func makeDefaultBlocks() -> [String: MemoryBlock] {
        var b: [String: MemoryBlock] = [:]
        b["persona"] = MemoryBlock(
            label: "persona",
            value: "I am KoboldOS, an advanced AI assistant running locally on macOS. I have access to tools including file operations, shell commands, and web browsing. I am helpful, precise, and privacy-focused.",
            limit: 2000,
            description: "The agent's personality, role, and self-description. The agent can update this.",
            readOnly: false
        )
        b["human"] = MemoryBlock(
            label: "human",
            value: "The user is running KoboldOS on macOS. No additional information about the user is known yet.",
            limit: 2000,
            description: "Long-term facts about the user: name, profession, preferences, instructions. Update as you learn more.",
            readOnly: false
        )
        b["short_term"] = MemoryBlock(
            label: "short_term",
            value: "",
            limit: 1500,
            description: "Current session context: what the user is working on right now, recent requests, active topics. Clear or overwrite when the context changes.",
            readOnly: false
        )
        b["knowledge"] = MemoryBlock(
            label: "knowledge",
            value: "",
            limit: 3000,
            description: "Learned solutions, patterns, and reusable knowledge: code snippets that worked, API endpoints, file paths, troubleshooting steps. Things you want to remember for future tasks.",
            readOnly: false
        )
        b["system"] = MemoryBlock(
            label: "system",
            value: "macOS AI Agent — local execution only",
            limit: 500,
            description: "System context (read-only).",
            readOnly: true
        )
        b["capabilities"] = MemoryBlock(
            label: "capabilities",
            value: """
            Du bist KoboldOS v\(KoboldVersion.current) — ein lokaler KI-Agent auf macOS.

            DEINE TOOLS:
            - shell: Beliebige Terminal-Befehle (ls, git, python3, brew, curl, etc.)
            - file: Dateien lesen, schreiben, auflisten, löschen (~/Desktop, ~/Documents, etc.)
            - browser: Webseiten abrufen (fetch) und im Web suchen (search)
            - calculator: Mathematische Berechnungen
            - core_memory_append/replace/read: Dein eigenes Gedächtnis verwalten
            - archival_memory_search/insert: Langzeit-Archiv durchsuchen/erweitern
            - skill_write: Skills erstellen/verwalten (.md Dateien die dein Verhalten erweitern)
            - task_manage: Geplante Aufgaben erstellen und verwalten (cron-artig)
            - workflow_manage: Workflow-Definitionen erstellen
            - call_subordinate: Sub-Agenten delegieren (coder, web, reviewer, utility)
            - delegate_parallel: Mehrere Sub-Agenten gleichzeitig starten
            - calendar: Apple Kalender-Events und Erinnerungen verwalten
            - contacts: Apple Kontakte durchsuchen und lesen
            - applescript: macOS-Apps steuern (Safari, Mail, Messages, Notizen, Finder)
            - notify_user: macOS Push-Benachrichtigungen senden

            DU KANNST:
            - Code schreiben und ausführen (Python, Swift, JS, Shell-Scripts)
            - Dateien erstellen, bearbeiten, organisieren
            - Im Web suchen und Seiten lesen
            - Git-Repositories verwalten
            - Systeminformationen abfragen (df, top, uname, etc.)
            - Aufgaben planen und automatisieren
            - Komplexe Aufgaben an Spezialisten-Agenten delegieren
            - Kalender-Termine erstellen und lesen
            - Kontakte durchsuchen, Emails senden/lesen
            - macOS steuern (Lautstärke, Screenshots, Apps öffnen, Finder)
            - Erinnerungen erstellen und verwalten
            """,
            limit: 2000,
            description: "What the agent can do — read-only reference.",
            readOnly: true
        )
        return b
    }

    // MARK: - Compilation (injected into system prompt every step)

    public func compile() -> String {
        guard !blocks.isEmpty else { return "" }
        let sorted = blocks.values.sorted { $0.label < $1.label }
        return sorted.map { block in
            "<\(block.label)>\n\(block.value)\n</\(block.label)>"
        }.joined(separator: "\n\n")
    }

    // MARK: - Block Access

    public func getBlock(_ label: String) -> MemoryBlock? {
        blocks[label]
    }

    public func allBlocks() -> [MemoryBlock] {
        blocks.values.sorted { $0.label < $1.label }
    }

    public func upsert(_ block: MemoryBlock) {
        blocks[block.label] = block
        save()
    }

    // MARK: - Agent-Callable Operations (Letta-style memory tools)

    public func append(label: String, content: String) throws {
        guard permissionEnabled("kobold.perm.modifyMemory") else {
            throw BlockMemoryError.blockReadOnly("Gedächtnis-Änderungen sind in den Einstellungen deaktiviert")
        }
        guard var block = blocks[label] else {
            throw BlockMemoryError.blockNotFound(label)
        }
        guard !block.readOnly else {
            throw BlockMemoryError.blockReadOnly(label)
        }
        let newValue = block.value.isEmpty ? content : block.value + "\n" + content
        guard newValue.count <= block.limit else {
            throw BlockMemoryError.overLimit(label)
        }
        block.value = newValue
        blocks[label] = block
        save()
    }

    public func replace(label: String, oldContent: String, newContent: String) throws {
        guard permissionEnabled("kobold.perm.modifyMemory") else {
            throw BlockMemoryError.blockReadOnly("Gedächtnis-Änderungen sind in den Einstellungen deaktiviert")
        }
        guard var block = blocks[label] else {
            throw BlockMemoryError.blockNotFound(label)
        }
        guard !block.readOnly else {
            throw BlockMemoryError.blockReadOnly(label)
        }
        let newValue = block.value.replacingOccurrences(of: oldContent, with: newContent)
        guard newValue.count <= block.limit else {
            throw BlockMemoryError.overLimit(label)
        }
        block.value = newValue
        blocks[label] = block
        save()
    }

    public func clear(label: String) throws {
        guard var block = blocks[label] else {
            throw BlockMemoryError.blockNotFound(label)
        }
        guard !block.readOnly else {
            throw BlockMemoryError.blockReadOnly(label)
        }
        block.value = ""
        blocks[label] = block
        save()
    }

    public func createBlock(label: String, value: String = "", limit: Int = 2000, description: String = "") {
        guard blocks[label] == nil else { return }
        blocks[label] = MemoryBlock(
            label: label, value: value, limit: limit,
            description: description, readOnly: false
        )
        save()
    }

    // MARK: - Memory Inheritance (for sub-agents)

    /// Inherit read-only copies of key blocks from a parent agent's memory.
    /// Sub-agents get persona, human, and knowledge context so they know who they're working for.
    public func inheritFrom(_ parent: CoreMemory) async {
        let parentBlocks = await parent.allBlocks()
        let inheritLabels = ["persona", "human", "knowledge", "capabilities"]
        for block in parentBlocks where inheritLabels.contains(block.label) {
            // Import as read-only so sub-agent can see but not modify parent's memory
            blocks[block.label] = MemoryBlock(
                id: block.id,
                label: block.label,
                value: block.value,
                limit: block.limit,
                description: block.description + " (geerbt)",
                readOnly: true
            )
        }
    }

    // MARK: - Persistence

    /// Flush memory blocks to disk immediately (called on app shutdown)
    public func flush() {
        save()
    }

    private func save() {
        // P12: Encoding auf Actor-Thread (schnell), Disk-Write off-Thread
        let data = blocks.values
        guard let encoded = try? JSONEncoder().encode(Array(data)) else { return }
        let url = persistenceURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? encoded.write(to: url)
        }
    }

    private func load() {
        guard let encoded = try? Data(contentsOf: persistenceURL),
              let saved = try? JSONDecoder().decode([MemoryBlock].self, from: encoded) else { return }
        for block in saved {
            // Only restore non-read-only blocks (keep system defaults)
            if blocks[block.label]?.readOnly == false || blocks[block.label] == nil {
                blocks[block.label] = block
            }
        }
    }
}

// MARK: - CoreMemoryTool (exposes CoreMemory as agent-callable tools)

public struct CoreMemoryAppendTool: Tool {
    public let name = "core_memory_append"
    public let description = "Append content to a core memory block. Use this to remember important information about the user or update your own persona."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "label": ToolSchemaProperty(type: "string", description: "Block label: 'persona', 'human', or custom", required: true),
                "content": ToolSchemaProperty(type: "string", description: "Text to append", required: true)
            ],
            required: ["label", "content"]
        )
    }

    private let memory: CoreMemory

    public init(memory: CoreMemory) { self.memory = memory }

    public func validate(arguments: [String: String]) throws {
        guard let label = arguments["label"], !label.isEmpty else {
            throw ToolError.missingRequired("label")
        }
        guard let content = arguments["content"], !content.isEmpty else {
            throw ToolError.missingRequired("content")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let label = arguments["label"] ?? ""
        let content = arguments["content"] ?? ""
        do {
            try await memory.append(label: label, content: content)
            return "✓ Appended to memory block '\(label)'"
        } catch {
            return "Memory error: \(error.localizedDescription)"
        }
    }
}

public struct CoreMemoryReplaceTool: Tool {
    public let name = "core_memory_replace"
    public let description = "Replace text in a core memory block. Use this to update or correct remembered information."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "label": ToolSchemaProperty(type: "string", description: "Block label", required: true),
                "old_content": ToolSchemaProperty(type: "string", description: "Text to replace", required: true),
                "new_content": ToolSchemaProperty(type: "string", description: "Replacement text", required: true)
            ],
            required: ["label", "old_content", "new_content"]
        )
    }

    private let memory: CoreMemory

    public init(memory: CoreMemory) { self.memory = memory }

    public func validate(arguments: [String: String]) throws {
        guard arguments["label"] != nil else { throw ToolError.missingRequired("label") }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let label = arguments["label"] ?? ""
        let old = arguments["old_content"] ?? ""
        let new = arguments["new_content"] ?? ""
        do {
            try await memory.replace(label: label, oldContent: old, newContent: new)
            return "✓ Updated memory block '\(label)'"
        } catch {
            return "Memory error: \(error.localizedDescription)"
        }
    }
}

// MARK: - CoreMemoryReadTool

public struct CoreMemoryReadTool: Tool {
    public let name = "core_memory_read"
    public let description = "Read your core memory blocks. Call this to recall what you know about the user, yourself, or the current context. Use without parameters to list all blocks, or specify a label to read a specific block."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "label": ToolSchemaProperty(type: "string", description: "Optional block label to read (e.g. 'human', 'persona'). Omit to list all blocks.", required: false)
            ],
            required: []
        )
    }

    private let memory: CoreMemory

    public init(memory: CoreMemory) { self.memory = memory }

    public func validate(arguments: [String: String]) throws {}

    public func execute(arguments: [String: String]) async throws -> String {
        if let label = arguments["label"], !label.isEmpty {
            if let block = await memory.getBlock(label) {
                return "[\(block.label)] (\(block.charCount)/\(block.limit) chars)\n\(block.value)"
            }
            return "No memory block with label '\(label)' found."
        }
        let blocks = await memory.allBlocks()
        if blocks.isEmpty { return "No memory blocks stored." }
        return blocks.map { block in
            "[\(block.label)] (\(block.charCount)/\(block.limit) chars)\n\(block.value)"
        }.joined(separator: "\n---\n")
    }
}
