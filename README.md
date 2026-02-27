# KoboldOS — Autonomous AI Agent System for macOS

**KoboldOS** is a native macOS application that runs a self-contained AI agent system locally on your Mac. It wraps an Ollama-backed LLM in a full agent loop with tools, persistent memory, a scheduling system, and a polished SwiftUI control panel — no cloud required.

**Current version: Alpha v0.3.5**

---

## Quick Start

```bash
# 1. Install Ollama and pull a model
brew install ollama && ollama serve
ollama pull llama3.2  # or any other model

# 2. Build and run KoboldOS
swift build -c release
bash scripts/build.sh  # creates ~/Desktop/KoboldOS-0.3.5.dmg
```

Or just open `~/Desktop/KoboldOS-0.3.5.dmg`, drag to Applications, and launch.

---

## Features

- **Autonomous Agent**: Full agent loop with tool execution, memory, and multi-step reasoning
- **46+ Built-in Tools**: Shell, File, Browser, Playwright, Screen Control, Calendar, Contacts, Telegram, Google/YouTube/Drive, SoundCloud, Suno AI, Reddit, Microsoft, GitHub, Slack, Notion, Uber, WhatsApp, HuggingFace, Lieferando, MQTT, CalDAV, RSS, and more
- **Teams (AI-Beratungsgremium)**: Parallele AI-Agenten diskutieren in 3 Runden (Analyse → Diskussion → Synthese)
- **Playwright Browser Automation**: Chrome navigieren, klicken, ausfüllen, Screenshots, JavaScript ausführen
- **Screen Control**: Maus/Tastatur-Steuerung, Screenshots, OCR via Vision.framework
- **Goals System**: Langfristige Ziele unter Persönlichkeit, fließen in den Agent-System-Prompt
- **Idle Tasks & Heartbeat**: Definierbare Aufgaben für den Agent wenn er nichts zu tun hat — konkret oder vage Richtungen
- **Speech**: Text-to-Speech (AVSpeechSynthesizer) + Speech-to-Text (whisper.cpp via SwiftWhisper) — auch via Telegram Voice Messages
- **Image Generation**: Local SDXL via ComfyUI (Juggernaut XL v9, SDXL Base), auto server start, output to ~/Documents/KoboldOS/Bilder/
- **Persistent Memory**: Three-tier memory system (Kurzzeit/Langzeit/Wissen) with vector search
- **Connections**: Google OAuth (YouTube/Drive Upload), SoundCloud (Upload), Telegram Bot (File/Photo/Audio/Voice), Suno AI (Musik), Reddit, Microsoft, GitHub, Slack, Notion, Uber, WhatsApp, A2A Protocol
- **Proactive Agent**: Heartbeat-System, Idle-Tasks, Goals, System-Health-Alerts
- **Scheduled Tasks**: Cron-based task scheduler with auto-execution + Team-Integration
- **Workflows**: Visual workflow editor with 46+ tools, skill injection, save to ~/Documents/KoboldOS/workflows/
- **Interactive Buttons**: Ja/Nein-Buttons im Chat mit Auto-Erkennung
- **Marketplace**: Widgets, Automationen, Skills, Themes, Konnektoren (Mock)
- **AI-Suggestions**: Ollama-basierte Vorschläge mit 4h-Cache
- **Skills System**: Markdown-based skills that extend agent capabilities
- **Remote Access**: Built-in web server + Cloudflare tunnel for access from any device
- **Auto-Updates**: GitHub-based update system with DMG download and auto-install

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│           KoboldOS Control Panel (SwiftUI App)          │
│  Dashboard · Chat · Aufgaben · Workflows · Teams        │
│  Marktplatz · Gedächtnis · Agenten · Einstellungen      │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTP (localhost:8080)
┌──────────────────────▼──────────────────────────────────┐
│              DaemonListener (in-process HTTP server)    │
│  /agent  /chat  /metrics  /memory  /models  /tasks      │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                    AgentLoop (actor)                    │
│  buildSystemPrompt() → LLMRunner → ToolCallParser       │
│  → ToolRegistry → execute → feed result back → loop    │
└──────────────┬────────────────────────┬─────────────────┘
               │                        │
