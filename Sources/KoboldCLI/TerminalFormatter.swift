import Foundation

// MARK: - TerminalFormatter
// ANSI color formatting for terminal output.

enum TerminalFormatter {

    // MARK: - ANSI Codes

    private static let reset     = "\u{1B}[0m"
    private static let bold      = "\u{1B}[1m"
    private static let dim       = "\u{1B}[2m"
    private static let italic    = "\u{1B}[3m"
    private static let red       = "\u{1B}[31m"
    private static let green     = "\u{1B}[32m"
    private static let yellow    = "\u{1B}[33m"
    private static let blue      = "\u{1B}[34m"
    private static let magenta   = "\u{1B}[35m"
    private static let cyan      = "\u{1B}[36m"
    private static let white     = "\u{1B}[37m"
    private static let gray      = "\u{1B}[90m"

    // MARK: - TTY Detection

    static var isTTY: Bool {
        isatty(STDOUT_FILENO) != 0
    }

    private static func wrap(_ text: String, _ codes: String...) -> String {
        guard isTTY else { return text }
        return codes.joined() + text + reset
    }

    // MARK: - Step Formatting

    static func thinking(_ text: String) -> String {
        wrap("  \u{1F9E0} \(text)", dim, gray)
    }

    static func toolCall(_ name: String, _ args: String) -> String {
        wrap("  \u{1F527} \(name): \(args)", yellow)
    }

    static func toolResult(_ text: String, success: Bool) -> String {
        if success {
            return wrap("  \u{2713} \(text)", green)
        } else {
            return wrap("  \u{2717} \(text)", red)
        }
    }

    static func finalAnswer(_ text: String) -> String {
        wrap("  \u{1F432} \(text)", bold, white)
    }

    static func error(_ text: String) -> String {
        wrap("\u{274C} \(text)", bold, red)
    }

    static func prompt() -> String {
        wrap("you> ", bold, cyan)
    }

    static func info(_ text: String) -> String {
        wrap(text, cyan)
    }

    static func success(_ text: String) -> String {
        wrap("\u{2713} \(text)", green)
    }

    static func warning(_ text: String) -> String {
        wrap("\u{26A0} \(text)", yellow)
    }

    // MARK: - Confidence

    static func confidence(_ value: Double) -> String {
        let label = String(format: "[confidence: %.2f]", value)
        if value >= 0.8 {
            return wrap(label, green)
        } else if value >= 0.5 {
            return wrap(label, yellow)
        } else {
            return wrap(label, red)
        }
    }

    // MARK: - Banner

    static func banner() -> String {
        let art = """

         \u{1F432} KoboldOS v0.2.5
         Lokaler KI-Agent für macOS
         /help für Befehle, /quit zum Beenden

        """
        return wrap(art, bold, cyan)
    }

    // MARK: - Table

    static func table(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }

        // Calculate column widths
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Header
        let headerLine = headers.enumerated().map { i, h in
            h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")

        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")

        // Rows
        let dataLines = rows.map { row in
            row.enumerated().map { i, cell in
                if i < widths.count {
                    return cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                }
                return cell
            }.joined(separator: "  ")
        }

        let header = isTTY ? wrap(headerLine, bold) : headerLine
        return ([header, separator] + dataLines).joined(separator: "\n")
    }
}
