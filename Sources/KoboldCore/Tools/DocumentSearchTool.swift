#if os(macOS)
import Foundation
import PDFKit

// MARK: - DocumentSearchTool (PDF/Text reading + semantic search)

public struct DocumentSearchTool: Tool, @unchecked Sendable {
    public let name = "document_search"
    public let description = "Dokumente lesen und durchsuchen: PDF/TXT-Dateien einlesen (read), semantische Suche in geladenen Dokumenten (search), geladene Dokumente auflisten (list)"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "read | search | list", required: true),
            "filepath": ToolSchemaProperty(type: "string", description: "Pfad zur PDF/TXT-Datei (für read)"),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff für semantische Suche (für search)"),
            "limit": ToolSchemaProperty(type: "string", description: "Max. Ergebnisse (Standard: 5)"),
            "page": ToolSchemaProperty(type: "string", description: "Bestimmte Seite lesen (für read, z.B. '3' oder '1-5')"),
        ], required: ["action"])
    }

    /// In-memory document store — chunks indexed by document path
    private static let store = DocumentStore()

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        switch arguments["action"] ?? "" {
        case "read": return readDocument(arguments)
        case "search": return searchDocuments(arguments)
        case "list": return listDocuments()
        default: return "Unbekannte Aktion. Verfügbar: read, search, list"
        }
    }

    // MARK: - Read Document

    private func readDocument(_ args: [String: String]) -> String {
        guard let filepath = args["filepath"], !filepath.isEmpty else {
            return "Error: 'filepath' Parameter fehlt."
        }

        let resolved = resolvePath(filepath)
        guard FileManager.default.fileExists(atPath: resolved) else {
            return "Error: Datei nicht gefunden: \(resolved)"
        }

        // Check file size (max 50MB for PDFs)
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        if fileSize > 50_000_000 {
            return "Error: Datei zu groß (\(fileSize / 1_000_000) MB). Maximum: 50 MB."
        }

        let ext = (resolved as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf":
            return readPDF(resolved, args: args)
        case "txt", "md", "csv", "json", "xml", "html", "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h":
            return readTextFile(resolved, args: args)
        default:
            // Try as text file
            return readTextFile(resolved, args: args)
        }
    }

    private func readPDF(_ path: String, args: [String: String]) -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return "Error: PDF konnte nicht geöffnet werden: \(path)"
        }

        let pageCount = doc.pageCount
        var pages: [Int] = []

        // Parse page range
        if let pageStr = args["page"] {
            if pageStr.contains("-") {
                let parts = pageStr.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 {
                    pages = Array(max(1, parts[0])...min(pageCount, parts[1]))
                }
            } else if let p = Int(pageStr) {
                pages = [min(pageCount, max(1, p))]
            }
        }

        // Default: all pages (but cap at 30 for output)
        if pages.isEmpty {
            pages = Array(1...min(pageCount, 30))
        }

        var fullText = ""
        var chunks: [String] = []

        for pageNum in pages {
            guard let page = doc.page(at: pageNum - 1),
                  let text = page.string, !text.isEmpty else { continue }
            fullText += "--- Seite \(pageNum) ---\n\(text)\n\n"

            // Chunk text (~500 chars per chunk for search)
            let words = text.split(separator: " ")
            var chunk = ""
            for word in words {
                chunk += (chunk.isEmpty ? "" : " ") + word
                if chunk.count >= 500 {
                    chunks.append("[\(path):S\(pageNum)] \(chunk)")
                    chunk = ""
                }
            }
            if !chunk.isEmpty {
                chunks.append("[\(path):S\(pageNum)] \(chunk)")
            }
        }

        if fullText.isEmpty {
            return "PDF hat keinen extrahierbaren Text (evtl. gescanntes Dokument — nutze das vision Tool für OCR)."
        }

        // Store chunks for semantic search
        Self.store.addDocument(path: path, chunks: chunks, pageCount: pageCount)

        let fileName = (path as NSString).lastPathComponent
        // Cap output to prevent overwhelming the LLM
        let outputText = fullText.count > 8000 ? String(fullText.prefix(8000)) + "\n\n[... gekürzt, \(fullText.count) Zeichen gesamt. Nutze 'search' für gezielte Suche.]" : fullText

        return "Dokument geladen: \(fileName) (\(pageCount) Seiten, \(chunks.count) Chunks indexiert)\n\n\(outputText)"
    }

    private func readTextFile(_ path: String, args: [String: String]) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Try latin1 fallback
            guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
                return "Error: Datei konnte nicht gelesen werden (unbekanntes Encoding)."
            }
            return processTextContent(content, path: path)
        }
        return processTextContent(content, path: path)
    }

    private func processTextContent(_ content: String, path: String) -> String {
        // Chunk for search
        let lines = content.components(separatedBy: .newlines)
        var chunks: [String] = []
        var chunk = ""
        var lineNum = 0
        for line in lines {
            lineNum += 1
            chunk += (chunk.isEmpty ? "" : "\n") + line
            if chunk.count >= 500 {
                chunks.append("[\(path):L\(lineNum)] \(chunk)")
                chunk = ""
            }
        }
        if !chunk.isEmpty {
            chunks.append("[\(path):L\(lineNum)] \(chunk)")
        }

        Self.store.addDocument(path: path, chunks: chunks, pageCount: 1)

        let fileName = (path as NSString).lastPathComponent
        let outputText = content.count > 8000 ? String(content.prefix(8000)) + "\n\n[... gekürzt, \(content.count) Zeichen gesamt]" : content

        return "Dokument geladen: \(fileName) (\(chunks.count) Chunks indexiert)\n\n\(outputText)"
    }

    // MARK: - Semantic Search

    private func searchDocuments(_ args: [String: String]) -> String {
        guard let query = args["query"], !query.isEmpty else {
            return "Error: 'query' Suchbegriff fehlt."
        }

        let allChunks = Self.store.allChunks()
        if allChunks.isEmpty {
            return "Keine Dokumente geladen. Bitte zuerst ein Dokument mit action='read' einlesen."
        }

        let limit = Int(args["limit"] ?? "5") ?? 5

        // TF-IDF semantic search
        let results = VectorSearch.search(query: query, entries: allChunks, limit: limit, minScore: 0.02)

        if results.isEmpty {
            return "Keine relevanten Treffer für: \"\(query)\""
        }

        var out = "Suchergebnisse für \"\(query)\" (\(results.count) Treffer):\n\n"
        for (i, result) in results.enumerated() {
            let score = String(format: "%.1f%%", result.score * 100)
            let chunk = allChunks[result.index]
            out += "[\(i + 1)] Relevanz: \(score)\n\(chunk)\n\n"
        }
        return out
    }

    // MARK: - List Loaded Documents

    private func listDocuments() -> String {
        let docs = Self.store.listDocuments()
        if docs.isEmpty { return "Keine Dokumente geladen." }

        var out = "Geladene Dokumente (\(docs.count)):\n\n"
        for doc in docs {
            out += "- \(doc.name) (\(doc.chunks) Chunks, \(doc.pages) Seiten)\n"
        }
        out += "\nNutze action='search' mit query='...' um darin zu suchen."
        return out
    }

    // MARK: - Path Helper

    private func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

// MARK: - DocumentStore (Thread-Safe In-Memory Index)

private final class DocumentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: DocumentEntry] = [:]

    struct DocumentEntry {
        let name: String
        let chunks: [String]
        let pageCount: Int
        let loadedAt: Date
    }

    struct DocumentInfo {
        let name: String
        let chunks: Int
        let pages: Int
    }

    func addDocument(path: String, chunks: [String], pageCount: Int) {
        lock.lock()
        documents[path] = DocumentEntry(
            name: (path as NSString).lastPathComponent,
            chunks: chunks,
            pageCount: pageCount,
            loadedAt: Date()
        )
        lock.unlock()
    }

    func allChunks() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return documents.values.flatMap { $0.chunks }
    }

    func listDocuments() -> [DocumentInfo] {
        lock.lock()
        defer { lock.unlock() }
        return documents.values.map { DocumentInfo(name: $0.name, chunks: $0.chunks.count, pages: $0.pageCount) }
    }
}

#elseif os(Linux)
import Foundation

public struct DocumentSearchTool: Tool, Sendable {
    public let name = "document_search"
    public let description = "Dokument-Suche (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .low
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func execute(arguments: [String: String]) async throws -> String { "Dokument-Suche ist auf Linux deaktiviert." }
}
#endif
