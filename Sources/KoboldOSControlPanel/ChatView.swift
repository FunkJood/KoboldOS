import SwiftUI
import AppKit

// MARK: - ChatView — Real LLM chat, always agent-powered

struct ChatView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var inputText: String = ""
    @State private var pendingAttachments: [MediaAttachment] = []
    @AppStorage("kobold.agent.type") private var agentType: String = "general"
    @AppStorage("kobold.koboldName") private var koboldName: String = "KoboldOS"
    @AppStorage("kobold.showAgentSteps") private var showAgentSteps: Bool = true
    @AppStorage("kobold.chat.fontSize") private var chatFontSize: Double = 16.5
    // Notifications moved to GlobalHeaderBar
    @State private var scrollDebounceTask: Task<Void, Never>?
    /// Number of messages visible from the end — grows when user taps "load more"
    @State private var visibleMessageCount: Int = 20
    /// Window update interval in nanoseconds (default: 1.5 seconds)
    @AppStorage("kobold.window.updateInterval") private var updateIntervalNanos: Int = 1_500_000_000

    /// Human-readable agent display name for the chat header badge
    var agentDisplayName: String {
        switch agentType {
        case "coder": return "Coder"
        case "web":   return "Web"
        default:      return "General"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            GlassDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if viewModel.messages.isEmpty { emptyState }

                        // E1: Range-basiertes ForEach — kein Array-Copy bei jedem Render
                        let allMessages = viewModel.messages
                        let startIndex = max(0, allMessages.count - visibleMessageCount)

                        if startIndex > 0 {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    visibleMessageCount = min(visibleMessageCount + 20, allMessages.count)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("\(startIndex) ältere Nachrichten laden")
                                }
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .id("load-more")
                        }

                        // E2: newestThinkingId aus RuntimeViewModel (O(1) statt O(n) Suche)
                        let newestThinkingId = viewModel.newestThinkingId

                        ForEach(startIndex..<allMessages.count, id: \.self) { idx in
                            let msg = allMessages[idx]
                            messageBubble(for: msg, newestThinkingId: newestThinkingId)
                                .id(msg.id)
                        }

                        // Live thinking/streaming area — single unified box
                        if viewModel.isAgentLoadingInCurrentChat {
                            // Only render ThinkingPanel if showAgentSteps is on (saves massive CPU on sub-agent runs)
                            if showAgentSteps {
                                ThinkingPanelBubble(entries: viewModel.activeThinkingSteps, isLive: true)
                                    .id("thinking-live")
                                SubAgentActivityBanner(entries: viewModel.activeThinkingSteps)
                                    .id("subagent-banner")
                            }

                            // A6: Static placeholder date — Date() creates new object every render, preventing SwiftUI skip
                            GlassChatBubble(message: "", isUser: false, timestamp: Self.placeholderDate, isLoading: true)
                                .id("loading")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) { debouncedScroll(proxy: proxy) }
                .onChange(of: viewModel.agentLoading) { debouncedScroll(proxy: proxy) }
                .onChange(of: viewModel.currentSessionId) { visibleMessageCount = 20 }
            }

            // Sticky Checklist
            if !viewModel.agentChecklist.isEmpty {
                AgentChecklistOverlay(items: viewModel.agentChecklist)
            }

            // Message queue indicator with send-now + clear buttons
            if !viewModel.messageQueue.isEmpty && viewModel.agentLoading {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full.fill").font(.system(size: 12.5)).foregroundColor(.koboldGold)
                    Text("\(viewModel.messageQueue.count) Nachricht\(viewModel.messageQueue.count > 1 ? "en" : "") in Warteschlange")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.koboldGold)
                    Spacer()
                    // Send next immediately
                    Button(action: { viewModel.sendNextQueued() }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.koboldEmerald)
                    }
                    .buttonStyle(.plain)
                    .help("Nächste sofort senden")
                    // Clear queue
                    Button(action: { viewModel.clearMessageQueue() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Warteschlange leeren")
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Color.koboldGold.opacity(0.08))
            }

            // Context Usage Bar (above input) — immer sichtbar pro Chat
                HStack(spacing: 8) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward")
                        .font(.system(size: 12.5))
                        .foregroundColor(viewModel.contextUsagePercent > 0.8 ? .orange : .secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(viewModel.contextUsagePercent > 0.8
                                      ? Color.orange.opacity(0.7)
                                      : Color.green.opacity(0.5))
                                .frame(width: geo.size.width * min(1.0, max(0, viewModel.contextUsagePercent)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(viewModel.contextUsagePercent * 100))%")
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundColor(viewModel.contextUsagePercent > 0.8 ? .orange : .secondary)
                        .frame(width: 36)
                    Text("\(formatTokenCount(viewModel.contextPromptTokens))/\(formatTokenCount(viewModel.contextWindowSize))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    // Komprimieren-Button
                    Button(action: { compressContext() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 10))
                            Text("Komp.")
                                .font(.system(size: 10.5))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .opacity(viewModel.contextUsagePercent > 0.5 ? 1.0 : 0.4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.15))

            GlassDivider()

            inputBar
        }
        .background(
            ZStack {
                Color.koboldBackground
                LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
    }

    // A6: Static date for loading bubble — avoids Date() on every render
    private static let placeholderDate = Date(timeIntervalSince1970: 0)

    // MARK: - Bubble Router

    @ViewBuilder
    func messageBubble(for msg: ChatMessage, newestThinkingId: UUID? = nil) -> some View {
        switch msg.kind {
        case .user(let text):
            VStack(alignment: .trailing, spacing: 6) {
                // Attachments above the text bubble
                if !msg.attachments.isEmpty {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(msg.attachments) { attachment in
                            AttachmentBubble(attachment: attachment)
                        }
                    }
                    .padding(.trailing, 4)
                }
                GlassChatBubble(message: text, isUser: true, timestamp: msg.timestamp)
            }
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 4) {
                GlassChatBubble(message: text, isUser: false, timestamp: msg.timestamp)
                if let c = msg.confidence {
                    ConfidenceBadge(value: c)
                }
            }
        case .toolCall(let name, let args):
            ToolCallBubble(toolName: name, args: args)
        case .toolResult(let name, let success, let output):
            if name == "shell" {
                TerminalResultBubble(command: "", output: output, success: success)
            } else if name == "file" && output.contains("\n__DIFF__\n") {
                DiffResultBubble(output: output, success: success)
            } else {
                ToolResultBubble(toolName: name, output: output, success: success)
            }
        case .thought(let text):
            if showAgentSteps {
                ThoughtBubble(text: text, thinkingLabel: l10n.language.thinking)
            }
        case .agentStep(let n, let desc):
            if showAgentSteps {
                AgentStepBubble(stepNumber: n, description: desc)
            }
        case .subAgentSpawn(let profile, let task):
            if showAgentSteps {
                SubAgentSpawnBubble(profile: profile, task: task)
            }
        case .subAgentResult(let profile, let output, let success):
            if showAgentSteps {
                SubAgentResultBubble(profile: profile, output: output, success: success)
            }
        case .thinking(let entries):
            if showAgentSteps {
                // A1: Use pre-computed newestThinkingId instead of O(n) scan per bubble
                ThinkingPanelBubble(entries: entries, isLive: false, isNewest: msg.id == newestThinkingId)
            }
        case .interactive(let text, let options):
            InteractiveBubble(
                text: text, options: options,
                isAnswered: msg.interactiveAnswered,
                selectedOptionId: msg.selectedOptionId,
                onSelect: { option in
                    viewModel.answerInteractive(messageId: msg.id, optionId: option.id, optionLabel: option.label)
                }
            )
        case .image(let path, let caption):
            ImageBubble(path: path, caption: caption)
        }
    }

    // MARK: - Header

    var chatHeader: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Spacer()
                    switch viewModel.chatMode {
                    case .workflow:
                        Text("⚡ \(viewModel.workflowChatLabel)").font(.system(size: 14.5, weight: .semibold))
                    case .normal:
                        Text(koboldName.isEmpty ? "KoboldOS" : koboldName).font(.system(size: 14.5, weight: .semibold))
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    Spacer()
                    switch viewModel.chatMode {
                    case .workflow:
                        GlassStatusBadge(label: "Workflow", color: .koboldGold, icon: "point.3.connected.trianglepath.dotted")
                    case .normal:
                        GlassStatusBadge(label: agentDisplayName, color: .koboldGold, icon: "brain")
                    }
                    if viewModel.chatMode == .normal, let topicId = viewModel.activeTopicId,
                       let topic = viewModel.topics.first(where: { $0.id == topicId }) {
                        HStack(spacing: 3) {
                            Circle().fill(topic.swiftUIColor).frame(width: 6, height: 6)
                            Text(topic.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(topic.swiftUIColor)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(topic.swiftUIColor.opacity(0.1)))
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(
                ZStack {
                    Color.koboldPanel.opacity(0.5)
                    LinearGradient(colors: [Color.koboldEmerald.opacity(0.03), .clear, Color.koboldGold.opacity(0.02)], startPoint: .leading, endPoint: .trailing)
                }
            )

            // Mode-specific banner
            if viewModel.chatMode == .workflow {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundColor(.koboldEmerald)
                    Text("Workflow-Chat — gespeichert unter Workflows")
                        .font(.caption)
                        .foregroundColor(.koboldEmerald)
                    Spacer()
                    Button(action: {
                        NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.workflows)
                        viewModel.newSession()
                    }) {
                        Text("Zurück zum Workflow").font(.caption2).foregroundColor(.koboldEmerald)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(
                    LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.06)], startPoint: .leading, endPoint: .trailing)
                )
            }
        }
    }

    // MARK: - Empty State

    private static let exampleSets: [[String]] = [
        [
            "Was kannst du alles?",
            "Räum meinen Desktop auf",
            "Wie viel Speicherplatz habe ich noch?",
            "Hilf mir beim Brainstorming",
        ],
        [
            "Welches Modell nutzt du gerade?",
            "Zeig mir was auf meinem Desktop liegt",
            "Erstelle ein kleines Python-Skript",
            "Schreibe eine kurze Nachricht per Telegram",
        ],
        [
            "Fasse diese Webseite zusammen",
            "Suche im Internet nach aktuellen Nachrichten",
            "Welche Programme laufen gerade?",
            "Erzähl mir einen Witz",
        ],
    ]

    @State private var activeTips: [String] = []
    @State private var tipRotation: Double = 0
    @State private var welcomeMessage: String = ""

    private func loadRandomTips() {
        // Try AI-generated suggestions first, fallback to hardcoded
        let aiTips = SuggestionService.shared.chatSuggestions
        if !aiTips.isEmpty {
            activeTips = Array(aiTips.shuffled().prefix(4))
        } else {
            let allTips = Self.exampleSets.flatMap { $0 }
            activeTips = Array(allTips.shuffled().prefix(4))
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            tipRotation += 360
        }
        // Also refresh welcome message
        let greeting = SuggestionService.shared.dashboardGreeting
        welcomeMessage = greeting.isEmpty ? Self.randomWelcome() : greeting
    }

    private static let welcomeMessages = [
        "ist bereit.", "wartet auf dich.", "hat Ideen.",
        "ist motiviert.", "hat aufgeräumt.", "ist wach.",
        "steht bereit.", "ist einsatzbereit.",
        "hat Kaffee gekocht.", "denkt schon nach.",
        "freut sich auf Arbeit.", "wartet ungeduldig.",
    ]

    private static func randomWelcome() -> String {
        welcomeMessages.randomElement() ?? "ist bereit."
    }

    var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 80)
            Text(l10n.language.startConversation)
                .font(.system(size: 23, weight: .semibold))
            Text("\(koboldName.isEmpty ? "KoboldOS" : koboldName) \(welcomeMessage.isEmpty ? "ist bereit." : welcomeMessage)")
                .font(.system(size: 17.5)).foregroundColor(.secondary)
            GlassCard(padding: 16, cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Probier mal...").font(.system(size: 15.5, weight: .semibold)).foregroundColor(.koboldGold)
                        Spacer()
                        Button(action: { loadRandomTips() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(.koboldEmerald)
                                .rotationEffect(.degrees(tipRotation))
                        }
                        .buttonStyle(.plain)
                        .help("Neue Tipps laden")
                    }
                    ForEach(activeTips, id: \.self) { example in
                        Button(action: {
                            inputText = ""
                            viewModel.sendMessage(example)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundColor(.koboldEmerald.opacity(0.7))
                                Text("\"\(example)\"")
                                    .font(.system(size: 15.5))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .background(
                                LinearGradient(colors: [Color.koboldEmerald.opacity(0.05), Color.koboldGold.opacity(0.03)], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        LinearGradient(colors: [Color.koboldEmerald.opacity(0.15), Color.koboldGold.opacity(0.1)], startPoint: .leading, endPoint: .trailing),
                                        lineWidth: 0.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 400)
            .onAppear {
                loadRandomTips()
                // Also trigger SuggestionService refresh in background
                Task { await SuggestionService.shared.generateSuggestions() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Bar
    // Always sends to Instructor — no model role selector shown here.

    var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Color.koboldEmerald.opacity(0.15), Color.koboldGold.opacity(0.1)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)

            // Attachment preview strip
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            AttachmentThumbnail(attachment: attachment, onRemove: {
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            }, compact: true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color.koboldSurface.opacity(0.6))
                Divider()
            }

            HStack(spacing: 8) {
                // Paperclip attachment button
                Button(action: openFilePicker) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17.5))
                        .foregroundColor(pendingAttachments.isEmpty ? .secondary : .koboldEmerald)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Datei anhängen")

                // Brain toggle — show/hide agent steps (thinking boxes)
                Button(action: { showAgentSteps.toggle() }) {
                    Image(systemName: showAgentSteps ? "brain.fill" : "brain")
                        .font(.system(size: 17.5))
                        .foregroundColor(showAgentSteps ? .koboldGold : .secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help(showAgentSteps ? "Agent-Schritte ausblenden" : "Agent-Schritte einblenden")

                // Clear chat — keep session, remove content and reset context
                Button(action: { clearCurrentChat() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Chat leeren (Session bleibt erhalten)")

                // Font size controls
                Button(action: { chatFontSize = max(12, chatFontSize - 1) }) {
                    Text("a").font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Text kleiner")

                Button(action: { chatFontSize = min(24, chatFontSize + 1) }) {
                    Text("A").font(.system(size: 17, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Text größer")

                GlassTextField(
                    text: $inputText,
                    placeholder: l10n.language.typeMessage,
                    isMultiline: true,
                    onSubmit: send
                )

                if viewModel.isAgentLoadingInCurrentChat {
                    Button(action: { viewModel.cancelAgent() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18.5, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.koboldGold)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .help("Agent stoppen")
                } else if viewModel.agentWasStopped && viewModel.lastAgentPrompt != nil {
                    // Resume button after agent was stopped
                    HStack(spacing: 6) {
                        Button(action: { viewModel.resumeAgent() }) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 18.5, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.koboldEmerald)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .help("Agent fortsetzen")

                        Button(action: send) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18.5, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.koboldEmerald.opacity(0.6))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
                    }
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18.5, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.koboldEmerald)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(
            ZStack {
                Color.koboldPanel
                LinearGradient(colors: [Color.koboldEmerald.opacity(0.02), .clear, Color.koboldGold.opacity(0.015)], startPoint: .leading, endPoint: .trailing)
            }
        )
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [] // allow all
        panel.message = "Dateien, Bilder, Audio oder Video anhängen"
        panel.prompt = "Anhängen"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let attachment = MediaAttachment(url: url)
                pendingAttachments.append(attachment)
            }
        }
    }

    private func send() {
        let rawText = inputText.trimmingCharacters(in: .whitespaces)
        guard !rawText.isEmpty || !pendingAttachments.isEmpty else { return }

        // Build the message text for the agent (embeds non-image file content)
        var agentMessage = rawText
        for attachment in pendingAttachments where attachment.base64 == nil {
            switch attachment.mediaType {
            case .file:
                // Try to read as UTF-8 text
                if let content = try? String(contentsOf: attachment.url, encoding: .utf8) {
                    let truncated = content.count > 8000
                        ? String(content.prefix(8000)) + "\n[Inhalt abgeschnitten...]"
                        : content
                    agentMessage += "\n\n--- Datei: \(attachment.name) ---\n\(truncated)\n---"
                } else {
                    agentMessage += "\n[Anhang: \(attachment.name), \(attachment.formattedSize) – Binärdatei]"
                }
            default:
                agentMessage += "\n[Anhang: \(attachment.name), \(attachment.formattedSize)]"
            }
        }

        // Display text in chat bubble: original user text or filename list if text is empty
        let displayText = rawText.isEmpty
            ? "📎 \(pendingAttachments.map { $0.name }.joined(separator: ", "))"
            : rawText

        let allAttachments = pendingAttachments
        inputText = ""
        pendingAttachments = []

        let finalAgentText = agentMessage.trimmingCharacters(in: .whitespaces)
        viewModel.sendMessage(
            displayText,
            agentText: finalAgentText.isEmpty ? "Beschreibe die angehängten Medien." : finalAgentText,
            attachments: allAttachments
        )
    }

    private func debouncedScroll(proxy: ScrollViewProxy) {
        scrollDebounceTask?.cancel()
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(updateIntervalNanos)) // Configurable debounce
            guard !Task.isCancelled else { return }
            if viewModel.isAgentLoadingInCurrentChat {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Formatiert Token-Zahlen als menschenlesbare Größen: 32768 → "32K", 1048576 → "1M"
    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_048_576 {
            let m = n / 1_048_576
            return "\(m)M"
        }
        if n >= 1024 {
            let k = n / 1024
            return "\(k)K"
        }
        return "\(n)"
    }

    /// Chat leeren: Messages entfernen, Session behalten, Context zurücksetzen
    private func clearCurrentChat() {
        let sessionId = viewModel.currentSessionId
        viewModel.clearChatHistory()
        // Reset context usage display
        viewModel.updateContextUsage(for: sessionId, promptTokens: 0, completionTokens: 0, windowSize: viewModel.contextWindowSize)
        viewModel.syncAgentStateToUI()
    }

    /// Kontext komprimieren — direkt im ViewModel (nicht über Daemon, da frischer Worker leere conversationMessages hat)
    private func compressContext() {
        let sessionId = viewModel.currentSessionId
        viewModel.appendCompressMessage(for: sessionId)
        // Compact directly: trim messages, keep last 20, replace older with summary
        viewModel.compactVisibleMessages(for: sessionId, keepLast: 20)
        let remaining = viewModel.messages.count
        viewModel.appendCompressResult(remaining: remaining, for: sessionId)
        // Reset context usage to reflect compressed state
        viewModel.updateContextUsage(for: sessionId, promptTokens: remaining * 80, completionTokens: 0, windowSize: viewModel.contextWindowSize)
        viewModel.syncAgentStateToUI()
    }
}
