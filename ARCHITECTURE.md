# KoboldOS — Architecture Guide (v0.3.98)

> Stand: 6. Maerz 2026 — Alpha v0.3.98

---

## 1. Project Structure

```
KoboldOS/
├── Sources/
│   ├── KoboldCLI/              Swift CLI (kobold command, daemon mode)
│   ├── KoboldCore/             Core library (shared by CLI + App)
│   │   ├── Agent/              AgentLoop, ToolCallParser, ToolRuleEngine, AgentWorkerPool
│   │   ├── Tools/              60+ Tool implementations (FileTool, ShellTool, ContactsTool, etc.)
│   │   ├── Trading/            Trading Engine, Strategy Engine, Risk Manager, Backtester
│   │   ├── Memory/             MemoryStore (Tag-based), EmbeddingStore, ConsciousnessEngine
│   │   ├── Native/             LLMRunner (Ollama only), ModelPuller
│   │   ├── Headless/           DaemonListener (HTTP/SSE server on port 8080)
│   │   ├── Security/           SecretStore (Keychain)
│   │   └── Plugins/            CalculatorPlugin
│   └── KoboldOSControlPanel/   macOS SwiftUI App
│       ├── RuntimeViewModel.swift   Central ViewModel (sessions, messaging, connectivity)
│       ├── ChatView.swift           Main chat UI
│       ├── SettingsView.swift       All settings (AppStorage-based)
│       ├── WebAppServer.swift       Embedded WebGUI (HTML/CSS/JS in buildHTML())
│       ├── TeamsView.swift          Agent teams management
│       ├── ContactsView.swift       CRM + Apple/Google contacts
│       └── GlassUI.swift            Design system (GlassChatBubble, FuturisticBox, etc.)
├── scripts/build.sh            DMG packaging + swift build
├── Package.swift               SPM manifest (SwiftWhisper only external dep)
└── CHANGELOG.md / README.md / ARCHITECTURE.md
```

## 2. Core Architecture

### Message Flow
```
User Input → RuntimeViewModel.sendMessage()
  → POST /agent/stream (SSE to DaemonListener)
  → AgentLoop.runStreaming() (full tool-use loop)
  → SSE chunks back to ViewModel (token-by-token)
  → SwiftUI renders via @Published messages
```

### Key Rules
- **sendMessage → `/agent/stream`** (SSE, full AgentLoop with tools) — NICHT `/chat`
- `/chat` = Legacy Ollama-Passthrough OHNE System-Prompt/Tools
- Daemon startet NUR in AppDelegate (nicht MainView.onAppear)
- KoboldOS = Ollama-only (keine Cloud-Provider in UI)

### Agent Types
- `general` — Orchestrator (User redet immer mit General)
- `coder` — Code-fokussierter Agent
- `web` — Web-Recherche Agent
- Alte Strings "instructor"/"planner" → automatisch auf `.general` gemappt

## 3. Session System

- Sessions gespeichert in `~/Library/Application Support/KoboldOS/sessions.json`
- `ChatSession.taskId: String?` — nil für normale Chats, gesetzt für Task-Chats
- `loadSessions()` in RuntimeViewModel.init()
- `saveSessionsWithRetry()` via `debouncedSave()` (3s Debounce)
- `switchToSession()` — Lazy Decoding (nur letzte 10 Messages sofort, Rest im Background)
- `.koboldShutdownSave` Notification → speichert bei App-Exit

## 4. Memory System

- **MemoryStore** (Actor, Singleton) — Tag-basierte Erinnerungen
- Typen: kurzzeit, langzeit, wissen, lösungen, fehler, regeln, verhalten
- Emotionale Valenz (Circumplex Model) + Arousal
- **EmbeddingStore** — Ollama-Embeddings für semantische Suche
- **ConsciousnessEngine** — Stimmung, Reflexion, Error/Solution-Tracking
- **smartMemoryRetrieval()** in AgentLoop — RAG mit Embedding (Fallback: TF-IDF)
- Settings: `maxSearch` (Suchpool), `maxResults` (Kontext-Limit), `consolidation`, `autoFragments`, `autoSolutions`

