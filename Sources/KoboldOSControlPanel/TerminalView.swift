import SwiftUI
import AppKit
import CPty

// MARK: - ANSI Escape Stripping (für Agent-Snapshots)

private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\].*?\\x07|\\x1B\\([A-Z]", options: [])

private func stripANSI(_ text: String) -> String {
    guard let regex = ansiRegex else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}

// MARK: - Terminal Screen Buffer (VT100 Emulator)

final class TerminalScreen {
    /// Terminal color: Default (index 0 = theme color), ANSI 16, 256-palette, or TrueColor RGB
    enum TermColor: Equatable {
        case `default`           // fg: neongrün, bg: transparent
        case ansi(UInt8)         // 30-37, 40-47, 90-97, 100-107
        case palette(UInt8)      // 256-color index (0-255)
        case rgb(UInt8, UInt8, UInt8) // TrueColor
    }

    struct Cell {
        var char: Character = " "
        var fg: TermColor = .default
        var bg: TermColor = .default
        var bold: Bool = false
        var reverse: Bool = false
        var dim: Bool = false
        var underline: Bool = false
    }

    // Thread-safety lock — TerminalScreen is accessed from background (flushBuffer) and main (render) threads
    private let screenLock = NSLock()

    var rows: Int
    var cols: Int
    var cursorRow: Int = 0
    var cursorCol: Int = 0
    var screen: [[Cell]]
    // Ringpuffer für Scrollback anstelle von Array (Performance-Optimierung)
    private var scrollback: [[Cell]] = []
    private let maxScrollback = 10000
    private var scrollbackStartIndex: Int = 0
    private var scrollbackCount: Int = 0

    // Hilfsfunktionen für Ringpuffer
    private func appendToScrollback(_ line: [Cell]) {
        if scrollbackCount < maxScrollback {
            // Noch Platz im Puffer
            scrollback.append(line)
            scrollbackCount += 1
        } else {
            // Überschreiben des ältesten Eintrags
            scrollback[scrollbackStartIndex] = line
            scrollbackStartIndex = (scrollbackStartIndex + 1) % maxScrollback
        }
    }

    private func getScrollbackLines() -> [[Cell]] {
        if scrollbackCount == 0 { return [] }

        var result: [[Cell]] = []
        for i in 0..<scrollbackCount {
            let index = (scrollbackStartIndex + i) % maxScrollback
            if index < scrollback.count {
                result.append(scrollback[index])
            }
        }
        return result
    }

    // Callback to write bytes back to PTY (for CPR, DA responses)
    var writeBack: (([UInt8]) -> Void)?

    // Current SGR state
    var sgrFg: TermColor = .default
    var sgrBg: TermColor = .default
    var sgrBold: Bool = false
    var sgrReverse: Bool = false
    var sgrDim: Bool = false
    var sgrItalic: Bool = false
    var sgrUnderline: Bool = false

    // Cursor visibility
    var cursorHidden: Bool = false

    // Alternate screen buffer
    private var savedMainScreen: [[Cell]]?
    private var savedMainScrollback: [[Cell]]?
    private var savedMainCursor: (row: Int, col: Int)?
    private(set) var isAlternateScreen: Bool = false

    // Scroll region
    var scrollTop: Int = 0
    var scrollBottom: Int  // Set in init

    // Saved cursor (DECSC/DECRC)
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var savedSgrFg: TermColor = .default
    private var savedSgrBg: TermColor = .default
    private var savedSgrBold: Bool = false

    // Origin mode (DECOM)
    var originMode: Bool = false

    // Autowrap
    var wrapPending: Bool = false

    // Bracketed paste mode (DEC 2004)
    var bracketedPasteMode: Bool = false

    // Focus event mode (DEC 1004)
    var focusEventMode: Bool = false

    // ESC sequence parser state
    private enum ParseState { case normal, escape, csi, osc, oscEscSeen, escHash }
    private var parseState: ParseState = .normal
    private var csiParams: String = ""
    private var oscBuffer: String = ""

    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    func resize(newRows: Int, newCols: Int) {
        screenLock.lock()
        defer { screenLock.unlock() }
        guard newRows != rows || newCols != cols else { return }
        var newScreen = Array(repeating: Array(repeating: Cell(), count: newCols), count: newRows)
        for r in 0..<min(rows, newRows) {
            for c in 0..<min(cols, newCols) {
                newScreen[r][c] = screen[r][c]
            }
        }
        screen = newScreen
        rows = newRows
        cols = newCols
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    // MARK: - Process raw PTY output

    func process(_ text: String) {
        screenLock.lock()
        defer { screenLock.unlock() }
        for ch in text {
            switch parseState {
            case .normal:
                processNormalChar(ch)
            case .escape:
                processEscapeChar(ch)
            case .csi:
                processCSIChar(ch)
            case .escHash:
                if ch == "8" {
                    for r in 0..<rows { for c in 0..<cols { screen[r][c] = Cell(char: "E") } }
                }
                parseState = .normal
            case .osc:
                // OSC terminiert mit BEL (\x07) oder ST (ESC \)
                if ch == "\u{07}" {
                    parseState = .normal
                } else if ch == "\u{1B}" {
                    // Könnte ESC \ (ST) sein — nächstes Zeichen prüfen
                    parseState = .oscEscSeen
                }
                // Alles andere: OSC-Inhalt ignorieren
            case .oscEscSeen:
                // Nach ESC innerhalb OSC
                if ch == "\\" {
                    parseState = .normal // ST = ESC backslash
                } else {
                    // War kein ST — ESC gehört zu neuem Escape
                    parseState = .escape
                    processEscapeChar(ch)
                }
            }
        }
    }

    private func processNormalChar(_ ch: Character) {
        switch ch {
        case "\u{1B}": // ESC
            parseState = .escape
        case "\r": // CR
            cursorCol = 0
            wrapPending = false
        case "\n": // LF
            lineFeed()
        case "\u{08}": // BS (Backspace)
            wrapPending = false
            if cursorCol > 0 { cursorCol -= 1 }
        case "\t": // Tab
            wrapPending = false
            cursorCol = min(cols - 1, (cursorCol / 8 + 1) * 8)
        case "\u{07}": // BEL — ignore
            break
        case "\u{0E}", "\u{0F}": // SO/SI (charset shift) — ignore
            break
        case "\u{00}"..."\u{06}", "\u{10}"..."\u{1A}", "\u{1C}"..."\u{1F}":
            break // Other C0 control chars — ignore
        default:
            // Normal printable character
            putChar(ch)
        }
    }

    private func processEscapeChar(_ ch: Character) {
        switch ch {
        case "[":
            parseState = .csi
            csiParams = ""
        case "]":
            parseState = .osc
            oscBuffer = ""
        case "(", ")": // Character set designation — skip next char
            parseState = .normal
        case "#":
            parseState = .escHash
        case "M": // Reverse Index (scroll down)
            reverseIndex()
            parseState = .normal
        case "D": // Index (scroll up)
            index()
            parseState = .normal
        case "E": // Next Line
            index()
            cursorCol = 0
            parseState = .normal
        case "7": // DECSC — Save cursor + attributes
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
            savedSgrFg = sgrFg
            savedSgrBg = sgrBg
            savedSgrBold = sgrBold
            parseState = .normal
        case "8": // DECRC — Restore cursor + attributes
            cursorRow = min(savedCursorRow, rows - 1)
            cursorCol = min(savedCursorCol, cols - 1)
            sgrFg = savedSgrFg
            sgrBg = savedSgrBg
            sgrBold = savedSgrBold
            parseState = .normal
        case "=", ">": // Keypad mode — ignore
            parseState = .normal
        case "c": // RIS — Full Reset
            fullReset()
            parseState = .normal
        default:
            parseState = .normal
        }
    }

    private func processCSIChar(_ ch: Character) {
        let ascii = ch.asciiValue ?? 0
        if ascii >= 0x40 && ascii <= 0x7E {
            // Final byte — execute and return to normal
            executeCSI(ch)
            parseState = .normal
        } else if ascii >= 0x20 && ascii <= 0x3F {
            // Parameter byte or intermediate byte
            csiParams.append(ch)
        } else {
            // Unexpected — abort CSI
            parseState = .normal
        }
    }

    // MARK: - CSI Sequence Execution

    private func executeCSI(_ cmd: Character) {
        // Check for DEC Private Mode prefix '?' or '>' or '!'
        let isPrivate = csiParams.hasPrefix("?")
        let isSecondary = csiParams.hasPrefix(">")
        let isTertiary = csiParams.hasPrefix("!")
        var cleanParams = csiParams
        if isPrivate || isSecondary || isTertiary { cleanParams = String(csiParams.dropFirst()) }

        // Filter out any remaining non-numeric, non-semicolon characters (intermediate bytes like space)
        let numericParams = String(cleanParams.filter { $0.isNumber || $0 == ";" })
        let parts = numericParams.split(separator: ";").compactMap { Int($0) }
        let p1 = parts.count > 0 ? parts[0] : 0
        let p2 = parts.count > 1 ? parts[1] : 0

        if isPrivate {
            executeDecPrivateMode(cmd, params: parts)
            return
        }
        if isSecondary {
            // Secondary DA response: ESC[>0;0;0c (VT100-like)
            if cmd == "c" {
                let response = "\u{1B}[>0;0;0c"
                writeBack?(Array(response.utf8))
            }
            return
        }
        if isTertiary {
            return
        }

        switch cmd {
        case "A": // Cursor Up
            cursorRow = max(scrollTop, cursorRow - max(1, p1))
            wrapPending = false
        case "B": // Cursor Down
            cursorRow = min(scrollBottom, cursorRow + max(1, p1))
            wrapPending = false
        case "C": // Cursor Forward
            cursorCol = min(cols - 1, cursorCol + max(1, p1))
            wrapPending = false
        case "D": // Cursor Back
            cursorCol = max(0, cursorCol - max(1, p1))
            wrapPending = false
        case "E": // Cursor Next Line
            cursorRow = min(scrollBottom, cursorRow + max(1, p1)); cursorCol = 0
        case "F": // Cursor Previous Line
            cursorRow = max(scrollTop, cursorRow - max(1, p1)); cursorCol = 0
        case "G", "`": // Cursor Horizontal Absolute
            cursorCol = min(cols - 1, max(0, (p1 > 0 ? p1 - 1 : 0)))
            wrapPending = false
        case "H", "f": // Cursor Position
            let targetRow = p1 > 0 ? p1 - 1 : 0
            let targetCol = p2 > 0 ? p2 - 1 : 0
            if originMode {
                cursorRow = min(scrollBottom, max(scrollTop, scrollTop + targetRow))
            } else {
                cursorRow = min(rows - 1, max(0, targetRow))
            }
            cursorCol = min(cols - 1, max(0, targetCol))
            wrapPending = false
        case "J": // Erase in Display
            eraseDisplay(mode: p1)
        case "K": // Erase in Line
            eraseLine(mode: p1)
        case "L": // Insert Lines
            scrollLinesDown(at: cursorRow, count: max(1, p1))
        case "M": // Delete Lines
            scrollLinesUp(at: cursorRow, count: max(1, p1))
        case "P": // Delete Characters
            deleteChars(max(1, p1))
        case "@": // Insert Characters
            insertChars(max(1, p1))
        case "X": // Erase Characters (ECH)
            let n = max(1, p1)
            for c in cursorCol..<min(cursorCol + n, cols) {
                screen[cursorRow][c] = Cell()
            }
        case "m": // SGR
            applySGR(parts)
        case "r": // DECSTBM — Set Scrolling Region
            let top = (p1 > 0 ? p1 - 1 : 0)
            let bottom = (p2 > 0 ? p2 - 1 : rows - 1)
            scrollTop = max(0, min(top, rows - 1))
            scrollBottom = max(scrollTop, min(bottom, rows - 1))
            // Cursor goes to home position
            if originMode {
                cursorRow = scrollTop
            } else {
                cursorRow = 0
            }
            cursorCol = 0
        case "h": // SM — Set Mode
            if p1 == 4 { /* Insert mode — ignore for now */ }
        case "l": // RM — Reset Mode
            if p1 == 4 { /* Replace mode — ignore for now */ }
        case "d": // VPA — Vertical Position Absolute
            cursorRow = min(rows - 1, max(0, (p1 > 0 ? p1 - 1 : 0)))
            wrapPending = false
        case "S": // Scroll Up
            for _ in 0..<max(1, p1) { scrollRegionUp() }
        case "T": // Scroll Down
            for _ in 0..<max(1, p1) { scrollRegionDown() }
        case "b": // REP — Repeat preceding char
            break // simplified: ignore
        case "c": // DA — Primary Device Attributes
            // Respond as VT100 with Advanced Video Option
            let response = "\u{1B}[?1;2c"
            writeBack?(Array(response.utf8))
        case "n": // DSR — Device Status Report
            if p1 == 5 {
                // Status report: "OK"
                let response = "\u{1B}[0n"
                writeBack?(Array(response.utf8))
            } else if p1 == 6 {
                // CPR: report cursor position
                let response = "\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R"
                writeBack?(Array(response.utf8))
            }
        case "t": // Window manipulation (xterm)
            switch p1 {
            case 8: // Resize window to p2 rows, p3 cols (ignore — we control size)
                break
            case 14: // Report window size in pixels
                let pixW = cols * 8  // Approximate
                let pixH = rows * 16
                let response = "\u{1B}[4;\(pixH);\(pixW)t"
                writeBack?(Array(response.utf8))
            case 18: // Report terminal size in characters (rows;cols)
                let response = "\u{1B}[8;\(rows);\(cols)t"
                writeBack?(Array(response.utf8))
            case 22: // Save window title — ignore
                break
            case 23: // Restore window title — ignore
                break
            default:
                break
            }
        case "s": // Save cursor (SCO)
            savedCursorRow = cursorRow; savedCursorCol = cursorCol
        case "u": // Restore cursor (SCO)
            cursorRow = min(savedCursorRow, rows - 1); cursorCol = min(savedCursorCol, cols - 1)
        default:
            break // Unknown CSI — ignore
        }
    }

    // MARK: - DEC Private Modes

    private func executeDecPrivateMode(_ cmd: Character, params: [Int]) {
        let set = (cmd == "h") // h = set, l = reset
        for mode in params {
            switch mode {
            case 1: // DECCKM — Cursor key mode (Application vs Normal)
                break // Handled by key input side
            case 7: // DECAWM — Auto-wrap
                break // Always on for us
            case 12: // Cursor blink — ignore
                break
            case 25: // DECTCEM — Cursor visibility
                cursorHidden = !set
            case 47: // Alternate screen buffer (older)
                if set { enterAlternateScreen() } else { leaveAlternateScreen() }
            case 1000, 1002, 1003, 1006, 1015: // Mouse tracking — ignore
                break
            case 1049: // Alternate screen buffer + save/restore cursor
                if set {
                    savedCursorRow = cursorRow; savedCursorCol = cursorCol
                    enterAlternateScreen()
                } else {
                    leaveAlternateScreen()
                    cursorRow = min(savedCursorRow, rows - 1)
                    cursorCol = min(savedCursorCol, cols - 1)
                }
            case 1004: // Focus event mode
                focusEventMode = set
            case 2004: // Bracketed paste mode
                bracketedPasteMode = set
            case 6: // DECOM — Origin mode
                originMode = set
                cursorRow = set ? scrollTop : 0
                cursorCol = 0
            default:
                break
            }
        }
    }

    // MARK: - Screen Operations

    private func putChar(_ ch: Character) {
        if wrapPending {
            wrapPending = false
            cursorCol = 0
            if cursorRow == scrollBottom {
                scrollRegionUp()
            } else if cursorRow < rows - 1 {
                cursorRow += 1
            }
        }
        screen[cursorRow][cursorCol] = Cell(
            char: ch, fg: sgrFg, bg: sgrBg, bold: sgrBold,
            reverse: sgrReverse, dim: sgrDim, underline: sgrUnderline
        )
        if cursorCol < cols - 1 {
            cursorCol += 1
        } else {
            wrapPending = true
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollRegionUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0: // Erase below
            eraseLine(mode: 0)
            for r in (cursorRow + 1)..<rows {
                screen[r] = Array(repeating: Cell(), count: cols)
            }
        case 1: // Erase above
            for r in 0..<cursorRow {
                screen[r] = Array(repeating: Cell(), count: cols)
            }
            for c in 0...cursorCol { screen[cursorRow][c] = Cell() }
        case 2, 3: // Erase all
            screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        default: break
        }
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0: // Erase to right
            for c in cursorCol..<cols { screen[cursorRow][c] = Cell() }
        case 1: // Erase to left
            for c in 0...min(cursorCol, cols - 1) { screen[cursorRow][c] = Cell() }
        case 2: // Erase whole line
            screen[cursorRow] = Array(repeating: Cell(), count: cols)
        default: break
        }
    }

    // insertLines/deleteLines now handled by scrollLinesDown/scrollLinesUp in CSI L/M

    private func deleteChars(_ n: Int) {
        let count = min(n, cols - cursorCol)
        for _ in 0..<count {
            screen[cursorRow].remove(at: cursorCol)
            screen[cursorRow].append(Cell())
        }
    }

    private func insertChars(_ n: Int) {
        let count = min(n, cols - cursorCol)
        for _ in 0..<count {
            screen[cursorRow].insert(Cell(), at: cursorCol)
            screen[cursorRow].removeLast()
        }
    }

    // MARK: - Scroll Region Operations

    private func scrollRegionUp() {
        if scrollTop < rows && scrollBottom < rows && scrollTop <= scrollBottom {
            if !isAlternateScreen {
                // Verwende Ringpuffer für konstante Zeitoperation
                appendToScrollback(screen[scrollTop])
            }
            screen.remove(at: scrollTop)
            screen.insert(Array(repeating: Cell(), count: cols), at: scrollBottom)
        }
    }

    private func scrollRegionDown() {
        if scrollTop < rows && scrollBottom < rows && scrollTop <= scrollBottom {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell(), count: cols), at: scrollTop)
        }
    }

    private func scrollLinesUp(at row: Int, count: Int) {
        let top = max(row, scrollTop)
        for _ in 0..<min(count, scrollBottom - top + 1) {
            screen.remove(at: top)
            screen.insert(Array(repeating: Cell(), count: cols), at: scrollBottom)
        }
    }

    private func scrollLinesDown(at row: Int, count: Int) {
        let top = max(row, scrollTop)
        for _ in 0..<min(count, scrollBottom - top + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: Cell(), count: cols), at: top)
        }
    }

    /// ESC D — Index (cursor down, scroll if at bottom of region)
    private func index() {
        if cursorRow == scrollBottom {
            scrollRegionUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    /// ESC M — Reverse Index (cursor up, scroll if at top of region)
    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollRegionDown()
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    // MARK: - Alternate Screen Buffer

    private func enterAlternateScreen() {
        guard !isAlternateScreen else { return }
        isAlternateScreen = true
        savedMainScreen = screen
        savedMainScrollback = scrollback
        savedMainCursor = (cursorRow, cursorCol)
        screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        scrollback = []
        cursorRow = 0; cursorCol = 0
        scrollTop = 0; scrollBottom = rows - 1
    }

    private func leaveAlternateScreen() {
        guard isAlternateScreen else { return }
        isAlternateScreen = false
        if let saved = savedMainScreen {
            // Resize if needed
            if saved.count == rows && (saved.first?.count ?? 0) == cols {
                screen = saved
            } else {
                screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
                for r in 0..<min(saved.count, rows) {
                    for c in 0..<min(saved[r].count, cols) {
                        screen[r][c] = saved[r][c]
                    }
                }
            }
        }
        if let savedScroll = savedMainScrollback { scrollback = savedScroll }
        if let savedCur = savedMainCursor {
            cursorRow = min(savedCur.row, rows - 1)
            cursorCol = min(savedCur.col, cols - 1)
        }
        savedMainScreen = nil; savedMainScrollback = nil; savedMainCursor = nil
        scrollTop = 0; scrollBottom = rows - 1
    }

    /// ESC c — Full terminal reset
    private func fullReset() {
        if isAlternateScreen { leaveAlternateScreen() }
        screen = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        scrollback = []
        cursorRow = 0; cursorCol = 0
        scrollTop = 0; scrollBottom = rows - 1
        sgrFg = .default; sgrBg = .default; sgrBold = false; sgrReverse = false
        sgrDim = false; sgrItalic = false; sgrUnderline = false
        cursorHidden = false; originMode = false; wrapPending = false
        bracketedPasteMode = false; focusEventMode = false
        parseState = .normal
    }

    // MARK: - SGR (Colors/Style)

    private func applySGR(_ codes: [Int]) {
        if codes.isEmpty { resetSGR(); return }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: resetSGR()
            case 1: sgrBold = true
            case 2: sgrDim = true
            case 3: sgrItalic = true
            case 4: sgrUnderline = true
            case 7: sgrReverse = true
            case 21, 22: sgrBold = false; sgrDim = false
            case 23: sgrItalic = false
            case 24: sgrUnderline = false
            case 27: sgrReverse = false
            case 30...37: sgrFg = .ansi(UInt8(code))
            case 38: // Extended foreground (256-color / TrueColor RGB)
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    // 256-color palette
                    sgrFg = .palette(UInt8(clamping: codes[i + 2]))
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    // TrueColor RGB
                    sgrFg = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4]))
                    i += 4
                }
            case 39: sgrFg = .default
            case 40...47: sgrBg = .ansi(UInt8(code))
            case 48: // Extended background (256-color / TrueColor RGB)
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    sgrBg = .palette(UInt8(clamping: codes[i + 2]))
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    sgrBg = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4]))
                    i += 4
                }
            case 49: sgrBg = .default
            case 90...97: sgrFg = .ansi(UInt8(code))
            case 100...107: sgrBg = .ansi(UInt8(code))
            default: break
            }
            i += 1
        }
    }

    private func resetSGR() {
        sgrFg = .default; sgrBg = .default; sgrBold = false; sgrReverse = false
        sgrDim = false; sgrItalic = false; sgrUnderline = false
    }

    // MARK: - Rendering

    static let defaultFg = NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0) // Neongrün

    // ANSI 16-Farb-Palette (Standard + Bright)
    private static let ansi16: [UInt8: NSColor] = [
        30: NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),    // Black
        31: NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1),   // Red
        32: NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1),   // Green
        33: NSColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1),    // Yellow
        34: NSColor(red: 0.4, green: 0.5, blue: 0.9, alpha: 1),    // Blue
        35: NSColor(red: 0.7, green: 0.4, blue: 0.85, alpha: 1),   // Magenta
        36: NSColor(red: 0.3, green: 0.8, blue: 0.85, alpha: 1),   // Cyan
        37: NSColor(red: 0.85, green: 0.87, blue: 0.83, alpha: 1), // White
        40: NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        41: NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1),
        42: NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1),
        43: NSColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1),
        44: NSColor(red: 0.4, green: 0.5, blue: 0.9, alpha: 1),
        45: NSColor(red: 0.7, green: 0.4, blue: 0.85, alpha: 1),
        46: NSColor(red: 0.3, green: 0.8, blue: 0.85, alpha: 1),
        47: NSColor(red: 0.85, green: 0.87, blue: 0.83, alpha: 1),
        90: NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),    // Bright Black
        91: NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1),    // Bright Red
        92: NSColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1),    // Bright Green
        93: NSColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1),    // Bright Yellow
        94: NSColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 1),    // Bright Blue
        95: NSColor(red: 0.85, green: 0.5, blue: 1.0, alpha: 1),   // Bright Magenta
        96: NSColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1),   // Bright Cyan
        97: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),    // Bright White
        100: NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        101: NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1),
        102: NSColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1),
        103: NSColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1),
        104: NSColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 1),
        105: NSColor(red: 0.85, green: 0.5, blue: 1.0, alpha: 1),
        106: NSColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1),
        107: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
    ]

    /// 256-Farb-Palette → NSColor
    static func paletteColor(_ index: UInt8) -> NSColor {
        // 0-7: Standard colors (same as ANSI 30-37)
        if index < 8 {
            return ansi16[30 + index] ?? defaultFg
        }
        // 8-15: Bright colors (same as ANSI 90-97)
        if index < 16 {
            return ansi16[82 + index] ?? defaultFg // 90 = 82+8
        }
        // 16-231: 6x6x6 color cube
        if index < 232 {
            let idx = Int(index) - 16
            let r = idx / 36
            let g = (idx % 36) / 6
            let b = idx % 6
            let vals: [CGFloat] = [0, 0.37, 0.53, 0.69, 0.84, 1.0]
            return NSColor(red: vals[r], green: vals[g], blue: vals[b], alpha: 1)
        }
        // 232-255: Grayscale (24 steps)
        let gray = CGFloat(Int(index) - 232) / 23.0
        return NSColor(red: gray, green: gray, blue: gray, alpha: 1)
    }

    /// Resolve TermColor to NSColor for foreground
    static func resolveColor(_ color: TermColor, isFg: Bool) -> NSColor? {
        switch color {
        case .default:
            return isFg ? defaultFg : nil
        case .ansi(let code):
            return ansi16[code] ?? (isFg ? defaultFg : nil)
        case .palette(let index):
            return paletteColor(index)
        case .rgb(let r, let g, let b):
            return NSColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1)
        }
    }

    func render(showCursor: Bool) -> NSAttributedString {
        screenLock.lock()
        defer { screenLock.unlock() }

        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let actualShowCursor = showCursor && !cursorHidden

        // Render scrollback (nur im Hauptscreen, nicht im Alternate)
        if !isAlternateScreen {
            let scrollLines = getScrollbackLines().suffix(500)
            for line in scrollLines {
                appendLine(line, to: result, font: font, boldFont: boldFont, cursorAt: nil)
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: Self.defaultFg]))
            }
        }

        // Render aktiven Screen
        for r in 0..<rows {
            let cursorCol = (actualShowCursor && r == cursorRow) ? self.cursorCol : nil
            appendLine(screen[r], to: result, font: font, boldFont: boldFont, cursorAt: cursorCol)
            if r < rows - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: Self.defaultFg]))
            }
        }
        return result
    }

    private func appendLine(_ line: [Cell], to result: NSMutableAttributedString, font: NSFont, boldFont: NSFont, cursorAt: Int?) {
        // Finde letzte nicht-leere Zelle (für Trimming), aber im Alternate Screen alles rendern
        var lastNonEmpty = isAlternateScreen ? cols - 1 : -1
        if !isAlternateScreen {
            for c in stride(from: line.count - 1, through: 0, by: -1) {
                if line[c].char != " " || line[c].fg != .default || line[c].bg != .default || (cursorAt == c) { lastNonEmpty = c; break }
            }
        }
        let renderTo = max(lastNonEmpty, cursorAt ?? -1)
        guard renderTo >= 0 else { return }

        for c in 0...renderTo {
            let cell = c < line.count ? line[c] : Cell()
            let isCursor = (cursorAt == c)

            var fgColor = Self.resolveColor(cell.fg, isFg: true) ?? Self.defaultFg
            var bgColor = Self.resolveColor(cell.bg, isFg: false)
            let f = cell.bold ? boldFont : font

            // Reverse video
            if cell.reverse {
                let tmp = fgColor
                fgColor = bgColor ?? .black
                bgColor = tmp
            }

            // Dim
            if cell.dim { fgColor = fgColor.withAlphaComponent(0.5) }

            if isCursor {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: f,
                    .foregroundColor: NSColor.black,
                    .backgroundColor: Self.defaultFg
                ]
                result.append(NSAttributedString(string: String(cell.char), attributes: attrs))
            } else {
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fgColor]
                if let bg = bgColor { attrs[.backgroundColor] = bg }
                if cell.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: String(cell.char), attributes: attrs))
            }
        }
    }

    /// Für Agent-Snapshots: Text ohne ANSI
    func plainText(lastN: Int = 50) -> String {
        screenLock.lock()
        defer { screenLock.unlock() }
        var lines: [String] = []
        for line in scrollback.suffix(lastN) {
            lines.append(String(line.map { $0.char }).trimmingCharacters(in: .whitespaces))
        }
        for r in 0..<rows {
            lines.append(String(screen[r].map { $0.char }).trimmingCharacters(in: .whitespaces))
        }
        return lines.suffix(lastN).joined(separator: "\n")
    }
}

