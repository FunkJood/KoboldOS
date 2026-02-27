# KoboldOS Changelog

## Alpha v0.3.2 — 2026-02-27

### UI & Settings Overhaul
- **Tab "Modelle" entfernt**: Ollama-Status + Worker-Pool in "Agenten" integriert
- **Context-Bar**: Formatierte Token-Anzeige (32K statt 32768), Komprimieren-Button, persistent sichtbar pro Chat
- **TTS-Speaker-Button**: Lautsprecher-Icon an jeder Assistant-Nachricht (hover)
- **Settings-Beschreibungen**: Erklärende Texte zu allen wichtigen Toggles und Pickern
- **Tabs reorganisiert**: "Datenschutz" + "Sicherheit" statt alte Namen, Provider-Picker entfernt (nur Ollama)
- **AgentsView**: Aktive Sessions entfernt, Tool Routing einklappbar

### Berechtigungen & Autonomie
- **Permission-Defaults**: `UserDefaults.register(defaults:)` in AppDelegate — alle 17 Keys haben korrekte Defaults ab Start
- **Autonomie-Level Fix**: Default Normal (2) statt Safe (1) bei nie gesetztem Wert (ShellTool + AgentLoop)
- **Agent-Prompt**: Level 2+ bekommt "nutze Tools selbstständig ohne nachzufragen"
- **ToolEngine-Rules**: "confirm with the user first" entfernt — Permissions vom System verwaltet

### Freeze-Fixes
- **isAgentLoadingInCurrentChat**: Computed Property statt undefined
- **Timer-Guards**: MemoryView 15s + isLoading-Guard, ThinkingPanel isLive-Guard, Connectivity 4s Timeout

### Startup-Checks
- **Ollama**: HTTP-Check bei Start (GET /api/tags), Status grün/rot
- **Embedding**: Prüft ob nomic-embed-text verfügbar ist

### Telegram-Bot
- **Persistente History**: JSON auf Disk, überlebt Neustarts
- **Source-Tag**: "telegram" wird beim Daemon-Call mitgesendet

### Skills-Integration
- **SkillLoader.relevantSkills()**: Keyword-Match durchsucht Skills pro Query
- **AgentLoop**: Relevante Skills werden in System-Prompt injiziert

### Aufräumen
- **Entfernt**: docker/, linux/, WebGUI, MCP (3 Dateien + alle Referenzen), MenuBarController, ImageGenManager, LlamaService
- **Versionsnummern**: Alle auf v0.3.2 vereinheitlicht

### Statistik
- ~50.185 Lines of Code (Swift)

---

## Alpha v0.3.16 — 2026-02-25

### Sub-Agent Live-Streaming
- **SubAgentStepRelay Actor**: Leitet Sub-Agent-Schritte live an den Parent-Stream weiter.
- **DelegateTaskTool**: Nutzt jetzt `runStreaming()` statt `run()` für Echtzeit-Feedback.
- **Thinking-Box**: Sub-Agent Think/ToolCall/ToolResult erscheinen live im UI.
- **Profil-Tags**: Steps werden mit `[profil]` getaggt für visuelle Unterscheidung.
- **AgentLoop**: `agentID` als public Property gespeichert.

### @StateObject Render-Loop Fix
- **@ObservedObject Migration**: 12x `@StateObject` mit `.shared` Singletons wurden durch `@ObservedObject` ersetzt.
- **Betroffene Views**: DashboardView, SettingsView, MainView, OnboardingView, AgentsView.
- **CPU-Optimierung**: Verhindert kaskadierende `objectWillChange` Render-Loops.

### Timeouts & Stabilität
- **Sub-Agent Default**: Timeout auf 600s (10 Min) erhöht (war 300s).
- **Tool-Timeout**: Auf 300s erhöht (war 120s).
- **Delegate-Timeout**: Auf 900s (15 Min) erhöht (war 300s).
- **SettingsView Fix**: Defekte MCP-Referenzen und Code-Fragmentierung bereinigt.

### Statistik
- ~48.400 Lines of Code (Swift)

---

## Alpha v0.3.15 — 2026-02-25

### Semantisches RAG-System (Echte Vektorsuche für Gedächtnis)
- **EmbeddingRunner**: Neuer Swift Actor — sendet Text an `ollama api/embeddings` (nomic-embed-text)
- **EmbeddingStore**: Persistenter Vektor-Store mit vDSP/Accelerate Cosinus-Ähnlichkeit (SIMD-optimiert)
- **smartMemoryRetrieval** ersetzt durch echte Semantik: Top-5 Treffer statt alle ~100 Einträge
- **Token-Ersparnis**: ~3000 → ~150 Tokens pro Anfrage (95% weniger Kontext-Overhead)
- **Fallback**: Bei fehlendem nomic-embed-text automatisch TF-IDF (bisheriges System)
- **Startup-Logik**: `reembedMissing()` embedded fehlende Einträge beim App-Start (Background Task)
- **Settings → Gedächtnis**: Neue "Embedding-Modell (RAG)"-Box mit Status-Check + `ollama pull`-Button
- **Voraussetzung**: `ollama pull nomic-embed-text` (274 MB, einmalig)

### Einzelne Memory-Dateien (statt entries.json)
- **MemoryStore** speichert jede Erinnerung als eigene `<id>.json` (statt einem großen Array)
- **Automatische Migration**: Alte `entries.json` wird beim Start in Einzeldateien umgewandelt und gelöscht
- **Vorteile**: Schnelleres Speichern, kein Datenverlust bei Korruption einer einzelnen Datei
- **update()** re-embedded geänderte Einträge automatisch

### Memory bearbeitbar
- **Bearbeiten-Button** (Stift-Icon) auf jeder Erinnerungskarte in der Gedächtnis-Ansicht
- **Edit-Sheet**: Gleiche UI wie Hinzufügen — Typ-Picker, TextEditor, Tags
- **PATCH-Endpunkt** in DaemonListener (`/memory/entries` PATCH) für die Aktualisierung
- **Re-Embedding**: Geänderte Einträge werden automatisch neu eingebettet

