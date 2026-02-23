import AppKit

// MARK: - SoundManager
// Plays macOS system sounds as feedback for agent events.
// All sounds from /System/Library/Sounds/ — no bundled audio files needed.

@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    enum SoundEvent {
        case boot           // App/Daemon gestartet
        case send           // User sendet Nachricht
        case typing         // Agent denkt/tippt (gedrosselt)
        case toolCall       // Agent ruft Tool auf
        case success        // Antwort fertig
        case error          // Fehler
        case notification   // Benachrichtigung
        case workflowStep   // Workflow-Schritt ausgeführt
        case workflowDone   // Workflow erfolgreich abgeschlossen
        case workflowFail   // Workflow fehlgeschlagen
    }

    // Sound-Mapping: Event → macOS System-Sound Dateiname
    private static let soundFiles: [SoundEvent: String] = [
        .boot:          "Hero",
        .send:          "Pop",
        .typing:        "Tink",
        .toolCall:      "Morse",
        .success:       "Glass",
        .error:         "Basso",
        .notification:  "Funk",
        .workflowStep:  "Purr",
        .workflowDone:  "Hero",
        .workflowFail:  "Sosumi",
    ]

    // Throttle: Minimum interval between typing sounds (seconds)
    private static let typingThrottleInterval: TimeInterval = 0.3

    private var lastTypingSoundTime: Date = .distantPast
    private var soundCache: [String: NSSound] = [:]

    private init() {}

    // MARK: - Public API

    func play(_ event: SoundEvent) {
        // Check global toggle
        guard UserDefaults.standard.object(forKey: "kobold.sounds.enabled") == nil
            || UserDefaults.standard.bool(forKey: "kobold.sounds.enabled") else { return }

        // Throttle typing sounds
        if event == .typing {
            let now = Date()
            guard now.timeIntervalSince(lastTypingSoundTime) >= Self.typingThrottleInterval else { return }
            lastTypingSoundTime = now
        }

        guard let fileName = Self.soundFiles[event] else { return }

        let volume = UserDefaults.standard.object(forKey: "kobold.sounds.volume") != nil
            ? Float(UserDefaults.standard.double(forKey: "kobold.sounds.volume"))
            : 0.5

        // Cache and play
        let sound: NSSound
        if let cached = soundCache[fileName] {
            sound = cached
        } else if let newSound = NSSound(named: NSSound.Name(fileName)) {
            soundCache[fileName] = newSound
            sound = newSound
        } else {
            return
        }

        // Stop if already playing (allows rapid re-trigger)
        if sound.isPlaying { sound.stop() }
        sound.volume = volume
        sound.play()
    }
}
