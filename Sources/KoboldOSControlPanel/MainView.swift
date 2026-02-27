import SwiftUI
import KoboldCore

@available(macOS 14.0, *)
struct MainView: View {
    @EnvironmentObject var runtimeManager: RuntimeManager
    @EnvironmentObject var l10n: LocalizationManager
    @StateObject private var viewModel = RuntimeViewModel()
    @State private var selectedTab: SidebarTab = .chat
    @State private var isSidebarCollapsed: Bool = false
    @AppStorage("kobold.hasOnboarded") private var hasOnboarded: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(viewModel: viewModel, selectedTab: $selectedTab, runtimeManager: runtimeManager, isCollapsed: $isSidebarCollapsed)
                    .frame(width: isSidebarCollapsed ? 48 : 220)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSidebarCollapsed)
                Divider()
                ContentAreaView(viewModel: viewModel, selectedTab: selectedTab, runtimeManager: runtimeManager)
            }
            .background(
                ZStack {
                    Color.koboldBackground
                    LinearGradient(
                        colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            )
            .blur(radius: hasOnboarded ? 0 : 10)
            .disabled(!hasOnboarded)

            if !hasOnboarded {
                OnboardingView(hasOnboarded: $hasOnboarded)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.spring(response: 0.5), value: hasOnboarded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.067, green: 0.075, blue: 0.082).opacity(0.95))
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: .koboldNavigate)) { note in
            if let tab = note.object as? SidebarTab {
                selectedTab = tab
            } else if let tabStr = note.userInfo?["tab"] as? String {
                // Navigation via userInfo (von Agent-Tools, z.B. app_terminal, app_browser)
                switch tabStr {
                case "chat": selectedTab = .chat
                case "tasks": selectedTab = .tasks
                case "workflows": selectedTab = .workflows
                case "settings": selectedTab = .settings
                // Dashboard entfernt
                case "memory": selectedTab = .memory
                default: break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .koboldNavigateSettings)) { _ in
            selectedTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("koboldClearHistory"))) { _ in
            viewModel.clearChatHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .koboldShowMainWindow)) { _ in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .alert("Daemon-Fehler", isPresented: $runtimeManager.showErrorAlert) {
            Button("Erneut versuchen") { runtimeManager.retryConnection() }
            Button("Beenden", role: .destructive) { exit(0) }
        } message: {
            Text(runtimeManager.errorMessage ?? "Unbekannter Fehler")
        }
        .onChange(of: selectedTab) {
            viewModel.currentViewTab = String(describing: selectedTab)
        }
        // Scheduled-Task-Observer: Wenn Daemon Cron-Task feuert → Task-Chat öffnen + ausführen
        .onReceive(NotificationCenter.default.publisher(for: .koboldScheduledTaskFired)) { note in
            guard let taskId = note.userInfo?["taskId"] as? String,
                  let taskName = note.userInfo?["taskName"] as? String,
                  let prompt = note.userInfo?["prompt"] as? String else { return }
            viewModel.executeTask(taskId: taskId, taskName: taskName, prompt: prompt, navigate: true)
            selectedTab = .chat
        }
        // Notification-Klick: Navigiere zur Task-Session
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("koboldNavigateToSession"))) { note in
            if let sessionId = note.userInfo?["sessionId"] as? UUID {
                viewModel.switchToSession(sessionId)
                selectedTab = .chat
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @Binding var selectedTab: SidebarTab
    @ObservedObject var runtimeManager: RuntimeManager
    @Binding var isCollapsed: Bool
    @EnvironmentObject var l10n: LocalizationManager
    @AppStorage("kobold.koboldName") private var koboldName: String = "KoboldOS"
    @AppStorage("kobold.userName") private var userName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // FIXED TOP: Logo + Collapse Button
            if isCollapsed {
                // Collapsed: only toggle button
                Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isCollapsed = false } }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 18.5, weight: .medium))
                        .foregroundColor(.koboldEmerald)
                        .frame(width: 32, height: 32)
                        .background(Color.koboldSurface.opacity(0.6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Menü einblenden")
                .padding(.top, 12)
                .padding(.bottom, 8)
            } else {
                // Expanded: Logo (klick = Sidebar einklappen)
                KoboldOSSidebarLogo(userName: userName)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isCollapsed = true }
                    }
                    .help("Sidebar einklappen")
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5).padding(.horizontal, 10)
            }

            if !isCollapsed {
                // SCROLLABLE MIDDLE: Navigation + Sessions/Projects
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Navigation tabs
                        ForEach(SidebarTab.allCases, id: \.self) { tab in
                            sidebarButton(tab)
                        }

                        Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)

                        // Context-sensitive list
                        if selectedTab == .workflows {
                            workflowSessionsList
                            Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 4)
                            projectsList
                            Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 4)
                            collapsibleChatsList
                        } else if selectedTab == .tasks {
                            collapsibleChatsList
                        } else {
                            sessionsList
                        }
                    }
                    .padding(.top, 6)
                }

                Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5).padding(.horizontal, 10)

                // FIXED BOTTOM: Daemon Status
                StatusIndicatorView(
                    status: runtimeManager.healthStatus,
                    pid: runtimeManager.daemonPID,
                    port: runtimeManager.port,
                    onRestart: { runtimeManager.retryConnection() },
                    onStop: { runtimeManager.stopDaemon() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if isCollapsed {
                // Collapsed: show icon-only navigation
                VStack(spacing: 2) {
                    ForEach(SidebarTab.allCases, id: \.self) { tab in
                        Button(action: { selectedTab = tab }) {
                            Image(systemName: iconForTab(tab))
                                .font(.system(size: 16.5))
                                .foregroundColor(selectedTab == tab ? .koboldEmerald : .secondary)
                                .frame(width: 32, height: 32)
                                .background(
                                    Group {
                                        if selectedTab == tab {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.koboldSurface)
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.koboldEmerald.opacity(0.2), lineWidth: 0.5))
                                        }
                                    }
                                )
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help(labelForTab(tab))
                    }
                }
                .padding(.top, 4)
                Spacer()
            }
        }
        .background(
            ZStack {
                Color.koboldPanel
                LinearGradient(
                    colors: [Color.koboldEmerald.opacity(0.03), .clear, Color.koboldGold.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Subtle right-edge glow line
                HStack { Spacer(); Rectangle().fill(LinearGradient(colors: [Color.koboldEmerald.opacity(0.15), Color.koboldGold.opacity(0.08)], startPoint: .top, endPoint: .bottom)).frame(width: 1) }
            }
        )
        .clipped()
    }

    // tasksSidebarList removed — tasks appear in normal chat list now

    // MARK: - Collapsible Normal Chats (shown in Tasks/Workflows tabs)
    @State private var showNormalChatsInSubTab: Bool = false

    private var collapsibleChatsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showNormalChatsInSubTab.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showNormalChatsInSubTab ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.secondary)
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11.5))
                        .foregroundColor(.koboldEmerald)
                    Text("Chats")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.sessions.count)")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showNormalChatsInSubTab {
                ForEach(viewModel.sessions.prefix(100), id: \.id) { session in
                    SidebarSessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSessionId,
                        icon: "bubble.left",
                        accentColor: .koboldEmerald
                    ) {
                        viewModel.switchToSession(session)
                        selectedTab = .chat
                    } onDelete: {
                        viewModel.deleteSession(session)
                    }
                }
                if viewModel.sessions.count > 20 {
                    Text("+ \(viewModel.sessions.count - 20) weitere...")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Workflow Sessions List
    private var workflowSessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Saved workflow definitions (from agent)
            HStack(spacing: 6) {
                Text("Workflows")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
                Button(action: { viewModel.loadWorkflowDefinitions() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11.5))
                }.buttonStyle(.plain).foregroundColor(.secondary)
                Button(action: {
                    viewModel.openWorkflowChat(nodeName: "Neuer Workflow")
                    selectedTab = .workflows
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .help("Neuen Workflow starten")
                .padding(.trailing, 12)
            }
            .padding(.vertical, 6)

            if viewModel.workflowDefinitions.isEmpty && viewModel.workflowSessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    Text("Noch keine Workflows")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            ForEach(viewModel.workflowDefinitions, id: \.id) { def in
                Button(action: {
                    viewModel.openWorkflowChat(nodeName: def.name)
                    selectedTab = .workflows
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 12.5))
                            .foregroundColor(.koboldGold)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(def.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            if !def.description.isEmpty {
                                Text(def.description).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button(action: { viewModel.deleteWorkflowDefinition(def) }) {
                            Image(systemName: "trash").font(.system(size: 11.5))
                        }.buttonStyle(.plain).foregroundColor(.secondary.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Workflow chats (sessions)
            if !viewModel.workflowSessions.isEmpty {
                Rectangle().fill(LinearGradient(colors: [.clear, Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 0.5).padding(.horizontal, 12).padding(.vertical, 4)

                HStack {
                    Text("Workflow-Chats")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                    Spacer()
                }
                .padding(.vertical, 4)

                ForEach(viewModel.workflowSessions) { session in
                    SidebarSessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSessionId,
                        icon: "bubble.left.and.bubble.right",
                        accentColor: .koboldGold
                    ) {
                        viewModel.switchToSession(session)
                        selectedTab = .workflows
                    } onDelete: {
                        viewModel.deleteSession(session)
                    }
                }
            }

        }
    }

    // MARK: - Projects List
    private var projectsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projekte")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
                Button(action: { viewModel.newProject() }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13.5))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .help("Neues Projekt")
                .padding(.trailing, 12)
            }
            .padding(.vertical, 6)

            ForEach(viewModel.projects) { project in
                SidebarProjectRow(
                    project: project,
                    isSelected: project.id == viewModel.selectedProjectId
                ) {
                    viewModel.selectedProjectId = project.id
                    selectedTab = .workflows
                } onDelete: {
                    viewModel.deleteProject(project)
                }
            }
        }
    }

    // MARK: - Sessions List (Topics + Date Groups — AgentZero-style)

    @State private var sessionSearchText: String = ""
    @State private var showNewTopicSheet: Bool = false
    @State private var newTopicName: String = ""
    @State private var newTopicColor: String = "#34d399"
    @State private var cachedFilteredSessions: [ChatSession] = []
    @State private var cachedDateGroups: [SessionGroup] = []
    @State private var lastSessionsHash: Int = 0

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Gespräche")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
                Text("\(viewModel.sessions.count)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.koboldSurface))

                // New topic folder button
                Button(action: { showNewTopicSheet = true }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12.5))
                        .foregroundColor(.koboldGold)
                }
                .buttonStyle(.plain)
                .help("Neues Thema erstellen")

                // Clear all chats
                Button(action: { viewModel.clearChatHistory() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Verlauf leeren")

                // New chat button
                Button(action: { viewModel.newSession(); selectedTab = .chat }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13.5))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .help("Neues Gespräch")
                .padding(.trailing, 12)
            }
            .padding(.vertical, 6)

            // Search
            if viewModel.sessions.count > 4 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    TextField("Suchen...", text: $sessionSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.koboldSurface.opacity(0.6))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Task sidebar section removed — tasks appear in normal chat list

            // Topic folders
            ForEach(viewModel.topics) { topic in
                SidebarTopicFolder(
                    topic: topic,
                    sessions: filteredSessions.filter { $0.topicId == topic.id },
                    currentSessionId: viewModel.currentSessionId,
                    isStreaming: viewModel.agentLoading,
                    onToggle: { viewModel.toggleTopicExpanded(topic) },
                    onNewChat: {
                        viewModel.newSession(topicId: topic.id)
                        selectedTab = .chat
                    },
                    onDeleteTopic: {
                        withAnimation(.easeOut(duration: 0.25)) { viewModel.deleteTopic(topic) }
                    },
                    onEditTopic: { updated in
                        viewModel.updateTopic(updated)
                    },
                    onSelectSession: { session in
                        viewModel.switchToSession(session)
                        selectedTab = .chat
                    },
                    onDeleteSession: { session in
                        withAnimation(.easeOut(duration: 0.25)) { viewModel.deleteSession(session) }
                    },
                    onRemoveFromTopic: { session in
                        viewModel.assignSessionToTopic(sessionId: session.id, topicId: nil)
                    }
                )
            }

            // Ungrouped sessions (no topic) — grouped by date (gecacht, kein Inline-Sort)
            if !cachedDateGroups.isEmpty {
                ForEach(cachedDateGroups, id: \.label) { group in
                    SessionGroupHeader(label: group.label)
                    ForEach(group.sessions) { session in
                        SidebarSessionRow(
                            session: session,
                            isCurrent: session.id == viewModel.currentSessionId,
                            isStreaming: session.id == viewModel.currentSessionId && viewModel.agentLoading,
                            topicColor: nil
                        ) {
                            viewModel.switchToSession(session)
                            selectedTab = .chat
                        } onDelete: {
                            withAnimation(.easeOut(duration: 0.25)) { viewModel.deleteSession(session) }
                        }
                        .contextMenu {
                            if !viewModel.topics.isEmpty {
                                Menu("Thema zuweisen") {
                                    ForEach(viewModel.topics) { topic in
                                        Button(action: { viewModel.assignSessionToTopic(sessionId: session.id, topicId: topic.id) }) {
                                            HStack {
                                                Circle().fill(topic.swiftUIColor).frame(width: 8, height: 8)
                                                Text(topic.name)
                                            }
                                        }
                                    }
                                }
                            }
                            Button(role: .destructive, action: { viewModel.deleteSession(session) }) {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                    }
                }
            }

            if viewModel.sessions.isEmpty && viewModel.topics.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Noch keine Gespräche")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .popover(isPresented: $showNewTopicSheet, arrowEdge: .trailing) {
            newTopicPopover
        }
        .onAppear { rebuildSessionCache() }
        .onChange(of: viewModel.sessions.count) { rebuildSessionCache() }
        .onChange(of: sessionSearchText) { rebuildSessionCache() }
        .onChange(of: viewModel.sessions.first?.title) { rebuildSessionCache() }
    }

    // MARK: - New Topic Popover

    private var newTopicPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neues Thema")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(.primary)

            TextField("Name...", text: $newTopicName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13.5))

            // Color picker
            HStack(spacing: 6) {
                ForEach(ChatTopic.defaultColors, id: \.self) { color in
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: newTopicColor == color ? 2 : 0)
                        )
                        .scaleEffect(newTopicColor == color ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2), value: newTopicColor)
                        .onTapGesture { newTopicColor = color }
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen") {
                    showNewTopicSheet = false
                    newTopicName = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("Erstellen") {
                    let name = newTopicName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        viewModel.createTopic(name: name, color: newTopicColor)
                    }
                    showNewTopicSheet = false
                    newTopicName = ""
                    newTopicColor = "#34d399"
                }
                .buttonStyle(.borderedProminent)
                .tint(.koboldEmerald)
                .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Helpers

    // filteredSessions ist jetzt gecacht — nur bei Änderungen neu berechnet (nicht bei jedem Render)
    private var filteredSessions: [ChatSession] { cachedFilteredSessions }

    private struct SessionGroup: Identifiable {
        let label: String
        let sessions: [ChatSession]
        var id: String { label }
    }

    /// Sessions + DateGroups neu berechnen (nur aufrufen wenn sessions/searchText sich ändern)
    private func rebuildSessionCache() {
        // All sessions in one list (tasks included — no separate task sidebar)
        let normalSessions = viewModel.sessions
        let sorted: [ChatSession]
        if sessionSearchText.isEmpty {
            sorted = normalSessions.sorted { $0.createdAt > $1.createdAt }
        } else {
            let q = sessionSearchText.lowercased()
            sorted = normalSessions
                .filter { $0.title.lowercased().contains(q) }
                .sorted { $0.createdAt > $1.createdAt }
        }
        cachedFilteredSessions = sorted

        // DateGroups für ungrouped sessions
        let ungrouped = sorted.filter { $0.topicId == nil }
        cachedDateGroups = buildDateGroups(ungrouped)
    }

    private func buildDateGroups(_ sessions: [ChatSession]) -> [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }

        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var older: [ChatSession] = []

        for session in sorted {
            if calendar.isDateInToday(session.createdAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.createdAt) {
                yesterday.append(session)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      session.createdAt >= weekAgo {
                thisWeek.append(session)
            } else {
                older.append(session)
            }
        }

        var groups: [SessionGroup] = []
        if !today.isEmpty     { groups.append(SessionGroup(label: "Heute", sessions: today)) }
        if !yesterday.isEmpty { groups.append(SessionGroup(label: "Gestern", sessions: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(SessionGroup(label: "Letzte 7 Tage", sessions: thisWeek)) }
        if !older.isEmpty     { groups.append(SessionGroup(label: "Älter", sessions: older)) }
        return groups
    }

    func sidebarButton(_ tab: SidebarTab) -> some View {
        Button(action: { selectedTab = tab }) {
            HStack {
                Image(systemName: iconForTab(tab))
                    .frame(width: 20)
                    .foregroundColor(selectedTab == tab ? .koboldEmerald : .secondary)
                Text(labelForTab(tab))
                    .fontWeight(selectedTab == tab ? .semibold : .regular)
                    .foregroundColor(selectedTab == tab ? .koboldEmerald : .white)
                Spacer()
                // Beta / Coming Soon badges
                if tab == .workflows {
                    Text("Beta")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.koboldGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.koboldGold.opacity(0.2)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Group {
                    if selectedTab == tab {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.koboldSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LinearGradient(colors: [Color.koboldEmerald.opacity(0.08), Color.koboldGold.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.2), Color.koboldGold.opacity(0.1)], startPoint: .leading, endPoint: .trailing), lineWidth: 0.5)
                            )
                    }
                }
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    func labelForTab(_ tab: SidebarTab) -> String {
        switch tab {
        case .chat:         return l10n.language.chat
        case .memory:       return "Gedächtnis"
        case .tasks:        return l10n.language.tasks
        case .workflows:    return l10n.language.team
        case .settings:     return l10n.language.settings
        }
    }

    func iconForTab(_ tab: SidebarTab) -> String {
        switch tab {
        case .chat:         return "message.fill"
        case .memory:       return "brain.filled.head.profile"
        case .tasks:        return "checklist"
        case .workflows:    return "point.3.connected.trianglepath.dotted"
        case .settings:     return "gearshape.fill"
        }
    }
}

// MARK: - SessionGroupHeader

struct SessionGroupHeader: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary.opacity(0.5))
                .tracking(0.8)
            Rectangle()
                .fill(LinearGradient(colors: [Color.secondary.opacity(0.15), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - SidebarTopicFolder (AgentZero-style project folder)

struct SidebarTopicFolder: View {
    let topic: ChatTopic
    let sessions: [ChatSession]
    let currentSessionId: UUID
    let isStreaming: Bool
    let onToggle: () -> Void
    let onNewChat: () -> Void
    let onDeleteTopic: () -> Void
    let onEditTopic: (ChatTopic) -> Void
    let onSelectSession: (ChatSession) -> Void
    let onDeleteSession: (ChatSession) -> Void
    let onRemoveFromTopic: (ChatSession) -> Void

    @State private var isHovered: Bool = false
    @State private var showEditor: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folder header
            HStack(spacing: 6) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: topic.isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 12.5))
                            .foregroundColor(topic.swiftUIColor)

                        Text(topic.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.9))
                            .lineLimit(1)

                        Text("\(sessions.count)")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(topic.swiftUIColor.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(topic.swiftUIColor.opacity(0.12)))

                        Spacer()

                        Image(systemName: topic.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)

                if isHovered {
                    // Edit button
                    Button(action: { showEditor = true }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.koboldSurface.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .help("Thema bearbeiten")

                    // New chat in topic
                    Button(action: onNewChat) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(topic.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(topic.swiftUIColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .help("Neuer Chat in \(topic.name)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.koboldSurface.opacity(0.4) : .clear)
            )
            .padding(.horizontal, 4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .contextMenu {
                Button(action: { showEditor = true }) {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                Button(action: onNewChat) {
                    Label("Neuer Chat", systemImage: "plus.message")
                }
                Divider()
                Button(role: .destructive, action: onDeleteTopic) {
                    Label("Thema löschen", systemImage: "trash")
                }
            }

            // Project path hint (when collapsed, show path if set)
            if !topic.isExpanded && !topic.projectPath.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(topic.displayPath)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)
            }

            // Sessions inside folder
            if topic.isExpanded {
                ForEach(sessions) { session in
                    SidebarSessionRow(
                        session: session,
                        isCurrent: session.id == currentSessionId,
                        isStreaming: session.id == currentSessionId && isStreaming,
                        topicColor: topic.swiftUIColor
                    ) {
                        onSelectSession(session)
                    } onDelete: {
                        onDeleteSession(session)
                    }
                    .padding(.leading, 10)
                    .contextMenu {
                        Button(action: { onRemoveFromTopic(session) }) {
                            Label("Aus Thema entfernen", systemImage: "folder.badge.minus")
                        }
                        Button(role: .destructive, action: { onDeleteSession(session) }) {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }

                if sessions.isEmpty {
                    Text("Keine Chats")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.leading, 36)
                        .padding(.vertical, 3)
                }
            }

            // Subtle bottom accent line
            Rectangle()
                .fill(topic.swiftUIColor.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
                .padding(.top, 2)
        }
        .padding(.top, 4)
        .sheet(isPresented: $showEditor) {
            TopicEditorSheet(topic: topic, onSave: onEditTopic)
        }
    }
}

// MARK: - TopicEditorSheet (full topic settings: name, color, project folder, instructions, memory)

struct TopicEditorSheet: View {
    let topic: ChatTopic
    let onSave: (ChatTopic) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editName: String = ""
    @State private var editColor: String = ""
    @State private var editInstructions: String = ""
    @State private var editProjectPath: String = ""
    @State private var editUseOwnMemory: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Circle().fill(Color(hex: editColor)).frame(width: 14, height: 14)
                Text("Thema bearbeiten")
                    .font(.system(size: 16.5, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Name", systemImage: "tag")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        TextField("Themenname...", text: $editName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14.5))
                    }

                    // Color
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Farbe", systemImage: "paintpalette")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach(ChatTopic.defaultColors, id: \.self) { color in
                                Circle()
                                    .fill(Color(hex: color))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle().stroke(Color.white, lineWidth: editColor == color ? 2.5 : 0)
                                    )
                                    .shadow(color: editColor == color ? Color(hex: color).opacity(0.5) : .clear, radius: 4)
                                    .scaleEffect(editColor == color ? 1.15 : 1.0)
                                    .animation(.spring(response: 0.25), value: editColor)
                                    .onTapGesture { editColor = color }
                            }
                        }
                    }

                    // Project folder
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Projektordner", systemImage: "folder.badge.gearshape")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("Ordner auf deinem Mac den der Agent als Arbeitsverzeichnis nutzt.")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary.opacity(0.6))
                        HStack(spacing: 8) {
                            TextField("~/Projects/MeinProjekt", text: $editProjectPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13.5, design: .monospaced))
                            Button("Wählen...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.message = "Projektordner für \"\(editName)\" wählen"
                                panel.prompt = "Auswählen"
                                if panel.runModal() == .OK, let url = panel.url {
                                    editProjectPath = url.path
                                }
                            }
                            .buttonStyle(.bordered)
                            if !editProjectPath.isEmpty {
                                Button(action: { editProjectPath = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !editProjectPath.isEmpty {
                            let exists = FileManager.default.fileExists(atPath: editProjectPath)
                            HStack(spacing: 4) {
                                Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(exists ? .green : .orange)
                                Text(exists ? "Ordner existiert" : "Ordner nicht gefunden")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(exists ? .green : .orange)
                            }
                        }
                    }

                    // Instructions
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Anweisungen", systemImage: "text.document")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("Spezifische Anweisungen die bei jedem Chat in diesem Thema an den Agenten gesendet werden. Z.B. Coding-Style, Kontext, Regeln.")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary.opacity(0.6))
                        TextEditor(text: $editInstructions)
                            .font(.system(size: 13.5, design: .monospaced))
                            .frame(minHeight: 150, maxHeight: 300)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.koboldSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                        HStack {
                            Spacer()
                            Text("\(editInstructions.count) Zeichen")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }

                    // Memory isolation
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $editUseOwnMemory) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Eigenes Gedächtnis", systemImage: "brain.head.profile")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("Wenn aktiv, hat dieses Thema ein isoliertes Gedächtnis. Der Agent speichert und liest Erinnerungen nur für dieses Thema.")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)
                    }
                }
                .padding(20)
            }

            Divider().padding(.horizontal, 16)

            // Footer buttons
            HStack {
                // Info: created date
                Text("Erstellt: \(topic.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary.opacity(0.5))
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Button("Speichern") {
                    var updated = topic
                    updated.name = editName.trimmingCharacters(in: .whitespaces).isEmpty ? topic.name : editName.trimmingCharacters(in: .whitespaces)
                    updated.color = editColor
                    updated.instructions = editInstructions
                    updated.projectPath = editProjectPath
                    updated.useOwnMemory = editUseOwnMemory
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.koboldEmerald)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 620)
        .background(Color.koboldBackground)
        .onAppear {
            editName = topic.name
            editColor = topic.color
            editInstructions = topic.instructions
            editProjectPath = topic.projectPath
            editUseOwnMemory = topic.useOwnMemory
        }
    }
}

