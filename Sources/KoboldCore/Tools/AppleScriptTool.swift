#if os(macOS)
import Foundation

// MARK: - AppleScriptTool (macOS implementation)
public struct AppleScriptTool: Tool, Sendable {
    public let name = "applescript"
    public let description = "Steuere macOS-Apps (Safari, Messages, Mail) via AppleScript"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "app": ToolSchemaProperty(
                    type: "string",
                    description: "Ziel-App: safari, messages, mail",
                    enumValues: ["safari", "messages", "mail"],
                    required: true
                ),
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion: open_url, get_tabs, get_page_content, click_link, fill_form, send_message, read_recent, send_email, read_inbox",
                    required: true
                ),
                "params": ToolSchemaProperty(
                    type: "string",
                    description: "JSON-Objekt mit Parametern (z.B. {\"url\": \"...\", \"to\": \"...\", \"text\": \"...\"})"
                )
            ],
            required: ["app", "action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let app = (arguments["app"] ?? "").lowercased()
        // Check mail permission for messages/mail apps
        if app == "mail" || app == "messages" {
            guard permissionEnabled("kobold.perm.mail", defaultValue: false) else {
                return "Mail/Nachrichten-Zugriff ist in den Einstellungen deaktiviert. Bitte unter Einstellungen → Berechtigungen aktivieren."
            }
        }
        let action = (arguments["action"] ?? "").lowercased()
        let paramsStr = arguments["params"] ?? "{}"
        let params = (try? JSONSerialization.jsonObject(with: Data(paramsStr.utf8)) as? [String: String]) ?? [:]

        let script: String
        switch app {
        case "safari":
            script = try safariScript(action: action, params: params)
        case "messages":
            script = try messagesScript(action: action, params: params)
        case "mail":
            script = try mailScript(action: action, params: params)
        default:
            throw ToolError.invalidParameter("app", "Unbekannte App: \(app). Erlaubt: safari, messages, mail")
        }

        return try await runOsascript(script)
    }

    // MARK: - Safari Scripts

    private func safariScript(action: String, params: [String: String]) throws -> String {
        switch action {
        case "open_url":
            guard let url = params["url"], !url.isEmpty else {
                throw ToolError.missingRequired("params.url")
            }
            return """
            tell application "Safari"
                activate
                open location "\(sanitize(url))"
            end tell
            return "OK: URL geöffnet"
            """
        case "get_tabs":
            return """
            tell application "Safari"
                set tabList to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabList to tabList & (name of t) & " | " & (URL of t) & linefeed
                    end repeat
                end repeat
                return tabList
            end tell
            """
        case "get_page_content":
            return """
            tell application "Safari"
                set pageText to do JavaScript "document.body.innerText.substring(0, 5000)" in current tab of front window
                return pageText
            end tell
            """
        default:
            throw ToolError.invalidParameter("action", "Unbekannte Safari-Aktion: \(action)")
        }
    }

    // MARK: - Messages Scripts

    private func messagesScript(action: String, params: [String: String]) throws -> String {
        switch action {
        case "send_message":
            guard let to = params["to"], !to.isEmpty else {
                throw ToolError.missingRequired("params.to")
            }
            guard let text = params["text"], !text.isEmpty else {
                throw ToolError.missingRequired("params.text")
            }
            return """
            tell application "Messages"
                set targetBuddy to buddy "\(sanitize(to))" of service 1
                send "\(sanitize(text))" to targetBuddy
            end tell
            return "OK: Nachricht gesendet an \(sanitize(to))"
            """
        case "read_recent":
            let count = Int(params["count"] ?? "5") ?? 5
            return """
            tell application "Messages"
                set chatList to ""
                set recentChats to chats
                set maxChats to \(min(count, 20))
                set chatCount to 0
                repeat with c in recentChats
                    if chatCount >= maxChats then exit repeat
                    set chatCount to chatCount + 1
                    set chatList to chatList & "Chat: " & (name of c) & linefeed
                end repeat
                return chatList
            end tell
            """
        default:
            throw ToolError.invalidParameter("action", "Unbekannte Messages-Aktion: \(action)")
        }
    }

    // MARK: - Mail Scripts

    private func mailScript(action: String, params: [String: String]) throws -> String {
        switch action {
        case "send_email":
            guard let to = params["to"], !to.isEmpty else {
                throw ToolError.missingRequired("params.to")
            }
            let subject = params["subject"] ?? "KoboldOS"
            let body = params["body"] ?? ""
            return """
            tell application "Mail"
                set newMessage to make new outgoing message with properties {subject:"\(sanitize(subject))", content:"\(sanitize(body))", visible:true}
                tell newMessage
                    make new to recipient at end of to recipients with properties {address:"\(sanitize(to))"}
                end tell
                send newMessage
            end tell
            return "OK: E-Mail gesendet an \(sanitize(to))"
            """
        case "read_inbox":
            let count = Int(params["count"] ?? "5") ?? 5
            return """
            tell application "Mail"
                set mailList to ""
                set msgs to messages of inbox
                set maxMsgs to \(min(count, 20))
                set msgCount to 0
                repeat with m in msgs
                    if msgCount >= maxMsgs then exit repeat
                    set msgCount to msgCount + 1
                    set mailList to mailList & "Von: " & (sender of m) & " | Betreff: " & (subject of m) & linefeed
                end repeat
                return mailList
            end tell
            """
        default:
            throw ToolError.invalidParameter("action", "Unbekannte Mail-Aktion: \(action)")
        }
    }

    // MARK: - Execution

    private func runOsascript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Atomic flag to prevent double-resume (timer + terminationHandler race)
            nonisolated(unsafe) let resumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            resumed.initialize(to: false)

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 30)
            timer.setEventHandler {
                guard !resumed.pointee else { return }
                resumed.pointee = true
                process.terminate()
                continuation.resume(throwing: ToolError.timeout)
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()
                guard !resumed.pointee else {
                    resumed.deinitialize(count: 1)
                    resumed.deallocate()
                    return
                }
                resumed.pointee = true
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: ToolError.executionFailed(err.isEmpty ? "Exit \(proc.terminationStatus)" : err))
                }
                resumed.deinitialize(count: 1)
                resumed.deallocate()
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                guard !resumed.pointee else {
                    resumed.deinitialize(count: 1)
                    resumed.deallocate()
                    return
                }
                resumed.pointee = true
                continuation.resume(throwing: ToolError.executionFailed(error.localizedDescription))
                resumed.deinitialize(count: 1)
                resumed.deallocate()
            }
        }
    }

    /// Sanitize strings for AppleScript to prevent injection
    private func sanitize(_ input: String) -> String {
        input.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

#elseif os(Linux)
import Foundation

// MARK: - AppleScriptTool (Linux implementation - placeholder)
public struct AppleScriptTool: Tool, Sendable {
    public let name = "applescript"
    public let description = "Steuere macOS-Apps via AppleScript (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "app": ToolSchemaProperty(
                    type: "string",
                    description: "Ziel-App: safari, messages, mail",
                    enumValues: ["safari", "messages", "mail"],
                    required: true
                ),
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion",
                    required: true
                )
            ],
            required: ["app", "action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        return "AppleScript-Funktionen sind auf Linux deaktiviert, da sie macOS-spezifisch sind."
    }
}
#endif