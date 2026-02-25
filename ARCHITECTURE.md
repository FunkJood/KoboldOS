# KoboldOS — Architecture & Developer Guide

This document is intended for developers continuing work on KoboldOS. It explains the architecture, key patterns, and gotchas discovered during development.

---

## 1. Project Structure

```
KoboldOS/
├── Sources/
│   ├── KoboldCLI/           Swift CLI executable (kobold command)
│   ├── KoboldCore/          Core library (imported by both CLI and App)
│   │   ├── Agent/           AgentLoop, ToolCallParser, ToolRuleEngine
│   │   ├── Tools/           All AgentTool implementations
│   │   ├── Memory/          CoreMemory actor (Letta-style)
│   │   ├── Native/          LLMRunner (Ollama + llama-server)
│   │   ├── Headless/        DaemonListener HTTP server
│   │   ├── Security/        SecretStore (Keychain)
│   │   └── Plugins/         CalculatorPlugin, etc.
│   └── KoboldOSControlPanel/ macOS SwiftUI application
├── Tests/KoboldCoreTests/    XCTest suite
├── scripts/build.sh          DMG packaging script
├── Package.swift             Swift Package Manager manifest
└── README.md / CHANGELOG.md / ARCHITECTURE.md
```

### Package.swift Dependencies
- No external dependencies! Everything is written from scratch.
- Uses only Apple frameworks: Foundation, SwiftUI, AppKit, Security, ServiceManagement, Darwin, EventKit, Contacts

---

## 2. The Daemon

`DaemonListener` is a **raw TCP HTTP server** written using Darwin socket APIs. It runs **in-process** inside the macOS app (launched by `RuntimeManager.startDaemon()`).

### Why in-process?
- No external binary needed → app is fully self-contained
- Easy to distribute as a DMG
- Shares Swift process memory with the app

### Key implementation details

```swift
// Each HTTP connection handled concurrently (not serialized on the actor)
for await client in clientStream {
    Task.detached(priority: .userInitiated) {
        await self.handleConnection(client)
        client.close()
    }
}
```

**IMPORTANT**: Use `Task.detached`, NOT `Task {}`. Using `Task {}` inside a `@MainActor` or actor method will serialize all requests on the actor, causing timeouts when one request is slow.

### TCP Body Reading
The `readRequest()` method uses **Content-Length loop-read** to handle large request bodies (e.g., base64 images):

```swift
// Loop-read until contentLength bytes consumed
while readSoFar < remaining {
    let nr = recv(fd, &bodyBuffer[readSoFar], ...)
    guard nr > 0 else { break }
    readSoFar += nr
}
```

### PID-based stale instance detection
The `/health` response includes the process PID. On startup, `RuntimeViewModel.checkHealthIsOurProcess()` verifies the PID matches `ProcessInfo.processInfo.processIdentifier`. If a stale daemon from a previous app instance is detected, `RuntimeManager.pingHealth()` kills it with `SIGTERM` and restarts.

### Sub-Agent Live-Streaming
New in v0.3.16: `SubAgentStepRelay` (actor) allows streaming events from delegated sub-agents back to the primary agent's stream. This enables the UI to show "Thinking..." steps from sub-agents in real-time.

---

## 3. The Agent Loop

`AgentLoop` in `Sources/KoboldCore/Agent/AgentLoop.swift` is a Swift actor.

### Message structure (CRITICAL)
Ollama models require proper role-based messages for tool use. The old "concatenate everything into a user message" approach broke tool calling:

```swift
// CORRECT — use generate(messages:) with proper roles
var messages: [[String: String]] = [
    ["role": "system", "content": sysPrompt],
    ["role": "user", "content": userMessage]
]
// After each tool use:
messages.append(["role": "assistant", "content": llmResponse])
messages.append(["role": "user", "content": "Tool results:\n\(toolResultsText)\n\nContinue..."])
```

### Tool call format
The parser (`ToolCallParser`) supports 4 formats, tried in order:
1. XML: `<tool_call>{"name":"shell","parameters":{"command":"ls"}}</tool_call>`
2. JSON code blocks: ` ```json { ... } ``` `
3. Inline JSON: `{"name": "...", "parameters": {...}}`
4. Bare JSON: entire response is a tool call

### System prompt design
The system prompt must be **very directive**. Models won't use tools unless explicitly told when/how:
- List WHEN to use each tool (e.g., "for file operations → use file tool")
- Show the EXACT XML format
- State: "NEVER say you cannot do X if a tool exists for it"