// MARK: - SidebarSessionRow

struct SidebarSessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    var icon: String = "message"
    var accentColor: Color = .koboldEmerald
    var isStreaming: Bool = false
    var topicColor: Color? = nil
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    private var effectiveAccent: Color { topicColor ?? accentColor }

    init(session: ChatSession, isCurrent: Bool, icon: String = "message", accentColor: Color = .koboldEmerald,
         isStreaming: Bool = false, topicColor: Color? = nil, onTap: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.session = session
        self.isCurrent = isCurrent
        self.icon = icon
        self.accentColor = accentColor
        self.isStreaming = isStreaming
        self.topicColor = topicColor
        self.onTap = onTap
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    // Status indicator dot — statisch, keine repeatForever Animation
                    ZStack {
                        Circle()
                            .fill(isCurrent ? effectiveAccent : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                        if isStreaming {
                            Circle()
                                .stroke(effectiveAccent.opacity(0.6), lineWidth: 1.5)
                                .frame(width: 12, height: 12)
                        }
                        if session.hasUnread && !isCurrent {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 13.5, weight: isCurrent || session.hasUnread ? .semibold : .regular))
                            .foregroundColor(isCurrent ? .primary : .primary.opacity(0.85))
                            .lineLimit(1)
                        Text(session.formattedDate)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.koboldSurface)
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: [effectiveAccent.opacity(0.1), effectiveAccent.opacity(0.02)], startPoint: .leading, endPoint: .trailing))
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(effectiveAccent.opacity(isStreaming ? 0.35 : 0.18), lineWidth: isStreaming ? 1.0 : 0.5)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.koboldSurface.opacity(0.5))
                        }
                    }
                )
            }
            .buttonStyle(.plain)

            // Delete button — visible on hover or current
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.koboldSurface.opacity(isHovered ? 0.8 : 0)))
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(isHovered || isCurrent ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .cornerRadius(8)
        .padding(.horizontal, 4)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - SidebarProjectRow

struct SidebarProjectRow: View {
    let project: Project
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(isSelected ? .koboldGold : .secondary)
                        Text(project.name)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .koboldGold : .primary)
                            .lineLimit(1)
                    }
                    Text(project.formattedDate)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.koboldSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(LinearGradient(colors: [Color.koboldGold.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.koboldGold.opacity(0.15), lineWidth: 0.5)
                                )
                        }
                    }
                )
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.trailing, 8)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }
}

