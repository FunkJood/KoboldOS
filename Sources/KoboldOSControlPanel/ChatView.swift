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
    @State private var showNotifications: Bool = false

    /// Human-readable agent display name for the chat header badge
    var agentDisplayName: String {
        switch agentType {
        case "coder":      return "Coder"
        case "researcher": return "Researcher"
        case "planner":    return "Planner"
        default:           return "Instructor"
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

                        ForEach(viewModel.messages) { msg in
                            messageBubble(for: msg)
                                .id(msg.id)
                        }

                        // Live thinking panel (while agent is working)
                        if viewModel.agentLoading && !viewModel.activeThinkingSteps.isEmpty {
                            ThinkingPanelBubble(entries: viewModel.activeThinkingSteps, isLive: true)
                                .id("thinking-live")
                            // Sub-Agent banner (always visible outside collapsed panel)
                            SubAgentActivityBanner(entries: viewModel.activeThinkingSteps)
                                .id("subagent-banner")
                        }

                        if viewModel.agentLoading {
                            GlassChatBubble(message: "", isUser: false, timestamp: Date(), isLoading: true)
                                .id("loading")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) { scrollToBottom(proxy: proxy) }
                .onChange(of: viewModel.agentLoading) { scrollToBottom(proxy: proxy) }
            }

            GlassDivider()
            inputBar
        }
        .background(Color.koboldBackground)
    }

    // MARK: - Bubble Router

    @ViewBuilder
    func messageBubble(for msg: ChatMessage) -> some View {
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
            } else {
                ToolResultBubble(toolName: name, output: output, success: success)
            }
        case .thought(let text):
            ThoughtBubble(text: text, thinkingLabel: l10n.language.thinking)
        case .agentStep(let n, let desc):
            AgentStepBubble(stepNumber: n, description: desc)
        case .subAgentSpawn(let profile, let task):
            SubAgentSpawnBubble(profile: profile, task: task)
        case .subAgentResult(let profile, let output, let success):
            SubAgentResultBubble(profile: profile, output: output, success: success)
        case .thinking(let entries):
            ThinkingPanelBubble(entries: entries, isLive: false)
        }
    }

    // MARK: - Header

    var chatHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        switch viewModel.chatMode {
                        case .workflow:
                            Text("⚡ \(viewModel.workflowChatLabel)").font(.headline)
                            GlassStatusBadge(label: "Workflow", color: .koboldGold, icon: "point.3.connected.trianglepath.dotted")
                        case .task:
                            Text("📋 \(viewModel.taskChatLabel)").font(.headline)
                            GlassStatusBadge(label: "Task", color: .blue, icon: "checklist")
                        case .normal:
                            Text(koboldName.isEmpty ? "KoboldOS" : koboldName).font(.headline)
                            GlassStatusBadge(label: agentDisplayName, color: .koboldGold, icon: "brain")
                        }
                    }
                    Text(viewModel.chatMode == .workflow
                         ? "Workflow-Chat · \(viewModel.workflowChatLabel)"
                         : viewModel.chatMode == .task
                         ? "Task-Chat · \(viewModel.taskChatLabel)"
                         : l10n.language.toolsAvailable)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                GlassStatusBadge(
                    label: viewModel.isConnected ? l10n.language.connected : l10n.language.offline,
                    color: viewModel.isConnected ? .koboldEmerald : .red
                )

                // Notification bell
                Button(action: {
                    showNotifications.toggle()
                    if showNotifications { viewModel.markAllNotificationsRead() }
                }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.unreadNotificationCount > 0 ? "bell.badge.fill" : "bell.fill")
                            .font(.system(size: 14))
                            .foregroundColor(viewModel.unreadNotificationCount > 0 ? .koboldGold : .secondary)
                        if viewModel.unreadNotificationCount > 0 {
                            Text("\(min(viewModel.unreadNotificationCount, 99))")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Circle().fill(Color.red))
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Benachrichtigungen")
                .popover(isPresented: $showNotifications, arrowEdge: .bottom) {
                    NotificationPopover(viewModel: viewModel)
                }

                Button(action: { viewModel.clearChatHistory() }) {
                    Image(systemName: "trash").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.language.clearHistory)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.koboldPanel)

            // Mode-specific banner
            if viewModel.chatMode == .workflow {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundColor(.koboldGold)
                    Text("Workflow-Chat — gespeichert unter Workflows")
                        .font(.caption)
                        .foregroundColor(.koboldGold)
                    Spacer()
                    Button(action: { viewModel.newSession() }) {
                        Text("Zurück zum Chat").font(.caption2).foregroundColor(.koboldEmerald)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.koboldGold.opacity(0.1))
            } else if viewModel.chatMode == .task {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Task-Chat — gespeichert unter Aufgaben")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Spacer()
                    Button(action: { viewModel.newSession() }) {
                        Text("Zurück zum Chat").font(.caption2).foregroundColor(.koboldEmerald)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
            }
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            Text("🐲").font(.system(size: 48))
            Text(l10n.language.startConversation).font(.title3)
            Text("\(koboldName.isEmpty ? "KoboldOS" : koboldName) ist bereit.")
                .font(.body).foregroundColor(.secondary)
            GlassCard(padding: 12, cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Beispiele").font(.caption.weight(.semibold)).foregroundColor(.koboldGold)
                    Text("• \"Dateien in ~/Desktop auflisten\"").font(.caption).foregroundColor(.secondary)
                    Text("• \"Wetter in Berlin abrufen\"").font(.caption).foregroundColor(.secondary)
                    Text("• \"Was ist 17 Fakultät?\"").font(.caption).foregroundColor(.secondary)
                    Text("• \"Schreibe mir ein Python-Skript...\"").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Bar
    // Always sends to Instructor — no model role selector shown here.

    var inputBar: some View {
        VStack(spacing: 0) {
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
                        .font(.system(size: 15))
                        .foregroundColor(pendingAttachments.isEmpty ? .secondary : .koboldEmerald)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Datei anhängen")

                // Brain toggle — show/hide agent steps
                Button(action: { showAgentSteps.toggle() }) {
                    Image(systemName: showAgentSteps ? "brain.fill" : "brain")
                        .font(.system(size: 15))
                        .foregroundColor(showAgentSteps ? .koboldGold : .secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help(showAgentSteps ? "Agent-Schritte ausblenden" : "Agent-Schritte einblenden")

                GlassTextField(
                    text: $inputText,
                    placeholder: l10n.language.typeMessage,
                    isMultiline: true,
                    onSubmit: send
                )

                if viewModel.agentLoading {
                    Button(action: { viewModel.cancelAgent() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.orange)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .help("Agent stoppen")
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.koboldEmerald)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color.koboldPanel)
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

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if viewModel.agentLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
