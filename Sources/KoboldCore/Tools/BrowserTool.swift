import Foundation

// MARK: - BrowserTool — HTTP-based web browsing (no WebKit dependency for CLI)

public struct BrowserTool: Tool, Sendable {

    public let name = "browser"
    public let description = "Fetch web pages, search the web, and download content via HTTP"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action: fetch, search",
                    enumValues: ["fetch", "search"],
                    required: true
                ),
                "url": ToolSchemaProperty(
                    type: "string",
                    description: "URL to fetch (for fetch action)"
                ),
                "query": ToolSchemaProperty(
                    type: "string",
                    description: "Search query (for search action)"
                ),
                "method": ToolSchemaProperty(
                    type: "string",
                    description: "HTTP method: GET, POST, PUT, DELETE (default: GET)"
                ),
                "headers": ToolSchemaProperty(
                    type: "string",
                    description: "JSON string of HTTP headers, e.g. {\"Authorization\": \"Bearer token\"}"
                ),
                "body": ToolSchemaProperty(
                    type: "string",
                    description: "Request body for POST/PUT"
                ),
                "timeout": ToolSchemaProperty(
                    type: "string",
                    description: "Timeout in seconds (default 15, max 60)"
                )
            ],
            required: ["action"]
        )
    }

    // Blocked URL patterns (security)
    private let blockedPatterns = [
        "localhost", "127.0.0.1", "0.0.0.0",
        "192.168.", "10.0.", "172.16.", "172.17.",
        "file://", "ftp://", "ssh://", "telnet://",
        "::1", "[::1]"
    ]

    private let maxResponseSize = 2 * 1024 * 1024 // 2MB

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        if action == "fetch" {
            guard let url = arguments["url"], !url.isEmpty else {
                throw ToolError.missingRequired("url (required for fetch action)")
            }
            try validateURL(url)
        } else if action == "search" {
            guard let q = arguments["query"], !q.isEmpty else {
                throw ToolError.missingRequired("query (required for search action)")
            }
        } else {
            throw ToolError.invalidParameter("action", "must be 'fetch' or 'search'")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let timeoutStr = arguments["timeout"] ?? "15"
        let timeout = min(Double(timeoutStr) ?? 15.0, 60.0)
        let method = arguments["method"]?.uppercased() ?? "GET"
        let headersJSON = arguments["headers"]
        let body = arguments["body"]

        switch action {
        case "fetch":
            let url = arguments["url"] ?? ""
            return try await fetchURL(url, timeout: timeout, method: method, headersJSON: headersJSON, body: body)
        case "search":
            let query = arguments["query"] ?? ""
            return try await searchWeb(query: query, timeout: timeout)
        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }

    // MARK: - URL Validation

    private func validateURL(_ urlStr: String, isInternal: Bool = false) throws {
        // Skip blocked patterns for internal requests (SearXNG search engine)
        if !isInternal {
            let lower = urlStr.lowercased()
            for pattern in blockedPatterns {
                if lower.contains(pattern) {
                    throw ToolError.networkError("Blocked URL pattern: \(pattern)")
                }
            }
        }

        guard let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw ToolError.invalidParameter("url", "Must be a valid http:// or https:// URL")
        }

        guard url.host != nil else {
            throw ToolError.invalidParameter("url", "URL must have a valid host")
        }
    }

    // MARK: - HTTP Status Descriptions

    private func statusDescription(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found (Redirect)"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "HTTP \(code)"
        }
    }

    // MARK: - Fetch

    private func fetchURL(_ urlStr: String, timeout: TimeInterval, method: String = "GET", headersJSON: String? = nil, body: String? = nil, isInternal: Bool = false) async throws -> String {
        guard let url = URL(string: urlStr) else {
            throw ToolError.networkError("Invalid URL: \(urlStr)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("KoboldOS/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain,application/json", forHTTPHeaderField: "Accept")

        // Parse and apply custom headers
        if let headersJSON, !headersJSON.isEmpty,
           let headersData = headersJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Apply body for POST/PUT
        if let body, !body.isEmpty, ["POST", "PUT", "PATCH"].contains(method) {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw ToolError.networkError("No HTTP response")
            }

            if data.count > maxResponseSize {
                throw ToolError.networkError("Response too large (\(data.count / 1024)KB > 2MB limit)")
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            var text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "[Binary data, \(data.count) bytes]"

            // Extract readable text from HTML
            if contentType.contains("html") {
                text = extractTextFromHTML(text)
            }

            return """
            URL: \(urlStr)
            Method: \(method)
            Status: \(http.statusCode) \(statusDescription(http.statusCode))
            Content-Type: \(contentType)
            Size: \(data.count) bytes
            ---
            \(text.prefix(16000))
            """
        } catch let e as URLError {
            throw ToolError.networkError("Network error (\(e.code.rawValue)): \(e.localizedDescription)")
        }
    }

    // MARK: - Search (DuckDuckGo HTML — reliable, no API key, no JS needed)

    private func searchWeb(query: String, timeout: TimeInterval) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // 1. Try local SearXNG first (isInternal=true bypasses localhost block)
        let searxURL = "http://localhost:4000/search?q=\(encoded)&format=json"
        if let searxResult = try? await fetchURL(searxURL, timeout: 5, isInternal: true) {
            let parsed = parseSearXNGResults(searxResult)
            if !parsed.isEmpty { return "Suchergebnisse für: \(query)\n\n\(parsed)" }
        }

        // 2. DuckDuckGo HTML (works reliably, server-rendered, no JS needed)
        if let ddgResults = try? await searchDuckDuckGoHTML(query: query, encoded: encoded, timeout: timeout) {
            if !ddgResults.isEmpty { return "Suchergebnisse für: \(query)\n\n\(ddgResults)" }
        }

        return "Keine Suchergebnisse für: \(query). Versuche eine andere Suche oder nutze 'fetch' mit einer konkreten URL."
    }

    // MARK: - DuckDuckGo HTML Search

    private func searchDuckDuckGoHTML(query: String, encoded: String, timeout: TimeInterval) async throws -> String {
        let ddgURL = "https://html.duckduckgo.com/html/?q=\(encoded)"

        guard let url = URL(string: ddgURL) else { return "" }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9,de;q=0.8", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return "" }
        guard let html = String(data: data, encoding: .utf8) else { return "" }

        return parseDuckDuckGoResults(html)
    }

    private func parseDuckDuckGoResults(_ html: String) -> String {
        var results: [(title: String, url: String, snippet: String)] = []

        // DDG HTML uses multi-class divs like <div class="links_main links_deep result__body">
        // Split on "result__body" (not class="result__body") to handle multi-class attributes
        let segments = html.components(separatedBy: "result__body")
        for segment in segments.dropFirst().prefix(10) {
            // Skip ads
            if segment.contains("result--ad") || segment.contains("badge--ad") { continue }

            // Title from <a class="result__a"
            var title = ""
            if let aStart = segment.range(of: "result__a"),
               let aContentStart = segment.range(of: ">", range: aStart.upperBound..<segment.endIndex),
               let aEnd = segment.range(of: "</a>", range: aContentStart.upperBound..<segment.endIndex) {
                title = stripHTMLTags(String(segment[aContentStart.upperBound..<aEnd.lowerBound]))
            }

            // URL from href in the result__a link
            var resultURL = ""
            if let hrefStart = segment.range(of: "result__a"),
               let hrefAttr = segment.range(of: "href=\"", range: segment.startIndex..<(hrefStart.upperBound)),
               let hrefEnd = segment.range(of: "\"", range: hrefAttr.upperBound..<segment.endIndex) {
                resultURL = String(segment[hrefAttr.upperBound..<hrefEnd.lowerBound])
            }
            // Fallback: result__url class
            if resultURL.isEmpty || resultURL.contains("duckduckgo.com") {
                if let urlStart = segment.range(of: "result__url"),
                   let urlContentStart = segment.range(of: ">", range: urlStart.upperBound..<segment.endIndex),
                   let urlEnd = segment.range(of: "<", range: urlContentStart.upperBound..<segment.endIndex) {
                    resultURL = String(segment[urlContentStart.upperBound..<urlEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !resultURL.isEmpty && !resultURL.hasPrefix("http") { resultURL = "https://\(resultURL)" }
            // Decode DDG redirect URLs
            if resultURL.contains("duckduckgo.com/l/?uddg="),
               let uddg = resultURL.components(separatedBy: "uddg=").last?.components(separatedBy: "&").first,
               let decoded = uddg.removingPercentEncoding {
                resultURL = decoded
            }

            // Snippet from result__snippet — get full content between open/close tags
            var snippet = ""
            if let snipStart = segment.range(of: "result__snippet"),
               let snipContentStart = segment.range(of: ">", range: snipStart.upperBound..<segment.endIndex) {
                // Find the closing </a> or </div> for the snippet
                let remaining = String(segment[snipContentStart.upperBound...])
                // Take everything up to the next </a> or </div>
                if let closeTag = remaining.range(of: "</a>") ?? remaining.range(of: "</div>") {
                    let rawSnippet = String(remaining[remaining.startIndex..<closeTag.lowerBound])
                    snippet = stripHTMLTags(rawSnippet)
                }
            }

            if !title.isEmpty && !resultURL.isEmpty {
                results.append((title: title, url: resultURL, snippet: String(snippet.prefix(200))))
            }
        }

        if results.isEmpty { return "" }

        return results.enumerated().map { idx, r in
            "\(idx + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n\n")
    }

    private func parseSearXNGResults(_ raw: String) -> String {
        // SearXNG JSON: try to extract title/url/content from results array
        guard let jsonStart = raw.range(of: "---\n") else { return "" }
        let jsonStr = String(raw[jsonStart.upperBound...])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return "" }

        return results.prefix(8).enumerated().map { idx, r in
            let title = r["title"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            let content = r["content"] as? String ?? ""
            return "\(idx + 1). \(title)\n   \(url)\n   \(String(content.prefix(200)))"
        }.joined(separator: "\n\n")
    }

    private func stripHTMLTags(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<"),
              let end = result.range(of: ">", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound...end.lowerBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML Text Extraction

    private func extractTextFromHTML(_ html: String) -> String {
        var text = html

        // Remove scripts and styles
        text = removeTagContent(text, tag: "script")
        text = removeTagContent(text, tag: "style")
        text = removeTagContent(text, tag: "head")
        text = removeTagContent(text, tag: "nav")
        text = removeTagContent(text, tag: "footer")

        // Replace block tags with newlines
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>",
                         "</h4>", "</li>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Remove all remaining HTML tags
        while let start = text.range(of: "<"),
              let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound...end.lowerBound)
        }

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–")
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }

        // Collapse whitespace
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private func removeTagContent(_ text: String, tag: String) -> String {
        var result = text
        let openTag = "<\(tag)"
        let closeTag = "</\(tag)>"
        while let start = result.range(of: openTag, options: .caseInsensitive),
              let end = result.range(of: closeTag, options: .caseInsensitive) {
            if start.lowerBound < end.upperBound {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else { break }
        }
        return result
    }
}