### Researcher-Agent entfernt (Web-Agent übernimmt)
- **AgentType.researcher entfernt** → ersetzt durch `AgentType.web`
- **Web-Agent** deckt jetzt Recherche, Web-Suche, APIs und Browser-Automatisierung ab
- **Alle Referenzen** in DaemonListener, DelegateTaskTool, AgentsView, ChatView, GlassUI,
  SettingsView, TeamsGroupView, TeamView, OnboardingView, SkillLoader, CoreMemory,
  WorkflowManageTool, KoboldCLI komplett auf "web" umgestellt
- **AgentsView**: Researcher-Eintrag aus Model-Konfiguration entfernt, Tool-Routing aktualisiert
- **ToolRuleEngine**: `.research` → `.web` (gleiche Limits: 20 Browser, 30 HTTP, 10 Shell)
- **SettingsView**: "Researcher"-Schritte-Picker → "Web"-Schritte-Picker (kobold.agent.webSteps)

### Apps-Einstellungen entfernt (CPU-Optimierung)
- **"Apps"-Sektion** aus Settings-Sidebar komplett entfernt (war Hauptverursacher unnötiger CPU-Last)
- **appsSettingsSection()** gelöscht (Terminal-Einstellungen, Browser-Einstellungen, Virtuelle Maus)
- **Tote Navigation-Aufrufe** in AppBrowserTool + AppTerminalTool entfernt
  (navigierten zu nicht mehr existierendem `applications`-Tab)
- **Ungenutzter @AppStorage-State** bereinigt

### Statistik
- ~54.200 Lines of Code (Swift)

---

## Alpha v0.3.1 — 2026-02-25

### Performance Update
- **num_ctx**: LLMRunner schickt jetzt `num_ctx` an Ollama (war komplett fehlend!)
- **Context-Picker**: 4K/8K/16K/32K/64K/128K/256K (kein 150K/200K mehr), Default 32K
- **Ollama**: OLLAMA_NUM_THREADS (alle CPU-Kerne), OLLAMA_FLASH_ATTENTION=1, OLLAMA_NUM_GPU=999
- **Worker-Pool**: max 1–16 (war 1–8), Default 4
- **App Nap deaktiviert**: NSProcessInfo.beginActivity(.latencyCritical, .userInitiated...) in AppDelegate
- **TypewriterText**: 12 chars/40ms statt 3/8ms → 85% weniger MainActor-Updates
- **ApplicationsView + AppMenuManager**: komplett gelöscht (war Alpha-Tab, Timer-Quelle)
- **System-Prompt**: ~800 Tokens gespart, macOS BSD-Shell-Hints hinzugefügt

### Multi-Chat vollständig isoliert
- **SessionAgentState** pro Session: isLoading, streamTask, contextTokens, etc. (alle getrennt)
- **pendingMessages**: `[UUID: [ChatMessage]]` — jede Session puffert unabhängig
- **streamingSessions**: `Set<UUID>` statt `Bool` — korrekt bei mehreren parallelen Chats
- **conversationHistory** per Session: Background-Sessions lesen aus `sessions[].messages`
- **Session-Switch Race-Condition**: synchrones `upsertCurrentSession()` vor `messages = []`

### Statistik
- ~53.348 Lines of Code (Swift)

---

## Alpha v0.2.8 — 2026-02-23

### Teams: Echtes Diskursmodell
- **3-Runden-Diskussion**: R1 Einzelanalyse (parallel) → R2 Diskussion (sequentiell) → R3 Koordinator-Synthese
- **Persistenz**: Teams und Gruppennachrichten werden als JSON gespeichert (`teams.json` + `team_messages/{id}.json`)
- **Organigramm**: Ziele pro Team (editierbar), Knoten klickbar für Agent-Details
- **Chat-Controls**: Font-Size A/a, Brain-Toggle, Clear-Button, Stop-Button (wie normaler Chat)
- **AgentTeam/TeamAgent/GroupMessage**: Vollständige Codable-Datenmodelle mit Runden-Tracking

### Neue Tools
- **PlaywrightTool**: Chrome-Browser-Automatisierung — `navigate`, `click`, `fill`, `screenshot`, `evaluate`, `get_text`, `wait`
- **ScreenControlTool**: Maus/Tastatur-Steuerung, Screenshots via `screencapture`, OCR via Vision.framework (`VNRecognizeTextRequest`)

### Goals-System
- **GoalEntry-Modell**: Text, isActive, Priority (hoch/mittel/niedrig), Category
- **Settings UI**: Ziele-Box unter Persönlichkeit mit Inline-Editing, Toggle, Priority-Picker
- **Agent-Integration**: Aktive Ziele fließen als "Langfristige Ziele" in den System-Prompt

### Idle Tasks & Heartbeat
- **Idle-Aufgaben-Liste**: User-definierbare Tasks für den Agent wenn idle — konkrete Jobs UND vage Richtungen
- **7 Beispiel-Tasks**: Brew Updates, Downloads aufräumen, Verbesserungen finden, Sicherheit im Blick, Neues entdecken, Projekte checken, Speicherplatz
- **Cooldown-System**: Pro Task konfigurierbar (Minuten), Rate-Limiting pro Stunde
- **Quiet Hours**: Konfigurierbare Ruhezeiten (z.B. 22–07 Uhr)
- **Sicherheits-Toggles**: Shell/Network/FileWrite separat aktivierbar
- **Heartbeat-Sektion**: In Allgemein-Settings mit Intervall, Log-Retention, Dashboard-Toggle
- **Idle-Settings**: In TasksView inline mit Timing, Kategorien, Prioritäts-Filter

### Tasks & Workflows ← Teams
- **ScheduledTask.teamId**: Tasks können optional ein Team nutzen
- **Team-Picker**: Bei Task-Erstellung optionales Team auswählen
- **Workflow Team-Node**: Team-Diskussion als Workflow-Schritt

