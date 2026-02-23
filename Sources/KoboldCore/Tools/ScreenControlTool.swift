#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import Vision

// MARK: - ScreenControlTool — Mouse, keyboard, screenshots, OCR for visual automation

public struct ScreenControlTool: Tool, Sendable {

    public let name = "screen_control"
    public let description = "Bildschirm-Kontrolle: Screenshots, Maus bewegen/klicken, Tastatur tippen, Text auf Bildschirm finden (OCR). Für visuelle PC-Automatisierung."
    public let riskLevel: RiskLevel = .critical

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion: screenshot, mouse_move, mouse_click, mouse_double_click, key_type, key_press, get_screen_size, find_text, get_mouse_position",
                    enumValues: ["screenshot", "mouse_move", "mouse_click", "mouse_double_click", "key_type", "key_press", "get_screen_size", "find_text", "get_mouse_position"],
                    required: true
                ),
                "x": ToolSchemaProperty(
                    type: "string",
                    description: "X-Koordinate in Pixel (für mouse_move, mouse_click)"
                ),
                "y": ToolSchemaProperty(
                    type: "string",
                    description: "Y-Koordinate in Pixel (für mouse_move, mouse_click)"
                ),
                "text": ToolSchemaProperty(
                    type: "string",
                    description: "Text zum Tippen (key_type) oder zum Suchen auf dem Bildschirm (find_text)"
                ),
                "key": ToolSchemaProperty(
                    type: "string",
                    description: "Taste für key_press: return, tab, escape, space, delete, up, down, left, right, cmd+c, cmd+v, cmd+a, cmd+z, shift+tab, etc."
                ),
                "region": ToolSchemaProperty(
                    type: "string",
                    description: "Screenshot-Region: 'full' (Standard) oder 'x,y,width,height'"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard UserDefaults.standard.bool(forKey: "kobold.perm.screenControl") else {
            throw ToolError.unauthorized("Bildschirmsteuerung ist in den Einstellungen deaktiviert. Aktiviere es unter Berechtigungen.")
        }

        let action = arguments["action"] ?? ""

        switch action {
        case "screenshot":
            return try captureScreen(region: arguments["region"])

        case "mouse_move":
            guard let x = Double(arguments["x"] ?? ""), let y = Double(arguments["y"] ?? "") else {
                throw ToolError.missingRequired("x und y Koordinaten erforderlich")
            }
            return moveMouse(x: x, y: y)

        case "mouse_click":
            guard let x = Double(arguments["x"] ?? ""), let y = Double(arguments["y"] ?? "") else {
                throw ToolError.missingRequired("x und y Koordinaten erforderlich")
            }
            return clickMouse(x: x, y: y, double: false)

        case "mouse_double_click":
            guard let x = Double(arguments["x"] ?? ""), let y = Double(arguments["y"] ?? "") else {
                throw ToolError.missingRequired("x und y Koordinaten erforderlich")
            }
            return clickMouse(x: x, y: y, double: true)

        case "key_type":
            guard let text = arguments["text"], !text.isEmpty else {
                throw ToolError.missingRequired("text zum Tippen erforderlich")
            }
            return typeText(text)

        case "key_press":
            guard let key = arguments["key"], !key.isEmpty else {
                throw ToolError.missingRequired("Taste erforderlich (z.B. 'return', 'cmd+c')")
            }
            return pressKey(key)

        case "get_screen_size":
            return getScreenSize()

        case "get_mouse_position":
            return getMousePosition()

        case "find_text":
            guard let text = arguments["text"], !text.isEmpty else {
                throw ToolError.missingRequired("Suchtext erforderlich")
            }
            return try await findTextOnScreen(text)

        default:
            throw ToolError.invalidParameter("action", "Unbekannte Aktion: \(action)")
        }
    }

    // MARK: - Screenshot

    private func captureScreen(region: String?) throws -> String {
        let id = UUID().uuidString.prefix(8)
        let path = "/tmp/kobold_screen_\(id).png"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        if let region = region, region != "full", region.contains(",") {
            let parts = region.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                process.arguments = ["-x", "-R", "\(parts[0]),\(parts[1]),\(parts[2]),\(parts[3])", "-t", "png", path]
            } else {
                process.arguments = ["-x", "-t", "png", path]
            }
        } else {
            process.arguments = ["-x", "-t", "png", path]
        }

        try process.run()
        process.waitUntilExit()

        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.executionFailed("Screenshot fehlgeschlagen. Eventuell fehlen Bildschirmaufnahme-Berechtigungen (Systemeinstellungen → Datenschutz → Bildschirmaufnahme).")
        }

        return "Screenshot gespeichert: \(path)"
    }

    // MARK: - Mouse

    private func moveMouse(x: Double, y: Double) -> String {
        let point = CGPoint(x: x, y: y)
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
        return "Maus bewegt zu (\(Int(x)), \(Int(y)))"
    }

    private func clickMouse(x: Double, y: Double, double: Bool) -> String {
        let point = CGPoint(x: x, y: y)

        // Move first
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)

        let clickCount: Int64 = double ? 2 : 1

        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: clickCount)
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.02)
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: clickCount)
            up.post(tap: .cghidEventTap)
        }

        return double ? "Doppelklick bei (\(Int(x)), \(Int(y)))" : "Klick bei (\(Int(x)), \(Int(y)))"
    }

    private func getMousePosition() -> String {
        let pos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        // Convert from bottom-left to top-left coordinate system
        return "Maus-Position: (\(Int(pos.x)), \(Int(screenHeight - pos.y)))"
    }

    // MARK: - Keyboard

    private func typeText(_ text: String) -> String {
        // Use CGEvent keyboard input for each character
        for char in text {
            let str = String(char) as NSString
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                var buffer = [UniChar](repeating: 0, count: 1)
                str.getCharacters(&buffer, range: NSRange(location: 0, length: 1))
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
                event.post(tap: .cghidEventTap)
            }
            if let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                eventUp.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return "Text getippt: \(text.prefix(50))\(text.count > 50 ? "..." : "")"
    }

    private func pressKey(_ keyCombo: String) -> String {
        let parts = keyCombo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode = 0

        for part in parts {
            switch part {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "shift":           flags.insert(.maskShift)
            case "alt", "option":   flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "return", "enter": keyCode = 36
            case "tab":             keyCode = 48
            case "space":           keyCode = 49
            case "delete", "backspace": keyCode = 51
            case "escape", "esc":   keyCode = 53
            case "up":              keyCode = 126
            case "down":            keyCode = 125
            case "left":            keyCode = 123
            case "right":           keyCode = 124
            case "a": keyCode = 0;  case "b": keyCode = 11; case "c": keyCode = 8
            case "d": keyCode = 2;  case "e": keyCode = 14; case "f": keyCode = 3
            case "g": keyCode = 5;  case "h": keyCode = 4;  case "i": keyCode = 34
            case "j": keyCode = 38; case "k": keyCode = 40; case "l": keyCode = 37
            case "m": keyCode = 46; case "n": keyCode = 45; case "o": keyCode = 31
            case "p": keyCode = 35; case "q": keyCode = 12; case "r": keyCode = 15
            case "s": keyCode = 1;  case "t": keyCode = 17; case "u": keyCode = 32
            case "v": keyCode = 9;  case "w": keyCode = 13; case "x": keyCode = 7
            case "y": keyCode = 16; case "z": keyCode = 6
            default: break
            }
        }

        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }

        return "Taste gedrückt: \(keyCombo)"
    }

    // MARK: - Screen Info

    private func getScreenSize() -> String {
        let w = CGDisplayPixelsWide(CGMainDisplayID())
        let h = CGDisplayPixelsHigh(CGMainDisplayID())
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        return "Bildschirm: \(w) x \(h) Pixel (Skalierung: \(scale)x)"
    }

    // MARK: - OCR / Find Text

    private func findTextOnScreen(_ searchText: String) async throws -> String {
        // 1. Take screenshot
        let path = "/tmp/kobold_ocr_\(UUID().uuidString.prefix(8)).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", path]
        try process.run()
        process.waitUntilExit()

        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ToolError.executionFailed("Screenshot für OCR fehlgeschlagen")
        }

        // 2. Use Vision framework for OCR
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return "Kein Text auf dem Bildschirm erkannt."
        }

        var found: [(String, CGRect)] = []
        let screenH = CGFloat(cgImage.height)

        for obs in observations {
            let text = obs.topCandidates(1).first?.string ?? ""
            if text.localizedCaseInsensitiveContains(searchText) {
                let box = obs.boundingBox
                // Convert normalized coordinates to pixel coordinates
                let pixelRect = CGRect(
                    x: box.origin.x * CGFloat(cgImage.width),
                    y: (1 - box.origin.y - box.height) * screenH,
                    width: box.width * CGFloat(cgImage.width),
                    height: box.height * screenH
                )
                found.append((text, pixelRect))
            }
        }

        // Clean up
        try? FileManager.default.removeItem(atPath: path)

        if found.isEmpty {
            return "Text '\(searchText)' nicht auf dem Bildschirm gefunden. Erkannte Texte: \(observations.prefix(10).compactMap { $0.topCandidates(1).first?.string }.joined(separator: ", "))"
        }

        let results = found.map { (text, rect) in
            "'\(text)' bei Position (\(Int(rect.midX)), \(Int(rect.midY))) [Bereich: \(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))]"
        }.joined(separator: "\n")

        return "Text '\(searchText)' gefunden:\n\(results)"
    }
}
#endif
