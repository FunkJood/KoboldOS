import SwiftUI
import Foundation

// MARK: - SuggestionService
// Generates dynamic suggestions via Ollama, caches for 4 hours, falls back to hardcoded

@MainActor
class SuggestionService: ObservableObject {
    static let shared = SuggestionService()

    @Published var dashboardGreeting: String = ""
    @Published var chatSuggestions: [String] = []
    @Published var taskSuggestions: [TaskSuggestionItem] = []
    @Published var isLoading: Bool = false

    struct TaskSuggestionItem: Codable, Identifiable {
        var id: String { name }
        let name: String
        let prompt: String
        let schedule: String
    }

    private struct CachedData: Codable {
        let timestamp: Date
        let greeting: String
        let chatPrompts: [String]
        let tasks: [TaskSuggestionItem]
    }

    private struct GeneratedJSON: Codable {
        let greeting: String?
        let chatPrompts: [String]?
        let tasks: [TaskJSON]?
        struct TaskJSON: Codable {
            let name: String
            let prompt: String
            let schedule: String?
        }
    }

    private let cacheKey = "kobold.suggestions.cache"
    private let cacheDuration: TimeInterval = 4 * 3600

    func generateSuggestions(forceRefresh: Bool = false) async {
        // Check cache
        if !forceRefresh, let cached = loadCache(),
           Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            applyCache(cached)
            return
        }

        isLoading = true
        defer { isLoading = false }

        let model = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "qwen2.5:3b"
        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
        let dayName = dayNames[weekday - 1]