### UI-Verbesserungen
- **Live Thinking Layers**: Nicht-überlappende 3-Schicht-Anzeige — Steps/Tools (oben, immer offen) → Thinking-Status (mitte) → Typing-Animation (unten)
- **Chat-Eingabe**: Doppelte Höhe, Schrift +1pt, lineLimit 1...5
- **Kontext-Balken**: Verschoben von Chat-Header nach über der Eingabeleiste
- **Schriftgröße**: Wirkt jetzt auf User UND Assistant Nachrichten (RichTextView + markdownAttributedString)
- **Temperatur**: Dashboard zeigt °C-Schätzwerte statt Kühl/Normal/Hoch
- **Interactive Buttons**: Ja/Nein nur noch bei echten kurzen Entscheidungsfragen (max 3 Zeilen, <300 Chars, Trigger-Phrase nötig)
- **AI-Vorschläge**: SuggestionService via Ollama mit 4h-Cache, Fallback auf Hardcoded
- **Nachrichten-Queue**: Statt Agent-Interrupt werden Nachrichten in Queue gehalten
- **MenuBar-Icon**: brain.head.profile (Gehirn)

### Settings-Reorganisation
- **Persönlichkeit**: Kommunikation, Soul.md, Personality.md, Verhaltensregeln, Ziele, Autonomie & Proaktivität
- **Allgemein**: Heartbeat-Einstellungen hinzugefügt
- **Benachrichtigungen**: Neue Sektion
- **Debugging & Sicherheit**: Neue Sektion (Logging, Recovery, Sandboxing)
- **Verbindung aus Allgemein entfernt** (bleibt in StatusIndicator)

### Bug Fixes
- **SD Crash Fix**: Model-Loading via `Task.detached` statt MainActor (Watchdog-Kill verhindert)
- **SD Model Selection**: Modelle aus Ordner laden/entladen
- **AppStorage Key-Kollision**: IdleTasks Bool vs Array hatten gleichen Key → getrennt
- **buildGoalsSection()**: Gab immer leeren String zurück (doppelter guard/return) → gefixt
- **TeamId beim Laden**: Wurde aus Daemon-Response nicht gelesen → gefixt
- **ViewBuilder 10-View-Limit**: Persönlichkeit-Sektion hatte 13 Views → Group-Wrapper
- **Agent System-Prompt**: Alle v0.2.8 Fähigkeiten dokumentiert (Screen Control, Playwright, Teams, etc.)

### Statistik
- 44.572 Lines of Code (Swift)

---

## Alpha v0.2.5 — 2026-02-22

### Neue Features
- **Text-to-Speech (TTS)**: Agent kann Text vorlesen via `speak`-Tool
  - AVSpeechSynthesizer (built-in, keine Dependency)
  - Stimme, Geschwindigkeit, Lautstärke konfigurierbar in Einstellungen → Sprache
  - Test-Button zum Vorhören
- **Speech-to-Text (STT)**: Lokale Spracherkennung via SwiftWhisper (whisper.cpp)
  - Model-Download (tiny/base/small/medium) aus HuggingFace
  - Automatische Transkription von Sprachnachrichten
  - Sprache wählbar (Auto-Detect, Deutsch, Englisch, etc.)
- **Stable Diffusion Bildgenerierung**: Lokale Bildgenerierung auf dem Mac
  - Apple ml-stable-diffusion CoreML Pipeline
  - `generate_image`-Tool für den Agent ("Generiere ein Bild von...")
  - Konfigurierbar: Master-Prompt, Negative Prompt, Schritte, Guidance Scale, Compute Units
  - Bilder werden in `~/Desktop/KoboldOS-Images/` gespeichert und inline im Chat angezeigt
- **Medien-Embedding**: Bilder, Audio und Videos in Agent-Antworten automatisch eingebettet
  - Regex-basierte Erkennung von Dateipfaden in Agent-Antworten
  - Toggle in Einstellungen → Allgemein ("Medien automatisch einbetten")
- **Proaktiv — Eigenständiges Anschreiben**: Agent darf von sich aus Nachrichten senden
  - Neuer Toggle: "Agent darf eigenständig anschreiben" (Erinnerungen, Hinweise)

### Tool-Execution Bug Fix (KRITISCH)
- **ToolCallParser komplett neu geschrieben**: 5 Parsing-Strategien in Prioritätsreihenfolge
  1. Markdown-Codeblöcke (` ```json ... ``` `)
  2. Erste-bis-letzte-Klammer Extraktion
  3. Balancierte JSON-Block-Suche mit `tool_name`-Erkennung
  4. XML-Style `<tool_call>` Extraktion
  5. Zeile-für-Zeile JSON-Scan
  - Akzeptiert jetzt auch `"action"`, `"reasoning"`, `"args"` als Schlüsselnamen
  - Logging bei Fallback auf "response" für Debugging
- **System-Prompt optimiert für lokale Modelle**: Englische CRITICAL INSTRUCTION am Anfang
  - Klare JSON-Format-Vorgabe auf Englisch (lokale Modelle verstehen Deutsch oft schlecht)
  - Feedback-Text bei Tool-Fehlern enthält jetzt JSON-Beispiel

### Verbindungen & Integrationen
- **Verbindungen mit echten Logos**: Alle Services (Google, SoundCloud, Telegram, iMessage) mit brand-authentischen SwiftUI-Logos
  - Side-by-side Layout: Google + SoundCloud, iMessage + Telegram, WebApp + Cloudflare, A2A
- **iMessage-Integration**: Toggle-basiert mit macOS-Berechtigungsanfrage
- **SoundCloud OAuth Fix**: Scope von "non-expiring" auf "" korrigiert (403-Fehler)
- **A2A in Verbindungen integriert**: Kein eigener Sidebar-Reiter mehr — Server + Berechtigungen + Token-Austausch unter Verbindungen

### UI/Layout-Verbesserungen
- **Dashboard überarbeitet**: Willkommens-Nachricht mit tagesbasiertem Gruß + täglich wechselnde Sprüche (31 Zitate)
  - "Metriken aktualisieren" Button in Header verschoben
  - Schnellaktionen-Box entfernt
  - Metrikkarten gleich groß und zentriert
