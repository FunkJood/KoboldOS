import Foundation

// MARK: - App Browser Tool
// Lets the agent control the in-app browser via NotificationCenter → SharedBrowserManager

public struct AppBrowserTool: Tool, @unchecked Sendable {
    public let name = "app_browser"
    public let description = """
        Control the in-app web browser. Actions: navigate, read_page, inspect, click, type, \
        execute_js, screenshot, new_tab, close_tab, list_tabs, snapshot, dismiss_popup, wait_for_load, submit_form. \
        \
        WORKFLOW for web interaction: \
        1. navigate to URL → 2. wait_for_load → 3. read_page or inspect to see elements → 4. interact (click/type/submit_form). \
        ALWAYS inspect or read_page FIRST before clicking — never guess selectors. \
        After clicking links/buttons that load new pages, use wait_for_load before reading again. \
        \
        LOGIN FLOWS (multi-step): Navigate to login page → wait_for_load → inspect to find email field → \
        type email → click next/submit → wait_for_load → inspect again (page changed!) → type password → click submit → wait_for_load. \
        Each step may load a new page — always wait_for_load + inspect between steps. \
        \
        COOKIE BANNERS: Use dismiss_popup first if a cookie banner blocks interaction. \
        FORM SUBMISSION: Use submit_form after typing to submit the form containing the element. \
        SCROLLING: Use execute_js with window.scrollBy(0, 500) to scroll down if elements are not visible.
        """
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action to perform. Use inspect/read_page first to find selectors!",
                    enumValues: ["navigate", "read_page", "inspect", "click", "type", "execute_js", "screenshot", "new_tab", "close_tab", "list_tabs", "snapshot", "dismiss_popup", "wait_for_load", "submit_form", "wait"],
                    required: true
                ),
                "url": ToolSchemaProperty(
                    type: "string",
                    description: "URL to navigate to (for navigate action)"
                ),
                "selector": ToolSchemaProperty(
                    type: "string",
                    description: "CSS selector for click/type/submit_form actions. Use #id, [name=...], or tag.class format."
                ),
                "text": ToolSchemaProperty(
                    type: "string",
                    description: "Text to type (for type action). For wait action: duration in milliseconds (default 1000)."
                ),
                "js": ToolSchemaProperty(
                    type: "string",
                    description: "JavaScript code to execute (for execute_js action)"
                ),
                "tab_id": ToolSchemaProperty(
                    type: "string",
                    description: "Target tab UUID (optional, defaults to active tab)"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard let action = arguments["action"] else {
            throw ToolError.missingRequired("action")
        }

        guard permissionEnabled("kobold.permission.appBrowser", defaultValue: true) else {
            return "[App-Browser-Steuerung ist deaktiviert. Aktiviere sie in Einstellungen → Apps.]"
        }

        let resultId = UUID().uuidString
        let tabId = arguments["tab_id"]

        var userInfo: [String: Any] = [
            "action": action,
            "tab_id": tabId ?? "",
            "result_id": resultId
        ]

        switch action {
        case "navigate":
            guard let url = arguments["url"], !url.isEmpty else {
                throw ToolError.missingRequired("url")
            }
            userInfo["url"] = url

        case "click":
            guard let selector = arguments["selector"], !selector.isEmpty else {
                throw ToolError.missingRequired("selector")
            }
            userInfo["selector"] = selector

        case "type":
            guard let selector = arguments["selector"], !selector.isEmpty else {
                throw ToolError.missingRequired("selector")
            }
            guard let text = arguments["text"] else {
                throw ToolError.missingRequired("text")
            }
            userInfo["selector"] = selector
            userInfo["text"] = text

        case "submit_form":
            guard let selector = arguments["selector"], !selector.isEmpty else {
                throw ToolError.missingRequired("selector")
            }
            userInfo["selector"] = selector

        case "execute_js":
            let jsCode = arguments["js"] ?? arguments["script"] ?? ""
            guard !jsCode.isEmpty else {
                throw ToolError.missingRequired("js")
            }
            userInfo["js"] = jsCode

        case "wait":
            // Explizites Warten (z.B. nach Klick auf "Weiter" bei mehrstufigen Logins)
            let durationMs = Int(arguments["text"] ?? "1000") ?? 1000
            let clampedMs = min(max(durationMs, 100), 10000) // 100ms bis 10s
            try await Task.sleep(nanoseconds: UInt64(clampedMs) * 1_000_000)
            return "Waited \(clampedMs)ms"

        case "read_page", "inspect", "screenshot", "new_tab", "close_tab", "list_tabs", "snapshot", "dismiss_popup", "wait_for_load":
            if let url = arguments["url"] { userInfo["url"] = url }
            break

        default:
            return "[Unbekannte Aktion: \(action)]"
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldAppBrowserAction"),
                object: nil,
                userInfo: userInfo
            )
        }


        let timeout: TimeInterval
        switch action {
        case "wait_for_load": timeout = 15
        case "screenshot", "read_page": timeout = 15
        case "navigate": timeout = 12
        default: timeout = 10
        }

        let result = await AppToolResultWaiter.shared.waitForResult(id: resultId, timeout: timeout)
        return result ?? "[Timeout bei Browser-Aktion: \(action)]"
    }
}
