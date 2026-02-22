import Foundation

// MARK: - PluginInfo

public struct PluginInfo: Sendable, Codable {
    public let manifest: PluginManifest
    public let isEnabled: Bool
    public let errorCount: Int
    public let loadedAt: Date

    public init(manifest: PluginManifest, isEnabled: Bool = true, errorCount: Int = 0, loadedAt: Date = Date()) {
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.errorCount = errorCount
        self.loadedAt = loadedAt
    }
}

// MARK: - PluginRegistry (loads plugins from ~/Library/Application Support/KoboldOS/Plugins/)

public actor PluginRegistry {

    public static let shared = PluginRegistry()

    private var plugins: [String: PluginInfo] = [:]
    private var disabledPlugins: Set<String> = []
    private var errorCounts: [String: Int] = [:]
    private let maxErrors = 5

    private let pluginsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/Plugins")
    }()

    private init() {}

    // MARK: - Load Plugins

    public func loadAll() async -> [PluginManifest] {
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        guard let dirs = try? fm.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var manifests: [PluginManifest] = []
        for dir in dirs where dir.hasDirectoryPath {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            if let manifest = loadManifest(from: manifestURL) {
                let info = PluginInfo(manifest: manifest)
                plugins[manifest.name] = info
                manifests.append(manifest)
                print("[PluginRegistry] Loaded plugin: \(manifest.name) v\(manifest.version)")
            }
        }

        return manifests
    }

    private func loadManifest(from url: URL) -> PluginManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    // MARK: - Enable / Disable

    public func enable(_ name: String) {
        disabledPlugins.remove(name)
        errorCounts[name] = 0
        if var info = plugins[name] {
            plugins[name] = PluginInfo(
                manifest: info.manifest,
                isEnabled: true,
                errorCount: 0,
                loadedAt: info.loadedAt
            )
        }
    }

    public func disable(_ name: String) {
        disabledPlugins.insert(name)
        if let info = plugins[name] {
            plugins[name] = PluginInfo(
                manifest: info.manifest,
                isEnabled: false,
                errorCount: info.errorCount,
                loadedAt: info.loadedAt
            )
        }
    }

    public func recordError(_ name: String) {
        errorCounts[name, default: 0] += 1
        if (errorCounts[name] ?? 0) >= maxErrors {
            disable(name)
            print("[PluginRegistry] Auto-disabled plugin '\(name)' after \(maxErrors) errors")
        }
    }

    public func list() -> [PluginInfo] {
        Array(plugins.values).sorted { $0.manifest.name < $1.manifest.name }
    }

    public func isEnabled(_ name: String) -> Bool {
        !disabledPlugins.contains(name)
    }

    // MARK: - Install Plugin

    public func install(from url: URL) async throws -> PluginManifest {
        let destDir = pluginsDirectory.appendingPathComponent(url.lastPathComponent)
        let manifestURL = url.appendingPathComponent("manifest.json")

        guard let manifest = loadManifest(from: manifestURL) else {
            throw PluginError.invalidManifest
        }

        // Validate
        guard !manifest.name.isEmpty, !manifest.version.isEmpty else {
            throw PluginError.invalidManifest
        }

        // Copy to plugins directory
        try FileManager.default.copyItem(at: url, to: destDir)

        let info = PluginInfo(manifest: manifest)
        plugins[manifest.name] = info

        print("[PluginRegistry] Installed plugin: \(manifest.name) v\(manifest.version)")
        return manifest
    }
}

// MARK: - PluginError

public enum PluginError: Error, LocalizedError {
    case invalidManifest
    case missingEntryPoint
    case permissionDenied(String)
    case alreadyInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Invalid or missing manifest.json"
        case .missingEntryPoint: return "Plugin entry point not found"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .alreadyInstalled: return "Plugin already installed"
        }
    }
}