- **Leerer Chat**: Smiley entfernt, Beispielbox größer mit 7 wechselnden Sets
  - Nur echte KoboldOS-Fähigkeiten (Shell, Telegram, Dateien, Bildgenerierung, etc.)
- **WebApp + Cloudflare Tunnel nebeneinander** (wie andere Verbindungen)
- **Proaktiv in Gedächtnis integriert**: Kein eigener Sidebar-Reiter mehr
- **"Skills" → "Fähigkeiten"** umbenannt

### Freeze-Fixes
- **UpdateManager Deadlock behoben**: `waitUntilExit()` in `installFromDMG()` blockierte den MainThread
  - Alle Process-Aufrufe (hdiutil mount/unmount, chmod) auf `Task.detached` verschoben
- **KoboldCLI Concurrency**: Swift Language Mode auf v5 gesetzt (ArgumentParser Sendable-Kompatibilität)

---

## Alpha v0.2.4 — 2026-02-22

### Bug Fixes (Session 4)
- **Chat-Routing Fix**: Nachrichten landen jetzt immer im richtigen Chat, auch wenn der Benutzer während einer Agent-Antwort den Chat wechselt
  - `appendToSession()` routet via `originSession` UUID zum korrekten Session-Array
  - `activeAgentOriginSession` trackt welche Session der Agent gerade bedient
- **sendWithAgentNonStreaming Fix**: Alle Nachricht-Appends verwenden jetzt `appendToSession()` statt direktem `messages.append()`
- **Daemon Autostart**: Daemon startet jetzt in `AppDelegate.applicationDidFinishLaunching` statt in `onAppear` — zuverlässigerer Start
- **Workflow/Projekt-Löschung persistiert**: Synchrone Saves mit `.atomic` Write für Workflow-Definitionen und Projekte — Löschungen gehen nicht mehr beim Beenden verloren
- **performShutdownSave verbessert**:
  - `upsertCurrentSession()` wird vor dem Speichern aufgerufen — aktuelle Chat-Daten gehen nicht verloren
  - Alle Session-Arrays (Chat, Task, Workflow) nutzen atomare Writes
  - Session-Deduplizierung vor dem Speichern verhindert Duplikate
- **isAgentLoadingInCurrentChat**: Loading-Spinner wird nur im richtigen Chat angezeigt (Computed Property statt globaler State)

---

## Alpha v0.2.2 — 2026-02-22

### New Features (Session-Upgrade)
- **Strikte Session-Trennung**: 3 separate Speicher für Chat, Task und Workflow Sessions
  - `ChatMode` Enum (normal/task/workflow) ersetzt `isWorkflowChat`
  - Eigene JSON-Dateien: `chat_sessions.json`, `task_sessions.json`, `workflow_sessions.json`
  - Sessions werden beim App-Beenden alle 3 korrekt gespeichert
- **Task-Bearbeitung**: Edit-Sheet mit vorausgefülltem Formular für bestehende Tasks
  - Enabled/Disabled Toggle direkt auf der TaskCard
  - Update via Backend `"action": "update"`
- **Task-Chats**: Eigene Chat-Sessions pro Task
  - Task-Chat-Button auf jeder TaskCard
  - Task-Sessions in eigener Sidebar-Liste unter "Aufgaben"
  - Chat-Header zeigt Task-Name mit blauem Badge
- **Workflow-Chats**: Persistierte Workflow-Sessions (nicht mehr temporär)
  - Workflow-Sessions in eigener Sidebar-Liste unter "Workflows"
  - Zurück-zum-Chat Button im Banner
- **Task Auto-Scheduler**: Automatische Task-Ausführung nach Cron-Zeitplan
  - Alle 60 Sekunden Prüfung fälliger Tasks
  - Cron-Parser für */N, N, N-M, * Syntax
  - `last_run` wird automatisch aktualisiert
- **Notification-Navigation**: Klick auf Benachrichtigung navigiert zum relevanten Chat/Task/Workflow
  - `NavigationTarget` System (chat, task, workflow, tab)
  - Pfeil-Icon bei navigierbaren Benachrichtigungen

### Previous Features
- **ProactiveEngine**: Proaktive Vorschläge auf dem Dashboard
  - Zeitbasierte Trigger (Morgen-Briefing, Tagesabschluss)
  - Error-Recovery-Vorschläge bei Fehlern im Chat
  - Systemgesundheits-Monitoring (Ollama-Status)
  - Benutzerdefinierte Regeln (Uhrzeit, Startup)
  - ProactiveSuggestionsBar UI-Komponente
- **StoreView**: Marketplace-Platzhalter für Tools, Skills und Automationen (Coming Soon)
- **VectorSearch**: Semantische Suche für Memory-Einträge
- **DelegateTaskTool**: Agent kann Aufgaben an Sub-Agenten delegieren
- **WebApp-Fernsteuerung**: Lokaler Web-Server mit Basic Auth
  - Spiegelt Chat, Dashboard, Gedächtnis, Aufgaben als Web-UI
  - Passwort-geschützt (Einstellungen → Fernsteuerung)
  - Proxy zum Daemon-API mit automatischer Token-Weiterleitung
- **Memory Policy**: Konfigurierbare Gedächtnis-Richtlinie (auto/ask/manual/disabled)
- **Verhaltensregeln**: Freie Textregeln die der Agent immer befolgt (in System-Prompt)
- **Apple Systemzugriff**: "Berechtigung anfragen"-Buttons für Kalender, Kontakte, Mail, Benachrichtigungen
- **Neue Chat-Session beim Start**: App startet immer mit frischem Chat, alte Session wird archiviert
- **Auto-Save bei App-Beendigung**: Chat, Sessions, Projekte und CoreMemory werden automatisch gespeichert

