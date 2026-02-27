import Foundation

// MARK: - RSS Reader Tool (kein Auth, URLSession + XML)
public struct RSSReaderTool: Tool {
    public let name = "rss"
    public let description = "RSS/Atom Feeds lesen: Feeds abrufen, verwalten und durchsuchen"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: fetch, list_feeds, add_feed, remove_feed", enumValues: ["fetch", "list_feeds", "add_feed", "remove_feed"], required: true),
            "url": ToolSchemaProperty(type: "string", description: "Feed-URL (für fetch und add_feed)"),
            "limit": ToolSchemaProperty(type: "string", description: "Max. Anzahl Einträge (Standard: 10)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let url = arguments["url"] ?? ""
        let limit = Int(arguments["limit"] ?? "10") ?? 10

        switch action {
        case "fetch":
            guard !url.isEmpty else { return "Error: 'url' Parameter wird für fetch benötigt." }
            return await fetchFeed(urlString: url, limit: limit)

        case "list_feeds":
            return listFeeds()

        case "add_feed":
            guard !url.isEmpty else { return "Error: 'url' Parameter wird für add_feed benötigt." }
            return addFeed(url: url)

        case "remove_feed":
            guard !url.isEmpty else { return "Error: 'url' Parameter wird für remove_feed benötigt." }
            return removeFeed(url: url)

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: fetch, list_feeds, add_feed, remove_feed"
        }
    }

    // MARK: - Feed Management (UserDefaults)

    private var savedFeeds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "kobold.rss.feeds") ?? [] }
    }

    private func listFeeds() -> String {
        let feeds = savedFeeds
        if feeds.isEmpty {
            return "Keine RSS-Feeds gespeichert. Verwende add_feed um einen Feed hinzuzufügen."
        }
        return "Gespeicherte Feeds (\(feeds.count)):\n" + feeds.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private func addFeed(url: String) -> String {
        var feeds = savedFeeds
        if feeds.contains(url) {
            return "Feed ist bereits gespeichert: \(url)"
        }
        feeds.append(url)
        UserDefaults.standard.set(feeds, forKey: "kobold.rss.feeds")
        return "Feed hinzugefügt: \(url) (Gesamt: \(feeds.count))"
    }

    private func removeFeed(url: String) -> String {
        var feeds = savedFeeds
        guard let index = feeds.firstIndex(of: url) else {
            return "Feed nicht gefunden: \(url)"
        }
        feeds.remove(at: index)
        UserDefaults.standard.set(feeds, forKey: "kobold.rss.feeds")
        return "Feed entfernt: \(url) (Verbleibend: \(feeds.count))"
    }

    // MARK: - Fetch & Parse RSS/Atom

    private func fetchFeed(urlString: String, limit: Int) async -> String {
        guard let url = URL(string: urlString) else {
            return "Error: Ungültige URL: \(urlString)"
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("KoboldOS RSS Reader/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                return "Error: HTTP \(status) beim Abrufen von \(urlString)"
            }

            let parser = RSSParser(limit: limit)
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()

            if parser.items.isEmpty {
                return "Keine Einträge im Feed gefunden (oder ungültiges XML)."
            }

            var result = "Feed: \(parser.feedTitle.isEmpty ? urlString : parser.feedTitle)\n"
            result += "Einträge: \(parser.items.count)\n\n"

            for (i, item) in parser.items.enumerated() {
                result += "[\(i + 1)] \(item.title)\n"
                if !item.link.isEmpty { result += "    Link: \(item.link)\n" }
                if !item.pubDate.isEmpty { result += "    Datum: \(item.pubDate)\n" }
                if !item.description.isEmpty {
                    let desc = item.description.prefix(200)
                    result += "    \(desc)\n"
                }
                result += "\n"
            }

            return String(result.prefix(8192))
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Simple RSS/Atom XML Parser

private class RSSParser: NSObject, XMLParserDelegate {
    struct FeedItem {
        var title = ""
        var link = ""
        var description = ""
        var pubDate = ""
    }

    var feedTitle = ""
    var items: [FeedItem] = []
    private let limit: Int
    private var currentElement = ""
    private var currentItem: FeedItem?
    private var currentText = ""
    private var isInChannel = false
    private var isInItem = false

    init(limit: Int) { self.limit = limit }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "item", "entry":
            isInItem = true
            currentItem = FeedItem()
        case "channel", "feed":
            isInChannel = true
        case "link":
            // Atom feeds use <link href="..."/>
            if isInItem, let href = attributes["href"] {
                currentItem?.link = href
            } else if !isInItem, let _ = attributes["href"] {
                // Feed-level link, ignore
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInItem {
            switch elementName {
            case "title": currentItem?.title = text
            case "link":
                if currentItem?.link.isEmpty == true { currentItem?.link = text }
            case "description", "summary", "content": currentItem?.description = stripHTML(text)
            case "pubDate", "published", "updated": currentItem?.pubDate = text
            case "item", "entry":
                if let item = currentItem, items.count < limit {
                    items.append(item)
                }
                currentItem = nil
                isInItem = false
                if items.count >= limit { parser.abortParsing() }
            default: break
            }
        } else if isInChannel {
            if elementName == "title" && feedTitle.isEmpty {
                feedTitle = text
            }
        }
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
