# KoboldOS — Roadmap & Planung

> Stand: Alpha v0.3.15 — 25. Feb 2026
> Dieses Dokument beschreibt geplante Features, Überarbeitungen und Entfernungen für zukünftige Versionen.

---

## Nächste Version: Alpha v0.4.0 — "Teams & Apps Rewrite"

### Teams-System — Komplette Überarbeitung

**Aktueller Stand (v0.3.15):**
- `TeamsGroupView.swift`, `TeamView.swift`, `SubCoordinateTeamTool.swift` existieren
- Teams funktionieren grundsätzlich (R1/R2/R3 Diskursmodell), sind aber eng mit dem Workflow-Builder verwoben
- Team-Node im Workflow-Builder ist vorhanden
- Team-Delegation für ScheduledTasks funktioniert

**Problem:**
- Teams-Code ist über RuntimeViewModel, TasksView, TeamView und TeamsGroupView verteilt
- Datenmodelle (AgentTeam, TeamAgent, GroupMessage) und View-Code in derselben Datei
- SubCoordinateTeamTool nutzt Notification-Pattern (ineffizient, schwer debugbar)
- Team-Node im Workflow-Builder macht den Workflow-Code unnötig komplex

**Geplante Änderungen:**
- **Teams aus Workflow-Builder lösen** — Team-Node-Typ entfernen, Teams werden eigenständig
- **Eigene Teams-Ansicht** als klar abgetrennter Bereich (nicht als Sidebar-Tab, sondern modal/sheet)
- **Vereinfachtes UI** — weniger Boilerplate, klarere Konfiguration von Agents pro Team
- **Klare Trennung**: Datenmodelle in eigene Datei `TeamModels.swift`
- **SubCoordinateTeamTool** überarbeiten: direkter async-Aufruf statt Notification-Pattern
- **Team-Ergebnisse** werden in eigenem Kontext angezeigt, nicht in Chat eingebettet

**Konkrete Schritte für v0.4.0:**
1. `SubCoordinateTeamTool.swift` — Notification-Pattern ersetzen durch direkten async-Aufruf
2. `TeamView.swift` — Team-Node-Type und `teamId`-Property aus WorkflowNode entfernen
3. `TeamsGroupView.swift` — Datenmodelle in eigene Datei `TeamModels.swift` auslagern
4. `RuntimeViewModel.swift` — Team-Code in eigenen `TeamManager` auslagern
5. `TasksView.swift` — Team-Delegation vereinfachen

---

### Apps-Ansicht — Neuimplementierung

**Aktueller Stand (v0.3.15):**
- `ApplicationsView.swift` und `AppMenuManager.swift` wurden in v0.3.1 entfernt (CPU-Hauptverursacher)
- Settings → "Apps"-Sektion in v0.3.15 entfernt
- AppBrowserTool + AppTerminalTool navigieren nicht mehr zu einem Apps-Tab

**Warum entfernt:**
- Die alte Implementierung nutzte permanente Timer → hohe CPU-Last auch im Idle
- Screenshots statt echter Fenstereinbettung → keine echte App-Interaktion möglich
- Redundant mit Shell-Tool + Browser-Tool für die meisten Anwendungsfälle

**Geplante Neuimplementierung:**
- **Echte Fenstereinbettung** via `NSWindowController` + `addChildWindow(_:ordered:)` (kein Screenshot)
- **Lazy Loading** — nur rendern wenn Tab aktiv, sofort pausieren wenn nicht sichtbar
- **Kein permanenter Timer** — Event-basiertes Update (Fenster-Änderungs-Benachrichtigungen)
- **Terminal** als PTY-basierter Terminal-Emulator (SwiftTerm oder eigene Implementierung)
- **Browser** als WKWebView mit Agent-Steuerung (AppBrowserTool navigiert direkt)
- **Settings** zurückbringen: Shell-Auswahl (zsh/bash), Browser-Startseite, Cookie-Blocking

**Konkrete Schritte für v0.4.0:**
1. `ApplicationsView.swift` neu schreiben mit echter Fenstereinbettung
2. `AppMenuManager.swift` ohne Timer, rein event-basiert
3. `AppBrowserTool.swift` — Navigation zu neuem Apps-Tab reaktivieren
4. `AppTerminalTool.swift` — Terminal-Sub-Tab reaktivieren
5. Settings → "Apps"-Sektion zurückbringen (nur sinnvolle Einstellungen)

