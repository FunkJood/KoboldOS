import Foundation
import Security

/// Secure secrets manager for storing API keys and sensitive information
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