// MARK: - Content Area

struct ContentAreaView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    let selectedTab: SidebarTab
    @ObservedObject var runtimeManager: RuntimeManager

    @State private var showGlobalNotifications = false

    var body: some View {
        ZStack {
            // Zartes Kleeblatt-Hintergrundmuster
            CloverPatternBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Global header bar (visible on all tabs except settings)
                if selectedTab != .settings {
                    GlobalHeaderBar(viewModel: viewModel, showNotifications: $showGlobalNotifications)
                        .padding(.horizontal, 16).padding(.top, 10)
                }

                Group {
                switch selectedTab {
                case .chat:
                    if runtimeManager.healthStatus == "OK" {
                        ChatView(viewModel: viewModel)
                    } else {
                        ChatLockedView(status: runtimeManager.healthStatus)
                    }
                case .memory:     MemoryView(viewModel: viewModel)
                case .tasks:      TasksView(viewModel: viewModel)
                case .workflows:
                    if viewModel.chatMode == .workflow {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.caption)
                                    .foregroundColor(.koboldEmerald)
                                Text("Workflow-Chat aktiv: \(viewModel.workflowChatLabel)")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.koboldEmerald)
                                Spacer()
                                Button(action: { viewModel.newSession() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.left").font(.caption2)
                                        Text("Zurück zum Canvas").font(.caption2)
                                    }
                                    .foregroundColor(.koboldEmerald)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(
                                LinearGradient(colors: [Color.koboldEmerald.opacity(0.12), Color.koboldGold.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                            )
                            GlassDivider()
                            ChatView(viewModel: viewModel)
                        }
                    } else {
                        TeamView(viewModel: viewModel)
                    }
                case .settings:     SettingsView(viewModel: viewModel)
                }
            }
            } // VStack

            // PersistentThinkingBar wird nur in ChatView angezeigt (nicht global)
        } // ZStack mit CloverPattern
    }
}

