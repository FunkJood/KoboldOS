# KoboldOS — Native macOS AI Agent System

**KoboldOS** is a fully local, native macOS AI agent app. It runs Ollama-backed LLMs with a complete tool-calling agent loop, persistent memory, multi-agent orchestration, a built-in workflow editor, and a polished SwiftUI control panel — no cloud required.

## Features

- **Agent Loop** with tool calling (Shell, File, Browser, Calculator, Memory, Skills, Tasks, Workflows)
- **Persistent Memory** (Kurzzeit/Langzeit/Wissen) — Letta-style labeled memory blocks
- **Multi-Agent Orchestration** — Instructor, Coder, Researcher, Planner profiles with sub-agent delegation
- **Workflow Editor** — Visual node-based automation (condition, delay, webhook, merger nodes)
- **Task Scheduler** — Cron-style scheduled agent tasks
- **Skills System** — Markdown-based skill files that extend agent behavior
- **Menu Bar Mode** — Always-on quick-chat via macOS status bar
- **A2A Protocol** — Agent-to-Agent communication support
- **CLI** — Full-featured `kobold` command-line interface with interactive REPL
- **Auto-Update** — GitHub-based update system with one-click install

## Quick Start

```bash
# 1. Install Ollama
brew install ollama && ollama serve
ollama pull llama3.2

# 2. Build KoboldOS
swift build -c release
bash scripts/build.sh   # creates DMG on Desktop
```

Or download the latest DMG from [Releases](https://github.com/FunkJood/KoboldOS/releases).

## Architecture

```
KoboldOS Control Panel (SwiftUI)
    |
    | HTTP localhost:8080
    v
DaemonListener (in-process TCP server)
    |
    v
AgentLoop (actor) --> ToolRegistry --> Tools
    |                                   (Shell, File, Browser, Memory, ...)
    v
LLMRunner (Ollama /api/chat)
```

## Module Structure

```
Sources/
├── KoboldCLI/               CLI (kobold daemon/model/metrics/trace)
├── KoboldCore/              Core library
│   ├── Agent/               AgentLoop, ToolCallParser, ToolRuleEngine
│   ├── Tools/               FileTool, ShellTool, BrowserTool, + 15 more
│   ├── Memory/              CoreMemory (actor, labeled blocks)
│   ├── Model/               OllamaBackend, ModelRouter
│   ├── Headless/            DaemonListener (raw Darwin TCP sockets)
│   ├── Runtime/             BackupManager, CrashMonitor
│   ├── Security/            SecretStore (Keychain), SecretsManager
│   └── Plugins/             PluginRegistry, SkillLoader
└── KoboldOSControlPanel/    macOS SwiftUI app
    ├── MainView             Sidebar + tab routing
    ├── ChatView             Chat UI with tool/thought bubbles
    ├── DashboardView        System metrics + activity timeline
    ├── SettingsView         10 settings sections
    ├── GlassUI              Design system
    ├── UpdateManager        GitHub auto-update
    ├── ToolEnvironment      Runtime tool detection
    └── ...
Tests/KoboldCoreTests/       78 tests
```

## Requirements

- macOS 14+ (Sonoma)
- [Ollama](https://ollama.com) installed and running
- Swift 6.0 (Xcode 16+) for building from source

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Status + version + PID |
| `/agent` | POST | Agent loop (with tools) |
| `/agent/stream` | POST | SSE streaming agent |
| `/metrics` | GET | Usage statistics |
| `/memory` | GET/POST | Memory management |
| `/models` | GET | Available Ollama models |
| `/tasks` | GET/POST | Task scheduler |
| `/trace` | GET | Activity timeline |

## Development

```bash
swift build          # Debug build
swift test           # Run 78 tests
bash scripts/build.sh  # Build DMG
```

## License

MIT License - see [LICENSE](LICENSE)
