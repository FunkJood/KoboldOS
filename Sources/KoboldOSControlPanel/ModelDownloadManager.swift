import SwiftUI
import Foundation

// MARK: - ModelDownloadManager
// Handles downloading AI models from HuggingFace and Ollama

@MainActor
class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    // Download state
    @Published var isDownloadingSD: Bool = false
    @Published var isDownloadingChat: Bool = false
    @Published var sdProgress: Double = 0
    @Published var chatProgress: Double = 0
    @Published var sdStatus: String = ""
    @Published var chatStatus: String = ""
    @Published var lastError: String? = nil

    // Model info
    @Published var sdModelInstalled: Bool = false
    @Published var chatModelInstalled: Bool = false

    // Recommended models
    let recommendedSDModel = "apple/coreml-stable-diffusion-2-1-base"
    let recommendedChatModel = "qwen2.5:3b"

    private var downloadTask: URLSessionDownloadTask? = nil

    init() {
        checkInstalledModels()
    }

    func checkInstalledModels() {
        // Check SD model
        let sdDir = sdModelDirectory()
        sdModelInstalled = FileManager.default.fileExists(atPath: sdDir.path)

        // Check chat model via Ollama
        Task {
            chatModelInstalled = await isOllamaModelInstalled(recommendedChatModel)
        }
    }

    func sdModelDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/sd-models")
    }

    func modelsRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/sd-models")
    }

    func openModelsFolder() {
        let dir = modelsRootDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Ollama Chat Model Download

    func downloadChatModel() {
        guard !isDownloadingChat else { return }
        isDownloadingChat = true
        chatStatus = "Starte Download..."
        chatProgress = 0
        lastError = nil

        Task {
            do {
                // Check if Ollama is available
                let ollamaPath = findOllama()
                guard let ollama = ollamaPath else {
                    self.lastError = "Ollama nicht gefunden. Bitte erst Ollama installieren."
                    self.isDownloadingChat = false
                    return
                }

                self.chatStatus = "Lade \(recommendedChatModel) via Ollama..."
                self.chatProgress = 0.1

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ollama)
                process.arguments = ["pull", recommendedChatModel]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()

                // Monitor progress in background
                Task.detached {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    await MainActor.run {
                        if process.terminationStatus == 0 {
                            self.chatProgress = 1.0
                            self.chatStatus = "Modell installiert!"
                            self.chatModelInstalled = true
                        } else {
                            self.lastError = "Ollama pull fehlgeschlagen: \(output.prefix(200))"
                            self.chatStatus = "Fehler"
                        }
                        self.isDownloadingChat = false
                    }
                }

                // Simulate progress updates while waiting
                for i in 1...8 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !isDownloadingChat { break }
                    chatProgress = min(0.9, Double(i) / 10.0)
                }
            } catch {
                self.lastError = error.localizedDescription
                self.chatStatus = "Fehler"
                self.isDownloadingChat = false
            }
        }
    }

    // MARK: - SD Model Download (HuggingFace)

    func downloadSDModel(force: Bool = false) {
        guard !isDownloadingSD else { return }
        isDownloadingSD = true
        sdStatus = "Starte Download..."
        sdProgress = 0
        lastError = nil

        Task {
            do {
                let destDir = sdModelDirectory()
                // On force re-download, remove existing files first
                if force && FileManager.default.fileExists(atPath: destDir.path) {
                    try? FileManager.default.removeItem(at: destDir)
                }
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                // Download compiled CoreML model files from HuggingFace
                let baseURL = "https://huggingface.co/\(recommendedSDModel)/resolve/main"
                let files = [
                    "merges.txt",
                    "vocab.json",
                    "TextEncoder.mlmodelc/model.mil",
                    "TextEncoder.mlmodelc/coremldata.bin",
                    "Unet.mlmodelc/model.mil",
                    "Unet.mlmodelc/coremldata.bin",
                    "VAEDecoder.mlmodelc/model.mil",
                    "VAEDecoder.mlmodelc/coremldata.bin",
                ]

                sdStatus = "Lade SD-Modell (\(files.count) Dateien)..."
                for (index, file) in files.enumerated() {
                    let url = URL(string: "\(baseURL)/\(file)")!
                    let destFile = destDir.appendingPathComponent(file)

                    // Create subdirectories
                    let dir = destFile.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                    // Skip if already exists (unless force)
                    if !force && FileManager.default.fileExists(atPath: destFile.path) {
                        sdProgress = Double(index + 1) / Double(files.count)
                        continue
                    }

                    let (data, _) = try await URLSession.shared.data(from: url)
                    try data.write(to: destFile)
                    sdProgress = Double(index + 1) / Double(files.count)
                    sdStatus = "Lade... (\(index + 1)/\(files.count))"
                }

                sdProgress = 1.0
                sdStatus = "SD-Modell installiert!"
                sdModelInstalled = true
                isDownloadingSD = false
            } catch {
                lastError = error.localizedDescription
                sdStatus = "Fehler beim Download"
                isDownloadingSD = false
            }
        }
    }

    // MARK: - Helpers

    private func findOllama() -> String? {
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func isOllamaModelInstalled(_ model: String) async -> Bool {
        guard let ollama = findOllama() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollama)
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(model.components(separatedBy: ":").first ?? model)
        } catch {
            return false
        }
    }
}
