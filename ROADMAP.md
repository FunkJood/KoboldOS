# KoboldOS Roadmap

## Alpha v0.2.6 (Aktuell)

### Performance & UI Overhaul
- Context Window 150K (konfigurierbar bis 200K), Agent-Limits konfigurierbar
- GlobalHeaderBar: Datum, Uhr (mittig), Wetter, aktive Agents, Benachrichtigungen
- Chat-Header verschlankt: Name/Model zentriert, Tools-Zeile entfernt
- Alle Fonts +1pt, Kleeblatt-Hintergrundmuster
- Agenten-Tab aus Sidebar in Settings verschoben
- Settings: "Persönlichkeit" (vorher "Agent"), neue "Agenten"-Sektion, "Agent-Leistung"
- Session-Switch: 2-Phasen-Restore, debounced saves
- RichTextView Caching, CloverPattern GPU-Rendering
- OAuth → UserDefaults (kein Keychain-PW-Prompt mehr)
- Workflow/Task Deep-Link Notifications + Sounds
- Sidebar: Chats klappbar unter Aufgaben/Workflows
- MCP-Infrastruktur erstellt (MCPClient, MCPConfigManager, MCPBridgeTool)
- TokenEstimator, 3-Stage Context Pruning, ArchivalMemory

### Bisherige Features (v0.1.1–v0.2.5)
- Agent-gesteuerter Chat mit SSE-Streaming
- Tool-System: Shell, File, Browser, Calendar, Contacts, HTTP, AppleScript
- CoreMemory (Kurzzeit, Langzeit, Wissen)
- Workflow-Editor (n8n-Style Canvas)
- Scheduled Tasks mit Cron-Expressions
- Skills-System (.md Dateien)
- ProactiveEngine (Dashboard-Vorschläge)
- Multi-Language Support (15 Sprachen)
- Auto-Update via GitHub Releases
- MacOS Menu Bar Integration
- Web-Fernsteuerung
- Strikte Session-Trennung (Chat/Task/Workflow)
- Notification-Navigation mit Deep-Links

---

## v0.2.7 — Voice Chat & MCP Integration

### Voice Chat (Prio 1)
- **TTS-Lautsprecher-Button** im Chat: Text-to-Speech für Agent-Antworten
- **Mikrofon-Eingabe**: Live-Audiogespräch (wie ChatGPT Voice Mode)
- **Natürliche männliche Stimme**: Bestes verfügbares Vocal Model
- **STT-Integration**: Whisper-basiert (STTManager bereits vorhanden)

### MCP verdrahten (Prio 1)
- **AgentLoop.setupTools() → MCPConfigManager.connectAllServers()**: MCP-Tools im Agent verfügbar
- **MCP Settings-UI**: Server-Konfiguration unter Settings → Verbindungen

### Weitere Tasks
- TeamView: Unused vars bereinigen, Race Conditions fixen, Trigger-Stubs implementieren
- Applikationen-Tab: Terminal/WebView/Programm-Runner in Sidebar

---

## v0.3.0 — Kontext-Intelligenz & Memory-Revolution

### Kontext-Management
- ~~Kontextgröße einstellbar~~ ✅ (v0.2.6: bis 200K)
- ~~Kontext-Komprimierung~~ ✅ (v0.2.6: 3-Stage Pruning + ArchivalMemory)
- **Dynamische Konversations-Komprimierung**: Ältere Messages automatisch zusammenfassen

### Memory-Upgrade (Prio 1)
- **Agent verwaltet Memory selbst**: Entscheidet autonom was archiviert/vergessen wird
- **AI-gefilterte Memory-Retrieval**: LLM filtert relevante Erinnerungen beim Abruf
- **AI-konsolidierte Memory-Speicherung**: LLM merged Duplikate beim Speichern
- **Solutions-Memory**: Gespeicherte Code-Snippets und bewährte Patterns
- **FAISS Vector-DB**: Echte semantische Suche statt TF-IDF
- **Shared Memory Blocks**: Geteiltes Wissen zwischen Agents
- **Jeder Agent hat persistente Identität** über Sessions hinweg