        let systemPrompt = """
        Du bist der KoboldOS-Assistent. Es ist \(dayName), \(hour) Uhr.
        Generiere auf Deutsch:
        1. Eine witzige, kurze Begrüßung im Kobold-Stil (max 80 Zeichen, wie "Dein Kobold hat Kaffee gekocht.")
        2. Vier kreative Chat-Vorschläge (praktische macOS-Aufgaben die ein KI-Agent erledigen kann, fortgeschrittene und einfache gemischt)
        3. Drei Automatisierungs-Vorschläge mit Name, Prompt und Zeitplan

        Antworte NUR als JSON:
        {"greeting":"...","chatPrompts":["...","...","...","..."],"tasks":[{"name":"...","prompt":"...","schedule":"Täglich 08:00"},{"name":"...","prompt":"...","schedule":"Wöchentlich"},{"name":"...","prompt":"...","schedule":"Alle 4 Stunden"}]}
        """

        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            applyFallback()
            return
        }

        let payload: [String: Any] = [
            "model": model,
            "prompt": systemPrompt,
            "stream": false,
            "options": ["temperature": 0.9, "num_predict": 512]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else {
                applyFallback(); return
            }

            // Extract JSON from response (may have markdown wrapping)
            let cleaned = response
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let responseData = cleaned.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(GeneratedJSON.self, from: responseData) {
                dashboardGreeting = parsed.greeting ?? fallbackGreeting()
                chatSuggestions = parsed.chatPrompts ?? fallbackChatPrompts()
                taskSuggestions = (parsed.tasks ?? []).map {
                    TaskSuggestionItem(name: $0.name, prompt: $0.prompt, schedule: $0.schedule ?? "Manuell")
                }
                if taskSuggestions.isEmpty { taskSuggestions = fallbackTaskSuggestions() }

                saveCache(CachedData(
                    timestamp: Date(),
                    greeting: dashboardGreeting,
                    chatPrompts: chatSuggestions,
                    tasks: taskSuggestions
                ))
            } else {
                applyFallback()
            }
        } catch {
            applyFallback()
        }
    }

    // MARK: - Cache

    private func loadCache() -> CachedData? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedData.self, from: data)
    }

    private func saveCache(_ cache: CachedData) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func applyCache(_ cache: CachedData) {
        dashboardGreeting = cache.greeting
        chatSuggestions = cache.chatPrompts
        taskSuggestions = cache.tasks
    }

    // MARK: - Fallbacks

    private func applyFallback() {
        dashboardGreeting = fallbackGreeting()
        chatSuggestions = fallbackChatPrompts()
        taskSuggestions = fallbackTaskSuggestions()
    }

    private func fallbackGreeting() -> String {
        let greetings = [
            "Dein Kobold hat Kaffee gekocht. Na ja, fast.",
            "Der Kobold wartet schon ungeduldig auf Befehle.",
            "Heute hat dein Kobold 0 Fehler gemacht. Noch.",
            "Psst... dein Kobold hat heimlich aufgeräumt.",
            "Dein Kobold ist bereit. Die Welt noch nicht.",
            "Lass uns was Cooles bauen. Oder wenigstens was Nützliches.",
            "Bereit für Chaos? Dein Kobold ist es.",
            "Kobold-Status: Motiviert und einsatzbereit.",
            "Dein Kobold hat 42 Ideen. Die meisten sind sogar gut.",
            "Die KI ist wach, der Mensch hoffentlich auch.",
            "Fehlerrate heute: 0%. Noch ist der Tag jung.",
            "Dein Kobold denkt mit. Manchmal sogar voraus.",
            "Dein Kobold ist so bereit, er vibriert fast.",
            "Heute im Angebot: Produktivität zum Bestpreis.",
            "Spoiler: Heute wird ein guter Tag.",
            "System läuft. Kobold läuft. Du auch?",
        ]
        let seed = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let hour = Calendar.current.component(.hour, from: Date())
        return greetings[(seed * 24 + hour) % greetings.count]
    }

    private func fallbackChatPrompts() -> [String] {
        let all = [
            "Räum meinen Desktop auf und sortiere nach Dateityp",
            "Welche Prozesse fressen gerade am meisten CPU?",
            "Generiere ein Bild von einem Drachen auf einer Burg",
            "Finde alle Dateien über 1 GB auf meinem Mac",
            "Erstelle ein Python-Skript das PDFs zusammenführt",
            "Komprimiere alle PNGs auf dem Desktop zu einem ZIP",
            "Lösche alle .DS_Store Dateien rekursiv",
            "Zeig mir die Git-History von diesem Projekt",
            "Erstelle einen Cronjob der täglich Logs aufräumt",
            "Finde alle offenen Ports auf meinem Mac",
            "Erstelle ein Bild im Anime-Stil von einer Katze",
            "Scanne mein WLAN und zeig alle verbundenen Geräte",
            "Führe dieses Python-Skript aus und zeig mir die Ausgabe",
            "Ändere mein Wallpaper auf ein zufälliges von Unsplash",
            "Prüfe ob meine Webseite erreichbar ist",
            "Wie viel Speicherplatz ist noch frei?",
            "Analysiere mein Git-Repo auf Code-Qualität",
            "Konvertiere dieses Video zu MP4 mit FFmpeg",
            "Erstelle eine Zusammenfassung der letzten 10 PDFs auf dem Desktop",
            "Schreibe einen Newsletter-Entwurf über KI-Trends",
        ]
        let seed = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let hour = Calendar.current.component(.hour, from: Date())
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed * 100 + hour))
        return Array(all.shuffled(using: &rng).prefix(4))
    }

    private func fallbackTaskSuggestions() -> [TaskSuggestionItem] {
        [
            TaskSuggestionItem(name: "System-Report", prompt: "Erstelle einen Bericht über CPU, RAM und Speichernutzung", schedule: "Stündlich"),
            TaskSuggestionItem(name: "Desktop aufräumen", prompt: "Sortiere Dateien auf dem Desktop nach Typ in Unterordner", schedule: "Täglich 18:00"),
            TaskSuggestionItem(name: "Backup-Check", prompt: "Prüfe ob alle wichtigen Ordner ein aktuelles Backup haben", schedule: "Wöchentlich"),
        ]
    }

    func iconForTask(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("backup") { return "externaldrive.fill" }
        if lower.contains("email") || lower.contains("mail") { return "envelope.fill" }
        if lower.contains("desktop") || lower.contains("aufräum") { return "trash.fill" }
        if lower.contains("bericht") || lower.contains("report") || lower.contains("system") { return "chart.bar.fill" }
        if lower.contains("sicherheit") || lower.contains("security") { return "lock.shield.fill" }
        if lower.contains("netzwerk") || lower.contains("network") || lower.contains("scan") { return "antenna.radiowaves.left.and.right" }
        if lower.contains("git") { return "arrow.triangle.branch" }
        if lower.contains("kalender") || lower.contains("termin") { return "calendar" }
        if lower.contains("wetter") { return "cloud.fill" }
        return "gearshape.fill"
    }
}

// MARK: - Seeded RNG for deterministic shuffling

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
