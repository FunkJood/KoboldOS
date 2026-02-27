import Foundation

// MARK: - Skill
// A markdown file from ~/Library/Application Support/KoboldOS/Skills/

public struct Skill: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let filename: String
    public let content: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, filename: String, content: String, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.filename = filename
        self.content = content
        self.isEnabled = isEnabled
    }
}

// MARK: - SkillLoader

public actor SkillLoader {
    public static let shared = SkillLoader()

    private let enabledKey = "kobold.skills.enabled"

    // A2: In-memory cache to avoid repeated disk reads (22+ file reads per message)
    private var cachedSkills: [Skill]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 60 // 1 minute

    private var skillsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
    }

    /// Invalidate cache when settings change (e.g. skill toggled)
    public func invalidateCache() {
        cachedSkills = nil
        cacheTimestamp = nil
    }

    // MARK: - Load

    public func loadSkills() async -> [Skill] {
        // Return cached if still fresh
        if let cached = cachedSkills, let ts = cacheTimestamp, Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        createDefaultSkillsIfNeeded()

        guard let files = try? fm.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let enabledNames = UserDefaults.standard.stringArray(forKey: enabledKey) ?? []

        let result = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> Skill? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return Skill(
                    name: name,
                    filename: url.lastPathComponent,
                    content: content,
                    isEnabled: enabledNames.contains(name)
                )
            }
            .sorted { $0.name < $1.name }

        cachedSkills = result
        cacheTimestamp = Date()
        return result
    }

    // MARK: - Toggle

    public func setEnabled(_ skillName: String, enabled: Bool) {
        var names = UserDefaults.standard.stringArray(forKey: enabledKey) ?? []
        if enabled {
            if !names.contains(skillName) { names.append(skillName) }
        } else {
            names.removeAll { $0 == skillName }
        }
        UserDefaults.standard.set(names, forKey: enabledKey)
        invalidateCache()
    }

    // MARK: - Build Prompt Injection

    /// Sucht relevante Skills per Keyword-Match und gibt passende Snippets zurück
    public func relevantSkills(query: String) async -> String {
        guard !query.isEmpty else { return "" }
        let skills = await loadSkills()
        let enabled = skills.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return "" }

        let queryLower = query.lowercased()
        let keywords = queryLower.split(separator: " ").map(String.init)

        let matches = enabled.filter { skill in
            let content = (skill.name + " " + skill.content).lowercased()
            return keywords.contains(where: { content.contains($0) })
        }

        guard !matches.isEmpty else { return "" }
        let snippets = matches.prefix(3).map { "### Skill: \($0.name)\n\($0.content)" }.joined(separator: "\n\n")
        return "\n\n## Relevante Skills\n\(snippets)"
    }

    /// Returns a prompt string with all enabled skills appended, ready for system prompt injection.
    public func enabledSkillsPrompt() async -> String {
        let skills = await loadSkills()
        let enabled = skills.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return "" }
        let sections = enabled.map { "### Skill: \($0.name)\n\($0.content)" }.joined(separator: "\n\n")
        return "\n\n---\n## Active Skills\n\n\(sections)"
    }

    // MARK: - Default Skills

    private let currentSkillsVersion = "v0.3.2"

    private func createDefaultSkillsIfNeeded() {
        let marker = skillsDir.appendingPathComponent(".defaults_installed")
        if let existing = try? String(contentsOf: marker, encoding: .utf8),
           existing == currentSkillsVersion { return }
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let defaults: [(String, String)] = [
            ("code_ausfuehren", """
            # Code ausführen

            Du kannst Code in beliebigen Sprachen ausführen.

            ## Python
            ```json
            {"tool_name": "shell", "tool_args": {"command": "python3 -c 'print(42 * 7)'"}}
            ```
            Für längere Scripts: Datei schreiben, dann ausführen:
            ```json
            {"tool_name": "file", "tool_args": {"action": "write", "path": "/tmp/script.py", "content": "import sys\\nprint(sys.version)"}}
            ```
            ```json
            {"tool_name": "shell", "tool_args": {"command": "python3 /tmp/script.py"}}
            ```

            ## Node.js
            ```json
            {"tool_name": "shell", "tool_args": {"command": "node -e 'console.log(JSON.stringify({ok: true}))'"}}
            ```

            ## Shell/Bash
            ```json
            {"tool_name": "shell", "tool_args": {"command": "echo $SHELL && uname -a"}}
            ```
            """),

            ("websuche", """
            # Websuche & Websites

            Du kannst im Web suchen und Websites abrufen.

            ## Suchen
            ```json
            {"tool_name": "browser", "tool_args": {"action": "search", "query": "Swift 6 concurrency tutorial"}}
            ```

            ## Website lesen
            ```json
            {"tool_name": "browser", "tool_args": {"action": "fetch", "url": "https://example.com"}}
            ```

            ## API aufrufen
            ```json
            {"tool_name": "browser", "tool_args": {"action": "fetch", "url": "https://api.example.com/data", "method": "POST", "headers": "{\\"Content-Type\\": \\"application/json\\"}", "body": "{\\"key\\": \\"value\\"}"}}
            ```

            Tipps:
            - Fasse lange Webseiten kurz zusammen
            - Bei Fehlern: probiere alternative URLs
            - Speichere nützliche API-Endpoints in knowledge-Memory
            """),

            ("dateiverwaltung", """
            # Dateiverwaltung

            Du hast vollen Zugriff auf das Dateisystem des Nutzers.

            ## Ordner auflisten
            ```json
            {"tool_name": "file", "tool_args": {"action": "list", "path": "~/Desktop"}}
            ```

            ## Datei lesen
            ```json
            {"tool_name": "file", "tool_args": {"action": "read", "path": "~/Documents/notiz.txt"}}
            ```

            ## Datei schreiben
            ```json
            {"tool_name": "file", "tool_args": {"action": "write", "path": "~/Desktop/output.txt", "content": "Inhalt hier"}}
            ```

            ## Häufige Pfade
            - Desktop: ~/Desktop
            - Dokumente: ~/Documents
            - Downloads: ~/Downloads
            - Home: ~/ oder /Users/{username}
            - Temp: verwende /tmp/ für temporäre Dateien

            Tipps:
            - Prüfe mit "exists" ob eine Datei vorhanden ist bevor du sie überschreibst
            - Erstelle Backups vor dem Überschreiben wichtiger Dateien
            """),

            ("aufgaben_planen", """
            # Aufgaben planen

            Du kannst geplante Aufgaben erstellen die automatisch ausgeführt werden.

            ## Aufgabe erstellen
            ```json
            {"tool_name": "task_manage", "tool_args": {"action": "create", "name": "Morgen-Briefing", "prompt": "Fasse die wichtigsten Tech-News von heute zusammen", "schedule": "0 8 * * *"}}
            ```

            ## Cron-Syntax
            - `*/5 * * * *` = alle 5 Minuten
            - `0 * * * *` = jede Stunde
            - `0 8 * * *` = täglich um 8:00
            - `0 9 * * 1-5` = Werktags um 9:00
            - `0 9 * * 1` = Montags um 9:00

            ## Aufgaben verwalten
            ```json
            {"tool_name": "task_manage", "tool_args": {"action": "list"}}
            {"tool_name": "task_manage", "tool_args": {"action": "delete", "id": "task_id"}}
            ```

            Tipps:
            - Manuell = nur auf Knopfdruck (kein Schedule)
            - Nutzer kann Tasks im Tasks-Tab der App sehen und starten
            """),

            ("delegation", """
            # Aufgaben delegieren

            Du kannst Aufgaben an spezialisierte Sub-Agenten delegieren.

            ## Einzelner Sub-Agent
            ```json
            {"tool_name": "call_subordinate", "tool_args": {"profile": "coder", "message": "Schreibe eine Python-Funktion die Primzahlen berechnet"}}
            ```

            ## Parallele Delegation
            ```json
            {"tool_name": "delegate_parallel", "tool_args": {"tasks": "[{\\"profile\\": \\"coder\\", \\"message\\": \\"Schreibe Tests\\"}, {\\"profile\\": \\"web\\", \\"message\\": \\"Recherchiere Best Practices\\"}]"}}
            ```

            ## Profile
            - **coder**: Code schreiben, Debugging, Architektur
            - **web**: Recherche, Web-Suche, APIs, Reports
            - **reviewer**: Code-Review, Qualitätsprüfung
            - **utility**: System-Aufgaben, Dateien, Shell
            - **general**: Allgemeine Aufgaben (Standard)

            Tipps:
            - Gib Sub-Agenten klare, spezifische Aufgaben
            - Nutze Delegation bei komplexen Aufgaben mit mehreren Schritten
            - Parallele Delegation spart Zeit bei unabhängigen Teilaufgaben
            """),

            ("system_info", """
            # System-Informationen

            Du kannst macOS-Systeminformationen abfragen.

            ## Häufige Befehle
            - `whoami` — Aktueller Benutzer
            - `uname -a` — Betriebssystem-Info
            - `sw_vers` — macOS-Version
            - `df -h` — Festplattenplatz
            - `top -l 1 -n 5` — CPU/RAM Auslastung
            - `ps aux | head -20` — Laufende Prozesse
            - `ifconfig | grep inet` — Netzwerk-Adressen
            - `brew list` — Installierte Homebrew-Pakete
            - `which python3 node git` — Installierte Tools prüfen

            ```json
            {"tool_name": "shell", "tool_args": {"command": "sw_vers && echo '---' && df -h / && echo '---' && uptime"}}
            ```

            Tipps:
            - Kombiniere mehrere Befehle mit && oder ;
            - Speichere häufig benötigte Pfade im knowledge-Memory
            """),

            ("dokument_analyse", """
            # Dokumente analysieren

            Du kannst PDF, HTML, Office-Dokumente und andere Textdateien analysieren.

            ## PDF lesen
            ```json
            {"tool_name": "document_query", "tool_args": {"path": "~/Documents/vertrag.pdf", "query": "Was sind die Hauptbedingungen?"}}
            ```

            ## HTML-Seite analysieren
            ```json
            {"tool_name": "document_query", "tool_args": {"path": "/tmp/page.html", "query": "Fasse den Inhalt zusammen"}}
            ```

            ## Office-Dokumente
            ```json
            {"tool_name": "document_query", "tool_args": {"path": "~/Documents/bericht.docx", "query": "Liste alle Empfehlungen auf"}}
            ```

            ## Remote-Dokument
            ```json
            {"tool_name": "browser", "tool_args": {"action": "fetch", "url": "https://example.com/report.pdf"}}
            ```

            Tipps:
            - Stelle präzise Fragen für bessere Ergebnisse
            - Große Dokumente werden automatisch in Abschnitte zerlegt
            - Ergebnisse im knowledge-Memory speichern für spätere Nutzung
            """),

            ("bild_analyse", """
            # Bilder analysieren (Vision)

            Du kannst Bilder mit einem Vision-LLM analysieren und beschreiben.

            ## Einzelnes Bild
            ```json
            {"tool_name": "vision_load", "tool_args": {"path": "~/Desktop/screenshot.png", "query": "Was siehst du auf diesem Bild?"}}
            ```

            ## Mehrere Bilder vergleichen
            ```json
            {"tool_name": "vision_load", "tool_args": {"path": "~/Desktop/vorher.png", "query": "Beschreibe dieses Bild"}}
            ```
            ```json
            {"tool_name": "vision_load", "tool_args": {"path": "~/Desktop/nachher.png", "query": "Was hat sich im Vergleich geändert?"}}
            ```

            ## Screenshot vom Bildschirm
            ```json
            {"tool_name": "shell", "tool_args": {"command": "screencapture -x /tmp/screen.png"}}
            ```
            ```json
            {"tool_name": "vision_load", "tool_args": {"path": "/tmp/screen.png", "query": "Was ist auf dem Bildschirm zu sehen?"}}
            ```

            Unterstützte Formate: PNG, JPG, JPEG, GIF, BMP, TIFF, WebP
            """),

            ("antwort_tools", """
            # Antwort & Kommunikation

            ## Finale Antwort an den Nutzer
            Wenn du deine Arbeit abgeschlossen hast, nutze das response-Tool:
            ```json
            {"tool_name": "response", "tool_args": {"message": "Hier ist das Ergebnis deiner Anfrage..."}}
            ```
            Das response-Tool signalisiert dem System dass deine Antwort vollständig ist.

            ## Benachrichtigungen senden
            Für wichtige Hinweise oder Warnungen während der Arbeit:
            ```json
            {"tool_name": "notify_user", "tool_args": {"title": "Aufgabe erledigt", "message": "Der Report wurde unter ~/Desktop/report.pdf gespeichert."}}
            ```
            Benachrichtigungen erscheinen als macOS-Notification — ideal für:
            - Langläufige Tasks die fertig sind
            - Wichtige Warnungen (Speicherplatz knapp, Fehler aufgetreten)
            - Erinnerungen an den Nutzer

            ## Nutzer-Eingabe anfordern
            Wenn du eine Entscheidung oder Information vom Nutzer brauchst, frag direkt per response:
            ```json
            {"tool_name": "response", "tool_args": {"message": "Soll ich die Datei überschreiben? Bitte antworte mit ja oder nein."}}
            ```

            Tipps:
            - Nutze `response` am Ende jeder abgeschlossenen Aufgabe
            - `notify_user` für Hintergrund-Tasks die lange dauern
            - Frag per `response` wenn du eine Entscheidung brauchst — der Nutzer antwortet dann
            """),

            ("api_skill_erstellen", """
            # API-Skills automatisch erstellen

            Wenn du eine neue API kennenlernst oder erfolgreich nutzt, erstelle automatisch einen Skill dafür.

            ## Skill-Datei erstellen
            ```json
            {"tool_name": "file", "tool_args": {"action": "write", "path": "~/Library/Application Support/KoboldOS/Skills/{api_name}.md", "content": "# {API Name}\\n\\nBasis-URL: https://api.example.com\\nAuth: Bearer {token}\\n\\n## Endpunkte\\n\\n### GET /resource\\n```json\\n{\\"tool_name\\": \\"browser\\", \\"tool_args\\": {\\"action\\": \\"fetch\\", \\"url\\": \\"https://api.example.com/resource\\", \\"headers\\": \\"{\\\\\\"Authorization\\\\\\": \\\\\\"Bearer {token}\\\\\\"}\\"}}\\n```\\n"}}
            ```

            ## Vorlage für API-Skills
            Jeder API-Skill sollte enthalten:
            1. **Titel** — Name der API
            2. **Basis-URL** — Hauptendpunkt
            3. **Authentifizierung** — Wie man sich authentifiziert (API Key, Bearer Token, Basic Auth)
            4. **Endpunkte** — Die wichtigsten Endpunkte mit Beispiel-JSON-Aufrufen
            5. **Antwortformat** — Wie die Antworten aussehen

            ## Wann erstellen
            - Wenn du eine API erfolgreich aufgerufen hast
            - Wenn der Nutzer dir API-Credentials gibt
            - Wenn du eine API-Dokumentation liest

            ## API-Key speichern
            Speichere den API-Key IMMER im Keychain, NICHT im Skill:
            ```json
            {"tool_name": "shell", "tool_args": {"command": "security add-generic-password -a 'kobold' -s 'api_name' -w 'secret_key' -U"}}
            ```

            Tipps:
            - Erstelle Skills auf Deutsch
            - Nutze den Skill-Namen als Dateinamen (lowercase, underscores)
            - Teste den API-Aufruf bevor du den Skill speicherst
            """),

            ("memory_verwaltung", """
            # Memory verwalten

            Du hast ein dreistufiges Gedächtnis das du aktiv pflegen musst.

            ## Langzeit-Memory (human)
            Permanente Fakten über den Nutzer:
            ```json
            {"tool_name": "core_memory_append", "tool_args": {"label": "human", "content": "Name: Tim, Entwickler, arbeitet mit Swift und Python"}}
            ```

            ## Kurzzeit-Memory (short_term)
            Aktueller Kontext der Session:
            ```json
            {"tool_name": "core_memory_append", "tool_args": {"label": "short_term", "content": "Arbeitet gerade an einem neuen Feature"}}
            ```

            ## Wissens-Memory (knowledge)
            Gelernte Lösungen und Muster:
            ```json
            {"tool_name": "core_memory_append", "tool_args": {"label": "knowledge", "content": "macOS screencapture: -x flag für lautlos, -R für Region"}}
            ```

            ## Memory korrigieren
            ```json
            {"tool_name": "core_memory_replace", "tool_args": {"label": "human", "old_content": "arbeitet mit Java", "new_content": "arbeitet mit Swift und Python"}}
            ```

            ## Wann was speichern
            - **human**: Namen, Beruf, Vorlieben, Gewohnheiten, Sprachen
            - **short_term**: Aktuelles Projekt, offene Aufgaben, Kontext
            - **knowledge**: Gelöste Probleme, Befehle, Tricks, API-Infos
            """),
        ]

        for (name, content) in defaults {
            let path = skillsDir.appendingPathComponent("\(name).md")
            try? content.write(to: path, atomically: true, encoding: .utf8)
        }

        // Enable some by default
        let enableByDefault = [
            "code_ausfuehren", "websuche", "dateiverwaltung", "delegation",
            "system_info", "aufgaben_planen", "dokument_analyse", "bild_analyse",
            "antwort_tools", "memory_verwaltung", "api_skill_erstellen"
        ]
        UserDefaults.standard.set(enableByDefault, forKey: enabledKey)

        // Write versioned marker so upgrades can install new skills
        try? currentSkillsVersion.write(to: marker, atomically: true, encoding: .utf8)
    }
}