// MARK: - Terminal Session (PTY-basiert, thread-safe)

final class TerminalSession: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    @Published var title: String = "Terminal"
    @Published var screenVersion: Int = 0 // Increments on each render to trigger SwiftUI update
    @Published var isRunning = false

    let screen = TerminalScreen(rows: 24, cols: 80)
    var commandHistory: [String] = []
    private var historyIndex = -1

    // PTY
    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private let fdLock = NSLock()
    private var readSource: DispatchSourceRead?
    private var isStopping = false

    // Debounced output (60fps)
    private var outputBuffer: [UInt8] = []
    private let bufferLock = NSLock()
    private var flushTimer: DispatchSourceTimer?
    private var cleanupTimer: Timer?

    // UI Update Throttling (max 30 FPS)
    private var lastUIUpdateTime: CFTimeInterval = 0
    private let minUIUpdateInterval: CFTimeInterval = 1.0/30.0 // 30 FPS max

    deinit {
        stopInternal()
        cleanupTimer?.invalidate()
    }

    func start(shell: String = "/bin/zsh") {
        guard !isRunning else { return }
        isStopping = false

        // Initialisiere Signalhandler
        kobold_init_signal_handlers()

        var pid: pid_t = 0
        let fd = kobold_forkpty(&pid, shell, Int32(screen.rows), Int32(screen.cols))
        guard fd >= 0 else {
            screen.process("Error: PTY konnte nicht erstellt werden\r\n")
            DispatchQueue.main.async { [weak self] in self?.screenVersion += 1 }
            return
        }

        fdLock.lock()
        masterFd = fd
        childPid = pid
        fdLock.unlock()

        // Wire up writeBack so TerminalScreen can send CPR/DA responses back to PTY
        screen.writeBack = { [weak self] bytes in
            self?.sendBytes(bytes)
        }

        DispatchQueue.main.async { [weak self] in self?.isRunning = true }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self, !self.isStopping else { return }
            self.fdLock.lock()
            let currentFd = self.masterFd
            self.fdLock.unlock()
            guard currentFd >= 0 else { return }

            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(currentFd, &buf, buf.count)
            if n > 0 {
                self.bufferLock.lock()
                self.outputBuffer.append(contentsOf: buf[0..<n])
                self.bufferLock.unlock()
            } else if n == 0 {
                DispatchQueue.main.async { [weak self] in self?.isRunning = false }
            }
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
        startFlushTimer()
    }

    private func setupCleanupTimer() {
        // Removed: was firing 1/s on Main RunLoop doing nothing (pure CPU waste)
    }

    func sendInput(_ text: String) {
        fdLock.lock()
        let currentFd = masterFd
        fdLock.unlock()
        guard currentFd >= 0 else { return }
        if let data = text.data(using: .utf8) {
            data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress { let _ = write(currentFd, base, ptr.count) }
            }
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        fdLock.lock()
        let currentFd = masterFd
        fdLock.unlock()
        guard currentFd >= 0 else { return }
        bytes.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { let _ = write(currentFd, base, bytes.count) }
        }
    }

    func sendCommand(_ command: String) {
        sendInput(command + "\n")
        if !command.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.commandHistory.insert(command, at: 0)
                if self.commandHistory.count > 1000 { self.commandHistory.removeLast() }
                self.historyIndex = -1
            }
        }
    }

    func sendInterrupt() { sendInput("\u{03}") }

    func resize(rows: Int, cols: Int) {
        screen.resize(newRows: rows, newCols: cols)
        fdLock.lock()
        let currentFd = masterFd
        fdLock.unlock()
        guard currentFd >= 0 else { return }
        kobold_pty_resize(currentFd, Int32(rows), Int32(cols))
    }

    func stop() {
        stopInternal()
        DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    }

    private func stopInternal() {
        isStopping = true
        flushTimer?.cancel()
        flushTimer = nil
        readSource?.cancel()
        readSource = nil

        fdLock.lock()
        let pid = childPid; let fd = masterFd
        childPid = 0; masterFd = -1
        fdLock.unlock()

        if pid > 0 { kill(pid, SIGHUP) }
        if fd >= 0 { close(fd) }
        flushBufferSync()
    }

    func readLastLines(_ n: Int = 50) -> String {
        screen.plainText(lastN: n)
    }

    // MARK: - Debounced Output (16ms = 60fps)

    private func startFlushTimer() {
        // Cancel existing timer to prevent leak on double-call
        flushTimer?.cancel()
        flushTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.flushBuffer() }
        timer.resume()
        flushTimer = timer
    }

    private var utf8Remainder: [UInt8] = [] // Unvollständige UTF-8-Sequenzen zwischen Reads

    private func flushBuffer() {
        bufferLock.lock()
        guard !outputBuffer.isEmpty else { bufferLock.unlock(); return }
        var data = outputBuffer
        outputBuffer.removeAll(keepingCapacity: true)
        // Also grab utf8Remainder under lock
        if !utf8Remainder.isEmpty {
            data.insert(contentsOf: utf8Remainder, at: 0)
            utf8Remainder.removeAll()
        }
        bufferLock.unlock()

        // Prüfen ob das Ende eine unvollständige UTF-8-Sequenz ist
        let trailingIncomplete = incompleteUTF8TrailingBytes(data)
        if trailingIncomplete > 0 {
            bufferLock.lock()
            utf8Remainder = Array(data.suffix(trailingIncomplete))
            bufferLock.unlock()
            data = Array(data.dropLast(trailingIncomplete))
        }

        if !data.isEmpty, let text = String(bytes: data, encoding: .utf8) {
            screen.process(text)
        }

        DispatchQueue.main.async { [weak self] in
            self?.screenVersion += 1
        }
    }

    /// Erkennt unvollständige UTF-8-Sequenzen am Ende eines Byte-Arrays
    private func incompleteUTF8TrailingBytes(_ data: [UInt8]) -> Int {
        guard !data.isEmpty else { return 0 }
        // Von hinten suchen: Finde den Start einer Multi-Byte-Sequenz
        let maxCheck = min(4, data.count)
        for i in 1...maxCheck {
            let byte = data[data.count - i]
            if byte & 0x80 == 0 { return 0 } // ASCII — alles komplett
            if byte & 0xC0 == 0xC0 { // Start-Byte einer Multi-Byte-Sequenz
                let expectedLen: Int
                if byte & 0xF8 == 0xF0 { expectedLen = 4 }
                else if byte & 0xF0 == 0xE0 { expectedLen = 3 }
                else if byte & 0xE0 == 0xC0 { expectedLen = 2 }
                else { return 0 } // Ungültiges Start-Byte
                return i < expectedLen ? i : 0 // Unvollständig wenn weniger Bytes als erwartet
            }
        }
        return 0
    }

    private func flushBufferSync() {
        bufferLock.lock()
        let data = outputBuffer
        outputBuffer.removeAll()
        bufferLock.unlock()
        guard !data.isEmpty else { return }
        if let text = String(bytes: data, encoding: .utf8) {
            screen.process(text)
        }
        DispatchQueue.main.async { [weak self] in self?.screenVersion += 1 }
    }
}

