import Foundation
import KoboldCore
@preconcurrency import SwiftWhisper
import AppKit

// MARK: - STTManager (Speech-to-Text via whisper.cpp)

@MainActor
final class STTManager: ObservableObject {
    static let shared = STTManager()

    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var currentModelName: String = ""

    private var whisper: Whisper?

    private let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/whisper-models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var autoTranscribe: Bool { UserDefaults.standard.bool(forKey: "kobold.stt.autoTranscribe") }
    var modelSize: String { UserDefaults.standard.string(forKey: "kobold.stt.model") ?? "base" }

    private init() {
        Task { await loadModelIfAvailable() }
    }

    // MARK: - Model Management

    private func modelURL(for size: String) -> URL {
        supportDir.appendingPathComponent("ggml-\(size).bin")
    }

    private func remoteModelURL(for size: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(size).bin")!
    }

    func loadModelIfAvailable() async {
        let size = modelSize
        let url = modelURL(for: size)
        guard FileManager.default.fileExists(atPath: url.path) else {
            isModelLoaded = false
            return
        }
        whisper = Whisper(fromFileURL: url)
        if whisper != nil {
            isModelLoaded = true
            currentModelName = size
            print("[STT] Model '\(size)' loaded")
        } else {
            print("[STT] Failed to load model from \(url.path)")
            isModelLoaded = false
        }
    }

    func downloadModel(size: String? = nil) async {
        let modelName = size ?? modelSize
        let localURL = modelURL(for: modelName)
        let remoteURL = remoteModelURL(for: modelName)

        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0

        print("[STT] Downloading model '\(modelName)' from \(remoteURL)")

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL, delegate: nil)
            try FileManager.default.moveItem(at: tempURL, to: localURL)
            downloadProgress = 1.0
            isDownloading = false
            await loadModelIfAvailable()
            print("[STT] Model '\(modelName)' downloaded successfully")
        } catch {
            print("[STT] Download failed: \(error)")
            isDownloading = false
        }
    }

    var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelURL(for: modelSize).path)
    }

    func deleteModel(size: String? = nil) {
        let modelName = size ?? modelSize
        let url = modelURL(for: modelName)
        try? FileManager.default.removeItem(at: url)
        if modelName == currentModelName {
            whisper = nil
            isModelLoaded = false
            currentModelName = ""
        }
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL) async -> String? {
        guard let whisper = whisper else {
            print("[STT] No model loaded")
            return nil
        }
        guard !isTranscribing else { return nil }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Convert audio to PCM float array (16kHz mono)
            let audioData = try await convertToPCM(url: audioURL)
            let segments = try await whisper.transcribe(audioFrames: audioData)
            let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            print("[STT] Transcribed: \(text.prefix(100))...")
            return text.isEmpty ? nil : text
        } catch {
            print("[STT] Transcription error: \(error)")
            return nil
        }
    }

    // MARK: - Audio Conversion (to 16kHz PCM float)

    private func convertToPCM(url: URL) async throws -> [Float] {
        // Use ffmpeg if available, otherwise try AVFoundation
        let pcmURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisper_input_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: pcmURL) }

        // Try ffmpeg conversion first (handles most formats)
        // ffmpeg async mit Timeout (blockiert nicht den Main Thread)
        _ = try? await AsyncProcess.run(
            executable: "/usr/bin/env",
            arguments: ["ffmpeg", "-i", url.path, "-ar", "16000", "-ac", "1", "-f", "wav", "-y", pcmURL.path],
            timeout: 30
        )

        let dataURL = FileManager.default.fileExists(atPath: pcmURL.path) ? pcmURL : url
        let data = try Data(contentsOf: dataURL)

        // Parse WAV header and extract PCM samples
        return parseWAVToFloats(data)
    }

    private func parseWAVToFloats(_ data: Data) -> [Float] {
        // Skip WAV header (44 bytes for standard WAV)
        let headerSize = 44
        guard data.count > headerSize else { return [] }

        let pcmData = data.subdata(in: headerSize..<data.count)
        var floats = [Float](repeating: 0, count: pcmData.count / 2)

        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<int16Buffer.count {
                floats[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        return floats
    }
}
