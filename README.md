<div align="center">

# KoboldOS

### AI Desktop Operating System

**Your machine. Your models. Your agents.**

A native macOS AI assistant that runs locally-first with multi-agent orchestration,
visual workflows, and a dark futuristic glass UI.

[![Alpha](https://img.shields.io/badge/status-alpha-orange?style=flat-square)]()
[![Version](https://img.shields.io/badge/version-0.2.6-blue?style=flat-square)]()
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma-black?style=flat-square&logo=apple&logoColor=white)]()
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-FA7343?style=flat-square&logo=swift&logoColor=white)]()
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-007AFF?style=flat-square&logo=swift&logoColor=white)]()
[![License](https://img.shields.io/badge/license-TBD-lightgrey?style=flat-square)]()

[Download](#installation) | [Features](#features) | [Architecture](#architecture) | [Build from Source](#build-from-source) | [Contributing](#contributing)

---

<!--
  Screenshot placeholder: Hero screenshot of KoboldOS dashboard
  showing the glass UI with emerald/gold accents, sidebar navigation,
  and the main chat interface with an active agent conversation.
  Recommended size: 1200x750px
-->
*Screenshot: KoboldOS main interface coming soon*

</div>

---

## What is KoboldOS?

KoboldOS is a native macOS desktop application that turns your Mac into a full-featured AI workstation. It combines a multi-agent chat system, visual workflow automation, and deep system integration into a single local-first app -- no browser, no Electron, no cloud dependency required.

Run local models through Ollama, connect to cloud providers when you need them, and let specialized agents collaborate to handle complex tasks autonomously.

---

## Features

### Multi-Agent Chat System

Five specialized agents that can delegate tasks to each other:

| Agent | Role |
|---|---|
| **Instructor** | General-purpose assistant, task coordination |
| **Coder** | Code generation, debugging, file operations |
| **Researcher** | Web search, information synthesis |
| **Planner** | Project planning, task decomposition |
| **Web** | Browser automation, web interaction |

Agents communicate through a built-in **Agent-to-Agent (A2A) protocol** and use `DelegateTaskTool` for sub-agent orchestration.

<!--
  Screenshot placeholder: Chat view showing a multi-turn conversation
  with an agent, including tool call bubbles and thought process indicators.
  Recommended size: 800x600px
-->

### Visual Workflow Builder

Build automation pipelines with a drag-and-drop node editor:

- Drag & drop nodes with real-time connections
- Zoom and pan across large workflows
- Condition nodes, delay nodes, webhook triggers, merger nodes
- JSON-based Plugin SDK for custom workflow nodes
- Execute workflows that chain multiple agents and tools

<!--
  Screenshot placeholder: Workflow editor showing connected nodes
  (e.g., Trigger -> Agent -> Condition -> two branches) with the
  dark glass UI and connection lines between nodes.
  Recommended size: 800x500px
-->

### Autonomous Task Management

- Create tasks that agents execute independently
- Agent delegation -- tasks can spawn sub-tasks for specialized agents
- Scheduled execution with cron-style timing
- Full task history and status tracking

### Local-First AI

| Capability | Provider |
|---|---|
| **LLM Inference** | [Ollama](https://ollama.com) (local), OpenAI, Anthropic, Groq |
| **Image Generation** | Apple [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) (CoreML, on-device) |
| **Speech-to-Text** | Local Whisper STT |
| **Text-to-Speech** | Native macOS TTS |

### Integrations & Protocols

- **MCP Client** -- Model Context Protocol support for ecosystem compatibility
- **Plugin SDK** -- JSON-based custom workflow nodes
- **Telegram Bot** -- Control your agents from Telegram
- **iMessage** -- Agent-powered iMessage responses
- **Google OAuth** -- Google services integration
- **SoundCloud OAuth** -- Audio platform integration
- **WebApp Server** -- Built-in web server with Cloudflare tunnel support

### System Features

- **Core Memory** -- Agent memories that persist across sessions (Letta-style labeled blocks)
- **Skill System** -- Inject capabilities via `.md` skill files
- **Secure Credential Storage** -- OAuth tokens in UserDefaults, secrets in macOS Keychain
- **Dashboard** -- System metrics, weather widget (Open-Meteo), proactive suggestions
- **Global Header Bar** -- Date, centered clock, weather, active agents count, notification bell on every page
- **Workflow & Task Notifications** -- Deep-link notifications that navigate directly to result chats
- **Sound Feedback** -- System sounds for agent events, workflow completion/failure
- **Menu Bar Mode** -- Quick-access chat from the macOS status bar
- **Auto-Update** -- GitHub-based update system with one-click install
- **Configurable Agent Performance** -- Context window up to 200K, step limits, timeouts, sub-agent concurrency

### Design

Dark futuristic UI built entirely in SwiftUI with a custom **Glass design system**, emerald and gold accent colors, and smooth animations. The interface is currently in German with i18n-ready architecture.

<!--
  Screenshot placeholder: Dashboard view showing system metrics cards,
  weather widget, and proactive suggestion tiles in the glass UI style.
  Recommended size: 800x500px
-->

---

## Installation

### Download (Recommended)

1. Download the latest `.dmg` from [**Releases**](https://github.com/FunkJood/KoboldOS/releases)
2. Open the DMG and drag **KoboldOS** to your Applications folder
3. Launch KoboldOS and follow the onboarding wizard
4. *(Optional)* Install [Ollama](https://ollama.com) for local model inference

### Build from Source

```bash
# Clone the repository
git clone https://github.com/FunkJood/KoboldOS.git
cd KoboldOS

# Build
swift build -c release

# Create DMG
bash scripts/build.sh
```

The DMG will be output to `dist/KoboldOS-0.2.6.dmg`.

### Requirements

| Requirement | Details |
|---|---|
| **macOS** | 14.0+ (Sonoma) |
| **Ollama** | Recommended for local models |
| **Xcode** | 15+ / Swift 5.9+ (build from source only) |

---

## Architecture

```
KoboldOS Control Panel (SwiftUI)
    |
    | HTTP localhost:8080
    v
DaemonListener (in-process TCP server)
    |
    v
AgentLoop (actor) ──> ToolRouter ──> Tools
    |                                 (Shell, File, Browser, Memory,
    |                                  MCP, Delegate, Workflow, ...)
    v
LLMRunner
    ├── Ollama      (local, /api/chat)
    ├── OpenAI      (cloud)
    ├── Anthropic   (cloud)
    └── Groq        (cloud)
```

### Module Structure

```
Sources/
├── KoboldCLI/                   Command-line interface
│   └── kobold daemon/model/metrics/trace
│
├── KoboldCore/                  Core framework
│   ├── Agent/                   AgentLoop, ToolCallParser, ToolRuleEngine
│   ├── Tools/                   15+ tools (File, Shell, Browser, MCP, Delegate, ...)
│   ├── Memory/                  CoreMemory (actor, labeled blocks)
│   ├── Model/                   OllamaBackend, ModelRouter, cloud providers
│   ├── MCP/                     Model Context Protocol client
│   ├── Headless/                DaemonListener (raw Darwin TCP sockets)
│   ├── Runtime/                 BackupManager, CrashMonitor
│   ├── Security/                SecretStore (Keychain), SecretsManager
│   ├── Plugins/                 PluginRegistry, SkillLoader, Plugin SDK
│   └── Workflows/               WorkflowEngine, node definitions
│
└── KoboldOSControlPanel/        macOS SwiftUI app
    ├── MainView                 Sidebar + tab routing
    ├── ChatView                 Chat UI with tool/thought bubbles
    ├── WorkflowEditorView       Visual node editor with drag & drop
    ├── DashboardView            System metrics + weather + suggestions
    ├── SettingsView             Settings (12 sections incl. Agents, Personality)
    ├── GlassUI/                 Design system (glass, emerald, gold)
    ├── UpdateManager            GitHub auto-update
    └── ...

Tests/KoboldCoreTests/           Test suite
```

### API Endpoints

KoboldOS exposes a local API through its TCP daemon:

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Status, version, PID |
| `/agent` | POST | Agent loop with tool calling |
| `/agent/stream` | POST | SSE streaming agent responses |
| `/metrics` | GET | Usage statistics |
| `/memory` | GET/POST | Core memory management |
| `/models` | GET | Available models (local + cloud) |
| `/tasks` | GET/POST | Task scheduler |
| `/trace` | GET | Activity timeline |

---

## Quick Start

After installation, here is how to get started:

```
1. Launch KoboldOS
2. Complete the onboarding wizard (set your name, pick a model)
3. Start chatting with the Instructor agent
4. Try: "Create a workflow that summarizes my clipboard every 5 minutes"
5. Explore the Dashboard for system metrics and suggestions
```

### Using with Ollama (Local Models)

```bash
# Install Ollama
brew install ollama

# Start the Ollama server
ollama serve

# Pull a recommended model
ollama pull llama3.2

# KoboldOS will auto-detect available models
```

### Using with Cloud Providers

Open **Settings** in KoboldOS and add your API keys:

- **OpenAI** -- GPT-4o, GPT-4, etc.
- **Anthropic** -- Claude Sonnet, Claude Opus, etc.
- **Groq** -- Fast inference for open models

All keys are stored securely in macOS Keychain.

---

## Development

```bash
# Debug build
swift build

# Run tests
swift test

# Release build + DMG
bash scripts/build.sh
```

### Project Layout

| Directory | Purpose |
|---|---|
| `Sources/KoboldCore/` | Core framework (agents, tools, memory, MCP) |
| `Sources/KoboldOSControlPanel/` | SwiftUI macOS app |
| `Sources/KoboldCLI/` | Command-line interface |
| `Tests/` | Test suite |
| `scripts/` | Build and utility scripts |

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full development plan.

Current priorities:
- [ ] Voice Chat (TTS + microphone, natural male voice)
- [ ] MCP server integration (infrastructure ready, wiring pending)
- [ ] English localization (currently German, i18n-ready)
- [ ] Plugin marketplace
- [ ] iOS companion app

---

## Contributing

Contributions are welcome! KoboldOS is in early alpha, so there is plenty of room to shape the project.

### How to Contribute

1. **Fork** the repository
2. **Create a branch** for your feature (`git checkout -b feature/my-feature`)
3. **Commit** your changes with clear messages
4. **Push** to your branch and open a **Pull Request**

### Areas Where Help is Needed

- English translations and i18n
- Additional MCP tool integrations
- Custom workflow node plugins
- Documentation and tutorials
- Testing on different macOS versions
- UI/UX feedback

### Reporting Issues

Found a bug or have a feature request? [Open an issue](https://github.com/FunkJood/KoboldOS/issues) with:
- macOS version
- KoboldOS version
- Steps to reproduce (for bugs)
- Expected vs. actual behavior

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

---

## License

*License to be determined.* See [LICENSE](LICENSE) for details.

---

<div align="center">

**Built with SwiftUI on macOS**

[GitHub](https://github.com/FunkJood/KoboldOS) | [Releases](https://github.com/FunkJood/KoboldOS/releases) | [Issues](https://github.com/FunkJood/KoboldOS/issues)

*KoboldOS is in active alpha development. APIs and features may change between releases.*

</div>
