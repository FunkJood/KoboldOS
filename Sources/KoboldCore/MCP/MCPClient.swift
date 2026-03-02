import Foundation

// MARK: - MCP Client — Model Context Protocol over stdio (JSON-RPC 2.0)

public actor MCPClient {

    // MARK: - Types

    public struct ServerConfig: Codable, Sendable, Equatable {
        public let name: String
        public let command: String
        public let args: [String]
        public let env: [String: String]?

        public init(name: String, command: String, args: [String], env: [String: String]? = nil) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
        }
    }

    public struct MCPToolInfo: Sendable {
        public let serverName: String
        public let name: String
        public let description: String
        public let inputSchema: MCPToolInputSchema

        public init(serverName: String, name: String, description: String, inputSchema: MCPToolInputSchema) {
            self.serverName = serverName
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    /// Parsed JSON Schema from MCP tool definitions
    public struct MCPToolInputSchema: Sendable {
        public let type: String
        public let properties: [String: MCPPropertySchema]
        public let required: [String]

        public init(type: String = "object", properties: [String: MCPPropertySchema] = [:], required: [String] = []) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }

    public struct MCPPropertySchema: Sendable {
        public let type: String
        public let description: String
        public let enumValues: [String]?

        public init(type: String, description: String = "", enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }

    // MARK: - Errors

    public enum MCPError: Error, LocalizedError, Sendable {
        case serverNotFound(String)
        case serverAlreadyConnected(String)
        case processLaunchFailed(String)
        case initializeFailed(String)
        case toolNotFound(String)
        case jsonRPCError(Int, String)
        case invalidResponse(String)
        case timeout
        case serverDisconnected(String)
        case writeError(String)

        public var errorDescription: String? {
            switch self {
            case .serverNotFound(let n): return "MCP server '\(n)' not found"
            case .serverAlreadyConnected(let n): return "MCP server '\(n)' already connected"
            case .processLaunchFailed(let r): return "Failed to launch MCP server: \(r)"
            case .initializeFailed(let r): return "MCP initialize failed: \(r)"
            case .toolNotFound(let n): return "MCP tool '\(n)' not found"
            case .jsonRPCError(let c, let m): return "JSON-RPC error \(c): \(m)"
            case .invalidResponse(let r): return "Invalid MCP response: \(r)"
            case .timeout: return "MCP request timed out"
            case .serverDisconnected(let n): return "MCP server '\(n)' disconnected"
            case .writeError(let r): return "Failed to write to MCP server: \(r)"
            }
        }
    }

    // MARK: - Internal State

    private final class ServerConnection: @unchecked Sendable {
        let config: ServerConfig
        let process: Process
        let stdinHandle: FileHandle
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        var tools: [MCPToolInfo]
        var initialized: Bool
        /// Lock protecting buffer and pendingRequests (accessed from readabilityHandler callback)
        let lock = NSLock()
        var buffer: Data

        /// Pending JSON-RPC requests: id -> continuation (uses Data to stay Sendable)
        var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]

        init(config: ServerConfig, process: Process, stdinHandle: FileHandle, stdoutHandle: FileHandle, stderrHandle: FileHandle) {
            self.config = config
            self.process = process
            self.stdinHandle = stdinHandle
            self.stdoutHandle = stdoutHandle
            self.stderrHandle = stderrHandle
            self.tools = []
            self.initialized = false
            self.buffer = Data()
        }
    }

    private var servers: [String: ServerConnection] = [:]
    private var nextRequestId: Int = 1

    private let protocolVersion = "2024-11-05"
    private let clientName = "KoboldOS"
    private let clientVersion = "0.2.5"
    private let requestTimeoutSeconds: TimeInterval = 30

    public init() {}

    // MARK: - Public API

    /// Connect to an MCP server, initialize it, and discover its tools.
    public func connectServer(_ config: ServerConfig) async throws {
        guard servers[config.name] == nil else {
            throw MCPError.serverAlreadyConnected(config.name)
        }

        let connection = try launchServer(config)
        servers[config.name] = connection

        // Start reading stdout in background
        startReadingOutput(serverName: config.name, connection: connection)

        // Initialize handshake
        do {
            try await sendInitialize(serverName: config.name)
            try await sendInitializedNotification(serverName: config.name)
            let tools = try await fetchToolList(serverName: config.name)
            connection.tools = tools
            connection.initialized = true
            print("[MCPClient] Connected to '\(config.name)' with \(tools.count) tools: \(tools.map(\.name).joined(separator: ", "))")
        } catch {
            // Cleanup on failure
            connection.process.terminate()
            servers.removeValue(forKey: config.name)
            throw error
        }
    }

    /// Disconnect a specific server.
    public func disconnectServer(_ name: String) async {
        guard let connection = servers[name] else { return }
        // Clear readabilityHandlers FIRST to stop new callbacks (prevents races)
        connection.stdoutHandle.readabilityHandler = nil
        connection.stderrHandle.readabilityHandler = nil
        // After handlers are nil, no more concurrent access — safe to read directly
        let pending = connection.pendingRequests
        connection.pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.serverDisconnected(name))
        }
        connection.process.terminate()
        servers.removeValue(forKey: name)
        print("[MCPClient] Disconnected '\(name)'")
    }

    /// Disconnect all servers.
    public func disconnectAll() async {
        for name in servers.keys {
            await disconnectServer(name)
        }
    }

    /// List all tools across all connected servers.
    public func listAllTools() -> [MCPToolInfo] {
        servers.values.flatMap { $0.tools }
    }

    /// List tools for a specific server.
    public func listTools(serverName: String) -> [MCPToolInfo] {
        servers[serverName]?.tools ?? []
    }

    /// Get names of all connected servers.
    public func connectedServers() -> [String] {
        Array(servers.keys).sorted()
    }

    /// Check if a server is connected.
    public func isConnected(_ name: String) -> Bool {
        guard let conn = servers[name] else { return false }
        return conn.process.isRunning && conn.initialized
    }

    /// Connect to a server by name using existing configuration.
    /// This is useful for connecting to servers on-demand rather than at startup.
    public func connectServerByName(_ name: String, configManager: MCPConfigManager) async throws {
        // Check if already connected
        if isConnected(name) {
            return
        }

        // Load configuration and connect
        let configs = await configManager.loadConfigs()
        guard let config = configs.first(where: { $0.name == name }) else {
            throw MCPError.serverNotFound(name)
        }

        try await connectServer(config)
    }

    /// Call a tool on a specific server.
    public func callTool(serverName: String, toolName: String, arguments: [String: Any]) async throws -> String {
        guard let connection = servers[serverName] else {
            throw MCPError.serverNotFound(serverName)
        }
        guard connection.process.isRunning else {
            throw MCPError.serverDisconnected(serverName)
        }

        let params: [String: Any] = [
            "name": toolName,
            "arguments": arguments
        ]

        let response = try await sendRequest(serverName: serverName, method: "tools/call", params: params)

        // Parse result — MCP tools/call returns { content: [{type: "text", text: "..."}] }
        if let content = response["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                guard let type = item["type"] as? String else { return nil }
                if type == "text", let text = item["text"] as? String {
                    return text
                }
                if type == "image" {
                    return "[image data]"
                }
                if type == "resource" {
                    return "[resource: \(item["uri"] as? String ?? "unknown")]"
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }

        // Fallback: try to extract any text
        if let text = response["text"] as? String {
            return text
        }

        // Return raw JSON as fallback
        if let data = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        return "MCP tool returned empty result"
    }

    // MARK: - Process Management

    private func launchServer(_ config: ServerConfig) throws -> ServerConnection {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve command path
        let resolvedCommand = resolveCommand(config.command)
        process.executableURL = URL(fileURLWithPath: resolvedCommand)
        process.arguments = config.args

        // Build environment
        var env = ProcessInfo.processInfo.environment
        // Enhanced PATH for finding npx, node, etc.
        let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")

        if let configEnv = config.env {
            for (key, value) in configEnv {
                env[key] = value
            }
        }
        process.environment = env

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw MCPError.processLaunchFailed(error.localizedDescription)
        }

        let connection = ServerConnection(
            config: config,
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading
        )

        // Log stderr in background
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[MCPClient:\(config.name):stderr] \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        return connection
    }

    /// Resolve a command name to a full path. For bare names like "npx", search PATH.
    private nonisolated func resolveCommand(_ command: String) -> String {
        if command.hasPrefix("/") {
            return command
        }
        // Search common paths
        let searchPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        for dir in searchPaths {
            let full = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        // Fallback: return as-is and let Process figure it out
        return command
    }

    // MARK: - stdout Reader

    /// Start a background task that reads newline-delimited JSON from stdout.
    private func startReadingOutput(serverName: String, connection: ServerConnection) {
        connection.stdoutHandle.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            guard !data.isEmpty, let conn = connection else { return }

            conn.lock.lock()
            // Prevent unbounded buffer growth (max 10MB)
            if conn.buffer.count + data.count > 10_000_000 {
                print("[MCPClient] WARNING: Buffer overflow for server — dropping old data")
                conn.buffer = Data()
            }
            conn.buffer.append(data)

            // Process complete lines (JSON-RPC messages are newline-delimited)
            var completedRequests: [(Int, Result<Data, any Error>)] = []
            while let newlineRange = conn.buffer.range(of: Data([0x0A])) {
                let lineData = conn.buffer.subdata(in: conn.buffer.startIndex..<newlineRange.lowerBound)
                conn.buffer.removeSubrange(conn.buffer.startIndex...newlineRange.lowerBound)

                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Check if this is a response (has "id" field)
                if let id = json["id"] as? Int {
                    if let error = json["error"] as? [String: Any] {
                        let code = error["code"] as? Int ?? -1
                        let message = error["message"] as? String ?? "Unknown error"
                        completedRequests.append((id, .failure(MCPError.jsonRPCError(code, message))))
                    } else if json["result"] != nil {
                        if let resultData = try? JSONSerialization.data(withJSONObject: json["result"]!) {
                            completedRequests.append((id, .success(resultData)))
                        } else {
                            completedRequests.append((id, .success(Data("{}".utf8))))
                        }
                    } else {
                        completedRequests.append((id, .success(Data("{}".utf8))))
                    }
                }
                // Notifications (no "id") are logged but not processed
                else if let method = json["method"] as? String {
                    print("[MCPClient:\(serverName)] Notification: \(method)")
                }
            }
            // Collect continuations under lock, then resume outside
            var toResume: [(CheckedContinuation<Data, any Error>, Result<Data, any Error>)] = []
            for (id, result) in completedRequests {
                if let cont = conn.pendingRequests.removeValue(forKey: id) {
                    toResume.append((cont, result))
                }
            }
            conn.lock.unlock()
            // Resume continuations outside the lock to prevent deadlocks
            for (cont, result) in toResume {
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - JSON-RPC Transport

    /// Send a JSON-RPC request and await the response.
    private func sendRequest(serverName: String, method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard let connection = servers[serverName] else {
            throw MCPError.serverNotFound(serverName)
        }

        let id = nextRequestId
        nextRequestId += 1

        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params = params {
            message["params"] = params
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              var messageData = String(data: jsonData, encoding: .utf8) else {
            throw MCPError.writeError("Failed to serialize JSON-RPC request")
        }

        // Append newline delimiter
        messageData += "\n"

        // Register continuation before writing — with 30s timeout to prevent indefinite hangs
        // Uses pendingRequests removal as atomic guard against double-resume
        let conn = connection
        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            conn.lock.lock()
            conn.pendingRequests[id] = continuation
            conn.lock.unlock()

            // Schedule timeout — removeValue acts as atomic guard (only first remover gets the continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                conn.lock.lock()
                let pending = conn.pendingRequests.removeValue(forKey: id)
                conn.lock.unlock()
                // Only resume if WE removed it (prevents double-resume with response handler)
                pending?.resume(throwing: MCPError.timeout)
            }

            // Write to stdin
            guard let data = messageData.data(using: .utf8) else {
                conn.lock.lock()
                let pending = conn.pendingRequests.removeValue(forKey: id)
                conn.lock.unlock()
                pending?.resume(throwing: MCPError.writeError("Failed to encode message"))
                return
            }

            do {
                try conn.stdinHandle.write(contentsOf: data)
            } catch {
                conn.lock.lock()
                let pending = conn.pendingRequests.removeValue(forKey: id)
                conn.lock.unlock()
                pending?.resume(throwing: MCPError.writeError(error.localizedDescription))
                return
            }
        }

        // Deserialize Data back to [String: Any]
        guard let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return [:]
        }
        return result
    }

    /// Send a JSON-RPC notification (no response expected).
    private func sendNotification(serverName: String, method: String, params: [String: Any]? = nil) throws {
        guard let connection = servers[serverName] else {
            throw MCPError.serverNotFound(serverName)
        }

        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params = params {
            message["params"] = params
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              var messageStr = String(data: jsonData, encoding: .utf8) else {
            throw MCPError.writeError("Failed to serialize notification")
        }
        messageStr += "\n"

        guard let data = messageStr.data(using: .utf8) else {
            throw MCPError.writeError("Failed to encode notification")
        }
        try connection.stdinHandle.write(contentsOf: data)
    }

    // MARK: - MCP Protocol Methods

    /// Send initialize request per MCP spec.
    private func sendInitialize(serverName: String) async throws {
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": clientName,
                "version": clientVersion
            ]
        ]

        let response = try await sendRequest(serverName: serverName, method: "initialize", params: params)

        // Validate server responded with protocol version
        guard response["protocolVersion"] != nil else {
            throw MCPError.initializeFailed("Server did not return protocolVersion")
        }

        if let serverInfo = response["serverInfo"] as? [String: Any],
           let name = serverInfo["name"] as? String {
            print("[MCPClient] Server '\(serverName)' identified as: \(name)")
        }
    }

    /// Send initialized notification (completes the handshake).
    private func sendInitializedNotification(serverName: String) throws {
        try sendNotification(serverName: serverName, method: "notifications/initialized")
    }

    /// Fetch the tool list from the server.
    private func fetchToolList(serverName: String) async throws -> [MCPToolInfo] {
        let response = try await sendRequest(serverName: serverName, method: "tools/list")

        guard let toolsArray = response["tools"] as? [[String: Any]] else {
            return []
        }

        return toolsArray.compactMap { toolDict -> MCPToolInfo? in
            guard let name = toolDict["name"] as? String else { return nil }
            let description = toolDict["description"] as? String ?? ""

            var schema = MCPToolInputSchema()
            if let inputSchema = toolDict["inputSchema"] as? [String: Any] {
                schema = parseInputSchema(inputSchema)
            }

            return MCPToolInfo(
                serverName: serverName,
                name: name,
                description: description,
                inputSchema: schema
            )
        }
    }

    /// Parse a JSON Schema into our MCPToolInputSchema type.
    private nonisolated func parseInputSchema(_ schema: [String: Any]) -> MCPToolInputSchema {
        let type = schema["type"] as? String ?? "object"
        let required = schema["required"] as? [String] ?? []

        var properties: [String: MCPPropertySchema] = [:]
        if let props = schema["properties"] as? [String: [String: Any]] {
            for (key, propDict) in props {
                let propType = propDict["type"] as? String ?? "string"
                let desc = propDict["description"] as? String ?? ""
                let enumVals = propDict["enum"] as? [String]
                properties[key] = MCPPropertySchema(type: propType, description: desc, enumValues: enumVals)
            }
        }

        return MCPToolInputSchema(type: type, properties: properties, required: required)
    }
}
