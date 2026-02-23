import Foundation
@preconcurrency import StableDiffusion
import CoreML
import AppKit
import CoreImage

// MARK: - ImageGenManager (Stable Diffusion via Apple ml-stable-diffusion)

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

    private var pipeline: StableDiffusionPipeline?

    private let modelsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/sd-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let outputDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/KoboldOS-Images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Settings from UserDefaults
    var masterPrompt: String { UserDefaults.standard.string(forKey: "kobold.sd.masterPrompt") ?? "masterpiece, best quality, highly detailed" }
    var negativePrompt: String { UserDefaults.standard.string(forKey: "kobold.sd.negativePrompt") ?? "ugly, blurry, distorted, low quality, deformed" }
    var steps: Int { max(10, min(100, UserDefaults.standard.integer(forKey: "kobold.sd.steps") == 0 ? 30 : UserDefaults.standard.integer(forKey: "kobold.sd.steps"))) }
    var guidanceScale: Float { let v = UserDefaults.standard.float(forKey: "kobold.sd.guidanceScale"); return v > 0 ? v : 7.5 }
    var imageSize: Int { let v = UserDefaults.standard.integer(forKey: "kobold.sd.imageSize"); return v > 0 ? v : 512 }
    var computeUnits: String { UserDefaults.standard.string(forKey: "kobold.sd.computeUnits") ?? "cpuAndGPU" }

    private init() {
        setupNotificationListener()
    }

    // MARK: - Model Management

    func modelDir(for name: String) -> URL {
        modelsDir.appendingPathComponent(name)
    }

    var availableModels: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path))?
            .filter { $0 != ".DS_Store" } ?? []
    }

    /// Heavy pipeline work runs off MainActor to prevent UI freeze / watchdog kill.
    func loadModel(name: String) async {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        loadError = nil

        let dir = modelDir(for: name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            loadError = "Modell '\(name)' nicht gefunden."
            isLoadingModel = false
            return
        }

        // Verify at least one .mlmodelc exists
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else {
            loadError = "Ordner '\(name)' enthält keine CoreML-Modelle (.mlmodelc)."
            isLoadingModel = false
            return
        }

        let cu = computeUnits
        do {
            let newPipeline: StableDiffusionPipeline = try await Task.detached(priority: .userInitiated) {
                var config = MLModelConfiguration()
                switch cu {
                case "cpuOnly": config.computeUnits = .cpuOnly
                case "all":     config.computeUnits = .all
                default:        config.computeUnits = .cpuAndGPU
                }
                let p = try StableDiffusionPipeline(
                    resourcesAt: dir, controlNet: [], configuration: config, reduceMemory: true
                )
                try p.loadResources()
                return p
            }.value
            pipeline = newPipeline
            isModelLoaded = true
            currentModelName = name
            loadError = nil
            print("[ImageGen] Model '\(name)' loaded (background)")
        } catch {
            loadError = "Laden fehlgeschlagen: \(error.localizedDescription)"
            print("[ImageGen] Load error: \(error)")
        }
        isLoadingModel = false
    }

    /// Load model directly from modelsDir root (used after download where files are placed directly)
    func loadModelFromRoot() async {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        loadError = nil

        let dir = modelsDir
        // Check for any .mlmodelc in root
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else {
            loadError = "Kein CoreML-Modell im Hauptordner gefunden. Bitte zuerst herunterladen."
            isLoadingModel = false
            return
        }

        let cu = computeUnits
        do {
            let newPipeline: StableDiffusionPipeline = try await Task.detached(priority: .userInitiated) {
                var config = MLModelConfiguration()
                switch cu {
                case "cpuOnly": config.computeUnits = .cpuOnly
                case "all":     config.computeUnits = .all
                default:        config.computeUnits = .cpuAndGPU
                }
                let p = try StableDiffusionPipeline(
                    resourcesAt: dir, controlNet: [], configuration: config, reduceMemory: true
                )
                try p.loadResources()
                return p
            }.value
            pipeline = newPipeline
            isModelLoaded = true
            currentModelName = "stable-diffusion-2.1-base"
            loadError = nil
            print("[ImageGen] Model loaded from root directory (background)")
        } catch {
            loadError = "Laden fehlgeschlagen: \(error.localizedDescription)"
            print("[ImageGen] Root load error: \(error)")
        }
        isLoadingModel = false
    }

    func unloadModel() {
        pipeline = nil
        isModelLoaded = false
        currentModelName = ""
    }

    // MARK: - Generation

    func generate(
        prompt: String,
        negativePrompt: String? = nil,
        steps: Int? = nil,
        guidanceScale: Float? = nil,
        seed: UInt32? = nil
    ) async throws -> (image: NSImage, path: String) {
        guard let pipeline = pipeline else {
            throw ImageGenError.noModelLoaded
        }
        guard !isGenerating else {
            throw ImageGenError.alreadyGenerating
        }

        isGenerating = true
        generationProgress = 0
        defer { isGenerating = false }

        let fullPrompt = "\(masterPrompt), \(prompt)"
        let negPrompt = negativePrompt ?? self.negativePrompt
        let stepCount = steps ?? self.steps
        let guidance = guidanceScale ?? self.guidanceScale
        let randomSeed = seed ?? UInt32.random(in: 0..<UInt32.max)

        var config = StableDiffusionPipeline.Configuration(prompt: fullPrompt)
        config.negativePrompt = negPrompt
        config.stepCount = stepCount
        config.guidanceScale = guidance
        config.seed = randomSeed
        config.disableSafety = false

        // Run pipeline on background thread to prevent UI freeze
        let pipelineRef = pipeline
        let configCopy = config
        let outDir = outputDir

        let (nsImage, outputPath): (NSImage, String) = try await Task.detached(priority: .userInitiated) {
            let images = try pipelineRef.generateImages(configuration: configCopy) { progress in
                Task { @MainActor in
                    self.generationProgress = Double(progress.step) / Double(progress.stepCount)
                }
                return true // continue
            }

            guard let cgImage = images.first ?? nil else {
                throw ImageGenError.generationFailed
            }

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            // Save to file
            let timestamp = Int(Date().timeIntervalSince1970)
            let sanitizedPrompt = prompt.prefix(40).replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            let filename = "\(sanitizedPrompt)_\(timestamp).png"
            let outputURL = outDir.appendingPathComponent(filename)

            if let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try pngData.write(to: outputURL)
            }

            return (nsImage, outputURL.path)
        }.value

        lastGeneratedImage = nsImage
        generationProgress = 1.0
        print("[ImageGen] Image saved to \(outputPath)")
        return (image: nsImage, path: outputPath)
    }

    // MARK: - Notification Listener (from GenerateImageTool)

    private func setupNotificationListener() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldImageGenerate"),
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            let prompt = notif.userInfo?["prompt"] as? String ?? ""
            let negPrompt = notif.userInfo?["negative_prompt"] as? String
            let steps = (notif.userInfo?["steps"] as? String).flatMap { Int($0) }
            let guidance = (notif.userInfo?["guidance_scale"] as? String).flatMap { Float($0) }
            let seed = (notif.userInfo?["seed"] as? String).flatMap { UInt32($0) }
            let callbackId = notif.userInfo?["callback_id"] as? String

            Task { @MainActor in
                do {
                    let result = try await self.generate(
                        prompt: prompt,
                        negativePrompt: negPrompt,
                        steps: steps,
                        guidanceScale: guidance,
                        seed: seed
                    )
                    // Post result back
                    NotificationCenter.default.post(
                        name: Notification.Name("koboldImageGenResult"),
                        object: nil,
                        userInfo: [
                            "path": result.path,
                            "callback_id": callbackId ?? "",
                            "success": "true"
                        ]
                    )
                } catch {
                    NotificationCenter.default.post(
                        name: Notification.Name("koboldImageGenResult"),
                        object: nil,
                        userInfo: [
                            "error": error.localizedDescription,
                            "callback_id": callbackId ?? "",
                            "success": "false"
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Errors

    enum ImageGenError: LocalizedError {
        case modelNotFound(String)
        case noModelLoaded
        case alreadyGenerating
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name): return "Model '\(name)' nicht gefunden. Bitte zuerst herunterladen."
            case .noModelLoaded: return "Kein Stable Diffusion Model geladen. Bitte in Einstellungen → Bildgenerierung ein Model herunterladen."
            case .alreadyGenerating: return "Es wird bereits ein Bild generiert. Bitte warten."
            case .generationFailed: return "Bildgenerierung fehlgeschlagen."
            }
        }
    }
}