### Bug Fixes
- **KRITISCH: App-Freeze behoben** (3 Ursachen):
  - `performShutdownSave()`: DispatchSemaphore auf Main Thread entfernt → fire-and-forget
  - ShellTool Race Condition: `UnsafeMutablePointer<Bool>` → `NSLock` für Thread-Safety
  - ShellTool Blocking IO: `readDataToEndOfFile()` → inkrementelles `availableData` mit readabilityHandler
- **Tasks 401-Fehler behoben**: Auth-Header fehlte in TasksView (loadTasks, createTask, deleteTask)
- **Memory-Seite zeigt Einträge**: Typ-Mapping für Standard-CoreMemory-Blocks (persona→Langzeit, knowledge→Wissen)
- **Memory-Seite Fehlerbehandlung**: Verbindungsfehler werden angezeigt statt still ignoriert
- **Daemon /memory/update**: Delete-Flag wird verarbeitet, Limit wird beibehalten
- **ProactiveEngine Retain Cycle**: Timer-Closure captured ViewModel stark → weak capture fix
- **ProactiveEngine Zeitabgleich**: Stunde+Minute statt nur Stunde für Regel-Trigger
- **Metriken-Reset funktioniert**: Auth-Header + Token-Tracking + lokaler State-Reset
- **Token-Tracking**: Daemon `/metrics` liefert jetzt `tokens_total` Feld
- **Force-Unwrap Crashes**: `arguments["key"]!` → `guard let` in WorkflowManageTool, SkillWriteTool, TaskManageTool
- **DaemonClient URL-Crashes**: `URL(string:)!` → `guard let` in GET/POST Methoden
- **Version-Inkonsistenzen**: Info.plist war auf 0.1.7, DaemonCommand auf v1.0.1, SkillLoader auf v0.1.7 — alle auf 0.2.2 synchronisiert

### UI Improvements
- **Chat-Eingabezeile kompakter**: Reduzierte Padding (vertical 7px statt 9px, bar 6px statt 8px)
- **OnboardingWizard Buttons funktional**: "Open Ollama" → öffnet ollama.com, "Installation Guide" → öffnet Docs
- **Debug-Prints entfernt**: OnboardingWizardView, ModelsView, BaseAgent, CodingAgent bereinigt
- **Einstellungen**: Neue Sektionen "Fernsteuerung" und "Apple Systemzugriff"
- **Info.plist**: macOS Privacy-Beschreibungen für Kalender, Kontakte, AppleScript, Benachrichtigungen

### Agent Improvements
- **Sprache aus Onboarding**: `kobold.agent.language` wird automatisch beim Onboarding gesetzt (15 Sprachen)
- **Dynamische Sprachwahl**: System Prompt unterstützt alle 15 Sprachen statt nur Deutsch/Englisch/Auto
- **Memory Policy im System-Prompt**: Agent befolgt konfigurierte Gedächtnis-Richtlinie
- **Verhaltensregeln im System-Prompt**: Benutzerdefinierte Regeln werden in jedes Gespräch injiziert

---

## Alpha v0.2.1 — 2026-02-22

### GitHub Auto-Update System
- **UpdateManager**: Automatische Updates über GitHub Releases
  - Hardcoded repo `FunkJood/KoboldOS` (kein Setup nötig)
  - Vergleicht GitHub Release Tags mit aktueller Version (semver)
  - Zeigt Release Notes, Download-Fortschritt und Status
  - Lädt DMG herunter, ersetzt App und startet automatisch neu
  - Auto-Check beim Start (konfigurierbar)
  - 404/kein Release = "Aktuell" statt Fehlermeldung

### Tool Environment & Dependencies
- **ToolEnvironment scanner**: Detects available system tools (Python, Node, Git, Ollama, Homebrew, etc.)
  - Shows availability grid with version info in Settings → Allgemein
  - Auto-scans on first visit, rescan button available
- **On-Demand Python**: Download standalone Python 3.12 (~17 MB) to App Support if not installed
  - Progress indicator during download
  - Installed to `~/Library/Application Support/KoboldOS/python/`
- **Enhanced Shell PATH**: ShellTool now uses intelligent PATH priority:
  1. App bundle (bundled tools)
  2. Downloaded Python in App Support
  3. Homebrew (`/opt/homebrew/bin`)
  4. System (`/usr/bin`, `/bin`)

### UI Improvements
- **Collapsed Sidebar Icons**: Menu icons remain visible and clickable when sidebar is collapsed
- **Settings Tab Width**: Settings sidebar matches main sidebar width (220px)
- **Standard Workdir Picker**: Folder picker in Settings for default working directory
- **Dashboard Cleanup**: Removed duplicate Modell/Ollama cards, added Latenz + Tokens to Systemstatus
- **Removed Redundant Model Boxes**: Removed "Primäres Ollama-Modell" and "Beliebte Modelle" from Modelle settings

### Security & API
- **Cloud API Keys**: Added OpenAI/Anthropic/Groq SecureField inputs in Datenschutz & Sicherheit
- **Daemon Auth Token**: Fixed to use real stored token with regenerate + copy buttons

### Agent Improvements
- **Tool Error Handling**: Agent now explains errors in German instead of showing raw JSON
  - Added error handling rule to system prompt
  - Modified feedback in all run methods (run, runStreaming, resume)
- **Workdir in System Prompt**: Agent knows the configured working directory

### Apple Integration
- **CalendarTool** (EventKit): Kalender-Events und Erinnerungen verwalten
  - `list_events`: Events der nächsten N Tage anzeigen
  - `create_event`: Neue Events mit Titel, Start/Ende, Ort, Notizen
  - `search_events`: Events nach Suchbegriff durchsuchen (±3 Monate)
  - `list_reminders`: Offene Erinnerungen auflisten
  - `create_reminder`: Neue Erinnerungen mit Fälligkeitsdatum
- **ContactsTool** (Contacts Framework): Apple Kontakte durchsuchen
  - `search`: Kontakte nach Name suchen (mit Telefon, Email, Firma, Geburtstag)
  - `list_recent`: Erste 20 Kontakte auflisten
