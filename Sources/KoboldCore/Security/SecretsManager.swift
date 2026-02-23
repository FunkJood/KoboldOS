#if os(macOS)
import Foundation
import Security

/// Secure secrets manager for storing API keys and sensitive information (macOS implementation)
public actor SecretsManager {
    private let serviceName: String
    private let accessGroup: String?

    public init(serviceName: String = "KoboldOS", accessGroup: String? = nil) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }

    /// Store a secret value
    public func storeSecret(key: String, value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: value.data(using: .utf8) as Any
        ]

        // Delete existing item if it exists
        SecItemDelete(query as CFDictionary)

        // Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretsError.storageFailed(status)
        }
    }

    /// Retrieve a secret value
    public func retrieveSecret(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw SecretsError.retrievalFailed(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete a secret
    public func deleteSecret(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsError.deletionFailed(status)
        }
    }

    /// List all secret keys
    public func listSecretKeys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        guard status != errSecItemNotFound else {
            return []
        }

        guard status == errSecSuccess else {
            throw SecretsError.listingFailed(status)
        }

        guard let results = items as? [[String: Any]] else {
            return []
        }

        return results.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Clear all secrets
    public func clearAllSecrets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsError.clearFailed(status)
        }
    }
}

/// Secrets manager error types
public enum SecretsError: Error, LocalizedError {
    case storageFailed(OSStatus)
    case retrievalFailed(OSStatus)
    case deletionFailed(OSStatus)
    case listingFailed(OSStatus)
    case clearFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .storageFailed(let status):
            return "Failed to store secret (status: \(status))"
        case .retrievalFailed(let status):
            return "Failed to retrieve secret (status: \(status))"
        case .deletionFailed(let status):
            return "Failed to delete secret (status: \(status))"
        case .listingFailed(let status):
            return "Failed to list secrets (status: \(status))"
        case .clearFailed(let status):
            return "Failed to clear secrets (status: \(status))"
        }
    }
}

#elseif os(Linux)
import Foundation
import Crypto

/// Secure secrets manager for storing API keys and sensitive information (Linux implementation)
public actor SecretsManager {
    private let secretsDirectory: URL
    private let masterKey: SymmetricKey

    public init(serviceName: String = "KoboldOS", accessGroup: String? = nil) {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        secretsDirectory = homeDir.appendingPathComponent(".koboldos/secrets")

        // Create secrets directory if it doesn't exist
        try? fileManager.createDirectory(at: secretsDirectory, withIntermediateDirectories: true)

        // Initialize or load master key for encryption
        masterKey = SecretsManager.loadOrCreateMasterKey(at: secretsDirectory)
    }

    /// Load existing master key or create a new one
    private static func loadOrCreateMasterKey(at directory: URL) -> SymmetricKey {
        let keyFile = directory.appendingPathComponent(".masterkey")
        if let keyData = try? Data(contentsOf: keyFile) {
            return SymmetricKey(data: keyData)
        } else {
            // Generate a new 256-bit key
            let newKey = SymmetricKey(size: .bits256)
            // Save the key securely
            try? newKey.data.write(to: keyFile)
            // Set restrictive permissions on the key file
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            return newKey
        }
    }

    /// Store a secret value
    public func storeSecret(key: String, value: String) throws {
        let fileURL = secretsDirectory.appendingPathComponent(key)

        // Encrypt the value
        guard let data = value.data(using: .utf8) else {
            throw SecretsError.storageFailed(-1)
        }

        do {
            let sealedBox = try AES.GCM.seal(data, using: masterKey)
            try sealedBox.combined.write(to: fileURL)
        } catch {
            throw SecretsError.storageFailed(-1)
        }
    }

    /// Retrieve a secret value
    public func retrieveSecret(key: String) throws -> String? {
        let fileURL = secretsDirectory.appendingPathComponent(key)
        guard let combinedData = try? Data(contentsOf: fileURL) else {
            return nil
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: masterKey)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            throw SecretsError.retrievalFailed(-1)
        }
    }

    /// Delete a secret
    public func deleteSecret(key: String) throws {
        let fileURL = secretsDirectory.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// List all secret keys
    public func listSecretKeys() throws -> [String] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: secretsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        // Exclude the master key file from the list
        return fileURLs.map { $0.lastPathComponent }.filter { $0 != ".masterkey" }
    }

    /// Clear all secrets
    public func clearAllSecrets() throws {
        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(at: secretsDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in fileURLs {
            // Don't delete the master key file
            if fileURL.lastPathComponent != ".masterkey" {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}

/// Secrets manager error types
public enum SecretsError: Error, LocalizedError {
    case storageFailed(Int32)
    case retrievalFailed(Int32)
    case deletionFailed(Int32)
    case listingFailed(Int32)
    case clearFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .storageFailed(let status):
            return "Failed to store secret (status: \(status))"
        case .retrievalFailed(let status):
            return "Failed to retrieve secret (status: \(status))"
        case .deletionFailed(let status):
            return "Failed to delete secret (status: \(status))"
        case .listingFailed(let status):
            return "Failed to list secrets (status: \(status))"
        case .clearFailed(let status):
            return "Failed to clear secrets (status: \(status))"
        }
    }
}
#endif