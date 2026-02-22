# KoboldOS Changelog

## Alpha v0.2.1 — 2026-02-22

### GitHub Auto-Update System
- **UpdateManager**: Check for updates against any GitHub repository
  - Configurable repo field in Settings (e.g., `user/KoboldOS`)
  - Compares GitHub Release tags with current version (semver)
  - Shows release notes, download progress, and status
  - Downloads DMG, replaces app, and restarts automatically
  - Auto-check on launch (configurable toggle)

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

### Bug Fixes
- **BrowserTool DDG Search**: Fixed parsing of multi-class HTML elements, removed broken Google scraping
  - DuckDuckGo uses `class="links_main links_deep result__body"` — fixed split logic
  - Added ad filtering, improved URL decoding for DDG redirects
  - Search chain: SearXNG → DuckDuckGo → error message
- **Autostart Linked**: MenuBarController now uses LaunchAgentManager (was raw UserDefaults)
- **Version bumped to 0.2.1** across all files

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