---

## 4. Memory System (CoreMemory)

`CoreMemory` is a Swift actor in `Sources/KoboldCore/Memory/CoreMemory.swift`.

### How it works
- Stores `MemoryBlock` structs: `(label: String, value: String, limit: Int)`
- `compile()` returns a formatted string of all blocks
- This string is prepended to every system prompt (agent always has full memory context)

### Memory type encoding (UI-side only)
The GUI uses label prefixes to visually group memory into types:
- `kt.user_name` → Kurzzeit (short-term)
- `lz.life_goals` → Langzeit (long-term)
- `ws.python_facts` → Wissen (knowledge)

The server doesn't know about types — it's purely a UI convention encoded in the label.

---

## 5. LLM Runner

`LLMRunner` in `Sources/KoboldCore/Native/LLMRunner.swift` is a Swift actor.

### Priority order
1. **Ollama** (`http://localhost:11434/api/chat`) — preferred
2. **llama-server** (`http://localhost:8081/v1/chat/completions`) — fallback

### Auto-detection
On init, `autoDetect()` tries Ollama first. If unavailable, tries llama-server. Sets `activeBackend` accordingly.

### Model selection
Stored in `UserDefaults` key `kobold.ollamaModel`. The user selects via Settings > Modelle or via `setActiveModel()` in RuntimeViewModel.

---

## 6. UI Architecture

### Navigation
`SidebarTab` enum (in MainView.swift) defines tab order via `CaseIterable`. The order of cases IS the sidebar order.

Current order: `dashboard → chat → tasks → workflows → teams → marketplace → memory → settings`

### State management
- `RuntimeViewModel` (`@MainActor` class) — all chat state, daemon API calls
- `RuntimeManager` (`@MainActor` class) — daemon lifecycle, health monitoring
- `AgentsStore` (`@MainActor` class) — per-agent model configs (persisted to UserDefaults)
- `LocalizationManager` (`@MainActor` class) — language strings

### Design System
All UI components are in `GlassUI.swift`:
- `GlassCard` — content card with blur background
- `GlassButton` — primary/secondary/destructive styles
- `GlassTextField` — single/multiline input with full-box tap area
- `GlassChatBubble` — user/assistant chat bubbles
- `ToolCallBubble` / `ToolResultBubble` / `ThoughtBubble` / `AgentStepBubble` — agent step visualization
- `GlassStatusBadge` — colored pill label
- `GlassProgressBar` — animated progress bar
- `MetricCard` — dashboard metric cards

### Custom Colors (in `Colors.swift` or similar)
- `Color.koboldEmerald` — primary green
- `Color.koboldGold` — secondary gold/yellow
- `Color.koboldBackground` — dark background
- `Color.koboldPanel` — slightly lighter panel
- `Color.koboldSurface` — surface/card background

---

## 7. Settings & Persistence

Settings are stored with `@AppStorage` (UserDefaults). Key names:

| Key | Type | Default | Purpose |
|---|---|---|---|
| `kobold.port` | Int | 8080 | Daemon port |
| `kobold.authToken` | String | "kobold-secret" | API auth token |
| `kobold.ollamaModel` | String | "" | Active Ollama model |
| `kobold.hasOnboarded` | Bool | false | First-launch wizard |
| `kobold.koboldName` | String | "KoboldOS" | Agent display name |
| `kobold.userName` | String | "" | User's name |
| `kobold.agent.type` | String | "general" | Default agent type |
| `kobold.showAdvancedStats` | Bool | false | Show backend metric card |
| `kobold.autonomyLevel` | Int | 2 | Permission level (1/2/3) |
| `kobold.perm.shell` | Bool | true | Shell execution allowed |
| `kobold.perm.fileWrite` | Bool | true | File write allowed |
| `kobold.perm.network` | Bool | true | Network access allowed |
| `kobold.perm.confirmAdmin` | Bool | true | Confirm admin actions |
| `kobold.agentConfigs` | Data | defaults | Agent model configs (JSON) |
| `kobold.language` | String | "de" | UI language |

---

## 8. Swift 6 Concurrency Gotchas

### ✅ DO: Use `nonisolated` for background work

```swift
nonisolated func fetchGPUName() async {
    // Background shell call — won't inherit actor isolation
}
```

### ✅ DO: Use `sysconf(_SC_PAGESIZE)` not `vm_page_size`

