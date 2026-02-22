import XCTest
@testable import KoboldCore

// MARK: - CoreMemory Tests (Letta-style memory blocks)

final class CoreMemoryTests: XCTestCase {

    var memory: CoreMemory!

    override func setUp() async throws {
        memory = CoreMemory(agentID: "test-\(UUID().uuidString)")
        // Wait for async init
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testDefaultBlocksExist() async throws {
        let blocks = await memory.allBlocks()
        let labels = blocks.map { $0.label }
        XCTAssertTrue(labels.contains("persona"), "persona block should exist")
        XCTAssertTrue(labels.contains("human"), "human block should exist")
        XCTAssertTrue(labels.contains("system"), "system block should exist")
    }

    func testDefaultPersonaHasContent() async throws {
        let persona = await memory.getBlock("persona")
        XCTAssertNotNil(persona)
        XCTAssertFalse(persona!.value.isEmpty, "Persona should have default content")
        XCTAssertFalse(persona!.readOnly, "Persona should not be read-only")
    }

    func testSystemBlockIsReadOnly() async throws {
        let system = await memory.getBlock("system")
        XCTAssertNotNil(system)
        XCTAssertTrue(system!.readOnly, "System block should be read-only")
    }

    func testAppendToBlock() async throws {
        try await memory.append(label: "human", content: "User likes dark mode")
        let human = await memory.getBlock("human")
        XCTAssertNotNil(human)
        XCTAssertTrue(human!.value.contains("User likes dark mode"), "Appended content should be in block")
    }

    func testAppendToReadOnlyBlockThrows() async throws {
        do {
            try await memory.append(label: "system", content: "Should fail")
            XCTFail("Should have thrown BlockMemoryError.blockReadOnly")
        } catch BlockMemoryError.blockReadOnly {
            // Expected
        }
    }

    func testAppendToNonexistentBlockThrows() async throws {
        do {
            try await memory.append(label: "nonexistent", content: "test")
            XCTFail("Should have thrown BlockMemoryError.blockNotFound")
        } catch BlockMemoryError.blockNotFound {
            // Expected
        }
    }

    func testReplaceInBlock() async throws {
        try await memory.replace(label: "persona", oldContent: "KoboldOS", newContent: "MyKobold")
        let persona = await memory.getBlock("persona")
        XCTAssertTrue(persona!.value.contains("MyKobold"), "Replacement should be applied")
    }

    func testClearBlock() async throws {
        try await memory.clear(label: "human")
        let human = await memory.getBlock("human")
        XCTAssertEqual(human!.value, "", "Block should be empty after clear")
    }

    func testCreateNewBlock() async throws {
        await memory.createBlock(label: "project", value: "Working on KoboldOS", description: "Current project context")
        let project = await memory.getBlock("project")
        XCTAssertNotNil(project)
        XCTAssertEqual(project!.value, "Working on KoboldOS")
    }

    func testCompilationIncludesAllBlocks() async throws {
        let compiled = await memory.compile()
        XCTAssertTrue(compiled.contains("<persona>"), "Compiled should have <persona> tag")
        XCTAssertTrue(compiled.contains("<human>"), "Compiled should have <human> tag")
        XCTAssertTrue(compiled.contains("<system>"), "Compiled should have <system> tag")
        XCTAssertTrue(compiled.contains("</persona>"), "Compiled should have </persona> closing tag")
    }

    func testUpsertBlock() async throws {
        let newBlock = MemoryBlock(label: "task", value: "Build KoboldOS", limit: 1000, description: "Current task")
        await memory.upsert(newBlock)
        let retrieved = await memory.getBlock("task")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved!.value, "Build KoboldOS")
    }

    func testUsagePercentCalculation() {
        let block = MemoryBlock(label: "test", value: String(repeating: "x", count: 500), limit: 1000)
        XCTAssertEqual(block.usagePercent, 0.5, accuracy: 0.001)
    }

    func testOverLimitDetection() {
        var block = MemoryBlock(label: "test", value: "", limit: 10)
        block.value = "This is too long for the limit"
        XCTAssertTrue(block.isOverLimit)
    }
}

// MARK: - CoreMemoryTool Tests

final class CoreMemoryToolTests: XCTestCase {

