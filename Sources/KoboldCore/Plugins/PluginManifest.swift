import Foundation

// MARK: - PluginManifest (KoboldAgent plugin concept in Swift)

public struct PluginManifest: Codable, Sendable {
    public let name: String
    public let version: String
    public let author: String
    public let description: String
    public let permissions: [String]
    public let toolName: String
    public let minKoboldVersion: String?

    public init(
        name: String,
        version: String,
        author: String,
        description: String,
        permissions: [String] = [],
        toolName: String,
        minKoboldVersion: String? = nil
    ) {
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.permissions = permissions
        self.toolName = toolName
        self.minKoboldVersion = minKoboldVersion
    }
}

// MARK: - Plugin Protocol

public protocol KoboldPlugin: Tool {
    static var manifest: PluginManifest { get }
}