### Filesystem-Agent
- **Agent kann PDFs, Dokumente organisieren und referenzieren**
- Dokument-Indexierung (PDF, Word, Markdown, Code)
- RAG über lokale Dateien (Retrieval-Augmented Generation)
- Datei-Zusammenfassungen und Metadaten-Extraktion

### WebApp als echte UI-Spiegelung
- **Komplette Spiegelung der nativen SwiftUI-UI** als WebApp
- Alle Views: Chat, Dashboard, Memory, Tasks, Workflows, Settings
- Echtzeit-Sync zwischen nativer App und WebApp
- Responsive Design für Mobile-Browser

### Eigene Model-Engine
- Native GGUF Model Loading (ohne Ollama-Abhängigkeit)
- Metal-beschleunigte Inferenz auf Apple Silicon
- Model-Download & Management direkt in der App
- Quantisierungs-Optionen (Q4, Q5, Q8)
- Prompt-Caching für schnellere Antworten

---

## v0.4.0 — Multi-Agent & Tool-Ökosystem

### Multi-Agent System v2
- **Agent-to-Agent (A2A) Protokoll**: Standardisierte Inter-Agent-Kommunikation
- **Subordinate Agents**: Eigene Prompts, Tools und Extensions pro Sub-Agent
- **Multi-Agent Routing**: "Most-specific wins" Hierarchie
- **Deterministische Routing-Regeln** (peer > role > guild > account > channel)
- **Isolierte Agents**: Eigene Credentials und Kanäle pro Agent

### Extension & Hook System
- **Lifecycle Hooks**: before_llm_call, after_tool_result, monologue_end, etc.
- **Auto-Loading externer Tool-Libraries**: Plugins dynamisch nachladen
- **Composio Integration**: 1000+ App-Verbindungen (Google, Slack, GitHub, etc.)
- **LangChain Tool-Kompatibilität**: Bestehende LangChain-Tools nutzen
- **CrewAI Tool-Kompatibilität**: CrewAI-Tools einbinden

### Playwright Browser-Automation
- Vollständige Browser-Steuerung (nicht nur HTTP-Requests)
- Seiten navigieren, Formulare ausfüllen, Screenshots machen
- JavaScript-Ausführung auf Webseiten
- Login-Sessions persistent halten

### Task-System v2
- Task-Ketten (Task A → Task B → Task C)
- Bedingte Ausführung (nur wenn Bedingung erfüllt)
- Heartbeat Scheduler für autonome wiederkehrende Aktionen
- Task-Protokoll mit Erfolgs/Fehler-History

### REST API
- **Vollständige REST API** für externe App-Integration
- Authentifizierung via API-Keys
- Swagger/OpenAPI Dokumentation
- Webhooks für Events (Task fertig, Agent-Antwort, etc.)

### Apps-Tab
- `SidebarTab.apps` im Enum
- Installierte Skills (.md), CLI-Tools, Python-Scripts als "Apps"
- Jedes App hat: Name, Icon, Beschreibung, "Ausführen"-Button
- Interaktives Terminal-Fenster für Skript-Output
- Node.js Code-Ausführung (neben Python und Bash)

---

## v0.5.0 — Voice, Messaging & Canvas

### Voice-Interface
- **Voice Wake Mode**: Always-on Spracherkennung ("Hey Kobold")
- **Talk Mode**: Bidirektionale Sprachkonversation
- **Whisper Integration**: Lokale Speech-to-Text Transkription
- **ElevenLabs TTS**: Natürliche Sprachausgabe
- **Voice-Notizen**: Spracheingabe → Agent verarbeitet

### Messaging-Kanäle
- **WhatsApp Integration** (Business API / Baileys)
- **Telegram Integration** (Bot API)
- **Slack Integration** (Bot/App)
- **Discord Integration** (Bot)
- **Signal Integration**
- **iMessage Integration** (BlueBubbles)
- **Microsoft Teams Integration**
- **Google Chat Integration**
- **Matrix Integration** (offenes Protokoll)
- **WebChat Widget** (embeddable für eigene Websites)
- Einheitlicher Message-Router für alle Kanäle

