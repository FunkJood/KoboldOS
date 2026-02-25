import Foundation
import AppKit

// MARK: - ImageGenManager (Stub — Stable Diffusion removed due to BPETokenizer crashes)

@MainActor
final class ImageGenManager: ObservableObject {
    static let shared = ImageGenManager()

    @Published var isGenerating = false
    @Published var generationProgress: Double = 0
    @Published var isModelLoaded = false
    @Published var isLoadingModel = false
    @Published var loadError: String?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var currentModelName: String = ""
    @Published var lastGeneratedImage: NSImage?

    var masterPrompt: String { "" }
    var negativePrompt: String { "" }
    var steps: Int { 30 }
    var guidanceScale: Float { 7.5 }
    var imageSize: Int { 512 }
    var computeUnits: String { "cpuAndGPU" }

    private init() {}

    var availableModels: [String] { [] }

    func loadModel(name: String) async {
        loadError = "Bildgenerierung ist in dieser Version deaktiviert."
    }

    func loadModelFromRoot() async {
        loadError = "Bildgenerierung ist in dieser Version deaktiviert."
    }

    func unloadModel() {
        isModelLoaded = false
        currentModelName = ""
    }

    enum ImageGenError: LocalizedError {
        case modelNotFound(String)
        case noModelLoaded
        case alreadyGenerating
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name): return "Model '\(name)' nicht gefunden."
            case .noModelLoaded: return "Bildgenerierung ist in dieser Version deaktiviert."
            case .alreadyGenerating: return "Es wird bereits ein Bild generiert."
            case .generationFailed: return "Bildgenerierung fehlgeschlagen."
            }
        }
    }

    func generate(
        prompt: String,
        negativePrompt: String? = nil,
        steps: Int? = nil,
        guidanceScale: Float? = nil,
        seed: UInt32? = nil
    ) async throws -> (image: NSImage, path: String) {
        throw ImageGenError.noModelLoaded
    }
}