- **AppleScript-Steuerung**: Mail, Messages, Notes, Safari, Finder, System
  - In System-Prompt dokumentiert mit Beispielen
- **Berechtigungen**: Neue Toggles in Einstellungen
  - Kalender & Erinnerungen, Kontakte, Mail & Nachrichten, Benachrichtigungen

### Bug Fixes
- **App-Freeze behoben (KRITISCH)**: Double-Resume in ShellTool
  - Timer und terminationHandler konnten beide `continuation.resume()` aufrufen
  - Fix: Atomarer Flag (`UnsafeMutablePointer<Bool>`) verhindert doppeltes Resume
- **HTTP Timeouts**: Health-Check 3s, Metrics/Auth-Requests 5s (war unbegrenzt)
- **"Unknown tool: input"**: SkillLoader JSON-Beispiel korrigiert (`input` → `response`)
- **Autonomielevel 1 nicht auswählbar**: Entfernte `VStack` um ersten Picker-Tag
- **Update 404-Fehler**: GitHub API 404 zeigt jetzt "Aktuell" statt Fehlermeldung
- **Session-Duplikate**: Alte Sessions werden vor neuer Erstellung aufgeräumt (max 5, Auto-Cleanup nach 5s)
- **Memory-System**: Entscheidungsbaum für human/short_term/knowledge komplett neu geschrieben
- **BrowserTool DDG Search**: Fixed parsing of multi-class HTML elements, removed broken Google scraping
- **Autostart Linked**: MenuBarController now uses LaunchAgentManager (was raw UserDefaults)
- **Version bumped to 0.2.1** across all files

### UI Improvements (v0.2.1)
- Einrichtungsassistent + Debug-Modus nebeneinander in einer Zeile
- Dashboard: Tokens/Latenz/Speicher-Karten entfernt → Anfragen, Tools, Laufzeit, Fehler in einer Reihe
- Verfügbare Tools Grid in Einstellungen mit Python-Download-Button

---

## Alpha v0.2.0 — 2026-02-22

### Stability & Security Fixes
- **Chat Session Deduplication**: Fixed duplicate sessions appearing in sidebar
  - Replaced race-condition-prone session insertion with atomic `upsertCurrentSession()` helper
  - Removed conflicting session sync from debounced `saveChatHistory()` — `saveSessions()` is now the single writer for `chat_sessions.json`
  - Added UUID-based deduplication on session load (`loadSessions()`)
  - All session management paths (`newSession()`, `switchToSession()`, `openWorkflowChat()`) now use the same safe upsert pattern
- **AgentLoop Anti-Freeze**: Prevents freezing on large/complex tasks
  - Message history pruning: sliding window keeps system prompt + last 20 message pairs, preventing context window overflow
  - Tool result truncation: outputs capped at 8000 chars to prevent context bloat
  - Conversation history limited to 50 entries (was unbounded)
  - Ollama `num_predict: 4096` prevents unbounded response generation
- **Socket Read Timeout**: 30-second `SO_RCVTIMEO` on client sockets prevents indefinite blocking from hung connections
- **Rate Limit Memory Leak**: Empty entries now cleaned from rate limit map
- **Workflow Persistence Consolidated**: DaemonListener and WorkflowManageTool now share the same `WorkflowDefinition` Codable model — no more format mismatch between JSON serialization methods
- **Version bumped to 0.2.0** across daemon `/health`, settings, and build script

### UI Improvements
- **MenuBar Chat Fix**: Fixed response parsing (`finalAnswer` → `output`) so toolbar quick-chat actually displays answers
- **MenuBar Right-Click Menu**: Added context menu with Einstellungen, Autostart toggle, and Beenden
- **Clear Chat Deletes Session**: Trash button in chat header now also removes the session from the sidebar
- **Thinking Panel Auto-Expand**: Agent thinking/steps panel is now expanded by default while active, collapsed for old messages
- **Settings Save Button**: Every settings tab now has a "Speichern" button with visual confirmation feedback
- **Notification Rules**: System push notifications only fire when app is in background; errors/warnings always fire
- **Context Length 256K**: Added 256K context length option to agent configuration picker
- **Dashboard Activity Timeline**: `/trace` endpoint now tracks real events (chat, tool calls, memory updates, tasks, workflows, errors) instead of returning empty data
- **Datensicherung Checkmarks**: Backup section now has per-category toggles (Gedächtnis, Secrets, Chats, Skills, Einstellungen, Aufgaben, Workflows)
- **MenuBar Stats Tab**: Popover now has Status/Chat tabs — Status shows daemon health, model, CPU/RAM/Disk metrics, and quick-action buttons
- **Auth Token Dynamic**: MenuBar chat uses stored auth token instead of hardcoded secret
- **Status Icon Health**: Menu bar icon changes to warning triangle when daemon is unhealthy

### Bug Fixes
- **BrowserTool Search Rewrite**: Complete rewrite of web search functionality
  - Google HTML scraping (free, no API key needed) with proper User-Agent headers
  - DuckDuckGo HTML fallback (was using broken Instant Answer API that returned nothing)
  - SearXNG local instance support preserved as first option
  - Proper result parsing with title, URL, and snippet extraction
  - Graceful fallback chain: SearXNG → Google → DuckDuckGo → error message

### Code Quality
- Removed unused `Combine` import and `cancellables` property from MenuBarController
- Fixed `updateStatusIcon` dead logic (both branches used same symbol)
- Code review: 78/78 tests pass, 0 build warnings (excluding pre-existing CLI warning)

---

## Alpha v0.1.6 — 2026-02-21

### New Features
- **SSE Streaming**: Real-time agent step visibility via `/agent/stream` endpoint
  - Thoughts, tool calls, and tool results stream live to the GUI
  - Uses Server-Sent Events (SSE) with `URLSession.bytes(for:)` parsing
  - `SO_NOSIGPIPE` prevents crashes on client disconnect
  - Existing `/agent` endpoint preserved for CLI backward compatibility
