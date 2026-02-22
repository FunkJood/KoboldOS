# KoboldOS Roadmap

## Alpha v0.2.2 (Aktuell)

### Session-Trennung & Task-System
- Strikte Trennung: 3 separate Session-Speicher (Chat, Task, Workflow)
- `ChatMode` Enum: Normal, Task, Workflow
- Task-Bearbeitung (Edit, Toggle enabled/disabled)
- Task-Chats in eigener Sidebar-Liste
- Workflow-Chats in eigener Sidebar-Liste
- Task Auto-Scheduler (Cron-basiert, alle 60s geprüft)
- Notification-Navigation: Klick auf Benachrichtigung navigiert zum Chat/Task/Workflow

### Bisherige Features
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

---

## v0.3.0 (Geplant)

### Apps-Tab
- `SidebarTab.apps` im Enum
- Zeigt: installierte Skills (.md), CLI-Tools, Python-Scripts
- Jedes "App" hat: Name, Icon, Beschreibung, "Ausführen"-Button
- Interaktives Terminal-Fenster für Skript-Output
- Browser-Tool als eingebetteter WebView

### Memory-Upgrade
- Langzeit-Gedächtnis mit Versionierung
- Memory-Import/Export als JSON
- Automatische Memory-Bereinigung (Duplikate, Konflikte)
- Memory-Suche mit semantischer Ähnlichkeit

### Eigene Model-Engine
- Native GGUF Model Loading (ohne Ollama-Abhängigkeit)
- Metal-beschleunigte Inferenz auf Apple Silicon
- Model-Download & Management direkt in der App
- Quantisierungs-Optionen (Q4, Q5, Q8)
- Prompt-Caching für schnellere Antworten

### Task Auto-Scheduler v2
- Echtzeit-Cron-Auswertung mit Sekunden-Präzision
- Task-Ketten (Task A → Task B)
- Bedingte Ausführung (nur wenn Bedingung erfüllt)
- Task-Protokoll mit Erfolgs/Fehler-History

---

## v0.4.0 (Vision)

### Cross-Platform Support
- iOS/iPadOS App (SwiftUI, shared Core)
- Linux-Support (CLI + headless daemon)
- Windows-Support (via .NET MAUI oder Electron)
- Sync zwischen Geräten (iCloud / eigener Server)

### Browser-Integration
- Eingebetteter WebView mit Agent-Steuerung
- Automatisches Web-Scraping
- Form-Ausfüllung und Navigation
- Screenshot-Analyse

### Plugin-Marketplace
- Community-Tools und Skills
- Ein-Klick-Installation
- Bewertungen und Reviews
- Automatische Updates

### Multi-Agent Orchestrierung
- Parallele Agent-Ausführung
- Agent-zu-Agent Kommunikation
- Spezialisierte Agent-Profile (Coder, Researcher, Reviewer)
- Workflow-basierte Agent-Ketten

---

## Langfristige Vision

- **Autonomes OS-Layer**: KoboldOS als intelligente Schicht über macOS
- **Voice-Interface**: Sprachsteuerung mit Whisper-Integration
- **Lokale RAG**: Retrieval-Augmented Generation über lokale Dokumente
- **Smart Home**: HomeKit-Integration für IoT-Steuerung
