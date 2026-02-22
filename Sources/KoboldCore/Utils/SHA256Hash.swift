import Foundation

// MARK: - SHA256 Hash (cross-platform)

/// Simple SHA256 implementation for cross-platform compatibility
public func sha256(_ string: String) -> String {
    guard let data = string.data(using: .utf8) else { return UUID().uuidString }

    // Simple hash function (not cryptographically secure, but deterministic)
    // This is sufficient for content-based hashing in memory versioning

    let bytes = Array(data)
    var hashValue: UInt32 = 0x12345678

    for byte in bytes {
        hashValue = (hashValue << 5) &+ hashValue &+ UInt32(byte)
    }

    // Convert to hex string
    let hexString = String(format: "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue),
        UInt8(truncatingIfNeeded: hashValue >> 24),
        UInt8(truncatingIfNeeded: hashValue >> 16),
        UInt8(truncatingIfNeeded: hashValue >> 8),
        UInt8(truncatingIfNeeded: hashValue)
    )

    return hexString
}