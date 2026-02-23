import Foundation

// MARK: - MCPConfigManager — Loads MCP server configs and manages lifecycle

/// Manages MCP server configurations from a JSON file and bridges tools into ToolRouter/ToolRegistry.
///
/// Config file location: ~/Library/Application Support/KoboldOS/mcp_servers.json
///
/// Format:
/// ```json
/// {
///   "mcpServers": {
///     "filesystem": {
///       "command": "npx",
///       "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/tim/Documents"],
///       "env": {}
///     }
///   }
/// }
/// ```
public actor MCPConfigManager {

    // MARK: - Types

    /// On-disk JSON structure
    private struct ConfigFile: Codable, Sendable {
        let mcpServers: [String: ServerEntry]
    }

    private struct ServerEntry: Codable, Sendable {
        let command: String
        let args: [String]
        let env: [String: String]?
    }

    // MARK: - State

    private let client: MCPClient
    private nonisolated(unsafe) let configPath: String
    private var registeredToolNames: [String: [String]] = [:]  // serverName -> [tool names in router]

    /// The shared MCP client used by this manager.
    public nonisolated var mcpClient: MCPClient { client }

    // MARK: - Singleton

    public static let shared = MCPConfigManager()

    // MARK: - Init

    public init(client: MCPClient? = nil) {
        self.client = client ?? MCPClient()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let koboldDir = appSupport.appendingPathComponent("KoboldOS")
        self.configPath = koboldDir.appendingPathComponent("mcp_servers.json").path
    }

    // MARK: - Config Loading

    /// Load server configurations from the JSON file.
    public func loadConfigs() -> [MCPClient.ServerConfig] {
        guard FileManager.default.fileExists(atPath: configPath) else {
            print("[MCPConfigManager] No config file at \(configPath)")
            return []
        }

        guard let data = FileManager.default.contents(atPath: configPath) else {
            print("[MCPConfigManager] Failed to read config file")
            return []
        }

        do {
            let configFile = try JSONDecoder().decode(ConfigFile.self, from: data)
            return configFile.mcpServers.map { (name, entry) in
                MCPClient.ServerConfig(
                    name: name,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env
                )
            }
        } catch {
            print("[MCPConfigManager] Failed to parse config: \(error.localizedDescription)")
            return []
        }
    }

    /// Save a server configuration to the JSON file (add or update).
    public func saveConfig(_ config: MCPClient.ServerConfig) throws {
        var configFile = loadConfigFile()
        configFile.mcpServers[config.name] = ServerEntry(
            command: config.command,
            args: config.args,
            env: config.env
        )
        try writeConfigFile(configFile)
    }

    /// Remove a server configuration from the JSON file.
    public func removeConfig(_ name: String) throws {
        var configFile = loadConfigFile()
        configFile.mcpServers.removeValue(forKey: name)
        try writeConfigFile(configFile)
    }

    // MARK: - Server Lifecycle

    /// Connect all configured servers and register their tools into a ToolRouter.
    public func connectAllServers(router: ToolRouter) async {
        let configs = loadConfigs()
        guard !configs.isEmpty else {
            print("[MCPConfigManager] No MCP servers configured")
            return
        }

        print("[MCPConfigManager] Connecting \(configs.count) MCP server(s)...")

        for config in configs {
            await connectAndRegister(config: config, router: router)
        }
    }

    /// Connect all configured servers and register their tools into a ToolRegistry.
    public func connectAllServers(registry: ToolRegistry) async {
        let configs = loadConfigs()
        guard !configs.isEmpty else {
            print("[MCPConfigManager] No MCP servers configured")
            return
        }

        print("[MCPConfigManager] Connecting \(configs.count) MCP server(s)...")

        for config in configs {
            await connectAndRegister(config: config, registry: registry)
        }
    }

    /// Connect a single server and register its tools into a ToolRouter.
    public func connectAndRegister(config: MCPClient.ServerConfig, router: ToolRouter) async {
        do {
            try await client.connectServer(config)
            let tools = await client.listTools(serverName: config.name)
            var toolNames: [String] = []

            for toolInfo in tools {
                let bridge = MCPBridgeTool(toolInfo: toolInfo, client: client)
                await router.register(bridge)
                toolNames.append(bridge.name)
            }

            registeredToolNames[config.name] = toolNames
            print("[MCPConfigManager] Registered \(tools.count) tools from '\(config.name)' into ToolRouter")
        } catch {
            print("[MCPConfigManager] Failed to connect '\(config.name)': \(error.localizedDescription)")
        }
    }

    /// Connect a single server and register its tools into a ToolRegistry.
    public func connectAndRegister(config: MCPClient.ServerConfig, registry: ToolRegistry) async {
        do {
            try await client.connectServer(config)
            let tools = await client.listTools(serverName: config.name)
            var toolNames: [String] = []

            for toolInfo in tools {
                let bridge = MCPBridgeTool(toolInfo: toolInfo, client: client)
                await registry.register(bridge)
                toolNames.append(bridge.name)
            }

            registeredToolNames[config.name] = toolNames
            print("[MCPConfigManager] Registered \(tools.count) tools from '\(config.name)' into ToolRegistry")
        } catch {
            print("[MCPConfigManager] Failed to connect '\(config.name)': \(error.localizedDescription)")
        }
    }

    /// Disconnect a server and unregister its tools from a ToolRouter.
    public func disconnectAndUnregister(name: String, router: ToolRouter) async {
        // Unregister bridge tools
        if let toolNames = registeredToolNames[name] {
            for toolName in toolNames {
                await router.unregister(toolName)
            }
            registeredToolNames.removeValue(forKey: name)
        }

        await client.disconnectServer(name)
        print("[MCPConfigManager] Disconnected and unregistered '\(name)'")
    }

    /// Disconnect all servers and unregister all MCP tools from a ToolRouter.
    public func disconnectAll(router: ToolRouter) async {
        for (name, toolNames) in registeredToolNames {
            for toolName in toolNames {
                await router.unregister(toolName)
            }
            print("[MCPConfigManager] Unregistered tools for '\(name)'")
        }
        registeredToolNames.removeAll()
        await client.disconnectAll()
    }

    /// Disconnect all servers.
    public func disconnectAll() async {
        registeredToolNames.removeAll()
        await client.disconnectAll()
    }

    // MARK: - Runtime Management

    /// Add a new server at runtime: save config, connect, and register tools.
    public func addServer(_ config: MCPClient.ServerConfig, router: ToolRouter) async throws {
        try saveConfig(config)
        await connectAndRegister(config: config, router: router)
    }

    /// Remove a server at runtime: disconnect, unregister, and remove config.
    public func removeServer(_ name: String, router: ToolRouter) async throws {
        await disconnectAndUnregister(name: name, router: router)
        try removeConfig(name)
    }

    /// Get status info for all configured servers.
    public func getStatus() async -> [(name: String, connected: Bool, toolCount: Int)] {
        let configs = loadConfigs()
        var status: [(name: String, connected: Bool, toolCount: Int)] = []

        for config in configs {
            let connected = await client.isConnected(config.name)
            let tools = await client.listTools(serverName: config.name)
            status.append((name: config.name, connected: connected, toolCount: tools.count))
        }

        return status
    }

    // MARK: - Private Helpers

    private func loadConfigFile() -> MutableConfigFile {
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let configFile = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return MutableConfigFile(mcpServers: [:])
        }
        var mutable = MutableConfigFile(mcpServers: [:])
        for (key, value) in configFile.mcpServers {
            mutable.mcpServers[key] = value
        }
        return mutable
    }

    private func writeConfigFile(_ configFile: MutableConfigFile) throws {
        // Ensure directory exists
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Convert to ConfigFile for encoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let codable = ConfigFile(mcpServers: configFile.mcpServers)
        let data = try encoder.encode(codable)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Mutable version of ConfigFile for in-memory edits.
    private struct MutableConfigFile {
        var mcpServers: [String: ServerEntry]
    }

    // MARK: - Config File Path

    /// Get the path to the config file (useful for UI/debugging).
    public nonisolated var configFilePath: String { configPath }

    /// Create a default config file if none exists.
    public func createDefaultConfigIfNeeded() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let defaultConfig = """
        {
          "mcpServers": {}
        }
        """

        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? defaultConfig.data(using: .utf8)?.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        print("[MCPConfigManager] Created default config at \(configPath)")
    }
}