// MARK: - Persistent Thinking Bar (sichtbar auf ALLEN Tabs während Agent arbeitet)

struct PersistentThinkingBar: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @State private var lastThought: String = ""
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            Text("Kobold denkt nach...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.koboldEmerald)
            if !lastThought.isEmpty {
                Text("— \(lastThought)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Circle()
                .fill(Color.koboldEmerald)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 1 : 0.4)
                .animation(.easeInOut(duration: 1.5), value: pulse)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.koboldEmerald.opacity(0.06))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { pulse = true }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("koboldAgentThought"))) { notif in
            if let text = notif.userInfo?["text"] as? String {
                lastThought = String(text.prefix(80))
            }
        }
    }
}

// MARK: - Global Header Bar (Dashboard dateWeatherBar + Glocke, auf allen Seiten außer Settings)

struct GlobalHeaderBar: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @Binding var showNotifications: Bool
    @ObservedObject private var weatherManager = WeatherManager.shared

    // Cached DateFormatters — DateFormatter() is expensive, create only once
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // P9: Task-based tick — Timer.publish leaked to main runloop even when header not visible
    @State private var tick = Date()

    var body: some View {
        HStack {
            // Datum links
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 15.5))
                    .foregroundColor(.koboldEmerald)
                Text(Self.dateFormatter.string(from: tick))
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Uhrzeit mittig
            Text(Self.timeFormatter.string(from: tick))
                .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.koboldEmerald)

            Spacer()

            // Wetter
            HStack(spacing: 8) {
                if weatherManager.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else if let temp = weatherManager.temperature {
                    Image(systemName: weatherManager.iconName)
                        .font(.system(size: 15.5))
                        .foregroundColor(.koboldGold)
                    Text(String(format: "%.0f°C", temp))
                        .font(.system(size: 15.5, weight: .semibold))
                    if !weatherManager.cityName.isEmpty {
                        Text(weatherManager.cityName)
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Online badge
            GlassStatusBadge(
                label: viewModel.isConnected ? "Online" : "Offline",
                color: viewModel.isConnected ? .koboldEmerald : .red
            )

            // Notification Bell
            Button(action: {
                showNotifications.toggle()
                if showNotifications { viewModel.markAllNotificationsRead() }
            }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.unreadNotificationCount > 0 ? "bell.badge.fill" : "bell.fill")
                        .font(.system(size: 16.5))
                        .foregroundColor(viewModel.unreadNotificationCount > 0 ? .koboldGold : .secondary)
                    if viewModel.unreadNotificationCount > 0 {
                        Text("\(min(viewModel.unreadNotificationCount, 99))")
                            .font(.system(size: 10.5, weight: .bold))
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
        }
        .padding(.horizontal, 4)
        .onAppear {
            weatherManager.fetchWeatherIfNeeded()
        }
        .task {
            // P9: Replaces Timer.publish(every:60, on:.main) — auto-cancelled when view disappears
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                tick = Date()
                weatherManager.fetchWeatherIfNeeded()
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.koboldPanel)
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color.koboldEmerald.opacity(0.04), .clear, Color.koboldGold.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Color.koboldEmerald.opacity(0.2), Color.koboldGold.opacity(0.15)], startPoint: .leading, endPoint: .trailing), lineWidth: 0.5)
            }
        )
    }
}

