import Foundation
#if os(macOS)
import Vision
import AppKit
#endif

// MARK: - Vision Tool (OCR + Image Analysis)
// Lets the agent analyze screenshots and images using Apple's Vision framework

public struct VisionTool: Tool, @unchecked Sendable {
    public let name = "vision_load"
    public let description = """
        Analyze an image using OCR (text recognition). \
        Extracts text from screenshots, photos, documents, web pages. \
        Use this after taking a screenshot with app_browser(action:screenshot) or screen_control(action:screenshot) to read text content. \
        Returns all recognized text blocks with their positions. \
        Supports German and English text recognition. \
        \
        BEST PRACTICE: Take screenshot first → vision_load to read text → use the text for next steps. \
        For finding specific text: provide a query parameter to filter results.
        """
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "path": ToolSchemaProperty(
                    type: "string",
                    description: "Absolute path to image file (PNG, JPG, TIFF, etc.)",
                    required: true
                ),
                "query": ToolSchemaProperty(
                    type: "string",
                    description: "Optional: search for specific text in the image (case-insensitive)"
                )
            ],
            required: ["path"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard let path = arguments["path"], !path.isEmpty else {
            throw ToolError.missingRequired("path")
        }
        let query = arguments["query"] ?? ""

        #if os(macOS)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return "[Fehler: Datei nicht gefunden: \(path)]"
        }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "[Fehler: Bild konnte nicht geladen werden: \(path)]"
        }

        // OCR mit Apple Vision Framework
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return "[Kein Text im Bild erkannt]"
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        struct TextBlock {
            let text: String
            let x: Int
            let y: Int
            let confidence: Float
        }

        var blocks: [TextBlock] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let bbox = obs.boundingBox
            // VNObservation uses normalized coords (0-1), origin bottom-left
            let centerX = Int((bbox.origin.x + bbox.width / 2) * imgW)
            let centerY = Int((1.0 - bbox.origin.y - bbox.height / 2) * imgH)
            blocks.append(TextBlock(
                text: candidate.string,
                x: centerX,
                y: centerY,
                confidence: candidate.confidence
            ))
        }

        if blocks.isEmpty {
            return "[Kein Text im Bild erkannt. Das Bild enthält möglicherweise nur grafische Elemente.]\nBildgröße: \(Int(imgW))x\(Int(imgH))px"
        }

        // Format output
        var result = "OCR-Ergebnis (\(blocks.count) Textblöcke, \(Int(imgW))x\(Int(imgH))px):\n\n"

        for block in blocks {
            result += "[\(block.x),\(block.y)] \(block.text)\n"
        }

        // Query filter
        if !query.isEmpty {
            let queryLower = query.lowercased()
            let matches = blocks.filter { $0.text.lowercased().contains(queryLower) }
            if matches.isEmpty {
                result += "\n--- Kein Treffer für '\(query)' ---"
            } else {
                result += "\n--- Treffer für '\(query)' (\(matches.count)) ---\n"
                for m in matches {
                    result += "[\(m.x),\(m.y)] \(m.text)\n"
                }
            }
        }

        return String(result.prefix(8000))
        #else
        return "[Vision-Tool nur auf macOS verfügbar]"
        #endif
    }
}
