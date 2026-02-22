import Foundation

public struct AgentStep: Sendable {
    public let tool: String
    public let args: String      // JSON-encoded args
    public let result: String
    public let durationMs: Int

    public init(tool: String, args: String, result: String, durationMs: Int) {
        self.tool = tool
        self.args = args
        self.result = result
        self.durationMs = durationMs
    }
}

public actor ToolEngine {
    private let maxOutput = 8192

    public static let shared = ToolEngine()
    private init() {}

    // MARK: - Dispatch

    public func execute(name: String, argsJSON: String) async -> String {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: invalid args JSON"
        }

        let result: String
        switch name {
        case "bash":
            let cmd = args["command"] as? String ?? ""
            result = await bash(cmd)
        case "read_file":
            let path = args["path"] as? String ?? ""
            result = readFile(path)
        case "write_file":
            let path    = args["path"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            result = writeFile(path, content: content)
        case "list_dir":
            let path = args["path"] as? String ?? ""
            result = listDir(path)
        case "web_fetch":
            let url = args["url"] as? String ?? ""
            result = await webFetch(url)
        case "google_api":
            let endpoint = args["endpoint"] as? String ?? ""
            let method = args["method"] as? String ?? "GET"
            let paramsStr = args["params"] as? String ?? "{}"
            let body = args["body"] as? String
            var params: [String: String]? = nil
            if let pData = paramsStr.data(using: .utf8),
               let pDict = try? JSONSerialization.jsonObject(with: pData) as? [String: String] {
                params = pDict
            }
            result = await googleApi(endpoint: endpoint, method: method, params: params, body: body)
        default:
            result = "Error: unknown tool '\(name)'"
        }

        let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        print("[Tool:\(name)] \(ms)ms → \(result.prefix(80))")
        return result
    }

    // MARK: - bash

    private func bash(_ command: String) async -> String {
        guard !command.isEmpty else { return "Error: empty command" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        // Collect pipe data via readabilityHandler (non-blocking, Sendable-safe)
        final class PipeCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _data = Data()
            func append(_ chunk: Data) { lock.lock(); _data.append(chunk); lock.unlock() }
            var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
        }
        let outCollector = PipeCollector()
        let errCollector = PipeCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outCollector.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errCollector.append(chunk)
        }

        do {
            try process.run()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return "Error: \(error.localizedDescription)"
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        var out = String(data: outCollector.data, encoding: .utf8) ?? ""
        let err = String(data: errCollector.data, encoding: .utf8) ?? ""

        if !err.isEmpty { out += (out.isEmpty ? "" : "\n") + "stderr: \(err)" }
        if out.isEmpty  { out = "(exit code: \(process.terminationStatus))" }
        return truncate(out)
    }

    // MARK: - file ops

    private func readFile(_ path: String) -> String {
        let p = NSString(string: path).expandingTildeInPath
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            return "Error: cannot read '\(path)'"
        }
        return truncate(text)
    }

    private func writeFile(_ path: String, content: String) -> String {
        let p = NSString(string: path).expandingTildeInPath
        let dir = URL(fileURLWithPath: p).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(toFile: p, atomically: true, encoding: .utf8)
            return "Written \(content.utf8.count) bytes to \(path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func listDir(_ path: String) -> String {
        let p = NSString(string: path).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: p) else {
            return "Error: cannot list '\(path)'"
        }
        return items.sorted().joined(separator: "\n")
    }

    // MARK: - web_fetch

    private func webFetch(_ urlString: String) async -> String {
        guard let url = URL(string: urlString) else { return "Error: invalid URL" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 KoboldOS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let raw = String(data: data, encoding: .utf8) ?? ""
            // Strip HTML tags
            let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                              .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                              .trimmingCharacters(in: .whitespacesAndNewlines)
            return truncate(stripped.isEmpty ? "(empty)" : stripped)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func truncate(_ s: String) -> String {
        if s.utf8.count <= maxOutput { return s }
        return String(s.prefix(maxOutput)) + "\n…(truncated)"
    }
}

// MARK: - Tool definitions for system prompt

public let toolSystemPrompt = """
You are KoboldOS — a powerful AI assistant running locally on macOS with full system access.

## Tools
Use tools by outputting a tool call block. One tool per block. Wait for results before proceeding.

<tool_call>
{"name": "TOOL_NAME", "args": {JSON_ARGS}}
</tool_call>

### Available Tools

**bash** — Run any shell command (zsh/bash)
`{"name": "bash", "args": {"command": "ls -la ~/Desktop"}}`

**read_file** — Read a file
`{"name": "read_file", "args": {"path": "~/Documents/notes.txt"}}`

**write_file** — Write content to a file
`{"name": "write_file", "args": {"path": "~/output.txt", "content": "Hello"}}`

**list_dir** — List directory contents
`{"name": "list_dir", "args": {"path": "~/Desktop"}}`

**web_fetch** — Fetch a webpage (HTML stripped to text)
`{"name": "web_fetch", "args": {"url": "https://example.com"}}`

**google_api** — Make authenticated Google API requests (YouTube, Drive, Gmail, Calendar, etc.)
`{"name": "google_api", "args": {"endpoint": "youtube/v3/search", "method": "GET", "params": "{\"part\": \"snippet\", \"q\": \"test\"}"}}`

## Rules
- Use tools proactively when the user asks you to interact with the system
- Chain multiple tool calls if needed (one at a time, wait for result)
- After getting tool results, summarize concisely
- For destructive operations (rm, format, etc.), confirm with the user first
- Be concise. No need to explain what you're doing if it's obvious from the tool call
"""
