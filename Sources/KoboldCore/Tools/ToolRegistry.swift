import Foundation

// MARK: - ToolRegistry (Singleton with auto-disable and error tracking)

public actor ToolRegistry {

    public static let shared = ToolRegistry()

    private var tools: [String: any Tool] = [:]
    private var errorCounts: [String: Int] = [:]
    private var disabledTools: Set<String> = []
    private let maxErrors = 50
    private var isSetup = false

    private init() {}

    // MARK: - Compatibility init for AgentLoop
    public init(setup: Bool = false) {}

    // MARK: - Setup (register all built-in tools)

    public func setup() async {
        guard !isSetup else { return }
        isSetup = true
        register(FileTool())
        register(ShellTool())
        register(HTTPTool())
        register(BrowserTool())

        // Register platform-specific tools conditionally
        #if os(macOS)
        register(AppleScriptTool())
        register(CalendarTool())
        register(ContactsTool())
        #endif

        print("[ToolRegistry] Setup complete: \(tools.keys.sorted().joined(separator: ", "))")
    }

    // MARK: - Registration

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
        errorCounts[tool.name] = 0
    }

    public func get(_ name: String) -> (any Tool)? {
        guard !disabledTools.contains(name) else { return nil }
        return tools[name]
    }

    public func list() -> [String] {
        Array(tools.keys).sorted()
    }

    public func listEnabled() -> [String] {
        tools.keys.filter { !disabledTools.contains($0) }.sorted()
    }

    // MARK: - Error Tracking & Auto-Disable

    public func recordError(for name: String) {
        errorCounts[name, default: 0] += 1
        if (errorCounts[name] ?? 0) >= maxErrors {
            disabledTools.insert(name)
            print("[ToolRegistry] Auto-disabled '\(name)' after \(maxErrors) consecutive errors")
        }
    }

    public func recordSuccess(for name: String) {
        errorCounts[name] = 0
    }

    public func enableTool(_ name: String) {
        disabledTools.remove(name)
        errorCounts[name] = 0
        print("[ToolRegistry] Re-enabled: \(name)")
    }

    public func isDisabled(_ name: String) -> Bool {
        disabledTools.contains(name)
    }

    public func getErrorCount(for name: String) -> Int {
        errorCounts[name] ?? 0
    }

    // MARK: - Execute with error tracking

    /// Tools that use extended timeout (sub-agent delegation — 10 min instead of 60s)
    private let extendedTimeoutTools: Set<String> = ["call_subordinate", "delegate_parallel"]

    public func execute(call: ToolCall, timeout: TimeInterval = 60) async -> ToolResult {
        let name = call.name

        if disabledTools.contains(name) {
            return .fail("Tool '\(name)' is disabled (too many errors). Re-enable with: kobold tool enable \(name)")
        }

        guard let tool = tools[name] else {
            return .fail("Unknown tool: '\(name)'. Available: \(listEnabled().joined(separator: ", "))")
        }

        do {
            try tool.validate(arguments: call.arguments)
        } catch {
            recordError(for: name)
            return .fail("Parameter validation: \(error.localizedDescription)")
        }

        do {
            let result: String
            // Extended timeout for delegation tools (10 min), normal timeout for others
            let effectiveTimeout = extendedTimeoutTools.contains(name) ? 600.0 : timeout
            do {
                result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await tool.execute(arguments: call.arguments) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                        throw ToolError.timeout
                    }
                    guard let output = try await group.next() else {
                        throw ToolError.executionFailed("Tool lieferte kein Ergebnis")
                    }
                    group.cancelAll()
                    return output
                }
            }
            recordSuccess(for: name)
            return .success(output: result)
        } catch ToolError.timeout {
            recordError(for: name)
            return .fail("Tool '\(name)' timed out after \(Int(timeout))s")
        } catch {
            recordError(for: name)
            return .fail(error.localizedDescription)
        }
    }

    // MARK: - Schema for LLM

    public func getToolDescriptions() -> String {
        tools.filter { !disabledTools.contains($0.key) }.map { (name, tool) in
            "- \(name): \(tool.description) [risk: \(tool.riskLevel.rawValue)]"
        }.sorted().joined(separator: "\n")
    }
}
