import Foundation
import AVFoundation

// MARK: - AudioTapProcessor (Thread-Safe Audio Processing)
// Separate Klasse die den installTap-Callback verarbeitet OHNE @MainActor Isolation.
// Verhindert den Swift Concurrency Runtime Crash (EXC_BREAKPOINT / dispatch_assert_queue_fail)
// der auftritt wenn eine @MainActor-isolierte Closure auf dem Audio-Realtime-Thread läuft.

private final class AudioTapProcessor: @unchecked Sendable {
    let inputSampleRate: Double
    let channelCount: UInt32
    let onResult: @Sendable (_ samples: [Float], _ level: Float, _ rms: Float) -> Void

    init(inputSampleRate: Double, channelCount: UInt32,
         onResult: @escaping @Sendable (_ samples: [Float], _ level: Float, _ rms: Float) -> Void) {
        self.inputSampleRate = inputSampleRate
        self.channelCount = channelCount
        self.onResult = onResult
    }

    func handleTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)

        // Mono-Downmix (falls Stereo)
        var monoSamples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount {
                monoSamples[i] = floatData[0][i]
            }
        } else {
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<Int(channelCount) {
                    sum += floatData[ch][i]
                }
                monoSamples[i] = sum / Float(channelCount)
            }
        }

        // Resampling: inputSampleRate → 16kHz (lineare Interpolation)
        let resampledSamples: [Float]
        if abs(inputSampleRate - 16000) < 100 {
            resampledSamples = monoSamples
        } else {
            let ratio = 16000.0 / inputSampleRate
            let outputCount = Int(Double(frameCount) * ratio)
            var output = [Float](repeating: 0, count: outputCount)
            for i in 0..<outputCount {
                let srcIndex = Double(i) / ratio
                let idx = Int(srcIndex)
                let frac = Float(srcIndex - Double(idx))
                if idx + 1 < frameCount {
                    output[i] = monoSamples[idx] * (1.0 - frac) + monoSamples[idx + 1] * frac
                } else if idx < frameCount {
                    output[i] = monoSamples[idx]
                }
            }
            resampledSamples = output
        }

        // RMS für Audio-Level (Waveform-Visualisierung)
        var rms: Float = 0
        for sample in resampledSamples {
            rms += sample * sample
        }
        rms = sqrt(rms / max(Float(resampledSamples.count), 1))
        // Non-lineares Mapping: sqrt-Kurve macht leise Sounds sichtbarer (Voice-KI-Look)
        let normalizedLevel = min(sqrt(rms * 25), 1.0)

        onResult(resampledSamples, normalizedLevel, rms)
    }
}

// MARK: - AudioRecordingManager (Live-Mikrofon-Aufnahme + VAD)
// Zeichnet Audio vom Mikrofon auf, resampled auf 16kHz mono (Whisper-Format),
// erkennt Sprache via VAD (Voice Activity Detection), und gibt fertige
// Audio-Segmente als WAV-Datei zurück.

@MainActor
final class AudioRecordingManager: ObservableObject {
    static let shared = AudioRecordingManager()

    // MARK: - Published State

    @Published var isRecording = false
    @Published var audioLevel: Float = 0        // 0.0 - 1.0 für Waveform-Visualisierung
    @Published var vadDetected = false           // Sprache erkannt
    @Published var hasMicrophonePermission = false

    /// Continuous-Modus: Engine läuft weiter nach jedem Speech-Segment (für Sprechen-Tab VAD)
    var continuousListening = false
    /// VAD-Schwellwert-Multiplikator (erhöht während TTS → Echo-Suppression)
    var vadThresholdMultiplier: Float = 1.0

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var speechStarted = false
    private var silenceSampleCount = 0  // Silence-Tracking in 16kHz-Samples (buffer-size-unabhängig)
    private let targetSampleRate: Double = 16000  // Whisper braucht 16kHz

    // MARK: - Settings

