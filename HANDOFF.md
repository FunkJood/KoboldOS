# KoboldOS v0.3.3 — Handoff / Session-Übergabe

## Stand: 2026-02-27

### Was wurde gemacht (v0.3.2 → v0.3.3)

#### 1. Task-Chat-System — FERTIG
Jede geplante/idle Task bekommt jetzt einen eigenen Chat:

- **ChatSession.taskId**: Optionales `String?`-Feld unterscheidet Task-Sessions von normalen Chats
- **taskSessions**: Computed Property filtert `sessions` nach `taskId != nil`
- **openTaskChat()**: Findet oder erstellt Task-Session, navigiert zum Chat-Tab
- **executeTask()**: Zentraler Entry-Point für Cron- und Idle-Tasks
  - `navigate: true` (Cron) → wechselt in den Task-Chat, zeigt Streaming live
  - `navigate: false` (Idle) → Background-Execution, Notification bei Fertigstellung
- **sendMessage(targetSessionId:)**: Erweitert um Background-Session-Support — Messages landen in der richtigen Session ohne UI-Disruption
- **Sidebar-Integration**: Task-Chats erscheinen als eigene Sektion "Task-Chats" über den normalen Chats (blaues Checklist-Icon)
- **Sidebar-Filter**: `collapsibleChatsList` und `rebuildSessionCache()` filtern Task-Sessions aus der normalen Chat-Liste

#### 2. Cron-Task Routing — FERTIG
- **DaemonListener**: `checkScheduledTasks()` postet jetzt `koboldScheduledTaskFired` Notification statt `handleAgent()` direkt aufzurufen (Output ging vorher verloren)
- **MainView.onReceive**: Empfängt die Notification auf MainActor und ruft `executeTask(navigate: true)` auf
- **ProactiveEngine**: Idle-Tasks nutzen `executeTask(navigate: false)` statt `sendMessage()` auf `currentSessionId`

#### 3. Notification-System — FERTIG
- **UNUserNotificationCenter**: Ersetzt deprecated `NSUserNotification` für macOS System-Notifications
- **KoboldNotification.sessionId**: In-App-Notifications tragen jetzt die Session-UUID
- **Click-to-Navigate**: Klick auf Notification → `navigateToTaskSession()` → wechselt zum richtigen Chat
- **System-Notifications**: Bei Task-Abschluss erscheint macOS-Notification mit Preview des Ergebnisses

#### 4. SoundCloud OAuth Token Fix — FERTIG
- **Problem**: `SoundCloudOAuth.swift` speicherte Tokens in UserDefaults (`kobold.soundcloud.accessToken`), aber `SoundCloudApiTool.swift` las aus SecretStore/Keychain (`soundcloud.access_token`)
- **Fix**: API-Tool liest jetzt aus UserDefaults mit den korrekten Keys

#### 5. Performance & Freeze-Fixes (v0.3.2) — FERTIG
Alle Blöcke A-F, P1-P8 aus der vorherigen Session:
- isNewest O(n) eliminiert, SkillLoader Cache, async let Parallelisierung
- repeatForever Animation entfernt, Markdown NSCache, GlobalHeaderBar DateFormatter
- Flush-Timer 500ms, Connectivity-Timer async, Session-Save 3s Debounce
- System-Prompt ~14K → ~6-7K Tokens gekürzt

### Build-Status
- `swift build` erfolgreich ✓
- Version: 0.3.3 in `scripts/build.sh`
- README.md aktualisiert ✓
- CHANGELOG.md aktualisiert ✓

### WICHTIG: Vor dem Testen
**Alle alten KoboldOS-Instanzen beenden!** Der Daemon läuft in-process, d.h. wenn eine alte Version noch im Hintergrund läuft (Window-Close = Minimize to Tray), belegt sie Port 8080. Cmd+Q oder Activity Monitor → KoboldOS beenden.

### Was noch offen ist / nächste Session

#### Sofort-Todos
1. **Alte KoboldOS-Instanz beenden** (Cmd+Q, Activity Monitor prüfen)
2. **Neue DMG installieren** und testen
3. **Task-Chat testen**: Task erstellen → Cron feuern lassen → Eigener Chat öffnet sich
4. **Idle-Task testen**: Idle-Task anlegen → Background-Execution → Notification erscheint
5. **Notification testen**: Klick auf Notification → navigiert zum Task-Chat
6. **Sidebar prüfen**: Task-Chats eigene Sektion, normale Chats gefiltert

#### Geplant (Block G/H/I aus Plan)
- **Block G**: Konsolidiertes Logging-System (logs/ Ordner, Tool-Logging, Performance-Logging)
- **Block H**: Tool-Restrictions entschärfen (Newline-Blocking, Operator-Tier, Allowlist erweitern)
- **Block I**: Brain-Icon statisch machen (scaleEffect entfernen)

#### Bekannte Schwächen
- **WebApp Chat hat kein SSE-Streaming** — nutzt aktuell einfachen POST + polling
- **UNUserNotificationCenter Delegate**: Tap-Handler für System-Notifications noch nicht implementiert (nur In-App-Notifications navigieren)
- **Task-Chat Cleanup**: Alte abgeschlossene Task-Chats werden nicht automatisch aufgeräumt

### Projektstruktur
- **Repo**: `/Users/tim/Documents/GitHub/KoboldOS/KoboldOS/`
- **Build**: `cd /Users/tim/Documents/GitHub/KoboldOS/KoboldOS && bash scripts/build.sh`
- **Commit**: GitHub Desktop (nicht CLI)

### Architektur-Kurzfassung
- SwiftUI macOS + In-Process Daemon (Port 8080)
- sendMessage → `/agent/stream` (SSE, voller AgentLoop) — NICHT `/chat`!
- `/chat` = Legacy Ollama-Passthrough OHNE System-Prompt/Tools
- Daemon startet NUR in AppDelegate (nicht MainView.onAppear)
- Agent-Typen: `general` (Orchestrator), `coder`, `web`

### API-Endpunkte
| Endpoint | Methode | Beschreibung |
|----------|---------|-------------|
| `/health` | GET | Status + PID |
| `/agent` | POST | Agent-Anfrage (SSE-Streaming) |
| `/chat` | POST | Direct LLM call (no tools) |
| `/metrics` | GET | Statistiken |
| `/metrics/reset` | POST | Reset counters |
| `/memory` | GET | All CoreMemory blocks |
| `/memory/update` | POST | Upsert/delete a block |
| `/memory/snapshot` | POST | Create snapshot |
| `/models` | GET | Available Ollama models |
| `/model/set` | POST | Set active model |
| `/tasks` | GET/POST | Task management |
| `/trace` | GET | Activity timeline |
| `/history/clear` | POST | Clear conversation history |