┌──────────────▼───────────┐   ┌────────▼────────────────┐
│    LLMRunner (actor)     │   │   ToolRegistry (actor)  │
│  Ollama /api/chat        │   │  FileTool  ShellTool     │
│  llama-server /v1/chat   │   │  PlaywrightTool  TTSTool │
│  proper system/user roles│   │  ScreenControlTool  etc. │
└──────────────────────────┘   └─────────────────────────┘
```

### Key Design Decisions

| Decision | Why |
|---|---|
| **In-process daemon** | No subprocess needed — app is self-contained and distributable |
| **Ollama-first** | Best local model support; llama-server as fallback |
| **Proper message roles** | `[system, user, assistant, user(tool_results)]` — models need this for reliable tool use |
| **5-strategy ToolCallParser** | Handles markdown blocks, balanced JSON, XML, line-scan — supports `tool_name`/`toolname` variants — works with any local model |
| **NotificationCenter bridge** | Tools in KoboldCore communicate with UI managers (TTS, ImageGen, STT) via notifications |
| **`Task.detached` per request** | Prevents actor serialization; handles concurrent requests |
| **Memory type prefixes** | `kt.` / `lz.` / `ws.` encode short/long-term/knowledge type in label |

---

## Module Structure

```
Sources/
├── KoboldCLI/               CLI tool — kobold daemon/model/metrics/trace/safe-mode
├── KoboldCore/              Core library
│   ├── Agent/               AgentLoop  ToolCallParser  ToolRuleEngine
│   ├── Tools/               FileTool  ShellTool  BrowserTool  TTSTool  GenerateImageTool
│   │                        PlaywrightTool  ScreenControlTool  CalendarTool  ContactsTool
│   │                        TelegramTool  GoogleApiTool  SoundCloudApiTool
│   │                        SunoApiTool  RedditApiTool  MicrosoftApiTool
│   │                        GitHubApiTool  SlackApiTool  NotionApiTool
│   │                        UberApiTool  WhatsAppApiTool  OAuthTokenHelper
│   │                        DelegateTaskTool  WorkflowManageTool  SkillWriteTool
│   ├── Memory/              CoreMemory (actor, Letta-style labeled blocks)
│   ├── Native/              LLMRunner (Ollama + llama-server)
│   ├── Headless/            DaemonListener (TCP HTTP server, raw Darwin sockets)
│   ├── Plugins/             SkillLoader  CalculatorPlugin
│   └── Security/            SecretStore (Keychain)
└── KoboldOSControlPanel/    macOS SwiftUI app
    ├── MainView.swift        Sidebar navigation + tab routing
    ├── ChatView.swift        Chat UI with tool bubbles + media embedding + live thinking layers
    ├── DashboardView.swift   Metrics + welcome + daily quotes + temperature in °C
    ├── MemoryView.swift      Gedächtnis (Kurzzeit/Langzeit/Wissen)
    ├── TasksView.swift       Scheduled tasks + Idle tasks with heartbeat system
    ├── TeamsGroupView.swift  Teams: Gruppenchat, Diskursmodell, Organigramm, Persistenz
    ├── MarketplaceView.swift Widgets, Automationen, Skills, Themes, Konnektoren
    ├── AgentsView.swift      Per-agent model/temp/vision config + tool routing
    ├── SettingsView.swift    12 Sektionen (Konto bis Über) + Heartbeat + Debugging
    ├── SuggestionService.swift AI-Vorschläge via Ollama mit Cache
    ├── ProactiveEngine.swift Heartbeat, Idle Tasks, Goals, Proactive Suggestions
    ├── TTSManager.swift      Text-to-Speech (AVSpeechSynthesizer)
    ├── STTManager.swift      Speech-to-Text (SwiftWhisper / whisper.cpp)
    ├── ImageGenManager.swift Stable Diffusion pipeline (CoreML) + model selection
    ├── GoogleOAuth.swift     Google OAuth 2.0 + API wrapper
    ├── SoundCloudOAuth.swift SoundCloud OAuth
    ├── TelegramBot.swift     Telegram Bot integration
    ├── WebAppServer.swift    Web UI + Cloudflare Tunnel
    ├── GlassUI.swift         Design system (GlassCard/Button/TextField/Bubbles)
    ├── RuntimeViewModel.swift Chat state + daemon API + media embedding + teams
    ├── RuntimeManager.swift  In-process daemon lifecycle + health monitor
    └── ...
