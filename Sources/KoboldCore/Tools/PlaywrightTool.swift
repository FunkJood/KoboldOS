#if os(macOS)
import Foundation

// MARK: - PlaywrightTool — Chrome browser automation via Playwright (Node.js)

public struct PlaywrightTool: Tool, Sendable {

    public let name = "playwright"
    public let description = "Browser-Automatisierung mit Chrome via Playwright. Volle DOM-Kontrolle, Screenshots, Formular-Ausfüllung, JavaScript-Ausführung. Immer Chrome."
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Aktion: navigate, click, fill, screenshot, evaluate, get_text, get_html, wait",
                    enumValues: ["navigate", "click", "fill", "screenshot", "evaluate", "get_text", "get_html", "wait"],
                    required: true
                ),
                "url": ToolSchemaProperty(
                    type: "string",
                    description: "URL für navigate-Aktion"
                ),
                "selector": ToolSchemaProperty(
                    type: "string",
                    description: "CSS-Selektor für click/fill/get_text/get_html"
                ),
                "value": ToolSchemaProperty(
                    type: "string",
                    description: "Wert für fill-Aktion oder Millisekunden für wait"
                ),
                "script": ToolSchemaProperty(
                    type: "string",
                    description: "JavaScript-Code für evaluate-Aktion"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard UserDefaults.standard.bool(forKey: "kobold.perm.playwright") else {
            throw ToolError.unauthorized("Playwright ist in den Einstellungen deaktiviert. Aktiviere es unter Berechtigungen.")
        }

        let action = arguments["action"] ?? ""
        let script = buildScript(action: action, arguments: arguments)

        let process = Process()
        let nodePath = findNodePath()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["-e", script]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            if errOutput.contains("Cannot find module") {
                throw ToolError.executionFailed("Playwright nicht installiert. Bitte ausführen: npm install -g playwright && npx playwright install chromium")
            }
            throw ToolError.executionFailed(errOutput.prefix(500).isEmpty ? "Playwright Fehler (Exit \(process.terminationStatus))" : String(errOutput.prefix(500)))
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findNodePath() -> String {
        let paths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/env"
    }

    private func buildScript(action: String, arguments: [String: String]) -> String {
        let url = sanitize(arguments["url"] ?? "")
        let selector = sanitize(arguments["selector"] ?? "")
        let value = sanitize(arguments["value"] ?? "")
        let script = arguments["script"] ?? ""

        // State file for persistent browser session
        let stateFile = "/tmp/kobold_playwright_state.json"

        switch action {
        case "navigate":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                await page.goto('\(url)', {timeout: 30000, waitUntil: 'domcontentloaded'});
                const title = await page.title();
                const text = await page.innerText('body').catch(() => '');
                console.log('Titel: ' + title + '\\n\\nInhalt (gekürzt):\\n' + text.substring(0, 2000));
                await ctx.storageState({path: '\(stateFile)'});
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "click":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                await page.click('\(selector)', {timeout: 10000});
                console.log('Geklickt: \(selector)');
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "fill":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                await page.fill('\(selector)', '\(value)', {timeout: 10000});
                console.log('Ausgefüllt: \(selector) = \(value)');
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "screenshot":
            let path = "/tmp/kobold_screenshot_\(UUID().uuidString.prefix(8)).png"
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                if ('\(url)') await page.goto('\(url)', {waitUntil: 'domcontentloaded'});
                await page.screenshot({path: '\(path)', fullPage: true});
                console.log('Screenshot gespeichert: \(path)');
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "evaluate":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                if ('\(url)') await page.goto('\(url)', {waitUntil: 'domcontentloaded'});
                const result = await page.evaluate(() => { \(script) });
                console.log(JSON.stringify(result, null, 2));
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "get_text":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                if ('\(url)') await page.goto('\(url)', {waitUntil: 'domcontentloaded'});
                const text = await page.innerText('\(selector.isEmpty ? "body" : selector)');
                console.log(text.substring(0, 4000));
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "get_html":
            return """
            const {chromium} = require('playwright');
            (async () => {
                const browser = await chromium.launch({channel: 'chrome', headless: false});
                const ctx = await browser.newContext();
                const page = await ctx.newPage();
                if ('\(url)') await page.goto('\(url)', {waitUntil: 'domcontentloaded'});
                const html = await page.innerHTML('\(selector.isEmpty ? "body" : selector)');
                console.log(html.substring(0, 4000));
                await browser.close();
            })().catch(e => { console.error(e.message); process.exit(1); });
            """

        case "wait":
            let ms = Int(value) ?? 1000
            return """
            const {chromium} = require('playwright');
            (async () => {
                await new Promise(r => setTimeout(r, \(ms)));
                console.log('Gewartet: \(ms)ms');
            })();
            """

        default:
            return "console.error('Unbekannte Aktion: \(action)'); process.exit(1);"
        }
    }

    private func sanitize(_ input: String) -> String {
        input.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
#endif
