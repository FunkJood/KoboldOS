import SwiftUI

// MARK: - Custom Colors

extension Color {

    /// String hex initializer: "#00C46A" or "00C46A" or "0x00C46A"
    init(hex: String, alpha: Double = 1.0) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        let value = UInt(cleaned, radix: 16) ?? 0
        self.init(hex: value, alpha: alpha)
    }

    /// UInt hex initializer: 0x00C46A
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }

    /// Deep dark background
    static let koboldBackground = Color(red: 0.067, green: 0.075, blue: 0.082)
    /// Slightly lighter panel background
    static let koboldPanel = Color(red: 0.09, green: 0.10, blue: 0.11)
    /// Surface color for cards / selected items
    static let koboldSurface = Color(red: 0.13, green: 0.145, blue: 0.16)
    /// Signature emerald green
    static let koboldEmerald = Color(red: 0.13, green: 0.82, blue: 0.55)
    /// Gold accent
    static let koboldGold = Color(red: 1.0, green: 0.78, blue: 0.22)
    /// Danger red
    static let koboldRed = Color(red: 0.95, green: 0.25, blue: 0.25)
    /// Tool call cyan
    static let koboldCyan = Color(red: 0.2, green: 0.75, blue: 0.9)
}