```swift
// vm_page_size is a global mutable C var — not concurrency-safe
// sysconf(_SC_PAGESIZE) is a POSIX function — safe to call from any context
let pageSize = UInt64(sysconf(_SC_PAGESIZE))
```

### ✅ DO: Extract before asserting in tests

```swift
// XCTAssert* macros use autoclosures — can't use await inside
let result = await myActor.doSomething()  // extract first
XCTAssertEqual(result, expected)          // then assert
```

### ❌ DON'T: Ignore "cannot find X in scope" from SourceKit

These are **false positives** when types are defined in other files in the same module. The build will succeed. Only fix if `swift build` also reports the error.

### ❌ DON'T: Use `String(format: "%-22s", swiftString)`

This crashes at runtime with Swift strings. Use `.padding(toLength:withPad:startingAt:)` instead.

---

## 9. Common Patterns

### Adding a new API endpoint

```swift
// In DaemonListener.swift, add to routeRequest():
case "/your-endpoint":
    guard method == "POST", let body else { return jsonError("No body") }
    return await handleYourEndpoint(body: body)

// Add handler:
private func handleYourEndpoint(body: Data) async -> String {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return jsonError("Invalid JSON")
    }
    // ... do work ...
    return jsonOK(["result": "ok"])
}
```

### Adding a new Tool

```swift
// 1. Create Sources/KoboldCore/Tools/YourTool.swift
public struct YourTool: Tool {
    public let name = "your_tool"
    public let description = "Does X."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "param1": ToolSchemaProperty(type: "string", description: "Description", required: true)
            ],
            required: ["param1"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let param = arguments["param1"] ?? ""
        return "Result: \(param)"
    }
}

// 2. Register in AgentLoop.setupTools():
await registry.register(YourTool())
```

### Posting to daemon from UI

```swift
guard let url = URL(string: viewModel.baseURL + "/your-endpoint") else { return }
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": "value"])
req.timeoutInterval = 30
let (data, _) = try await URLSession.shared.data(for: req)
if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    // handle response
}
```

---

## 10. Testing

```bash
swift test
```

Test files in `Tests/KoboldCoreTests/`. The suite has 76 tests covering:
- AgentLoop execution (mock LLM responses)
- ToolCallParser (all 4 parsing modes)
- CoreMemory CRUD
- ToolRegistry registration and execution
- LLMRunner backend detection

---

## 11. Build & Packaging

```bash
# Debug build
swift build

# Release build
swift build -c release

# Create DMG (outputs to ~/Desktop/KoboldOS-X.X.X.dmg)
bash scripts/build.sh
```

The build script:
1. Runs `swift build -c release`
2. Creates `dist/KoboldOSvX.X.X.app/` bundle structure
3. Copies executable + AppIcon
4. Writes Info.plist into the bundle
5. Runs `hdiutil create` to make a DMG
6. Copies DMG to Desktop

---

## 12. Development History (What was built when)

### Phase 1: Foundation (v0.1.1)
- Raw Darwin TCP HTTP server (`DaemonListener`)
- AgentLoop with ToolRegistry and ToolCallParser
- Ollama + llama-server LLM backends
- CoreMemory with labeled blocks
- 5 tools: File, Shell, Browser, Calculator, Memory
- SwiftUI app skeleton with GlassUI design system
- CLI tool (`kobold` binary)

### Phase 2: Chat & UI (v0.1.2)
- Full chat interface with message persistence
- Tool visualization bubbles (collapsible)
- MemoryView, TasksView, AgentsView
- Onboarding wizard (HatchingView)
- Session management (named conversations)
- WorkflowView canvas (beta)

### Phase 3: Stability & Settings (v0.1.3)
- Fixed HTTP 400 errors (all errors now return HTTP 200 with ⚠️ prefix)
- Stale daemon detection via PID in /health
- SettingsView complete overhaul (6 sections, real bindings)
- Permissions system (autonomy levels 1/2/3)
- Vision support for image attachments
- LaunchAgentManager for autostart

### Phase 4: Tool Execution & Polish (v0.1.4)
- **CRITICAL FIX**: AgentLoop now uses proper system/user/assistant message roles
- Stronger system prompt with explicit tool use instructions
- Added `instructor` AgentType
- DaemonListener returns `tool_results` in response
- Chat header shows "Instructor" instead of raw "general"
- GlassTextField: full-box click area, reduced height
- File attachment text extraction (non-image files embedded in prompt)

