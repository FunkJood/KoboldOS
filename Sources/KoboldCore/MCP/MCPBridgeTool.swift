import Foundation

// MARK: - MCPBridgeTool — Bridges an MCP server tool into KoboldOS Tool protocol

/// Wraps an MCP tool as a KoboldOS Tool so it can be registered in ToolRouter/ToolRegistry.
/// Tool name format: "mcp_<server>_<tool>" to avoid collisions with built-in tools.
public struct MCPBridgeTool: Tool, @unchecked Sendable {

    public let name: String
    public let description: String
    public let schema: ToolSchema
    public let riskLevel: RiskLevel = .medium

    /// The MCP server this tool belongs to.
    let serverName: String
    /// The original tool name on the MCP server.
    let mcpToolName: String
    /// Reference to the MCPClient actor for execution.
    let client: MCPClient

    public init(toolInfo: MCPClient.MCPToolInfo, client: MCPClient) {
        // Sanitize server and tool names for the combined key
        let sanitizedServer = MCPBridgeTool.sanitize(toolInfo.serverName)
        let sanitizedTool = MCPBridgeTool.sanitize(toolInfo.name)
        self.name = "mcp_\(sanitizedServer)_\(sanitizedTool)"
        self.description = "[MCP:\(toolInfo.serverName)] \(toolInfo.description)"
        self.serverName = toolInfo.serverName
        self.mcpToolName = toolInfo.name
        self.client = client

        // Convert MCP JSON Schema into KoboldOS ToolSchema
        var properties: [String: ToolSchemaProperty] = [:]
        let requiredKeys = toolInfo.inputSchema.required

        for (key, prop) in toolInfo.inputSchema.properties {
            properties[key] = ToolSchemaProperty(
                type: prop.type,
                description: prop.description,
                enumValues: prop.enumValues,
                required: requiredKeys.contains(key)
            )
        }

        self.schema = ToolSchema(
            properties: properties,
            required: requiredKeys
        )
    }

    public func execute(arguments: [String: String]) async throws -> String {
        // Ensure MCP server is connected before executing tool
        // This handles the case where MCP servers weren't connected at startup
        let isConnected = await client.isConnected(serverName)
        if !isConnected {
            print("[MCPBridgeTool] Connecting to server '\(serverName)' for tool '\(mcpToolName)'")

            // Attempt to connect with timeout
            let connectTask = Task {
                try await client.connectServerByName(serverName, configManager: MCPConfigManager.shared)
            }

            // Wait for connection with timeout (5 seconds)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw ToolError.executionFailed("MCP server connection timeout")
            }

            do {
                // Wait for either connection or timeout
                try await connectTask.value
                timeoutTask.cancel()
                print("[MCPBridgeTool] Successfully connected to server '\(serverName)'")
            } catch {
                timeoutTask.cancel()
                throw ToolError.executionFailed("Failed to connect to MCP server '\(serverName)': \(error.localizedDescription)")
            }
        }

        // Convert [String: String] to [String: Any] for MCP
        // KoboldOS tools use string-typed arguments; MCP tools may need other types.
        // We attempt to parse numeric and boolean strings back to their native types.
        var jsonArgs: [String: Any] = [:]
        for (key, value) in arguments {
            jsonArgs[key] = coerceValue(value, forKey: key)
        }

        do {
            return try await client.callTool(
                serverName: serverName,
                toolName: mcpToolName,
                arguments: jsonArgs
            )
        } catch {
            throw ToolError.executionFailed("MCP tool '\(mcpToolName)' on server '\(serverName)': \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Sanitize a name for use in tool identifiers (lowercase, replace non-alphanumeric with underscore).
    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .lowercased()
    }

    /// Try to coerce string values back to native JSON types based on schema info.
    private func coerceValue(_ value: String, forKey key: String) -> Any {
        // Check schema type hint
        if let propSchema = findSchemaProperty(key) {
            switch propSchema.type {
            case "integer":
                if let intVal = Int(value) { return intVal }
            case "number":
                if let doubleVal = Double(value) { return doubleVal }
            case "boolean":
                let lower = value.lowercased()
                if lower == "true" { return true }
                if lower == "false" { return false }
            case "array", "object":
                // Try to parse as JSON
                if let data = value.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    return parsed
                }
            default:
                break
            }
        }
        return value
    }

    /// Look up a property in the MCP tool's schema.
    private func findSchemaProperty(_ key: String) -> ToolSchemaProperty? {
        schema.properties[key]
    }
}
