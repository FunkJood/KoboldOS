# KoboldOS v0.2.3 — Handoff / Session-Übergabe

## Stand: 2026-02-22 (Session 3)

### Was wurde gemacht (alle Sessions zusammen)

#### 1. Freeze-Fixes (Stabilität) — FERTIG
Alle kritischen UI-Freeze-Ursachen behoben:

- **CodingAgent.swift**: `waitUntilExit()` + `readDataToEndOfFile()` durch async `PipeCollector` + `readabilityHandler` ersetzt
- **ClaudeCodeBackend.swift**: Gleiches Pattern — Sendable-safe `PipeCollector` class für nicht-blockierendes Pipe-Reading
- **ToolEngine.swift**: `bash()` Funktion — Pipe-Daten werden jetzt über `readabilityHandler` gesammelt statt nach `waitUntilExit()` blockierend gelesen
- **RuntimeViewModel.swift**:
  - `loadMetrics()` nach Agent-Response: `await` → fire-and-forget `Task { await loadMetrics() }`
  - `loadChatHistory()`: Bleibt synchron (async verursachte Race Condition bei Session-Archivierung)
  - `connect()`: `loadMetrics/loadModels/checkOllamaStatus` parallelisiert mit `async let`, Retry-Intervall 400ms statt 800ms, 15 Versuche

#### 2. WebApp Komplett-Redesign — FERTIG
`WebAppServer.buildHTML()` komplett neu geschrieben:

- **Design**: Apple-inspiriert, Dark Theme, Glassmorphism, Lucide Icons (via CDN), Inter Font
- **4 Tabs**: Chat, Aufgaben, Gedächtnis, Einstellungen
- **Chat**: Modernes Bubble-UI, Typing-Dots Animation, Markdown-Rendering, Tool-Result Tags
- **Aufgaben**: Task-Liste mit Status-Badges, CRUD (Erstellen/Pausieren/Löschen)
- **Gedächtnis**: Statistik-Karten, Typ-Filter (Kurzzeit/Langzeit/Wissen), Tag-Filterung, Suche, Erstellen/Löschen
- **Einstellungen**: Metriken-Grid, Model-Picker (alle Ollama-Modelle), Daemon-Info
- **Responsive**: Desktop (260px Sidebar) → Tablet (64px Icons) → Mobile (Bottom-Tab-Bar)

#### 3. Telegram Bot Konversationskontext — FERTIG
- Per-Chat History mit max 20 Nachrichten (user + assistant)
- Bisheriges Gespräch wird als Kontext in den Agent-Request injiziert
- Neue Befehle: `/clear` (Gespräch zurücksetzen), `/status` (zeigt Kontext-Größe)
- `source: "telegram"` Feld im Agent-Request für zukünftige Unterscheidung

#### 4. Auth 401 Bug Fix — FERTIG
**Root Cause**: `@AppStorage` Default-Werte werden NICHT in UserDefaults geschrieben bis sie explizit gesetzt werden. RuntimeManager las Token via UserDefaults.standard (→ nil), DaemonListener bekam leeren Token, alle API-Requests scheiterten mit 401.

**Fix**:
- `RuntimeManager.swift`: `@AppStorage("kobold.authToken") var authToken` direkt hinzugefügt — Daemon bekommt jetzt korrekt den Token
- `RuntimeViewModel.swift`: `init()` schreibt Token explizit in UserDefaults falls nil
- `SettingsView.swift`: WebApp Token kommt von `RuntimeManager.shared.authToken`

#### 5. Version Bump auf v0.2.3 — FERTIG
10+ Dateien aktualisiert, DMG gebaut, GitHub Releases erstellt (v0.2.1, v0.2.2, v0.2.3)

### Build-Status
- `swift build -c release` erfolgreich ✓
- DMG: `~/Desktop/KoboldOS-0.2.3.dmg` ✓
- Sources synchron zwischen Arbeitsverzeichnis und GitHub-Repo ✓

### WICHTIG: Vor dem Testen
**Alle alten KoboldOS-Instanzen beenden!** Der Daemon läuft in-process, d.h. wenn eine alte Version noch im Hintergrund läuft (Window-Close = Minimize to Tray), belegt sie Port 8080. Cmd+Q oder Activity Monitor → KoboldOS beenden.

### Git-Status (GitHub-Repo)
Dateien bereit zum Commit (via GitHub Desktop):
- Geänderte + neue Dateien synchronisiert
- DMG auf Desktop für manuellen Upload zum Release

### Was noch offen ist / nächste Session

#### Sofort-Todos
1. **Alte KoboldOS-Instanz beenden** (Cmd+Q, Activity Monitor prüfen)
2. **Neue DMG installieren** und testen
3. **GUI Chat testen**: Nachricht senden → Antwort erhalten (kein 401 mehr)
4. **WebApp testen**: Fernsteuerung aktivieren → alle 4 Tabs durchklicken
5. **Telegram Bot testen**: Gespräch führen → `/clear` testen

#### Bekannte Schwächen
- **WebApp Chat hat kein SSE-Streaming** — nutzt aktuell einfachen POST + polling
- **performShutdownSave()** ist noch synchron auf MainThread
- **Session-Klick in History**: Verhalten bei Archivierung prüfen

### Projektstruktur-Erinnerung
- **Source**: `/Users/tim/AgentZero/workdir/KoboldOS/`
- **GitHub Repo**: `/Users/tim/Documents/GitHub/KoboldOS/KoboldOS/`
- **Build**: `cd /Users/tim/AgentZero/workdir/KoboldOS && bash scripts/build.sh`
- **Sync**: `rsync -av --delete Sources/ /Users/tim/Documents/GitHub/KoboldOS/KoboldOS/Sources/`
- **Commit**: GitHub Desktop (nicht CLI)

### API-Endpunkte für WebApp-Referenz
| Endpoint | Methode | Beschreibung |
|----------|---------|-------------|
| `/health` | GET | Status + Version + PID |
| `/agent` | POST | Agent-Anfrage (message, source?) |
| `/metrics` | GET | Statistiken |
| `/models` | GET | Verfügbare Ollama-Modelle |
| `/model/set` | POST | Modell wechseln |
| `/tasks` | GET/POST | Tasks CRUD |
| `/memory/entries` | GET/POST/DELETE | Memory CRUD |
| `/memory/entries/tags` | GET | Alle Tags |
| `/history/clear` | POST | Chat-Verlauf leeren |