- **Brain Toggle**: Show/hide agent thinking steps in chat
  - Brain icon button (filled when on) next to attachment button in input bar
  - `@AppStorage("kobold.showAgentSteps")` persists across sessions
  - When off, only final answers appear in chat
- **Auto-Memory After Onboarding**: Direct POST to `/memory/update` instead of unreliable LLM-based setup
  - Persona block: agent name + personality + language in chosen language
  - Human block: user name + primary use + language preference
  - Agent greets user by name on first chat (memory already set)
- **SkillWriteTool**: Agent can self-author skills (`create`, `list`, `delete`)
  - Writes `.md` files to `~/Library/Application Support/KoboldOS/Skills/`
  - Filename sanitization (no `/`, no `..`)
  - Auto-enables newly created skills
- **TaskManageTool**: Agent can manage scheduled tasks (`create`, `list`, `update`, `delete`)
  - Persists to `~/Library/Application Support/KoboldOS/tasks.json`
  - Tasks have name, prompt, cron schedule, enabled flag
- **WorkflowManageTool**: Agent can manage workflow definitions (`create`, `list`, `delete`)
  - Persists to `~/Library/Application Support/KoboldOS/workflows.json`
  - v1 CRUD; full orchestration in later version
- **10 New Languages**: Portuguese, Hindi, Chinese, Japanese, Korean, Turkish, Polish, Dutch, Arabic, Russian
  - Refactored to dictionary-based translation lookup (no more 50+ switch cases)
  - All 15 languages accessible via compact dropdown picker in onboarding
  - Agent instructions and all UI strings translated
- **Language Dropdown**: Onboarding language selection changed from button list to `Picker(.menu)` dropdown
- **Enhanced Workflow Editor**: Custom connections model + new node types
  - `WorkflowConnection` model (sourceNodeId -> targetNodeId)
  - Port circles on node edges for visual connection points
  - New node types: `.condition`, `.merger`, `.delay`, `.webhook`
  - Output capture from each node passed to connected nodes
- **Settings Redesign**: 8 sections (was 6)
  - New "Gedachtnis" section: memory limits, auto-save, export/import, reset
  - New "Skills" section: skill cards with enable/disable toggles, "Open Skills folder" button
  - New "Entwickler" section: trace viewer, debug toggles, API tester, JSON response viewer

### Improvements
- **BrowserTool Enhanced**:
  - `method` parameter (GET/POST/PUT/DELETE)
  - `headers` parameter (JSON string -> dictionary)
  - `body` parameter for POST/PUT
  - Response limit increased from 8000 -> 16000 chars
  - HTTP status code descriptions in responses
  - SearXNG localhost blocking fixed (internal exception for search engine calls)
- **DMG Packaging**: Enhanced with Applications symlink + README + CHANGELOG + Dokumentation
- Version bumped to 0.1.6 in daemon `/health` endpoint, settings, and build script

---

## Alpha v0.1.5 — 2026-02-21

### New Features
- **Gedächtnis-System**: Renamed "Speicher" → "Gedächtnis" with three memory types:
  - Kurzzeit (`kt.` prefix) — short-term session context
  - Langzeit (`lz.` prefix) — long-term persistent memory
  - Wissen (`ws.` prefix) — knowledge base / reference facts
- **Memory UI**: Search bar, type filter chips, memory type info cards, JSON export via NSSavePanel
- **Memory Cards**: Confirmation dialog on delete, character counter, type badge
- **Dashboard CPU/RAM/Disk**: Live system resource monitoring
  - CPU: POSIX `getloadavg()` normalized per active core
  - RAM: `host_statistics64` + `sysconf(_SC_PAGESIZE)` (Swift 6 safe)
  - Disk: Free/total disk space via `attributesOfFileSystem`
- **Dashboard Shortcuts**: Quick-navigation tiles for Chat, Aufgaben, Gedächtnis, Workflows, Skills
- **Task Scheduler**: Replaced raw cron input with friendly preset picker
  - 14 presets: Manuell, Alle 5/15/30 Min., Stündlich, Alle 2/4/6 Std., Täglich 08/12/18/22 Uhr, Werktags 09, Wöchentlich, Benutzerdefiniert
  - Visual preview of selected schedule, stats row (Gesamt/Aktiv/Pausiert)
  - Confirmation dialog on delete
- **SkillsView**: New dedicated view for managing agent skills
  - Browse, search, and toggle skills on/off
  - Import markdown skill files via file picker
  - Skill detail sheet with full content preview
  - Skills injected into agent system prompt when enabled
- **Sidebar**: Dashboard → Chat → Aufgaben → Workflows → Gedächtnis → Skills → Agenten → Einstellungen

### Critical Fixes — Agent Communication Rewrite (AgentZero-Muster)
- **JSON-only Kommunikation**: Agent antwortet NUR als JSON (`thoughts`/`tool_name`/`tool_args`)
  - Kein XML `<tool_call>` mehr — lokale Modelle können JSON viel besser als XML
  - Jede Antwort ist strukturiert: Gedanken → Tool-Aufruf → Ergebnis
  - Sogar Endantworten gehen über das `response` Tool (wie AgentZero)
- **ResponseTool**: Neues Terminal-Tool — der EINZIGE Weg für den Agent, dem Nutzer zu antworten
  - Erzwingt strukturierte Kommunikation statt willkürlichem Text
  - Beendet die Agent-Schleife sauber
