# KoboldOS — Roadmap

> Stand: Alpha v0.3.98 — 6. Maerz 2026

---

## Aktueller Fokus: Stabilisierung (v0.3.x)

### Erledigt in v0.3.98
- Trading Engine: Regime-Aware Risikomanagement (Bull/Bear/Sideways/Crash)
- Trading: 9 Strategien mit Bear-Buy-Suppression + Sideways-Optimierung
- Trading: EV-Gate, Familien-Deduplizierung, SELL-Veto
- Trading: Fee-Rate-Korrektur (1.2% Coinbase), TP/SL-Ratio-Optimierung
- Trading: EUR-Reserve-Intelligence, Daily Limits, Pair Cooldown
- Trading: Trade-History Bug-Fix (SQLite-Persistenz), SQL-Injection-Fix
- Trading: EUR-Werte in aktiven Orders + Historie, HODL P&L
- Trading: Dynamische Asset-Konzentration (50% Bull, 15% Bear)
- Versionsnummern konsolidiert (KoboldVersion.swift als Single Source of Truth)

### Erledigt in v0.3.8
- WebGUI Teams Tab (Chat als Content View, Member-Editing, System-Prompts)
- WebGUI Workflow-Engine (Inspector, Connection Snap, Node-by-Node Execution)
- Workflow Thought Stream (Live-Token-Anzeige pro Agent-Node)
- Workflow Chat (dedizierter Chat mit Output-Routing)
- Desktop Team-Mitglieder bearbeitbar (Inline-Edit)
- CRM Modul im WebGUI (Kontakte, Firmen, Deals, Aktivitaeten)
- CSS Variable Fix (--accent-primary, SVG Connections sichtbar)
- Chat-Freeze bei langen Sessions (Lazy Decoding)
- Google Import 403 + Token-Refresh
- Shell-Tier Mutual Exclusion

### Offen fuer v0.3.x
- Trading: Zombie-Position-Vermeidung (gradueller TP-Decay)
- WebGUI Mobile-responsive Design
- CRM Agent-Workflow optimieren
- Telegram JSON-Leak weiter absichern
- Qdrant-Integration testen und stabilisieren
- ComfyUI Image Engine verbessern

---

## Geplant: v0.4.0 — "Polish & Performance"

### Trading
- Short-Selling (inverse Pairs / dYdX)
- Paper-Trading Modus (Simulation ohne echtes Geld)
- Performance-Dashboard mit Equity-Kurve
- Strategie-Marketplace (Community-Strategien)

### Teams
- Team-Ergebnisse besser in eigenen Sessions anzeigen
- Team-Routing optimieren (weniger Notification-Pattern)

### Workflows
- Sub-Workflow Execution (verschachtelte Workflows)
- Condition-Evaluation (echte Expression-Engine)
- Webhook-Trigger (eingehende HTTP-Requests starten Workflows)
- Workflow-Templates (vorgefertigte Pipelines)

### Memory
- Embedding-basierte Deduplikation bei Auto-Memorize
- Memory-Export/Import (JSON)

### WebGUI
- Vollstaendige Feature-Parity mit Desktop-App
- Mobile-responsive Design
- Workflow-Ergebnisse persistieren

### Agent
- Multi-Turn Tool-Use Optimierung
- Bessere Error-Recovery fuer lokale Modelle

---

## Langfristig: v0.5.0+

- A2A (Agent-to-Agent) Protokoll erweitern
- Plugin-System fuer Community-Tools
- Lokale Fine-Tuning Integration
- Multi-User Support (Docker)