    var vadEnabled: Bool { UserDefaults.standard.bool(forKey: "kobold.voice.vadEnabled") }
    /// VAD-Schwellwert — berechnet aus Mikrofon-Empfindlichkeit (1-10 Skala).
    /// Sensitivity 1 = Threshold 0.08 (muss schreien), 10 = 0.003 (flüstern reicht).
    var vadThreshold: Float {
        // Direkte Threshold-Überschreibung hat Priorität (Legacy-Support)
        let direct = UserDefaults.standard.float(forKey: "kobold.voice.vadThreshold")
        if direct > 0 { return direct }
        // Sensitivitäts-basierter Threshold (Standard)
        let sensitivity = UserDefaults.standard.double(forKey: "kobold.voice.micSensitivity")
        let sens = sensitivity > 0 ? sensitivity : 7.0  // Default: 7 (eher empfindlich)
        // Exponentielles Mapping: Sens 1→0.08, 5→0.02, 7→0.01, 10→0.004
        return Float(0.1 * pow(0.5, sens / 2.5))
    }
    var silenceTimeoutSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "kobold.voice.silenceTimeout")
        return v > 0 ? v : 0.7  // 0.7s für schnelle Voice-Interaktion (vorher 1.5s)
    }

    // MARK: - Callback

    /// Wird aufgerufen wenn ein Sprach-Segment fertig ist (Audio-Datei-URL)
    var onSpeechCaptured: ((URL) -> Void)?

    // MARK: - Init

    private init() {
        checkMicrophonePermission()
    }

    // MARK: - Permission

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.hasMicrophonePermission = granted
                }
            }
        default:
            hasMicrophonePermission = false
        }
    }

    // MARK: - Audio Engine Setup (NONISOLATED — kritisch!)
    // Diese Methode ist nonisolated static, damit die installTap-Closure
    // KEINE @MainActor-Isolation erbt. Swift 6 inferiert Closures die in
    // @MainActor-Methoden erstellt werden als @MainActor-isoliert, was zum
    // EXC_BREAKPOINT auf dem Audio-Realtime-Thread führt.

    private nonisolated static func configureAudioEngine(
        onResult: @escaping @Sendable (_ samples: [Float], _ level: Float, _ rms: Float) -> Void
    ) throws -> (engine: AVAudioEngine, sampleRate: Double, channelCount: UInt32) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = inputFormat.sampleRate
        let channelCount = inputFormat.channelCount

        let processor = AudioTapProcessor(
            inputSampleRate: sampleRate,
            channelCount: channelCount,
            onResult: onResult
        )

        // installTap-Closure wird in nonisolated-Kontext erstellt → KEINE Actor-Isolation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
            processor.handleTap(buffer, time)
        }

        try engine.start()
        return (engine, sampleRate, channelCount)
    }

    // MARK: - Start/Stop Recording

    func startRecording() {
        guard !isRecording else { return }
        guard hasMicrophonePermission else {
            print("[AudioRec] Keine Mikrofon-Berechtigung")
            checkMicrophonePermission()
            return
        }

        audioBuffer.removeAll()
        speechStarted = false
        silenceSampleCount = 0

        // weak ref für die @Sendable onResult-Closure
        weak let manager = self

        do {
            let (engine, sampleRate, channelCount) = try Self.configureAudioEngine { samples, level, rms in
                // @Sendable Closure — dispatcht sicher zu MainActor
                Task { @MainActor in
                    guard let mgr = manager, mgr.isRecording else { return }
                    mgr.audioLevel = level
                    mgr.audioBuffer.append(contentsOf: samples)

                    // VAD-Logik (wenn aktiviert)
                    if mgr.vadEnabled {
                        let effectiveThreshold = mgr.vadThreshold * mgr.vadThresholdMultiplier
                        let isAboveThreshold = rms > effectiveThreshold
                        if isAboveThreshold {
                            if !mgr.speechStarted {
                                mgr.speechStarted = true
                                mgr.vadDetected = true
                                print("[AudioRec] VAD: Sprache erkannt (threshold: \(effectiveThreshold))")
                            }
                            mgr.silenceSampleCount = 0
                        } else if mgr.speechStarted {
                            mgr.silenceSampleCount += samples.count
                            let samplesForTimeout = Int(mgr.silenceTimeoutSeconds * 16000)
                            if mgr.silenceSampleCount >= samplesForTimeout {
                                if mgr.continuousListening {
                                    print("[AudioRec] VAD: Stille erkannt, flushe Segment (continuous)")
                                    mgr.flushSpeechSegment()
                                } else {
                                    print("[AudioRec] VAD: Stille erkannt, stoppe Aufnahme")
                                    mgr.stopRecording()
                                }
                            }
                        }
                    }
                }
            }

            audioEngine = engine
            isRecording = true
            print("[AudioRec] Aufnahme gestartet (Input: \(Int(sampleRate))Hz, \(channelCount)ch)")
        } catch {
            print("[AudioRec] Engine Start fehlgeschlagen: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        continuousListening = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        audioLevel = 0
        vadDetected = false
        vadThresholdMultiplier = 1.0

        // Falls Audio vorhanden → WAV schreiben und Callback aufrufen
        if !audioBuffer.isEmpty {
            if let wavURL = writeBufferToWAV() {
                print("[AudioRec] Aufnahme gespeichert: \(wavURL.lastPathComponent) (\(audioBuffer.count) samples)")
                onSpeechCaptured?(wavURL)
            }
        }

        audioBuffer.removeAll()
        speechStarted = false
        silenceSampleCount = 0
    }

    // MARK: - Continuous Listening (Sprechen-Tab VAD)

    /// Startet Daueraufnahme — Engine läuft weiter nach jedem Speech-Segment.
    /// VAD erkennt Sprache → flusht Segment → Callback → wartet auf nächste Sprache.
    func startContinuousListening() {
        continuousListening = true
        startRecording()
    }

    /// Stoppt Daueraufnahme komplett (Engine wird beendet).
    func stopContinuousListening() {
        continuousListening = false
        stopRecording()
    }

    /// Flusht das aktuelle Speech-Segment OHNE die Engine zu stoppen.
    /// Wird im Continuous-Modus aufgerufen wenn VAD Stille erkennt.
    func flushSpeechSegment() {
        guard !audioBuffer.isEmpty else {
            speechStarted = false
            silenceSampleCount = 0
            return
        }

        if let wavURL = writeBufferToWAV() {
            print("[AudioRec] Segment geflusht: \(wavURL.lastPathComponent) (\(audioBuffer.count) samples)")
            onSpeechCaptured?(wavURL)
        }

        audioBuffer.removeAll()
        speechStarted = false
        silenceSampleCount = 0
        vadDetected = false
    }

    // MARK: - WAV Output

    private func writeBufferToWAV() -> URL? {
        guard !audioBuffer.isEmpty else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent("kobold_voice_\(UUID().uuidString.prefix(8)).wav")

        // WAV Header (44 Bytes, 16kHz, Mono, 16-bit PCM)
        let sampleRate: UInt32 = 16000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(audioBuffer.count * 2)  // 16-bit = 2 bytes pro Sample
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // Subchunk1 size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM format
        header.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        // Float → Int16 Konvertierung
        var pcmData = Data(capacity: audioBuffer.count * 2)
        for sample in audioBuffer {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            pcmData.append(withUnsafeBytes(of: int16Value.littleEndian) { Data($0) })
        }

        do {
            try (header + pcmData).write(to: wavURL)
            return wavURL
        } catch {
            print("[AudioRec] WAV-Schreiben fehlgeschlagen: \(error)")
            return nil
        }
    }
}