    func testAppendToolExecutes() async throws {
        let memory = CoreMemory(agentID: "tool-test-\(UUID().uuidString)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let tool = CoreMemoryAppendTool(memory: memory)
        let result = try await tool.execute(arguments: ["label": "human", "content": "test content"])
        XCTAssertTrue(result.contains("Appended"), "Should report success")
    }

    func testAppendToolValidation() {
        let memory = CoreMemory(agentID: "tool-val-test")
        let tool = CoreMemoryAppendTool(memory: memory)
        XCTAssertThrowsError(try tool.validate(arguments: ["content": "no label"]))
        XCTAssertThrowsError(try tool.validate(arguments: ["label": "human"])) // no content
    }

    func testReplaceToolExecutes() async throws {
        let memory = CoreMemory(agentID: "replace-tool-test-\(UUID().uuidString)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let tool = CoreMemoryReplaceTool(memory: memory)
        let result = try await tool.execute(arguments: [
            "label": "persona",
            "old_content": "KoboldOS",
            "new_content": "TestAgent"
        ])
        XCTAssertTrue(result.contains("Updated"), "Should report success")
    }
}

// MARK: - ToolRuleEngine Tests

final class ToolRuleEngineTests: XCTestCase {

    func testTerminalToolEndsLoop() {
        let engine = ToolRuleEngine(rules: [.terminal(toolName: "send_message")])
        XCTAssertTrue(engine.shouldTerminate(afterCalling: "send_message"))
        XCTAssertFalse(engine.shouldTerminate(afterCalling: "file"))
    }

    func testMaxCountLimit() {
        var engine = ToolRuleEngine(rules: [.maxCount(toolName: "browser", limit: 3)])
        XCTAssertFalse(engine.isAtLimit(toolName: "browser"))
        engine.record(toolName: "browser")
        engine.record(toolName: "browser")
        engine.record(toolName: "browser")
        XCTAssertTrue(engine.isAtLimit(toolName: "browser"))
    }

    func testContinueAfterOverridesTerminal() {
        let engine = ToolRuleEngine(rules: [
            .terminal(toolName: "http"),
            .continueAfter(toolName: "http")
        ])
        XCTAssertFalse(engine.shouldTerminate(afterCalling: "http"))
    }

    func testChildRuleReturnsNextTools() {
        let engine = ToolRuleEngine(rules: [.child(toolName: "file", children: ["shell", "browser"])])
        let next = engine.requiredNextTools(after: "file")
        XCTAssertNotNil(next)
        XCTAssertTrue(next!.contains("shell"))
        XCTAssertTrue(next!.contains("browser"))
    }

    func testResetClearsCounts() {
        var engine = ToolRuleEngine(rules: [.maxCount(toolName: "shell", limit: 1)])
        engine.record(toolName: "shell")
        XCTAssertTrue(engine.isAtLimit(toolName: "shell"))
        engine.reset()
        XCTAssertFalse(engine.isAtLimit(toolName: "shell"))
    }

    func testDefaultRuleSet() {
        let engine = ToolRuleEngine.default
        XCTAssertFalse(engine.rules.isEmpty)
    }

    func testResearchRuleSet() {
        let engine = ToolRuleEngine.research
        XCTAssertFalse(engine.rules.isEmpty)
    }
}

// MARK: - ToolCallParser Tests (Extended)

final class ToolCallParserExtendedTests: XCTestCase {

    let parser = ToolCallParser()

    func testParseXMLStyle() {
        let response = """
        I'll use the shell tool.
        <tool_call>{"name": "shell", "parameters": {"command": "whoami"}}</tool_call>
        """
        let calls = parser.parse(response: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "shell")
        XCTAssertEqual(calls[0].arguments["command"], "whoami")
    }

    func testParseBareJSON() {
        let response = """
        {"name": "core_memory_append", "parameters": {"label": "human", "content": "User likes dark mode"}}
        """
        let calls = parser.parse(response: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "core_memory_append")
        XCTAssertEqual(calls[0].arguments["label"], "human")
    }

    func testParseJSONCodeBlock() {
        let response = """
        Here's the tool call:
        ```json
        {"name": "file", "parameters": {"action": "read", "path": "/tmp/test.txt"}}
        ```
        """
        let calls = parser.parse(response: response)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "file")
    }

    func testPlainTextBecomesImplicitResponse() {
        // AgentZero pattern: plain text → implicit response tool call
        let calls = parser.parse(response: "The capital of France is Paris.")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "response")
    }

    func testMultipleXMLToolCalls() {
        let response = """
        I'll check two things:
        <tool_call>{"name": "shell", "parameters": {"command": "whoami"}}</tool_call>
        <tool_call>{"name": "shell", "parameters": {"command": "pwd"}}</tool_call>
        """
        let calls = parser.parse(response: response)
        XCTAssertEqual(calls.count, 2)
    }

    func testFormatSuccessResult() {
        let result = ToolResult.success(output: "tim")
        let formatted = parser.formatToolResult(result, callId: "test-123", toolName: "shell")
        XCTAssertTrue(formatted.contains("success"))
        XCTAssertTrue(formatted.contains("tim"))
        XCTAssertTrue(formatted.contains("shell"))
    }