## 5. Tool System

- 55+ Tools registriert in ToolRegistry
- Risk Levels: `.low`, `.medium`, `.high`, `.critical`
- HiTL (Human-in-the-Loop) für high/critical basierend auf `autonomyLevel` Setting
- Tool-Call Recovery: `extractEmbeddedToolCall()` für lokale Modelle die JSON in Text wrappen
- Shell-Tiers: safe/normal/power (mutual exclusive via onChange)

## 6. WebGUI

- Embedded HTML/CSS/JS in `WebAppServer.swift` → `buildHTML()` (~6.750 Zeilen)
- SSE-Proxy via `SSEProxyDelegate` (URLSessionDataDelegate)
- Sessions in Browser `localStorage`, conversation_history pro Request
- NWConnection-basierter HTTP-Server (nicht URLSession)
- Tabs: Chat, Aufgaben, Gedächtnis, Workflows, Teams, Einstellungen, Verbindungen, CRM
- Version-Tag im HTML-Kommentar triggert Auto-Update
- Login-System mit Username/Passwort Auth

### WebGUI Teams
- Team-Chat als Content View (Sidebar bleibt sichtbar, kein Overlay)
- Alternierende Agent-Nachrichten (links/rechts nach Member-Index)
- Member-Info-Bar mit farbigen Avatar-Pills
- Inline-Edit fuer Mitglieder (Name, Rolle, System-Prompt)

### WebGUI Workflow-Engine
- Visueller Canvas mit 18 Node-Typen, 4-Port-System (top/right/bottom/left)
- Inspector mit Desktop-Paritaet (alle Node-Typ-spezifischen Felder)
- Connection Snap (80px Threshold) + visueller Glow-Feedback
- SVG Bezier-Connections mit Pfeilspitzen, Error-Routing
- Node-by-Node topologische BFS-Ausfuehrung:
  - Start-Nodes (keine eingehenden Connections) als Einstiegspunkte
  - Dependency-Check vor jeder Node-Ausfuehrung
  - Agent-Nodes via SSE-Streaming (`/agent/stream`)
  - Visuelle Status pro Node: waiting → running → success/error
- Per-Node Thought Stream: Live-Bubble am laufenden Node zeigt SSE-Tokens
- Workflow Chat: Dedizierter Chat mit chronologischen Node-Outputs

## 7. OAuth / Connections

- Google, SoundCloud: Tokens in UserDefaults (`kobold.google.*`, `kobold.soundcloud.*`)
- Microsoft, Uber: OAuthTokenHelper für Refresh
- NIEMALS SecretStore für OAuth-Tokens (UI und Tools müssen gleiche Keys nutzen)
- Token-Refresh bei 401/403 automatisch (Google Import)

## 8. Trading Engine

### Architektur
```
TradingEngine (Actor, Singleton)
  ├── MarketRegimeDetector    → Bull/Bear/Sideways/Crash Erkennung
  ├── StrategyEngine (Actor)  → 9 Built-in + Custom-Strategien
  ├── TradingRiskManager      → Circuit Breakers, Regime-Aware Limits
  ├── TradeExecutor            → Coinbase Advanced Trade API
  ├── TradingAgent             → KI-Agent-Entscheidungsschicht
  ├── TradingDatabase (SQLite) → Persistente Trade-Historie
  ├── TradingActivityLog       → In-Memory Activity Feed (48h)
  ├── Backtester               → Multi-Coin Auto-Backtest
  └── TradingForecaster        → Kurzfrist-Prognosen
```

### Zyklus (alle 60 Sekunden)
1. Candle-Daten von Coinbase holen (1h + 6h Timeframe)
2. Indikatoren berechnen (RSI, MACD, EMA, BB, ATR, OBV)
3. Marktregime erkennen → RiskManager aktualisieren
4. Circuit Breaker pruefen (Preis-Drop, Volatilitaets-Spike, Stop-Kaskade)
5. Alle Strategien evaluieren → Familien-Deduplizierung → Konflikt-Resolution
6. EV-Gate + Daily Limit + Pair Cooldown + EUR-Reserve pruefen
7. Multi-Timeframe-Bestaetigung (4h-Trend)
8. Trade ausfuehren (direkt oder via KI-Agent)
9. Offene Positionen monitoren (TP/SL/Trailing)
10. Externe Holdings monitoren (DCA + Signal-basierte Verkaeufe)