---

## Mittelfristig: Alpha v0.4.x

### Memory-System Verbesserungen
- **Tag-Vorschläge** beim Hinzufügen (basierend auf vorhandenen Tags)
- **Bulk-Edit**: Mehrere Einträge gleichzeitig löschen oder Typ ändern
- **Memory-Import**: JSON-Import für Backups einzelner Einträge
- **Auto-Re-Embedding** wenn Embedding-Modell gewechselt wird

### Agent-Verbesserungen
- **Streaming für Sub-Agents**: Ergebnisse live gestreamt statt als Block
- **Context-Komprimierung**: Automatisches Zusammenfassen älterer Nachrichten
- **Tool-Timeouts** konfigurierbar pro Tool (nicht nur global)
- **Agent-Profile**: Gespeicherte Persönlichkeits-Presets schnell wechselbar

### Performance
- **Lazy MemoryStore**: Entries on-demand laden, nicht alle beim Start
- **EmbeddingRunner-Cache**: Häufig abgefragte Embeddings in LRU-Cache
- **DaemonListener**: HTTP/1.1 Keep-Alive für weniger Connection-Overhead

### UI
- **Chat-Export**: Einzelnen Chat als Markdown/PDF exportieren
- **Suche über alle Chats**: Volltext-Suche in Chat-History
- **Keyboard Shortcuts**: Navigations-Shortcuts für alle Haupt-Bereiche
- **Drag & Drop**: Dateien direkt in Chat ziehen

---

## Langfristig: Alpha v0.5+

### Lokale Modelle
- **GGUF direkt laden**: Ohne Ollama, direkt via llama.cpp Swift-Bindings
- **Model-Benchmarking**: Welches Modell ist am schnellsten für welche Task?
- **Spezialisierte Modelle per Agent**: Web-Agent → Mistral, Coder → DeepSeek

### Multi-Agent-Orchestrierung
- **Agent-Netzwerke**: N Agents koordinieren ohne zentralen Instructor
- **Ergebnis-Voting**: Mehrere Agents, bestes Ergebnis gewinnt
- **Parallele Tool-Ausführung**: Mehrere Tools gleichzeitig in einer Agent-Runde

### Plattform-Erweiterung
- **iOS-Companion**: Einfache Chat-App die mit Mac-Daemon kommuniziert
- **API-Server**: KoboldOS als lokaler AI-API-Provider für andere Apps

---

## Bekannte technische Schulden

| Bereich | Problem | Priorität |
|---------|---------|-----------|
| RuntimeViewModel | 3500+ Zeilen — braucht Aufspaltung in Manager-Klassen | Hoch |
| AgentLoop | System-Prompt kann bei vielen Tools > 15K Tokens werden | Hoch |
| TeamsGroupView | Datenmodelle + View in einer Datei gemischt | Mittel |
| MemoryStore | Kein shared singleton — jede Instanz lädt von Disk | Mittel |
| EmbeddingStore | Kein automatisches Re-embedding bei Modellwechsel | Mittel |
| DaemonListener | Custom TCP HTTP-Parser — fehleranfällig bei Edge Cases | Niedrig |

---

## Entscheidungslog

| Version | Entscheidung | Grund |
|---------|-------------|-------|
| v0.3.1 | ApplicationsView + AppMenuManager entfernt | Hauptverursacher CPU-Last (Timer-Loop) |
| v0.3.1 | SidebarTab.applications entfernt | Abhängig von obigem |
| v0.3.1 | TypewriterText: 12 chars/40ms statt 3/8ms | 85% weniger MainActor-Updates |
| v0.3.15 | Settings → "Apps"-Sektion entfernt | Tote UI ohne Apps-Tab |
| v0.3.15 | AgentType.researcher entfernt → .web | Redundant mit Web-Agent |
| v0.3.15 | MemoryStore → Einzeldateien | Robustheit, keine Massen-Korruption |
| v0.3.15 | RAG via Ollama Embeddings eingeführt | 95% Token-Ersparnis bei Memory-Recall |
| v0.3.15 | Memory editierbar in UI | Nutzer-Wunsch, war nur Add/Delete möglich |
| Geplant | Teams vollständig überarbeiten | Zu eng verwoben, schwer wartbar |
| Geplant | Apps-Ansicht neu implementieren | Echte Fenstereinbettung statt Screenshots |
