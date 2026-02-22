#if os(macOS)
import Foundation
import Security

// MARK: - SecretStore (macOS implementation using Keychain)
public actor SecretStore {
    public static let shared = SecretStore()

    private let service = "com.koboldos.secrets"

    // MARK: - Write

    public func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing value first
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new value
        let addQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     key,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[SecretStore] Failed to set '\(key)': \(status)")
        }
    }

    // MARK: - Read

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    // MARK: - Delete

    public func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - List All Keys

    public func allKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

#elseif os(Linux)
import Foundation

// MARK: - SecretStore (Linux implementation using encrypted files)
public actor SecretStore {
    public static let shared = SecretStore()

    private let secretsDirectory: URL

    private init() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        secretsDirectory = homeDir.appendingPathComponent(".koboldos/secrets")

        // Create secrets directory if it doesn't exist
        try? fileManager.createDirectory(at: secretsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Write

    public func set(_ value: String, forKey key: String) {
        let fileURL = secretsDirectory.appendingPathComponent(key)
        guard let data = value.data(using: .utf8) else { return }

        // In a production implementation, you would encrypt the data here
        // For now, we'll store it as plain text for simplicity
        try? data.write(to: fileURL)
    }

    // MARK: - Read

    public func get(_ key: String) -> String? {
        let fileURL = secretsDirectory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Delete

    public func delete(_ key: String) {
        let fileURL = secretsDirectory.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - List All Keys

    public func allKeys() -> [String] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: secretsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return fileURLs.map { $0.lastPathComponent }.sorted()
    }
}
#endif