// MARK: - Terminal Text View (Key-Input → PTY)

final class TerminalTextView: NSTextView {
    weak var session: TerminalSession?

    override var acceptsFirstResponder: Bool { true }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let str = insertString as? String { session?.sendInput(str) }
    }

    override func insertNewline(_ sender: Any?) { session?.sendBytes([0x0D]) }
    override func insertTab(_ sender: Any?) { session?.sendBytes([0x09]) }
    override func insertBacktab(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x5A]) }
    override func deleteBackward(_ sender: Any?) { session?.sendBytes([0x7F]) }
    override func deleteForward(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x33, 0x7E]) }
    override func moveUp(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x41]) }
    override func moveDown(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x42]) }
    override func moveRight(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x43]) }
    override func moveLeft(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x44]) }
    override func moveToBeginningOfLine(_ sender: Any?) { session?.sendBytes([0x01]) }
    override func moveToEndOfLine(_ sender: Any?) { session?.sendBytes([0x05]) }
    override func cancelOperation(_ sender: Any?) { session?.sendBytes([0x1B]) }
    override func pageUp(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x35, 0x7E]) }
    override func pageDown(_ sender: Any?) { session?.sendBytes([0x1B, 0x5B, 0x36, 0x7E]) }

    override func keyDown(with event: NSEvent) {
        guard let session = session, session.isRunning else { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.control) {
            if let chars = event.charactersIgnoringModifiers, let c = chars.first, let v = c.asciiValue {
                session.sendBytes([v & 0x1F])
                return
            }
        }
        if event.keyCode == 76 { session.sendBytes([0x0D]); return } // Keypad Enter
        self.interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string) {
                if session?.screen.bracketedPasteMode == true {
                    // Wrap paste in bracketed paste markers
                    session?.sendBytes(Array("\u{1B}[200~".utf8))
                    session?.sendInput(text)
                    session?.sendBytes(Array("\u{1B}[201~".utf8))
                } else {
                    session?.sendInput(text)
                }
                return true
            }
        } else if event.charactersIgnoringModifiers == "c" {
            if let r = selectedRanges.first?.rangeValue, r.length > 0 { copy(nil); return true }
            session?.sendBytes([0x03]); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

// MARK: - Terminal NSView Container

final class RawTerminalNSView: NSView {
    weak var session: TerminalSession? {
        didSet { textView.session = session }
    }

    private var scrollView: NSScrollView!
    private(set) var textView: TerminalTextView!
    private var lastVersion: Int = -1
    private var cursorBlinkTimer: Timer?
    private var cursorVisible = true
    private var userScrolledUp = false
    private var lastUIUpdateTime: CFTimeInterval = 0
    private let minUIUpdateInterval: CFTimeInterval = 1.0/30.0

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    func cleanup() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    override func removeFromSuperview() {
        cleanup()
        super.removeFromSuperview()
    }

    private func setup() {
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .black
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light

        let contentSize = scrollView.contentSize
        let tc = NSTextContainer(size: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineBreakMode = .byClipping  // Terminal-Text darf NICHT umbrechen!
        tc.lineFragmentPadding = 0

        let lm = NSLayoutManager()
        lm.addTextContainer(tc)
        let ts = NSTextStorage()
        ts.addLayoutManager(lm)

        textView = TerminalTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: tc)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .black
        textView.textColor = TerminalScreen.defaultFg
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.insertionPointColor = TerminalScreen.defaultFg

        scrollView.documentView = textView
        addSubview(scrollView)

        // Detect user scrolling — NUR bei echtem User-Scroll, nicht bei programmatischem
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        // Cursor blink timer (600ms — slightly slower to reduce CPU, only redraws if window visible)
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, self.window != nil, !(self.window?.isVisible == false) else { return }
            self.cursorVisible.toggle()
            self.renderScreen(autoScroll: false)
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let docView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let contentHeight = docView.frame.height
        let scrollPos = visibleRect.origin.y + visibleRect.height
        // Prüfe ob User hochgescrollt hat (30px Toleranz)
        userScrolledUp = (contentHeight - scrollPos) > 30
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if let session = session {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            // Korrekt: NSLayoutManager.defaultLineHeight für präzise Zeilenhöhe
            let lm = NSLayoutManager()
            let charH = ceil(lm.defaultLineHeight(for: font))
            // Korrekt: Breite über mehrere Zeichen mitteln
            let sampleWidth = NSString("MMMMMMMMMM").size(withAttributes: [.font: font]).width
            let charW = sampleWidth / 10.0
            let insetW = textView?.textContainerInset.width ?? 4
            let scrollerW: CGFloat = 15
            let usableWidth = max(100, bounds.width - insetW * 2 - scrollerW)
            let usableHeight = max(100, bounds.height - (textView?.textContainerInset.height ?? 4) * 2)
            let cols = max(40, Int(usableWidth / charW))
            let rows = max(10, Int(usableHeight / charH))
            session.resize(rows: rows, cols: cols)
        }
    }

    func updateIfNeeded(version: Int) {
        guard version != lastVersion else { return }
        lastVersion = version
        cursorVisible = true

        // UI Update Throttling
        let currentTime = CACurrentMediaTime()
        if currentTime - lastUIUpdateTime >= minUIUpdateInterval {
            renderScreen(autoScroll: true)
            lastUIUpdateTime = currentTime
        } else {
            // Planen eines verzögerten Updates falls innerhalb des Intervalls
            DispatchQueue.main.asyncAfter(deadline: .now() + minUIUpdateInterval) {
                if self.lastVersion == version { // Nur aktualisieren wenn immer noch relevant
                    self.renderScreen(autoScroll: true)
                    self.lastUIUpdateTime = CACurrentMediaTime()
                }
            }
        }
    }

    private func renderScreen(autoScroll: Bool = true) {
        guard let session = session else { return }

        // Wenn User Text markiert hat → NICHT updaten (Markierung würde verschwinden)
        if let ranges = textView.selectedRanges as? [NSValue],
           let first = ranges.first?.rangeValue, first.length > 0 {
            return // Skip render solange Selektion aktiv
        }

        let attributed = session.screen.render(showCursor: cursorVisible)
        let isAltScreen = session.screen.isAlternateScreen
        let savedOrigin = (userScrolledUp && !isAltScreen) ? scrollView.contentView.bounds.origin : nil

        // Scroll-Notifications temporär deaktivieren während Content-Update
        // (verhindert falsche userScrolledUp-Detection durch setAttributedString)
        scrollView.contentView.postsBoundsChangedNotifications = false
        textView.textStorage?.setAttributedString(attributed)

        // Im Alternate Screen (Claude CLI, vim, htop): IMMER ans Ende scrollen
        if isAltScreen || (autoScroll && !userScrolledUp) {
            textView.scrollToEndOfDocument(nil)
        } else if let origin = savedOrigin {
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
            let clampedOrigin = NSPoint(x: origin.x, y: min(origin.y, maxY))
            scrollView.contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Notifications wieder aktivieren nach Layout
        DispatchQueue.main.async { [weak self] in
            self?.scrollView.contentView.postsBoundsChangedNotifications = true
        }
    }
}

// MARK: - SwiftUI Wrapper

struct RawTerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> RawTerminalNSView {
        let view = RawTerminalNSView(frame: .zero)
        view.session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            view.window?.makeFirstResponder(view.textView)
        }
        return view
    }

    func updateNSView(_ nsView: RawTerminalNSView, context: Context) {
        nsView.session = session
        nsView.textView.session = session
        nsView.updateIfNeeded(version: session.screenVersion)
    }

    static func dismantleNSView(_ nsView: RawTerminalNSView, coordinator: ()) {
        nsView.cleanup()
    }
}

