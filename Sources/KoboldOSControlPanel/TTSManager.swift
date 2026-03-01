import Foundation
import AVFoundation
import AppKit

// MARK: - TTSManager (macOS System TTS + ElevenLabs)

@MainActor
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = TTSManager()

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    // Streaming TTS (ElevenLabs PCM-Streaming für niedrige Latenz)
    private var streamingEngine: AVAudioEngine?
    private var streamingNode: AVAudioPlayerNode?
    private var streamingFormat: AVAudioFormat?
    private var streamingTask: Task<Void, Never>?

    @Published var isSpeaking: Bool = false
    @Published var elevenLabsVoices: [ElevenLabsVoice] = []
    @Published var elevenLabsError: String? = nil       // Letzer Fehler (z.B. "Bezahlplan erforderlich")
    @Published var elevenLabsCredits: Int? = nil         // Verbleibende Zeichen (nil = unbekannt)
    @Published var elevenLabsCreditsLimit: Int? = nil    // Monatliches Limit

    struct ElevenLabsVoice: Identifiable, Codable {
        let voice_id: String
        let name: String
        let language: String
        let category: String
        let preview_url: String
        var id: String { voice_id }
    }

    // Settings (read from UserDefaults)
    var defaultVoice: String { UserDefaults.standard.string(forKey: "kobold.tts.voice") ?? "de-DE" }
    var defaultRate: Float { Float(UserDefaults.standard.double(forKey: "kobold.tts.rate")).clamped(to: 0.1...1.0) }
    var defaultVolume: Float { Float(UserDefaults.standard.double(forKey: "kobold.tts.volume")).clamped(to: 0.0...1.0) }
    var autoSpeak: Bool { UserDefaults.standard.bool(forKey: "kobold.tts.autoSpeak") }
    var stripPunctuation: Bool { UserDefaults.standard.bool(forKey: "kobold.tts.stripPunctuation") }

    // ElevenLabs Settings
    var elevenLabsEnabled: Bool { UserDefaults.standard.bool(forKey: "kobold.elevenlabs.enabled") }
    var elevenLabsApiKey: String { UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? "" }
    var elevenLabsVoiceId: String { UserDefaults.standard.string(forKey: "kobold.elevenlabs.voiceId") ?? "" }
    var elevenLabsModel: String { UserDefaults.standard.string(forKey: "kobold.elevenlabs.model") ?? "eleven_flash_v2_5" }

    private override init() {
        super.init()
        synthesizer.delegate = self
        setupNotificationListener()
    }

    // MARK: - Speak (Routing: ElevenLabs oder System)

    func speak(_ text: String, voice: String? = nil, rate: Float? = nil) {
        stop()

        let processedText = stripPunctuation ? text.strippingPunctuation() : text
        guard !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if elevenLabsEnabled && !elevenLabsApiKey.isEmpty {
            speakElevenLabs(processedText, voiceId: voice)
        } else {
            speakSystem(processedText, voice: voice, rate: rate)
        }
    }

    // MARK: - System TTS (AVSpeechSynthesizer)

    private func speakSystem(_ text: String, voice: String? = nil, rate: Float? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        let voiceId = voice ?? defaultVoice
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId)
            ?? AVSpeechSynthesisVoice(language: voiceId)
            ?? AVSpeechSynthesisVoice(language: "de-DE")
        utterance.rate = rate ?? defaultRate
        utterance.volume = defaultVolume
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    // MARK: - ElevenLabs TTS

    /// Prüft ob eine Voice-ID ein ElevenLabs-Format hat (20+ alphanumerische Zeichen)
    /// vs. System-Locale ("de-DE") oder Apple-Voice-ID ("com.apple.voice...")
    private func looksLikeElevenLabsId(_ id: String) -> Bool {
        return id.count >= 15 && !id.contains(".") && !id.contains("-")
            && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private func speakElevenLabs(_ text: String, voiceId: String? = nil) {
        // Nur echte ElevenLabs Voice-IDs akzeptieren, Locale-Codes ("de-DE") ignorieren
        let vid: String
        if let provided = voiceId, !provided.isEmpty, looksLikeElevenLabsId(provided) {
            vid = provided
            print("[TTS] ElevenLabs: Verwende übergebene Voice-ID: \(vid)")
        } else {
            vid = elevenLabsVoiceId
            if let provided = voiceId, !provided.isEmpty {
                print("[TTS] ElevenLabs: '\(provided)' sieht nicht nach ElevenLabs-ID aus → verwende konfigurierte: \(vid.isEmpty ? "(leer!)" : vid)")
            }
        }
        guard !vid.isEmpty else {
            print("[TTS] ElevenLabs: Keine Voice-ID konfiguriert (kobold.elevenlabs.voiceId ist leer), Fallback auf System")
            speakSystem(text)
            return
        }

        print("[TTS] ElevenLabs Streaming: Voice=\(vid), Model=\(elevenLabsModel), Text=\(text.prefix(50))...")
        isSpeaking = true

        streamingTask = Task {
            do {
                self.elevenLabsError = nil
                // Streaming-Engine vorbereiten
                setupStreamingPlayback()

                // Streaming-Endpoint mit maximaler Latenz-Optimierung
                let urlStr = "https://api.elevenlabs.io/v1/text-to-speech/\(vid)/stream?optimize_streaming_latency=3&output_format=pcm_16000"
                guard let url = URL(string: urlStr) else { throw URLError(.badURL) }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 30

                let payload: [String: Any] = [
                    "text": text,
                    "model_id": elevenLabsModel,
                    "voice_settings": [
                        "stability": 0.5,
                        "similarity_boost": 0.75
                    ]
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let startTime = Date()
                let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0

                guard code == 200 else {
                    // Error Body lesen
                    var errData = Data()
                    for try await byte in asyncBytes {
                        errData.append(byte)
                        if errData.count > 500 { break }
                    }
                    let errorBody = String(data: errData, encoding: .utf8) ?? ""
                    print("[TTS] ElevenLabs Streaming HTTP \(code): \(errorBody)")
                    throw URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "ElevenLabs HTTP \(code): \(errorBody.prefix(200))"
                    ])
                }

                // PCM-Chunks streamen: 3200 Bytes = 100ms bei 16kHz 16-bit mono
                var pcmBuffer = Data(capacity: 3200)
                let chunkThreshold = 3200
                var firstChunkLogged = false
                var totalBytes = 0

                for try await byte in asyncBytes {
                    if Task.isCancelled { break }
                    pcmBuffer.append(byte)
                    if pcmBuffer.count >= chunkThreshold {
                        if !firstChunkLogged {
                            let ttfb = Date().timeIntervalSince(startTime)
                            print("[TTS] ElevenLabs: Erster Chunk nach \(String(format: "%.0f", ttfb * 1000))ms")
                            firstChunkLogged = true
                        }
                        totalBytes += pcmBuffer.count
                        scheduleAudioChunk(pcmBuffer)
                        pcmBuffer = Data(capacity: 3200)
                    }
                }

                // Letzten Chunk mit Completion-Callback schedulen
                if !pcmBuffer.isEmpty && !Task.isCancelled {
                    totalBytes += pcmBuffer.count
                    await scheduleFinalChunkAndWait(pcmBuffer)
                }

                let totalMs = Date().timeIntervalSince(startTime) * 1000
                let durationMs = Double(totalBytes) / 32.0  // 16kHz * 2 bytes = 32 bytes/ms
                print("[TTS] ElevenLabs Streaming fertig: \(totalBytes) bytes, \(String(format: "%.0f", durationMs))ms Audio in \(String(format: "%.0f", totalMs))ms")

                if !Task.isCancelled {
                    self.isSpeaking = false
                }

            } catch let error as URLError {
                let desc = error.localizedDescription
                print("[TTS] ElevenLabs Streaming Fehler: \(desc) — Fallback auf System")
                if desc.contains("402") || desc.contains("payment") {
                    self.elevenLabsError = "Bezahlplan erforderlich"
                } else if desc.contains("401") || desc.contains("Unauthorized") {
                    self.elevenLabsError = "Ungültiger API-Key"
                } else if desc.contains("429") {
                    self.elevenLabsError = "Rate-Limit erreicht"
                } else {
                    self.elevenLabsError = desc
                }
                teardownStreamingPlayback()
                speakSystem(text)
            } catch {
                print("[TTS] ElevenLabs Streaming Fehler: \(error.localizedDescription) — Fallback auf System")
                self.elevenLabsError = error.localizedDescription
                teardownStreamingPlayback()
                speakSystem(text)
            }
        }
    }

    // MARK: - Streaming Playback Engine (AVAudioPlayerNode für PCM-Chunks)

    private func setupStreamingPlayback() {
        guard streamingEngine == nil else { return }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            print("[TTS] Streaming-Format ungültig")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            node.play()
            streamingEngine = engine
            streamingNode = node
            streamingFormat = format
        } catch {
            print("[TTS] Streaming Engine Fehler: \(error)")
        }
    }

    private func scheduleAudioChunk(_ pcmData: Data) {
        guard let node = streamingNode, let format = streamingFormat else { return }
        let sampleCount = pcmData.count / 2  // 16-bit = 2 bytes pro Sample
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmData.withUnsafeBytes { rawPtr in
            if let src = rawPtr.baseAddress {
                memcpy(buffer.int16ChannelData![0], src, pcmData.count)
            }
        }
        node.scheduleBuffer(buffer)
    }

    /// Schedulet den letzten Chunk und wartet bis er abgespielt wurde
    private func scheduleFinalChunkAndWait(_ pcmData: Data) async {
        guard let node = streamingNode, let format = streamingFormat else { return }
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmData.withUnsafeBytes { rawPtr in
            if let src = rawPtr.baseAddress {
                memcpy(buffer.int16ChannelData![0], src, pcmData.count)
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                cont.resume()
            }
        }
    }

    private func teardownStreamingPlayback() {
        streamingNode?.stop()
        streamingEngine?.stop()
        streamingEngine = nil
        streamingNode = nil
        streamingFormat = nil
    }

    // MARK: - ElevenLabs Voice Loading

    func loadElevenLabsVoices() async {
        guard !elevenLabsApiKey.isEmpty else { elevenLabsVoices = []; return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return }

        var req = URLRequest(url: url)
        req.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = json["voices"] as? [[String: Any]] else { return }

            elevenLabsVoices = voices.compactMap { v in
                guard let id = v["voice_id"] as? String,
                      let name = v["name"] as? String else { return nil }
                let labels = v["labels"] as? [String: String] ?? [:]
                let lang = labels["language"] ?? labels["accent"] ?? "multilingual"
                let category = v["category"] as? String ?? ""
                let previewUrl = v["preview_url"] as? String ?? ""
                return ElevenLabsVoice(voice_id: id, name: name, language: lang,
                                       category: category, preview_url: previewUrl)
            }
        } catch {
            print("[TTS] ElevenLabs Voices laden fehlgeschlagen: \(error)")
        }
    }

    // MARK: - ElevenLabs Credits/Subscription abfragen

    func loadElevenLabsCredits() async {
        guard !elevenLabsApiKey.isEmpty else { return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else { return }

        var req = URLRequest(url: url)
        req.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

            guard code == 200 else {
                // API-Key hat möglicherweise keine user_read Permission
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let detail = json["detail"] as? [String: Any],
                   let status = detail["status"] as? String {
                    if status == "missing_permissions" {
                        print("[TTS] ElevenLabs Credits: API-Key hat keine user_read Permission — Credits nicht abrufbar")
                        // Kein Fehler anzeigen, Credits bleiben einfach nil
                    } else {
                        print("[TTS] ElevenLabs Credits: \(status)")
                    }
                } else {
                    print("[TTS] ElevenLabs Credits: HTTP \(code)")
                }
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            // character_count = verbraucht, character_limit = monatliches Limit
            if let used = json["character_count"] as? Int,
               let limit = json["character_limit"] as? Int {
                elevenLabsCredits = limit - used
                elevenLabsCreditsLimit = limit
                print("[TTS] ElevenLabs Credits: \(limit - used)/\(limit) Zeichen verbleibend")
            }

            // Tier/Plan anzeigen
            if let tier = json["tier"] as? String {
                print("[TTS] ElevenLabs Plan: \(tier)")
                if tier == "free" {
                    elevenLabsError = "Kostenloser Plan — Library-Stimmen nicht via API verfügbar. Bezahlten Plan aktivieren oder eigene Stimme klonen."
                }
            }
        } catch {
            print("[TTS] ElevenLabs Credits laden fehlgeschlagen: \(error)")
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        // Streaming TTS stoppen
        streamingTask?.cancel()
        streamingTask = nil
        streamingNode?.stop()
        streamingNode?.play()  // Reset für nächste Chunks
        isSpeaking = false
    }

    // MARK: - Available Voices

    struct SystemVoice: Identifiable {
        let id: String       // AVSpeechSynthesisVoice.identifier
        let name: String
        let language: String
        let quality: String
    }

    struct VoiceGroup: Identifiable {
        let language: String
        let voices: [SystemVoice]
        var id: String { language }
    }

    nonisolated static var allSystemVoices: [SystemVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
            .map { voice in
                let quality: String
                switch voice.quality {
                case .enhanced: quality = "Enhanced"
                case .premium:  quality = "Premium"
                default:        quality = "Standard"
                }
                return SystemVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
            }
    }

    nonisolated static var groupedVoices: [VoiceGroup] {
        let voices = allSystemVoices
        let grouped = Dictionary(grouping: voices, by: { $0.language })
        return grouped.keys.sorted().map { lang in
            VoiceGroup(language: lang, voices: grouped[lang] ?? [])
        }
    }

    nonisolated static var availableLanguages: [String] {
        Array(Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))).sorted()
    }

    // MARK: - Notification Listener (from TTSTool)

    private func setupNotificationListener() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("koboldTTSSpeak"),
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            let text = notif.userInfo?["text"] as? String ?? ""
            let voice = notif.userInfo?["voice"] as? String
            let rateStr = notif.userInfo?["rate"] as? String
            let rate = rateStr.flatMap { Float($0) }
            guard !text.isEmpty else { return }
            MainActor.assumeIsolated {
                self.speak(text, voice: voice, rate: rate)
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    // MARK: - AVAudioPlayerDelegate (ElevenLabs MP3 Playback)

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.audioPlayer = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.isSpeaking = false
            self.audioPlayer = nil
        }
    }
}

// MARK: - String Extension: Punctuation Stripping

private extension String {
    /// Entfernt Satzzeichen aber behält Wörter, Zahlen und Leerzeichen
    func strippingPunctuation() -> String {
        // Behalte: Buchstaben, Zahlen, Leerzeichen, Zeilenumbrüche
        // Entferne: . , ; : ! ? " ' ( ) [ ] { } - _ / \ @ # $ % ^ & * ~ ` < > |
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(.newlines)
        return unicodeScalars.filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .replacingOccurrences(of: "  ", with: " ") // Doppelte Leerzeichen entfernen
    }
}

// MARK: - Float Clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