// MARK: - Locked State

struct ChatLockedView: View {
    let status: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 49))
                .foregroundColor(.secondary)
            Text("Daemon nicht bereit")
                .font(.title2.bold())
            Text("Status: \(status)")
                .font(.body)
                .foregroundColor(.secondary)
            Text("Warte auf Daemon-Start...")
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SidebarTab
// Order here defines sidebar display order

enum SidebarTab: String, CaseIterable {
    case chat
    case tasks
    case workflows
    case memory
    case settings
}

// MARK: - KoboldOS Sidebar Logo

struct KoboldOSSidebarLogo: View {
    let userName: String
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            // Dark green background
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.03, green: 0.12, blue: 0.06),
                                 Color(red: 0.01, green: 0.07, blue: 0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.koboldEmerald.opacity(0.35), lineWidth: 1)
                )

            // Circuit traces (Canvas)
            Canvas { ctx, size in
                let lines: [(CGPoint, CGPoint)] = [
                    (CGPoint(x: 0, y: size.height * 0.3), CGPoint(x: size.width * 0.15, y: size.height * 0.3)),
                    (CGPoint(x: size.width * 0.15, y: size.height * 0.3), CGPoint(x: size.width * 0.15, y: size.height * 0.6)),
                    (CGPoint(x: size.width * 0.85, y: size.height * 0.4), CGPoint(x: size.width, y: size.height * 0.4)),
                    (CGPoint(x: size.width * 0.85, y: size.height * 0.4), CGPoint(x: size.width * 0.85, y: size.height * 0.7)),
                    (CGPoint(x: size.width * 0.3, y: size.height), CGPoint(x: size.width * 0.3, y: size.height * 0.85)),
                    (CGPoint(x: size.width * 0.6, y: size.height), CGPoint(x: size.width * 0.6, y: size.height * 0.85)),
                ]
                let nodes: [CGPoint] = [
                    CGPoint(x: size.width * 0.15, y: size.height * 0.3),
                    CGPoint(x: size.width * 0.85, y: size.height * 0.4),
                    CGPoint(x: size.width * 0.3, y: size.height * 0.85),
                    CGPoint(x: size.width * 0.6, y: size.height * 0.85),
                ]
                for (from, to) in lines {
                    var p = Path(); p.move(to: from); p.addLine(to: to)
                    ctx.stroke(p, with: .color(Color.koboldEmerald.opacity(0.25)), lineWidth: 1)
                }
                for pt in nodes {
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)),
                             with: .color(Color.koboldEmerald.opacity(0.5)))
                }
            }
            .cornerRadius(10)

            // Static subtle glow (removed .repeatForever — was a permanent 60fps timer)
            Ellipse()
                .fill(Color.koboldEmerald.opacity(0.09))
                .frame(width: 120, height: 20)
                .blur(radius: 8)
                .offset(y: 12)

            // Main content
            HStack(spacing: 8) {
                // App Icon with glow
                ZStack {
                    // Static glow behind icon
                    Circle()
                        .fill(Color.koboldEmerald.opacity(0.20))
                        .frame(width: 52, height: 52)
                        .blur(radius: 10)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.koboldEmerald.opacity(0.6), radius: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("KoboldOS")
                        .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.koboldGold, Color(hex: "#FFE566"), Color.koboldEmerald],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: Color.koboldEmerald.opacity(0.8), radius: 4)

                    if !userName.isEmpty {
                        Text(userName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Color.koboldEmerald.opacity(0.7))
                            .tracking(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .onAppear { glowPulse = true }
    }
}
