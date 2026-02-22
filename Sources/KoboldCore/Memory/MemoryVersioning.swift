import Foundation
import CommonCrypto

// MARK: - MemoryVersionStore
// Git-style versioning for CoreMemory blocks.
// Each commit captures a snapshot of all blocks with a content-based hash.

public actor MemoryVersionStore {
    public static let shared = MemoryVersionStore()

    public struct MemoryVersion: Codable, Sendable {
        public let id: String              // SHA-256 hash of content
        public let timestamp: Date
        public let blocks: [String: String] // label → content
        public let parentId: String?       // previous version
        public let message: String         // "Auto-snapshot after session X"
    }

    public struct BlockDiff: Sendable {
        public let label: String
        public let change: DiffType
        public let oldValue: String
        public let newValue: String
    }

    public enum DiffType: String, Sendable {
        case added
        case removed
        case modified
        case unchanged
    }

    private var versions: [MemoryVersion] = []
    private let storeDir: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/memory_versions")
        self.storeDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Load versions from disk inline (nonisolated init)
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            versions = files
                .filter { $0.lastPathComponent.hasPrefix("v_") && $0.pathExtension == "json" }
                .compactMap { url -> MemoryVersion? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(MemoryVersion.self, from: data)
                }
                .sorted { $0.timestamp > $1.timestamp }
        }
    }

    // MARK: - Commit

    public func commit(blocks: [String: String], message: String) -> MemoryVersion {
        let contentStr = blocks.sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")
        let hash = sha256(contentStr)

        // Skip if identical to latest
        if let latest = versions.first, latest.id == hash {
            return latest
        }

        let version = MemoryVersion(
            id: hash,
            timestamp: Date(),
            blocks: blocks,
            parentId: versions.first?.id,
            message: message
        )
        versions.insert(version, at: 0)

        // Save version file
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(version) {
            let url = storeDir.appendingPathComponent("v_\(String(hash.prefix(16))).json")
            try? data.write(to: url, options: .atomic)
        }

        // Keep only last 100 versions
        if versions.count > 100 {
            let removed = versions.removeLast()
            let url = storeDir.appendingPathComponent("v_\(String(removed.id.prefix(16))).json")
            try? FileManager.default.removeItem(at: url)
        }

        return version
    }

    // MARK: - Rollback

    public func rollback(to versionId: String) -> [String: String]? {
        guard let version = versions.first(where: { $0.id.hasPrefix(versionId) }) else {
            return nil
        }
        return version.blocks
    }

    // MARK: - Diff

    public func diff(from fromId: String, to toId: String) -> [BlockDiff] {
        guard let fromVersion = versions.first(where: { $0.id.hasPrefix(fromId) }),
              let toVersion = versions.first(where: { $0.id.hasPrefix(toId) }) else {
            return []
        }

        var diffs: [BlockDiff] = []
        let allLabels = Set(fromVersion.blocks.keys).union(toVersion.blocks.keys)

        for label in allLabels.sorted() {
            let old = fromVersion.blocks[label] ?? ""
            let new = toVersion.blocks[label] ?? ""

            if old.isEmpty && !new.isEmpty {
                diffs.append(BlockDiff(label: label, change: .added, oldValue: old, newValue: new))
            } else if !old.isEmpty && new.isEmpty {
                diffs.append(BlockDiff(label: label, change: .removed, oldValue: old, newValue: new))
            } else if old != new {
                diffs.append(BlockDiff(label: label, change: .modified, oldValue: old, newValue: new))
            }
        }

        return diffs
    }

    // MARK: - Log

    public func log(limit: Int = 20) -> [MemoryVersion] {
        Array(versions.prefix(limit))
    }

    // MARK: - Persistence

    private struct VersionIndex: Codable {
        let ids: [String]
    }

    // Index is implicit from version files on disk — loaded in init

    // MARK: - SHA-256

    private func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return UUID().uuidString }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