- **Dirty JSON Parser**: Verzeiht typische LLM-Fehler
  - Trailing Commas, unquoted Keys, Python True/False, Kommentare
  - Findet JSON auch wenn Text drumherum steht (wie AgentZero's `json_parse_dirty`)
- **Tool-Beschreibungen mit JSON-Beispielen**: Jedes Tool hat ein vollständiges JSON-Beispiel
  - Lokale Modelle sehen exakt das Format, das sie ausgeben sollen
  - Statt vager Beschreibung → konkretes Copy-Paste-Beispiel
- **System-Prompt kompakt & klar**: Kurze Regeln + 5 konkrete Beispiele
  - "Hallo" → response, "Dateien zeigen" → file, "Ich heiße Tim" → memory_append
- **Shared CoreMemory**: DaemonListener teilt jetzt die AgentLoop-Instanz
  - Memory-Änderungen über UI sofort im Agent-Kontext sichtbar
- **Agent Memory Integration**: `core_memory_read` Tool hinzugefügt

### Improvements
- Dashboard: Replaced GPU display with disk space monitoring (more useful)
- Dashboard: Removed redundant "Backend" metric card (Ollama status already shown)
- Dashboard: Added "Speicher frei" metric card showing available disk space
- Dashboard refresh interval reduced to 3 seconds (was 5)
- Fixed all build warnings (0 warnings):
  - SettingsView: Updated deprecated `onChange(of:) { _ in }` to new API
  - DashboardView: Fixed actor isolation in Timer closure with `@MainActor`
- Version bumped to 0.1.5 in daemon /health endpoint
- Navigation menu: Renamed "Speicher" → "Gedächtnis", added Skills shortcut (Cmd+5)

---

## Alpha v0.1.4 — 2026-02-21

### Critical Bug Fixes
- **AgentLoop — proper LLM message roles**: Fixed root cause of tools never executing.
  - Previously: entire system prompt + context sent as single `{"role":"user"}` message
  - Now: `[{"role":"system"}, {"role":"user"}, {"role":"assistant"}, {"role":"user"(tool_results)}]`
  - Uses `LLMRunner.generate(messages:)` instead of the broken `generate(prompt:)`
  - Tool results fed back as user messages (Ollama doesn't support native tool role)
- **Stronger system prompt**: Explicit instructions on when/how to use tools, strict examples
- **DaemonListener tool_results**: `/agent` now returns `tool_results` array in response
  - UI shows collapsible `ToolResultBubble` for each executed tool
- **Chat header badge**: Now shows "Instructor" instead of raw "general" for default agent type

### New Features
- **File attachment analysis**: Non-image files (text, code, etc.) have their content embedded
  - User types a message, attaches a `.py`/`.txt`/`.json` file → content automatically included
  - Up to 8000 chars extracted; binary files show size info
  - Display text in bubble stays clean (shows original user text)
- **GlassTextField click area**: Entire rounded rectangle is now tappable (not just the text line)
  - Added `.contentShape(RoundedRectangle)` + `.onTapGesture { isFocused = true }`
  - Reduced input bar height with `padding(.vertical, 9)` and `lineLimit(1...3)`
- **Added `instructor` AgentType**: step limit 12, maps from "general" default
- **RuntimeViewModel**: `sendMessage(_:agentText:attachments:)` — separate display text from agent text

### Architecture
- AgentType enum: added `.instructor` case with step limit 12
- DaemonListener: `handleAgent` defaults to `.instructor` for all non-specialized requests
- DaemonListener: tool results collected from `step.type == .toolResult` steps and included in response

---

## Alpha v0.1.3 — 2026-02-20

### Bug Fixes
- **HTTP 400 errors**: `handleAgent` now returns HTTP 200 with `⚠️` prefix in output instead of 400
  - Added `agentError(_ msg: String) -> String` helper
- **Stale daemon detection**: `/health` response includes `pid` field
  - `RuntimeViewModel.checkHealthIsOurProcess()` verifies PID matches current process
  - `RuntimeManager.pingHealth()` kills stale old-instance daemon via `SIGTERM`
- **Metrics model field**: `/metrics` now returns current active Ollama model
- **Ollama status**: `checkOllamaStatus()` no longer overwrites user's model selection
- **Concurrent requests**: DaemonListener uses `Task.detached` (not `Task {}`) per connection
- **TCP framing**: `readRequest()` uses Content-Length loop-read to prevent body truncation

### New Features
- **AgentsView Vision toggle**: Per-agent `supportsVision` flag, badge in card header
- **DashboardView**: Shows active model, "Backend" card only with showAdvancedStats
- **SettingsView overhaul**: 6-section navigation (Allgemein/Modelle/Berechtigungen/Sicherheit/Erweitert/Über)
  - Real `@AppStorage` bindings (replaced all `.constant(false)` fakes)
  - Autonomy level 1/2/3 with per-permission toggles
  - SMAppService-backed autostart toggle via `LaunchAgentManager`
  - Per-agent model pickers inline in settings
- **File attachments**: `MediaAttachment`, `AttachmentThumbnail`, `AttachmentBubble` views
  - NSOpenPanel picker for all file types
  - Images sent as base64 to Ollama vision API

---

## Alpha v0.1.2 — 2026-02-19

### Features
- **ChatView**: Tool visualization bubbles (ToolCallBubble, ToolResultBubble, ThoughtBubble, AgentStepBubble)
- **MemoryView**: CoreMemory block editor with load/save/delete/snapshot
- **TasksView**: Scheduled task list with create/delete/run
- **AgentsView**: Per-agent model, temperature, context length configuration
- **Onboarding**: HatchingView with persona setup, agent type selection
- **Chat history persistence**: Saved to `~/Library/Application Support/KoboldOS/chat_history.json`
- **Session management**: Named sessions in sidebar, switch between conversations
- **WorkflowView (TeamView)**: Basic n8n-style node canvas (beta)

---

## Alpha v0.1.1 — 2026-02-18

### Foundation
- **KoboldCore**: AgentLoop, ToolRegistry, ToolCallParser, CoreMemory, LLMRunner
- **DaemonListener**: Raw TCP HTTP server on port 8080
- **KoboldCLI**: `kobold daemon/model/metrics/trace/safe-mode` commands
- **LLMRunner**: Ollama `/api/chat` + llama-server `/v1/chat/completions`
- **Tools**: FileTool, ShellTool, BrowserTool, CalculatorPlugin, CoreMemoryAppend/Replace
- **ToolRuleEngine**: OpenClaw-style per-type usage rules (default/coder/research)
- **KoboldOSControlPanel**: Basic SwiftUI app with sidebar navigation
- **GlassUI design system**: GlassCard, GlassButton, GlassTextField, GlassChatBubble
