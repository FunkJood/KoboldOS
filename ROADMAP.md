# KoboldOS Roadmap

## Alpha v0.2.8 (Aktuell — 2026-02-23)

### v0.2.8 Features
- **Teams**: Echtes 3-Runden-Diskursmodell, Persistenz, Organigramm, Chat-Controls
- **PlaywrightTool**: Chrome-Automatisierung (navigate, click, fill, screenshot, evaluate)
- **ScreenControlTool**: Maus/Tastatur/Screenshot/OCR (CGEvent, Vision.framework)
- **Goals-System**: Ziele unter Persönlichkeit → Agent System-Prompt
- **Idle Tasks**: User-definierbare Aufgaben mit Cooldown, Quiet Hours, Kategorien
- **Heartbeat**: Konfigurierbarer Timer, Rate-Limiting, Sicherheits-Toggles
- **Task/Workflow ← Teams**: teamId Integration, Team-Picker, Team-Node
- **Live Thinking Layers**: Steps + Thinking + Typing nicht-überlappend
- **SD Crash Fix**: Task.detached für Model-Loading, Modell-Auswahl aus Ordner
- **Interactive Buttons**: Strikte Ja/Nein-Erkennung
- **AI-Vorschläge**: SuggestionService via Ollama mit Cache
- **Settings**: Benachrichtigungen, Debugging & Sicherheit, Heartbeat in Allgemein

### Bisherige Features (v0.2.5 und früher)
- Agent-gesteuerter Chat mit SSE-Streaming
- 25+ Tools: Shell, File, Browser, Playwright, Screen Control, Calendar, Contacts, HTTP, AppleScript
- TTS (AVSpeechSynthesizer), STT (SwiftWhisper), Stable Diffusion (CoreML)
- CoreMemory (Kurzzeit, Langzeit, Wissen) mit Archivierung
- Workflow-Editor (n8n-Style Canvas) + Teams-Tab + Marktplatz
- Scheduled Tasks mit Cron-Expressions
- Skills-System (.md Dateien)
- ProactiveEngine (Heartbeat, Idle Tasks, Goals, Suggestions)
- Multi-Language Support (15 Sprachen)
- Auto-Update via GitHub Releases
- MacOS Menu Bar Integration (brain.head.profile Icon)
- Web-Fernsteuerung + Cloudflare Tunnel
- Connections: Google, SoundCloud, Telegram, iMessage, A2A

---

## v0.3.0 — Kontext-Intelligenz & Memory-Revolution

### Kontext-Management (Prio 1)
- **Kontext-Bewusstsein**: Agent ist sich IMMER über aktuelle Kontextgröße bewusst
- **Kontextgröße einstellbar** in Settings (4K, 8K, 16K, 32K, 64K, 128K, 256K)
- **Kontext-Komprimierung am Ende**: Wenn Kontext voll, automatisch:
  1. Wichtigstes in Erinnerungen (CoreMemory) speichern
  2. Stichpunkte/Zusammenfassung für neuen Kontext erstellen
  3. Alten Kontext archivieren, neuen starten mit Zusammenfassung
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
| TTS + STT + Stable Diffusion | v0.2.5 | Done |
| Teams (Diskursmodell) | v0.2.8 | Done |
| Playwright Browser | v0.2.8 | Done |
| Screen Control (Maus/Tastatur/OCR) | v0.2.8 | Done |
| Goals-System | v0.2.8 | Done |
| Idle Tasks + Heartbeat | v0.2.8 | Done |
| Interactive Buttons | v0.2.8 | Done |
| AI-Vorschläge (SuggestionService) | v0.2.8 | Done |
| Marktplatz (Mock) | v0.2.8 | Done |
| MCP Wiring | v0.2.9 | Geplant |
| Voice Chat (TTS + Mikro) | v0.2.9 | Geplant |
| Kontext-Komprimierung | v0.3.0 | Geplant |
| Agent Self-Managed Memory | v0.3.0 | Geplant |
| FAISS Vector-DB | v0.3.0 | Geplant |
| WebApp UI-Spiegelung | v0.3.0 | Geplant |
| Eigene Model-Engine | v0.3.0 | Geplant |
| Filesystem-Agent (PDF etc.) | v0.3.0 | Geplant |
| A2A Protokoll | v0.4.0 | Geplant |
| Composio/LangChain/CrewAI | v0.4.0 | Geplant |
| REST API | v0.4.0 | Geplant |
| Voice (Whisper + ElevenLabs) | v0.5.0 | Geplant |
| Messaging (WhatsApp etc.) | v0.5.0 | Geplant |
| Canvas/A2UI | v0.5.0 | Geplant |
| iOS App | v0.6.0 | Geplant |
| Android App | v0.6.0 | Geplant |
| Linux/Windows | v0.6.0 | Geplant |
| Docker | v0.6.0 | Geplant |
| Skill Marketplace | v0.6.0 | Geplant |
