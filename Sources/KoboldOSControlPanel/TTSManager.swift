import Foundation
import AVFoundation
import AppKit

// MARK: - TTSManager (AVSpeechSynthesizer Wrapper)

@MainActor
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSManager()

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isSpeaking: Bool = false

    // Settings (read from UserDefaults)
    var defaultVoice: String { UserDefaults.standard.string(forKey: "kobold.tts.voice") ?? "de-DE" }
    var defaultRate: Float { Float(UserDefaults.standard.double(forKey: "kobold.tts.rate")).clamped(to: 0.1...1.0) }
    var defaultVolume: Float { Float(UserDefaults.standard.double(forKey: "kobold.tts.volume")).clamped(to: 0.0...1.0) }
    var autoSpeak: Bool { UserDefaults.standard.bool(forKey: "kobold.tts.autoSpeak") }

    private override init() {
        super.init()
        synthesizer.delegate = self
        setupNotificationListener()
    }

    // MARK: - Speak

    func speak(_ text: String, voice: String? = nil, rate: Float? = nil) {
        stop()

        let utterance = AVSpeechUtterance(string: text)

        let voiceId = voice ?? defaultVoice
        utterance.voice = AVSpeechSynthesisVoice(language: voiceId)
            ?? AVSpeechSynthesisVoice(language: "de-DE")

        utterance.rate = rate ?? defaultRate
        utterance.volume = defaultVolume
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: - Available Voices

    static var availableVoices: [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.language < $1.language }
            .map { (id: $0.language, name: $0.name, language: $0.language) }
    }

    static var availableLanguages: [String] {
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
}

// MARK: - Float Clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