// MARK: - Shared Terminal Manager

@MainActor
final class SharedTerminalManager: ObservableObject {
    static let shared = SharedTerminalManager()

    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionId: UUID?

    var activeSession: TerminalSession? { sessions.first { $0.id == activeSessionId } }

    func newSession() -> UUID {
        let session = TerminalSession()
        sessions.append(session)
        activeSessionId = session.id
        session.start()
        return session.id
    }

    func closeSession(_ id: UUID) {
        sessions.first(where: { $0.id == id })?.stop()
        sessions.removeAll { $0.id == id }
        if activeSessionId == id { activeSessionId = sessions.last?.id }
    }

    func session(for id: UUID?) -> TerminalSession? {
        if let id = id { return sessions.first { $0.id == id } }
        return activeSession
    }

    func readOutput(sessionId: UUID? = nil, lastN: Int = 50) -> String {
        session(for: sessionId)?.readLastLines(lastN) ?? "[Keine Terminal-Session aktiv]"
    }

    func sendCommand(_ command: String, sessionId: UUID? = nil) -> String {
        guard let s = session(for: sessionId) else { return "[Keine Terminal-Session aktiv]" }
        s.sendCommand(command)
        return "Befehl gesendet: \(command)"
    }

    func getSnapshot(sessionId: UUID? = nil) -> [String: String] {
        guard let s = session(for: sessionId) else { return ["error": "Keine Terminal-Session aktiv"] }
        return [
            "session_id": s.id.uuidString, "title": s.title,
            "is_running": s.isRunning ? "true" : "false",
            "last_output": s.readLastLines(50)
        ]
    }
}

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    @ObservedObject var manager = SharedTerminalManager.shared

    var body: some View {
        VStack(spacing: 0) {
            terminalTabBar
            if let session = manager.activeSession {
                TerminalSessionView(session: session)
            } else { emptyState }
        }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 0) {
            ForEach(manager.sessions) { session in
                tabButton(session: session)
            }
            Button(action: { let _ = manager.newSession() }) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.black.opacity(0.3))
    }

    private func tabButton(session: TerminalSession) -> some View {
        let isActive = manager.activeSessionId == session.id
        return Button(action: { manager.activeSessionId = session.id }) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill").font(.system(size: 10))
                Text(session.title).font(.system(size: 12)).lineLimit(1)
                Button(action: { manager.closeSession(session.id) }) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(isActive ? .koboldEmerald : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isActive ? AnyView(RoundedRectangle(cornerRadius: 6).fill(Color.koboldEmerald.opacity(0.1))) : AnyView(Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
            Text("Neues Terminal öffnen").font(.system(size: 14)).foregroundColor(.secondary)
            Button(action: { let _ = manager.newSession() }) {
                Label("Terminal starten", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent).tint(.koboldEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
}

// MARK: - Terminal Session View

struct TerminalSessionView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        ZStack {
            RawTerminalViewRepresentable(session: session)
            if !session.isRunning {
                VStack {
                    Spacer()
                    Text("Session beendet")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.8)))
                        .padding(.bottom, 8)
                }
            }
        }
    }
}