### Phase 5: Memory, Dashboard, Scheduler (v0.1.5)
- Gedächtnis (memory) system: Kurzzeit/Langzeit/Wissen types
- Memory search/filter, JSON export
- Dashboard CPU/RAM/GPU with live monitoring
- TasksView: friendly schedule preset picker (14 options)
- Sidebar reordered: Dashboard → Chat → Aufgaben → Workflows → Gedächtnis → Agenten → Einstellungen
- More descriptive texts throughout UI

---

## 13. Apple Integration (v0.2.1)

### CalendarTool (`Sources/KoboldCore/Tools/CalendarTool.swift`)
- Uses **EventKit** framework for calendar events and reminders
- `EKEventStore` with `requestFullAccessToEvents()` (macOS 14+) / `requestAccess(to:)` fallback
- Actions: `list_events`, `create_event`, `search_events`, `list_reminders`, `create_reminder`
- Reminder fetch uses `withCheckedThrowingContinuation` with `nonisolated(unsafe)` for Sendability

### ContactsTool (`Sources/KoboldCore/Tools/ContactsTool.swift`)
- Uses **Contacts** framework (`CNContactStore`)
- Actions: `search` (by name), `list_recent` (first 20)
- Fetches: name, phone, email, organization, birthday

### AppleScript Integration
- Mail, Messages, Notes, Safari, Finder, System controls via existing `AppleScriptTool`
- Documented in AgentLoop system prompt with examples

### UpdateManager (`Sources/KoboldOSControlPanel/UpdateManager.swift`)
- GitHub Releases API auto-update (`FunkJood/KoboldOS`)
- DMG download → mount → replace app → restart
- `DownloadDelegate` for progress tracking

### ToolEnvironment (`Sources/KoboldOSControlPanel/ToolEnvironment.swift`)
- Scans system for available tools (Python, Node, Git, etc.)
- On-demand Python 3.12 download to App Support
- `enhancedPATH` for intelligent PATH construction

### New AppStorage Keys (v0.2.1)

| Key | Type | Default | Purpose |
|---|---|---|---|
| `kobold.perm.notifications` | Bool | true | Push notifications |
| `kobold.perm.calendar` | Bool | false | Calendar & Reminders access |
| `kobold.perm.contacts` | Bool | false | Contacts access |
| `kobold.perm.mail` | Bool | false | Mail & Messages access |

---

## 14. v0.2.8 — Teams, PC-Control, Goals (2026-02-23)

### Teams (Beratungsgremium)
- `TeamsGroupView.swift`: Vollständiges Team-System mit Gruppenchat und Organigramm
- 3-Runden-Diskursmodell: Analyse (parallel) → Diskussion (sequentiell) → Synthese
- Persistenz: `teams.json` + `team_messages/{teamId}.json`
- Task/Workflow-Integration via `teamId` Property

### New Tools
- `PlaywrightTool`: Chrome automation via `node -e` mit Playwright script
- `ScreenControlTool`: CGEvent (Maus/Tastatur), `/usr/sbin/screencapture`, Vision.framework OCR

### Goals & Idle Tasks
- `GoalEntry` in ProactiveEngine: Langfristige Ziele → Agent System-Prompt
- `IdleTask` System: User-definierte Aufgaben mit Cooldown, Quiet Hours, Sicherheits-Toggles
- Heartbeat-Timer prüft: Agent idle? → User idle? → Quiet Hours? → Rate Limit? → Idle Task ausführen

### Key Patterns (v0.2.8)
- `Task.detached` for ALL heavy work (SD model loading, pipeline execution) — prevents watchdog kills
- ViewBuilder 10-view limit: Use `Group { }` wrapper when section has 10+ top-level views
- `@AppStorage` keys: Use distinct keys for Bool toggles vs JSON persistence (collision bug fixed)
- `isYesNoQuestion()`: Strict filtering — max 3 lines, <300 chars, trigger phrase required in last line

---

## 15. Planned / TODO

- [ ] MCP wiring: AgentLoop.setupTools() → MCPConfigManager.connectAllServers() (infrastructure exists)
- [ ] MCP Settings-UI in SettingsView unter Verbindungen
- [ ] Voice Chat: TTS + Mikro (natürliche männliche Stimme)
- [ ] Applikationen-Tab: Terminal/WebView/Programm-Runner in Sidebar
- [ ] Agent-Autonomie: Event-Loop, Filesystem-Watcher
- [ ] Neue Verbindungen: GitHub, Microsoft, Email, WhatsApp
- [ ] Plugin system (load external Swift plugins)
- [ ] GPU utilization % (requires IOKit AcceleratorEntry)