```

---

## Agent System

### Tool Calling Format

The agent communicates exclusively via JSON:

```json
{"tool_name": "shell", "tool_args": {"command": "ls ~/Desktop"}, "thoughts": "Let me list the desktop files."}
```

The `ToolCallParser` uses 5 strategies to extract tool calls from LLM output:
1. Markdown code blocks (` ```json ... ``` `)
2. First-to-last brace extraction
3. Balanced JSON block scan with `tool_name` detection
4. XML-style `<tool_call>` fallback
5. Line-by-line JSON accumulation

Final answers go through the `response` tool: `{"tool_name": "response", "tool_args": {"text": "Here is the answer..."}}`

### Available Tools

| Tool | Description |
|---|---|
| `response` | Send final answer to user |
| `shell` | Execute shell commands |
| `file` | Read/write/list/search files |
| `browser` | Web search + HTTP requests |
| `speak` | Text-to-Speech (read text aloud) |
| `generate_image` | Stable Diffusion image generation |
| `calendar` | Apple Calendar events & reminders |
| `contacts` | Apple Contacts search |
| `telegram_send` | Send Telegram messages, files, photos, audio. Receive voice messages via STT |
| `google_api` | Google Drive, Gmail, YouTube (incl. video upload), Calendar |
| `soundcloud_api` | SoundCloud: tracks, playlists, audio upload |
| `suno_api` | Suno AI music generation (generate, status, get_track) |
| `reddit_api` | Reddit: search, browse, post, comment |
| `microsoft_api` | Microsoft Graph API (OneDrive, Outlook, Teams) |
| `github_api` | GitHub API (repos, issues, PRs) |
| `slack_api` | Slack messaging and channels |
| `notion_api` | Notion pages and databases |
| `uber_api` | Uber ride management |
| `whatsapp_api` | WhatsApp Business messaging |
| `playwright` | Chrome browser automation (navigate, click, fill, screenshot, evaluate) |
| `screen_control` | Mouse/keyboard control, screenshots, OCR (Vision.framework) |
| `core_memory_append/replace` | Memory management |
| `delegate_task` | Delegate to sub-agents |
| `workflow_manage` | Workflow CRUD |
| `task_manage` | Task scheduler CRUD |
| `skill_write` | Self-author agent skills |

### Agent Types

| Type | Description |
|---|---|
| general | Orchestrator agent (user-facing, routes to other agents) |
| coder | Code-focused agent (shell/file access) |
| web | Web-focused agent (browser/search) |

---

## Memory System (Gedächtnis)

Three memory types stored as CoreMemory blocks with label prefixes:

| Type | Prefix | Description |
|---|---|---|
| Kurzzeit | `kt.` | Short-term, session context |
| Langzeit | `lz.` | Long-term, persists across sessions |
| Wissen | `ws.` | Knowledge base, reference facts |

All blocks are compiled into every system prompt so the agent always has context.

---

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Status + PID |
| `/agent` | POST | Run agent loop (tool-enabled) |
| `/chat` | POST | Direct LLM call (no tools) |
| `/metrics` | GET | Usage stats |
| `/metrics/reset` | POST | Reset counters |
| `/memory` | GET | All CoreMemory blocks |
| `/memory/update` | POST | Upsert/delete a block |
| `/memory/snapshot` | POST | Create snapshot |
| `/models` | GET | Available Ollama models |
| `/model/set` | POST | Set active model |
| `/tasks` | GET/POST | Task management |
| `/trace` | GET | Activity timeline |
| `/history/clear` | POST | Clear conversation history |

---

## CLI

```bash
kobold daemon --port 8080          # Start daemon
kobold model list                  # List available models
kobold model set llama3.2          # Set active model
kobold metrics [--json] [--watch]  # View metrics
kobold safe-mode status/enable/reset
kobold trace list / get <id> / hash <id>
```

---

## Settings

Accessible via **Einstellungen** tab (14 sections):

- **Konto**: Profile, agent name
- **Allgemein**: Updates, display, autostart, tools, heartbeat settings
- **Persönlichkeit**: Kommunikation, Soul.md, Personality.md, Verhaltensregeln, Ziele, Autonomie & Proaktivität
- **Agenten**: Per-agent model/temperature/vision config, tool routing
- **Modelle**: Primary Ollama model, per-agent model overrides
- **Gedächtnis**: Memory limits, recall, auto-memorization, export/import
- **Berechtigungen**: Autonomy level (1=safe/2=normal/3=full), individual permission toggles, Playwright + Screen Control
- **Datenschutz & Sicherheit**: Safe mode, API keys, secrets (Keychain)
- **Verbindungen**: Google (YouTube/Drive Upload), SoundCloud (Upload), Telegram (Files), Suno AI, Reddit, Microsoft, GitHub, Slack, Notion, Uber, WhatsApp, WebApp, Cloudflare Tunnel, A2A Protocol
- **Sprache & Audio**: TTS (voice, rate, volume), STT (model, language), Stable Diffusion (model selection, prompts, steps, guidance)
- **Fähigkeiten**: Skill management with enable/disable toggles
- **Benachrichtigungen**: Notification settings
- **Debugging & Sicherheit**: Logging, recovery, tool sandboxing
- **Über**: Version, PID, credits, log export

---

## Development

```bash
# Build
swift build

# Run tests
swift test

# Build DMG
bash scripts/build.sh

# Run daemon directly
.build/debug/kobold daemon --port 8080
```

### Adding a New Tool

1. Create `Sources/KoboldCore/Tools/YourTool.swift` conforming to `AgentTool`
2. Register in `AgentLoop.setupTools()`
3. The tool description appears automatically in the system prompt

### Adding a New Endpoint

1. Add case to `routeRequest()` in `DaemonListener.swift`
2. Add handler method `handleYourEndpoint(body:) async -> String`
3. Return `jsonOK(["key": "value"])` for success

---

## Known Issues / Limitations

- Stable Diffusion requires CoreML model download (~2 GB) on first use
- STT (Whisper) requires model download (~75-466 MB) on first use
- Vision only works with multimodal models (llava, llama3.2-vision)
- llama-server backend needs manual setup
- Playwright requires `npm install -g playwright` and Chrome installed
- Screen Control requires macOS Accessibility permissions (System Preferences → Security → Accessibility)
- Teams marketplace items are mock/placeholder data
- OAuth tokens for some services may expire — reconnect in Settings → Connections if needed
- Telegram Voice Messages require a Whisper model loaded in Settings → Sprache & Audio and ffmpeg installed (`brew install ffmpeg`)