### Canvas / A2UI
- **Visueller Workspace**: Agent kann strukturierten Output als Canvas rendern
- Code-Editor mit Syntax-Highlighting
- Diagramme und Flowcharts (Mermaid)
- Tabellen und Daten-Visualisierungen
- Interaktive Formulare vom Agent generiert

---

## v0.6.0 — Cross-Platform & Ecosystem

### Cross-Platform Support
- **iOS/iPadOS Companion App** (SwiftUI, shared KoboldCore)
- **Android Companion App** (Kotlin)
- **Linux-Support** (CLI + headless Daemon)
- **Windows-Support** (via Electron oder .NET MAUI)
- **Sync zwischen Geräten** (iCloud / eigener Server)

### Docker Deployment
- **Docker Image** für Self-Hosting
- Docker Compose mit allen Abhängigkeiten
- Sandboxed Code-Ausführung in Container
- One-Click Deploy auf VPS

### Skill Marketplace
- **Community Skill Registry** (KoboldHub)
- Ein-Klick-Installation von Skills
- Bewertungen und Reviews
- Portable Skill Format (YAML-basiert)
- Automatische Skill-Updates
- Skill-Verifizierung und Sicherheits-Scan

### CLI Distribution
- **Homebrew Package**: `brew install koboldos`
- **PyPI Package**: `pip install koboldos-lite` (headless Agent)
- **npm Package**: CLI-Tools für Node.js Integration
- Onboarding CLI Wizard (`kobold init`)

---

## Langfristige Vision (v1.0+)

### Autonomes OS-Layer
- KoboldOS als intelligente Schicht über macOS/iOS/Linux/Windows
- Automatische Erkennung von Benutzeraktionen und proaktive Hilfe
- System-weite Hotkeys und Shortcuts

### Smart Home & IoT
- HomeKit-Integration für IoT-Steuerung
- Szenen-Automatisierung via Agent
- Sensor-Daten als Agent-Kontext

### Enterprise Features
- Team-Accounts mit Rollen und Berechtigungen
- Audit-Log für alle Agent-Aktionen
- Compliance-Modi (DSGVO, SOC2)
- On-Premise Deployment Guide

### Lokale RAG Pipeline
- Vollständige Retrieval-Augmented Generation
- Automatische Indexierung von ~/Documents
- Chunking, Embedding, Re-Ranking
- Antworten mit Quellenangaben

---

## Feature-Tracker

| Feature | Version | Status |
|---------|---------|--------|
| Session-Trennung | v0.2.2 | Done |
| Task-System Upgrade | v0.2.2 | Done |
| Context 150K + konfigurierbar | v0.2.6 | Done |
| GlobalHeaderBar | v0.2.6 | Done |
| Performance (Caching, GPU, Debounce) | v0.2.6 | Done |
| Workflow/Task Notifications | v0.2.6 | Done |
| OAuth Keychain→UserDefaults | v0.2.6 | Done |
| MCP Infrastruktur | v0.2.6 | Done |
| Kontext-Komprimierung (3-Stage) | v0.2.6 | Done |
| Voice Chat (TTS + Mikro) | v0.2.7 | Nächste |
| MCP verdrahten | v0.2.7 | Nächste |
| Agent Self-Managed Memory | v0.3.0 | Geplant |
| FAISS Vector-DB | v0.3.0 | Geplant |
| WebApp UI-Spiegelung | v0.3.0 | Geplant |
| Eigene Model-Engine | v0.3.0 | Geplant |
| Filesystem-Agent (PDF etc.) | v0.3.0 | Geplant |
| A2A Protokoll | v0.4.0 | Geplant |
| Composio/LangChain/CrewAI | v0.4.0 | Geplant |
| Playwright Browser | v0.4.0 | Geplant |
| REST API | v0.4.0 | Geplant |
| Voice Wake Mode | v0.5.0 | Geplant |
| Messaging (WhatsApp etc.) | v0.5.0 | Geplant |
| Canvas/A2UI | v0.5.0 | Geplant |
| iOS App | v0.6.0 | Geplant |
| Android App | v0.6.0 | Geplant |
| Linux/Windows | v0.6.0 | Geplant |
| Docker | v0.6.0 | Geplant |
| Skill Marketplace | v0.6.0 | Geplant |