    func testFormatFailureResult() {
        let result = ToolResult.failure(error: "Command not found", code: 127)
        let formatted = parser.formatToolResult(result, callId: "err-1", toolName: "shell")
        XCTAssertTrue(formatted.contains("failed"))
        XCTAssertTrue(formatted.contains("Command not found"))
    }
}

// MARK: - FileTool Security Tests

final class FileToolSecurityTests: XCTestCase {

    func testAllowedPathPasses() throws {
        let tool = FileTool()
        // Use the real system temp directory (NSTemporaryDirectory), not /tmp symlink
        let tmpPath = NSTemporaryDirectory() + "test.txt"
        XCTAssertNoThrow(try tool.validate(arguments: ["action": "read", "path": tmpPath]))
    }

    func testBlockedEtcPath() throws {
        let tool = FileTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["action": "read", "path": "/etc/passwd"]))
    }

    func testBlockedSystemPath() throws {
        let tool = FileTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["action": "read", "path": "/usr/bin/bash"]))
    }

    func testPathTraversalBlocked() throws {
        let tool = FileTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["action": "read", "path": "/tmp/../etc/passwd"]))
    }

    func testMissingActionThrows() throws {
        let tool = FileTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["path": "/tmp/test.txt"]))
    }

    func testReadWriteDeleteCycle() async throws {
        let tool = FileTool()
        let path = NSTemporaryDirectory() + "kobold_test_\(UUID().uuidString).txt"
        let content = "KoboldOS test content"

        // Write
        let writeResult = try await tool.execute(arguments: ["action": "write", "path": path, "content": content])
        XCTAssertTrue(writeResult.contains("Written") || writeResult.contains("wrote"), "Write should succeed: \(writeResult)")

        // Read
        let readResult = try await tool.execute(arguments: ["action": "read", "path": path])
        XCTAssertTrue(readResult.contains(content), "Read should return written content: \(readResult)")

        // Delete
        let deleteResult = try await tool.execute(arguments: ["action": "delete", "path": path])
        XCTAssertTrue(deleteResult.contains("Deleted") || deleteResult.contains("deleted"), "Delete should succeed: \(deleteResult)")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "File should be gone")
    }
}

// MARK: - ShellTool Tests

final class ShellToolTests: XCTestCase {

    func testWhitelistedCommandPasses() throws {
        let tool = ShellTool()
        XCTAssertNoThrow(try tool.validate(arguments: ["command": "whoami"]))
    }

    func testBlockedCommandFails() throws {
        let tool = ShellTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["command": "rm -rf /"]))
    }

    func testPipeOperatorBlocked() throws {
        let tool = ShellTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["command": "whoami | cat"]))
    }

    func testSudoBlocked() throws {
        let tool = ShellTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["command": "sudo whoami"]))
    }

    func testWhoamiExecutes() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "whoami"])
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "whoami should return a username")
    }

    func testDateExecutes() async throws {
        let tool = ShellTool()
        let result = try await tool.execute(arguments: ["command": "date"])
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

// MARK: - ToolRegistry Auto-Disable Tests

final class ToolRegistryAutoDisableTests: XCTestCase {

    func testRegisterAndList() async throws {
        let registry = ToolRegistry()
        await registry.register(FileTool())
        let tools = await registry.list()
        XCTAssertTrue(tools.contains("file"))
    }

    func testAutoDisableAfterErrors() async throws {
        let registry = ToolRegistry()
        await registry.register(FileTool())

        // Trigger 5 failures
        for _ in 0..<5 {
            await registry.recordError(for: "file")
        }

        let disabled = await registry.isDisabled("file")
        XCTAssertTrue(disabled, "Tool should be auto-disabled after 5 errors")
    }

    func testReEnableAfterAutoDisable() async throws {
        let registry = ToolRegistry()
        await registry.register(FileTool())
        for _ in 0..<5 { await registry.recordError(for: "file") }
        await registry.enableTool("file")
        let stillDisabled = await registry.isDisabled("file")
        XCTAssertFalse(stillDisabled, "Tool should be re-enabled after manual enable")
    }

    func testSuccessResetsErrorCount() async throws {
        let registry = ToolRegistry()
        await registry.register(FileTool())
        for _ in 0..<3 { await registry.recordError(for: "file") }
        await registry.recordSuccess(for: "file")
        // After success, error count resets — need 5 more errors to disable
        for _ in 0..<4 { await registry.recordError(for: "file") }
        let notDisabled = await registry.isDisabled("file")
        XCTAssertFalse(notDisabled, "Tool should still be enabled after only 4 errors post-reset")
    }
}
