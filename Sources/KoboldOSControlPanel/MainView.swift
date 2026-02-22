import SwiftUI

@available(macOS 14.0, *)
struct MainView: View {
    @EnvironmentObject var runtimeManager: RuntimeManager
    @EnvironmentObject var l10n: LocalizationManager
    @StateObject private var viewModel = RuntimeViewModel()
    @State private var selectedTab: SidebarTab = .dashboard
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
            .background(Color.koboldBackground)
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
            if let tab = note.object as? SidebarTab { selectedTab = tab }
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
                        .font(.system(size: 16, weight: .medium))
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
                // Expanded: Logo with collapse button overlay
                ZStack(alignment: .topTrailing) {
                    KoboldOSSidebarLogo(userName: userName)
                        .padding(.horizontal, 10)

                    Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isCollapsed = true } }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.koboldEmerald.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(Color.koboldSurface.opacity(0.5))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("Menü einklappen")
                    .padding(.top, 4)
                    .padding(.trailing, 14)
                }
                .padding(.top, 8)
                .padding(.bottom, 6)

                Divider().padding(.horizontal, 10)
            }

            if !isCollapsed {
                // SCROLLABLE MIDDLE: Navigation + Sessions/Projects
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Navigation tabs
                        ForEach(SidebarTab.allCases, id: \.self) { tab in
                            sidebarButton(tab)
                        }

                        Divider()
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)

                        // Context-sensitive list
                        if selectedTab == .workflows {
                            workflowSessionsList
                            Divider().padding(.horizontal, 10).padding(.vertical, 4)
                            projectsList
                        } else if selectedTab == .tasks {
                            tasksSidebarList
                        } else {
                            sessionsList
                        }
                    }
                    .padding(.top, 6)
                }

                Divider().padding(.horizontal, 10)

                // FIXED BOTTOM: Daemon Status
                StatusIndicatorView(
                    status: runtimeManager.healthStatus,
                    pid: runtimeManager.daemonPID,
                    port: runtimeManager.port
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
                                .font(.system(size: 14))
                                .foregroundColor(selectedTab == tab ? .koboldEmerald : .secondary)
                                .frame(width: 32, height: 32)
                                .background(selectedTab == tab ? Color.koboldSurface : Color.clear)
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
        .background(Color.koboldPanel)
        .clipped()
    }

    // MARK: - Tasks Sidebar List
    private var tasksSidebarList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Task-Chats")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
            }
            .padding(.vertical, 6)

            if viewModel.taskSessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Noch keine Task-Chats")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
                ForEach(viewModel.taskSessions) { session in
                    SidebarSessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSessionId,
                        icon: "checklist",
                        accentColor: .blue
                    ) {
                        viewModel.switchToSession(session)
                        selectedTab = .chat
                    } onDelete: {
                        viewModel.deleteSession(session)
                    }
                }
            }
        }
    }

    // MARK: - Workflow Sessions List
    private var workflowSessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workflow-Chats")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
            }
            .padding(.vertical, 6)

            if viewModel.workflowSessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Noch keine Workflow-Chats")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
                ForEach(viewModel.workflowSessions) { session in
                    SidebarSessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSessionId,
                        icon: "point.3.connected.trianglepath.dotted",
                        accentColor: .koboldGold
                    ) {
                        viewModel.switchToSession(session)
                        selectedTab = .chat
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
                        .font(.system(size: 11))
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
                } onDelete: {
                    viewModel.deleteProject(project)
                }
            }
        }
    }

    // MARK: - Sessions List
    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Gespräche")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                Spacer()
                Button(action: { viewModel.newSession(); selectedTab = .chat }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .help("Neues Gespräch")
                .padding(.trailing, 12)
            }
            .padding(.vertical, 6)

            ForEach(viewModel.sessions) { session in
                SidebarSessionRow(
                    session: session,
                    isCurrent: session.id == viewModel.currentSessionId
                ) {
                    viewModel.switchToSession(session)
                    selectedTab = .chat
                } onDelete: {
                    viewModel.deleteSession(session)
                }
            }
        }
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
                // Beta badge for Team tab
                if tab == .workflows {
                    Text("Beta")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.koboldGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.koboldGold.opacity(0.2)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selectedTab == tab ? Color.koboldSurface : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    func labelForTab(_ tab: SidebarTab) -> String {
        switch tab {
        case .chat:       return l10n.language.chat
        case .dashboard:  return l10n.language.dashboard
        case .memory:     return "Gedächtnis"
        case .tasks:      return l10n.language.tasks
        case .store:      return "Store"
        case .agents:     return l10n.language.agents
        case .workflows:  return l10n.language.team
        case .settings:   return l10n.language.settings
        }
    }

    func iconForTab(_ tab: SidebarTab) -> String {
        switch tab {
        case .chat:       return "message.fill"
        case .dashboard:  return "chart.bar.fill"
        case .memory:     return "brain.filled.head.profile"
        case .tasks:      return "checklist"
        case .store:      return "bag.fill"
        case .agents:     return "person.3.fill"
        case .workflows:  return "point.3.connected.trianglepath.dotted"
        case .settings:   return "gearshape.fill"
        }
    }
}