### Regime-Aware Limits
| Parameter | Bull | Sideways | Bear | Crash |
|-----------|------|----------|------|-------|
| Max Positionen | Basis ×2 | Basis | Basis -1 | 0 |
| Max pro Coin | 50% | 30% | 15% | 10% |
| Trade-Size | 2% | 2% | 1% | 0% |
| Trailing-Stop | Basis | Basis | Basis ×1.5 | Basis ×2.0 |

### Strategien
9 Built-in-Strategien, jede mit eigenem Regime-Modifier:
- **Momentum** (RSI + MACD + EMA): Trend-Staerke-Messung
- **Trend Following** (EMA Crossover): Golden/Death Cross
- **Breakout** (Period High/Low): Volume-bestaetigt, Sideways-unterdrueckt
- **Mean Reversion** (Bollinger Bands): Optimiert fuer Sideways
- **Scalping** (RSI + Momentum + BB): Fee-aware, strenge Thresholds
- **Ultra Scalp** (6 Checks): A+ Setups only, 4+ Bestaetigungen noetig
- **Divergence** (Preis vs. RSI): Swing-High/Low Analyse
- **Accumulation** (OBV): Smart-Money-Detection
- **Support/Resistance** (Key Levels): Bounce + Rejection Erkennung

### Signal-Pipeline
```
evaluateAll() → Familien-Dedup → Gewichtetes Voting
  → SELL-Veto (>85%) → Fee-Filter → Confidence-Threshold (0.80)
  → EV-Gate → Multi-TF-Check → Daily Limit → EUR-Reserve → Execute
```

### Datenbanken
- **TradingDatabase** (SQLite): Persistente Trade-Records (OPEN/CLOSED)
- **TradingActivityLog** (In-Memory JSON): 48h Rolling Window fuer UI-Feed
- Beide werden parallel beschrieben bei jedem Trade

### Key Settings (UserDefaults)
| Key | Default | Beschreibung |
|-----|---------|-------------|
| `kobold.trading.feeRate` | 0.012 | Coinbase Taker Fee (1.2%) |
| `kobold.trading.takeProfit` | 8.0 | Take-Profit % |
| `kobold.trading.fixedStopLoss` | 3.0 | Stop-Loss % |
| `kobold.trading.trailingStop` | 4.0 | Trailing-Stop % (regime-adaptiv) |
| `kobold.trading.confidenceThreshold` | 0.80 | Min. Signal-Confidence |
| `kobold.trading.maxOpenPositions` | 3 | Basis (wird per Regime skaliert) |
| `kobold.trading.maxDailyTrades` | 6 | Max Trades pro Tag |
| `kobold.trading.pairCooldownMinutes` | 120 | Cooldown pro Pair (Minuten) |
| `kobold.trading.eurReserve` | 0 | Mindest-EUR-Saldo |
| `kobold.trading.hodlCoin` | "" | HODL-Coin (nie verkauft) |
| `kobold.trading.maxDailyLoss` | 3.0 | Max Tagesverlust % |
| `kobold.trading.maxWeeklyLoss` | 6.0 | Max Wochenverlust % |

## 9. Entfernte Features (NIEMALS wieder einbauen)

MCP, MenuBarController, PopoverView, ImageGenManager, LlamaService, WebGUI Target, docker/, linux/, ApplicationsView, AppMenuManager, DashboardView, Cloud Provider UI, AgentType.planner/.instructor, OllamaAgent.swift, ToolEngine.swift, iMessage-Integration

## 9. Performance Optimizations

- Flush-Timer: 500ms, single `objectWillChange.send()` pro Cycle
- Connectivity-Timer: Async Task statt Timer.publish
- Session-Save: 3s Debounce
- Chat: Lazy Message Decoding + kein Array-Copy (direkte Index-Referenz)
- TypewriterText: MUSS `onDisappear` haben (Task canceln!)
