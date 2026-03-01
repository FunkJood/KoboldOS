══════════════════════════════════════════════
KOBOLDOS ALPHA v0.2.8 — SCHNELLSTART
══════════════════════════════════════════════

OPTION A: APP STARTEN (EMPFOHLEN)
──────────────────────────────────────────────
1. KoboldOS.app in /Applications ziehen
2. Doppelklick auf KoboldOS.app
3. Daemon startet automatisch im Hintergrund
4. GUI oeffnet sich mit Chat + Onboarding

OPTION B: CLI INTERACTIVE MODE
──────────────────────────────────────────────
1. Terminal oeffnen
2. ./KoboldOS.app/Contents/MacOS/kobold
3. Interaktive Chat-Session startet automatisch
4. Daemon wird bei Bedarf im Hintergrund gestartet

OPTION C: DAEMON MANUELL STARTEN
──────────────────────────────────────────────
1. Terminal: ./KoboldOS.app/Contents/MacOS/kobold daemon
2. Terminal: open KoboldOS.app

GUI-FUNKTIONEN
──────────────────────────────────────────────
- Dashboard    — System-Uebersicht, Metriken, Temperatur (°C)
- Chat         — Nachrichten senden, Agent nutzt 25+ Tools automatisch
- Aufgaben     — Wiederkehrende + Idle-Aufgaben mit Heartbeat
- Workflows    — Visueller Workflow-Editor mit Team-Nodes
- Teams        — AI-Beratungsgremium mit 3-Runden-Diskursmodell
- Marktplatz   — Widgets, Automationen, Skills, Themes
- Gedaechtnis  — Core Memory (Kurzzeit/Langzeit/Wissen)
- Einstellungen — 14 Sektionen (Konto bis Debugging)
- Neue Tools   — Playwright (Chrome), Screen Control (Maus/Tastatur/OCR)

CLI-BEFEHLE
──────────────────────────────────────────────
kobold                  — Interaktive Chat-Session (Standard)
kobold daemon           — Daemon starten
kobold health           — Server-Status pruefen
kobold model list|set   — Modelle verwalten
kobold metrics          — System-Metriken
kobold memory list|get  — Core Memory anzeigen
kobold memory log       — Memory-Versionshistorie
kobold task list|create — Aufgaben verwalten
kobold workflow run     — Workflows ausfuehren
kobold skill list       — Skills anzeigen
kobold secret set|get   — Secrets verwalten
kobold config list|set  — Konfiguration
kobold checkpoint list  — Checkpoints anzeigen
kobold card             — Agent Card anzeigen
kobold safe-mode        — Safe Mode Status
kobold trace list|get   — Trace-Logs

INTERAKTIVE SESSION — SLASH-BEFEHLE
──────────────────────────────────────────────
/help           — Alle Befehle anzeigen
/new            — Neue Session starten
/list           — Alle Sessions anzeigen
/load <id>      — Session laden
/model [name]   — Modell anzeigen/wechseln
/agent [type]   — Agent-Typ wechseln
/memory [label] — Memory-Bloecke anzeigen
/export [pfad]  — Session als Markdown exportieren
/resume [id]    — Checkpoint fortsetzen
/clear          — Session leeren
/quit           — Beenden

HTTP ENDPOINTS
──────────────────────────────────────────────
GET  /health                    — Server Status
POST /agent                     — Agent (multi-step, mit Tools)
POST /agent/stream              — Agent mit SSE Streaming
POST /chat                      — Direkter LLM Chat (ohne Tools)
GET  /models                    — Verfuegbare Modelle
GET  /metrics                   — System Metriken
GET  /memory                    — Core Memory Bloecke
GET  /tasks                     — Geplante Aufgaben
GET  /workflows                 — Workflows
GET  /checkpoints               — Gespeicherte Checkpoints
GET  /memory/versions           — Memory Versionshistorie
GET  /.well-known/agent.json    — A2A Agent Card (public)

VORAUSSETZUNGEN
──────────────────────────────────────────────
- macOS 14.0 (Sonoma) oder neuer
- Ollama installiert (brew install ollama)
- Mindestens ein LLM Modell (ollama pull llama3.2)

PROBLEME?
──────────────────────────────────────────────
- GUI zeigt "Disconnected"? → Daemon laeuft nicht, App neustarten
- Chat sendet nicht? → Enter-Taste druecken
- Port belegt? → lsof -i :8080
- Keine Modelle? → ollama pull llama3.2

VERSION: Alpha 0.2.8 | BUILD: 2026-02-23
══════════════════════════════════════════════