// MARK: - SidebarSessionRow

struct SidebarSessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    var icon: String = "message"
    var accentColor: Color = .koboldEmerald
    let onTap: () -> Void
    let onDelete: () -> Void

    init(session: ChatSession, isCurrent: Bool, icon: String = "message", accentColor: Color = .koboldEmerald,
         onTap: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.session = session
        self.isCurrent = isCurrent
        self.icon = icon
        self.accentColor = accentColor
        self.onTap = onTap
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundColor(isCurrent ? accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(isCurrent ? accentColor : .primary)
                            .lineLimit(1)
                        Text(session.formattedDate)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(isCurrent ? Color.koboldSurface : Color.clear)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.trailing, 8)
            }
            .buttonStyle(.plain)
            .opacity(isCurrent ? 1 : 0)
        }
        .cornerRadius(6)
        .padding(.horizontal, 4)
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
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? .koboldGold : .secondary)
                        Text(project.name)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .koboldGold : .primary)
                            .lineLimit(1)
                    }
                    Text(project.formattedDate)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(isSelected ? Color.koboldSurface : Color.clear)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
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

    var body: some View {
        Group {
            switch selectedTab {
            case .chat:
                if runtimeManager.healthStatus == "OK" {
                    ChatView(viewModel: viewModel)
                } else {
                    ChatLockedView(status: runtimeManager.healthStatus)
                }
            case .dashboard:  DashboardView(viewModel: viewModel)
            case .memory:     MemoryView(viewModel: viewModel)
            case .tasks:      TasksView(viewModel: viewModel)
            case .store:      StoreView()
            case .agents:     AgentsView(viewModel: viewModel)
            case .workflows:  TeamView(viewModel: viewModel)
            case .settings:   SettingsView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Locked State

struct ChatLockedView: View {
    let status: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
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
    case dashboard
    case chat
    case tasks
    case workflows
    case memory
    case store
    case agents
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

            // Glow pulse
            Ellipse()
                .fill(Color.koboldEmerald.opacity(glowPulse ? 0.12 : 0.06))
                .frame(width: 120, height: 20)
                .blur(radius: 8)
                .offset(y: 12)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: glowPulse)

            // Main content
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("KoboldOS")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.koboldGold, Color(hex: "#FFE566"), Color.koboldEmerald],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: Color.koboldEmerald.opacity(0.8), radius: glowPulse ? 6 : 3)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: glowPulse)

                    Text("Alpha v0.2.3")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.koboldGold)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Capsule().fill(Color.koboldGold.opacity(0.2)))
                        .overlay(Capsule().stroke(Color.koboldGold.opacity(0.4), lineWidth: 0.5))
                }

                if !userName.isEmpty {
                    Text(userName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.koboldEmerald.opacity(0.7))
                        .tracking(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .onAppear { glowPulse = true }
    }
}
