import SwiftUI

// MARK: - TeamsGroupView
// Beratungsgremium: Mehrere AI-Agenten diskutieren parallel, widersprechen sich, und der Koordinator fasst zusammen.
// Rundenbasiertes Diskussionsprotokoll: R1 Einzelanalyse → R2 Diskussion → R3 Synthese

struct TeamsGroupView: View {
    @ObservedObject var viewModel: RuntimeViewModel

    @State private var selectedTeamId: UUID? = nil
    @State private var showAddTeam = false
    @State private var showOrgChart = false
    @State private var groupChatInput: String = ""
    @State private var isTeamWorking = false
    @State private var editingAgent: TeamAgent? = nil
    @State private var editingTeamGoals = false
    @AppStorage("kobold.chat.fontSize") private var chatFontSize: Double = 16.5
    @State private var showAgentSteps: Bool = true

    var body: some View {
        HSplitView {
            teamListPanel
                .frame(minWidth: 240, maxWidth: 300)

            if let team = selectedTeam {
                if showOrgChart {
                    orgChartView(team: team)
                } else {
                    groupChatView(team: team)
                }
            } else {
                emptyState
            }
        }
        .onAppear { viewModel.loadTeams() }
    }

    private var selectedTeam: AgentTeam? {
        viewModel.teams.first { $0.id == selectedTeamId }
    }

    // MARK: - Team List

    private var teamListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Teams").font(.system(size: 18.5, weight: .bold))
                Spacer()
                Button(action: { showAddTeam = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            GlassDivider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(viewModel.teams) { team in
                        teamRow(team)
                    }
                }
                .padding(8)
            }
        }
        .background(Color.koboldPanel.opacity(0.5))
        .sheet(isPresented: $showAddTeam) {
            AddTeamSheet { newTeam in
                viewModel.teams.append(newTeam)
                viewModel.saveTeams()
                selectedTeamId = newTeam.id
            }
        }
    }

    private func teamRow(_ team: AgentTeam) -> some View {
        Button(action: { selectedTeamId = team.id; showOrgChart = false }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.koboldEmerald.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: team.icon).font(.system(size: 15)).foregroundColor(.koboldEmerald)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    Text("\(team.agents.count) Agenten").font(.system(size: 12.5)).foregroundColor(.secondary)
                }
                Spacer()
                if selectedTeamId == team.id {
                    Circle().fill(Color.koboldEmerald).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTeamId == team.id ? Color.koboldEmerald.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Löschen", role: .destructive) {
                viewModel.teams.removeAll { $0.id == team.id }
                viewModel.saveTeams()
                if selectedTeamId == team.id { selectedTeamId = nil }
            }
        }
    }

    // MARK: - Group Chat

    private func groupChatView(team: AgentTeam) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: team.icon).font(.system(size: 18)).foregroundColor(.koboldEmerald)
                Text(team.name).font(.system(size: 18.5, weight: .bold))
                Spacer()
                if isTeamWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Team berät...").font(.system(size: 13.5)).foregroundColor(.koboldGold)
                    }
                }
                Button(action: { showOrgChart = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.dots.scatter").font(.system(size: 13.5))
                        Text("Organigramm").font(.system(size: 13.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.koboldGold.opacity(0.15))
                    .foregroundColor(.koboldGold)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            GlassDivider()

            // Agent badges with status
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(team.agents) { agent in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(agent.isActive ? Color.koboldEmerald : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(agent.name).font(.system(size: 13.5, weight: .medium))
                            Text("·").foregroundColor(.secondary)
                            Text(agent.role).font(.system(size: 12.5)).foregroundColor(.secondary)
                            Text("(\(agent.profile))").font(.system(size: 11.5)).foregroundColor(.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            GlassDivider()

            // Messages
            let messages = viewModel.teamMessages[team.id] ?? []
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            groupMessageBubble(msg)
                                .id(msg.id)
                        }
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
                                Text("Stelle eine Frage an das Team").font(.system(size: 15.5)).foregroundColor(.secondary)
                                Text("Die Agenten analysieren parallel, diskutieren untereinander und der Koordinator fasst zusammen.").font(.caption).foregroundColor(.secondary.opacity(0.7)).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Input bar with controls
            HStack(spacing: 8) {
                // Clear chat
                Button(action: { clearTeamChat(teamId: team.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Chat leeren")

                // Show/hide round indicators
                Button(action: { showAgentSteps.toggle() }) {
                    Image(systemName: showAgentSteps ? "brain.fill" : "brain")
                        .font(.system(size: 15))
                        .foregroundColor(showAgentSteps ? .koboldGold : .secondary)
                        .frame(width: 30, height: 32)
                        .background(Color.koboldSurface.opacity(0.4))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help(showAgentSteps ? "Runden-Info ausblenden" : "Runden-Info einblenden")

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

                // Text input
                TextField("Frage an das Team...", text: $groupChatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(10)
                    .onSubmit { sendGroupMessage(team: team) }
                    .disabled(isTeamWorking)

                // Send / Stop
                if isTeamWorking {
                    Button(action: { isTeamWorking = false }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Diskussion abbrechen")
                } else {
                    Button(action: { sendGroupMessage(team: team) }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.koboldEmerald)
                    }
                    .buttonStyle(.plain)
                    .disabled(groupChatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Nachricht senden")
                }
            }
            .padding(12)
        }
    }

    private func groupMessageBubble(_ msg: GroupMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.isUser {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(msg.content)
                        .font(.system(size: CGFloat(chatFontSize)))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.koboldEmerald.opacity(0.15))
                        .cornerRadius(12)
                    Text(msg.timestamp, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                ZStack {
                    let isCoord = msg.agentName == "Koordinator" || msg.round == 3
                    Circle().fill((isCoord ? Color.koboldGold : Color.koboldEmerald).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Text(String(msg.agentName.prefix(1)))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(isCoord ? .koboldGold : .koboldEmerald)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(msg.agentName).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldGold)
                        if showAgentSteps {
                            roundBadge(msg.round)
                        }
                    }
                    if msg.isStreaming {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Analysiert...").font(.system(size: CGFloat(chatFontSize))).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                    } else {
                        Text(msg.content)
                            .font(.system(size: CGFloat(chatFontSize)))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(msg.round == 3 ? Color.koboldGold.opacity(0.06) : Color.white.opacity(0.04))
                            .cornerRadius(12)
                    }
                    Text(msg.timestamp, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func roundBadge(_ round: Int) -> some View {
        let (label, color): (String, Color) = {
            switch round {
            case 1: return ("Analyse", .koboldEmerald)
            case 2: return ("Diskussion", .orange)
            case 3: return ("Synthese", .koboldGold)
            default: return ("", .clear)
            }
        }()
        if !label.isEmpty {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }

    private func clearTeamChat(teamId: UUID) {
        viewModel.teamMessages[teamId] = []
        viewModel.saveTeamMessages(for: teamId)
    }

    // MARK: - Team Discourse Engine

    private func sendGroupMessage(team: AgentTeam) {
        let text = groupChatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        let teamId = team.id
        appendMessage(teamId: teamId, msg: GroupMessage(content: text, isUser: true, agentName: "Du", round: 0))
        groupChatInput = ""
        isTeamWorking = true

        let activeAgents = team.agents.filter { $0.isActive }
        guard !activeAgents.isEmpty else {
            appendMessage(teamId: teamId, msg: GroupMessage(content: "Keine aktiven Agenten im Team.", isUser: false, agentName: "System", round: 0))
            isTeamWorking = false
            return
        }

        // Add streaming placeholders for Round 1
        var placeholderIds: [UUID: UUID] = [:]
        for agent in activeAgents {
            let placeholder = GroupMessage(content: "", isUser: false, agentName: agent.name, round: 1, isStreaming: true)
            placeholderIds[agent.id] = placeholder.id
            appendMessage(teamId: teamId, msg: placeholder)
        }

        Task {
            // === RUNDE 1: Einzelanalyse (parallel) ===
            var round1Results: [(agentName: String, agentId: UUID, output: String)] = []
            await withTaskGroup(of: (UUID, String, String).self) { group in
                for agent in activeAgents {
                    group.addTask {
                        let prompt = """
                        Du bist \(agent.name) (\(agent.role)) in einem Beratungsteam.
                        Deine Anweisungen: \(agent.instructions)

                        Der Nutzer fragt: \(text)

                        Analysiere die Frage aus deiner Perspektive. Sei konkret und präzise. Antworte auf Deutsch.
                        """
                        let result = await viewModel.sendTeamAgentMessage(prompt: prompt, profile: agent.profile)
                        return (agent.id, agent.name, result)
                    }
                }
                for await (agentId, agentName, output) in group {
                    round1Results.append((agentName: agentName, agentId: agentId, output: output))
                    // Replace placeholder with real result
                    if let phId = placeholderIds[agentId] {
                        await MainActor.run {
                            replacePlaceholder(teamId: teamId, placeholderId: phId, content: output, round: 1)
                        }
                    }
                }
            }

            // === RUNDE 2: Diskussion (sequentiell — jeder sieht Runde 1) ===
            let r1Summary = round1Results.map { "[\($0.agentName)]: \($0.output)" }.joined(separator: "\n\n---\n\n")

            for agent in activeAgents {
                let myR1 = round1Results.first { $0.agentId == agent.id }?.output ?? ""
                let othersR1 = round1Results.filter { $0.agentId != agent.id }
                    .map { "[\($0.agentName)]: \($0.output)" }.joined(separator: "\n\n")

                guard !othersR1.isEmpty else { continue }

                let prompt = """
                Du bist \(agent.name) (\(agent.role)).

                Die Frage war: \(text)

                Deine erste Analyse: \(myR1)

                Die anderen Teammitglieder haben Folgendes gesagt:
                \(othersR1)

                Reagiere kurz: Stimmst du zu? Widersprichst du? Was fehlt? Sei direkt und konstruktiv. Antworte auf Deutsch.
                """
                let discussionResult = await viewModel.sendTeamAgentMessage(prompt: prompt, profile: agent.profile)
                await MainActor.run {
                    appendMessage(teamId: teamId, msg: GroupMessage(content: discussionResult, isUser: false, agentName: agent.name, round: 2))
                }
            }

            // === RUNDE 3: Koordinator-Synthese ===
            let coordinator = activeAgents[0]
            let r2Messages = (viewModel.teamMessages[teamId] ?? []).filter { $0.round == 2 }
            let r2Summary = r2Messages.map { "[\($0.agentName)]: \($0.content)" }.joined(separator: "\n\n")

            let synthesisPrompt = """
            Du bist \(coordinator.name) und fasst die Team-Beratung zusammen.

            Ursprüngliche Frage: \(text)

            Runde 1 — Einzelanalysen:
            \(r1Summary)

            Runde 2 — Diskussion:
            \(r2Summary)

            Fasse zusammen:
            1. Konsens: Worüber sind sich alle einig?
            2. Offene Punkte: Wo gibt es Widersprüche oder Unsicherheit?
            3. Empfehlung: Was ist die beste Handlungsempfehlung?

            Sei strukturiert und klar. Antworte auf Deutsch.
            """
            let synthesis = await viewModel.sendTeamAgentMessage(prompt: synthesisPrompt, profile: coordinator.profile)
            await MainActor.run {
                appendMessage(teamId: teamId, msg: GroupMessage(content: synthesis, isUser: false, agentName: "Koordinator", round: 3))
                isTeamWorking = false
                viewModel.saveTeamMessages(for: teamId)
            }
        }
    }

    private func appendMessage(teamId: UUID, msg: GroupMessage) {
        if viewModel.teamMessages[teamId] == nil {
            viewModel.teamMessages[teamId] = []
        }
        viewModel.teamMessages[teamId]?.append(msg)
    }

    private func replacePlaceholder(teamId: UUID, placeholderId: UUID, content: String, round: Int) {
        guard var msgs = viewModel.teamMessages[teamId],
              let idx = msgs.firstIndex(where: { $0.id == placeholderId }) else { return }
        msgs[idx] = GroupMessage(
            id: placeholderId,
            content: content,
            isUser: false,
            agentName: msgs[idx].agentName,
            timestamp: msgs[idx].timestamp,
            round: round,
            isStreaming: false
        )
        viewModel.teamMessages[teamId] = msgs
    }

    // MARK: - Org Chart (erweitert: Ziele, Aufgaben, Status, Workflow-Flow)

    private func orgChartView(team: AgentTeam) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { showOrgChart = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13.5))
                        Text("Zurück zum Chat").font(.system(size: 13.5))
                    }
                    .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Organigramm — \(team.name)")
                    .font(.system(size: 18.5, weight: .bold))
                Spacer()
                Button(action: { editingTeamGoals = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "target").font(.system(size: 13.5))
                        Text("Ziele").font(.system(size: 13.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.koboldEmerald.opacity(0.15))
                    .foregroundColor(.koboldEmerald)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            GlassDivider()

            ScrollView {
                VStack(spacing: 16) {
                    // Team goals
                    if !team.goals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Team-Ziele").font(.system(size: 13.5, weight: .semibold)).foregroundColor(.koboldGold)
                            ForEach(team.goals, id: \.self) { goal in
                                HStack(spacing: 6) {
                                    Image(systemName: "target").font(.system(size: 12)).foregroundColor(.koboldEmerald)
                                    Text(goal).font(.system(size: 13.5)).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.koboldGold.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.koboldGold.opacity(0.15), lineWidth: 0.5))
                        .padding(.horizontal, 20)
                    }

                    // Team description
                    if !team.description.isEmpty {
                        Text(team.description)
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }

                    // Workflow flow indicator
                    flowIndicator(team: team)

                    // Leader
                    if let leader = team.agents.first {
                        orgNode(agent: leader, isLeader: true, team: team)
                    }

                    // Connection lines
                    if team.agents.count > 1 {
                        Rectangle()
                            .fill(Color.koboldEmerald.opacity(0.3))
                            .frame(width: 2, height: 30)
                    }

                    // Members
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(Array(team.agents.dropFirst())) { agent in
                            VStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.koboldEmerald.opacity(0.3))
                                    .frame(width: 2, height: 20)
                                orgNode(agent: agent, isLeader: false, team: team)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            }
        }
        .sheet(isPresented: $editingTeamGoals) {
            if let idx = viewModel.teams.firstIndex(where: { $0.id == team.id }) {
                TeamGoalsSheet(team: $viewModel.teams[idx]) {
                    viewModel.saveTeams()
                }
            }
        }
        .sheet(item: $editingAgent) { agent in
            if let teamIdx = viewModel.teams.firstIndex(where: { $0.id == team.id }),
               let agentIdx = viewModel.teams[teamIdx].agents.firstIndex(where: { $0.id == agent.id }) {
                AgentEditSheet(agent: $viewModel.teams[teamIdx].agents[agentIdx]) {
                    viewModel.saveTeams()
                }
            }
        }
    }

    private func flowIndicator(team: AgentTeam) -> some View {
        VStack(spacing: 4) {
            Text("Diskurs-Ablauf").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary.opacity(0.7))
            HStack(spacing: 4) {
                flowStep("Frage", icon: "questionmark.circle", color: .koboldEmerald)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                flowStep("R1: Analyse", icon: "brain", color: .koboldEmerald)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                flowStep("R2: Diskurs", icon: "bubble.left.and.bubble.right", color: .orange)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                flowStep("R3: Synthese", icon: "checkmark.seal", color: .koboldGold)
            }
        }
        .padding(.vertical, 8)
    }

    private func flowStep(_ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }

    private func orgNode(agent: TeamAgent, isLeader: Bool, team: AgentTeam) -> some View {
        Button(action: { editingAgent = agent }) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isLeader ? Color.koboldGold.opacity(0.2) : Color.koboldEmerald.opacity(0.15))
                        .frame(width: isLeader ? 60 : 48, height: isLeader ? 60 : 48)
                    Image(systemName: isLeader ? "crown.fill" : "person.fill")
                        .font(.system(size: isLeader ? 22 : 17))
                        .foregroundColor(isLeader ? .koboldGold : .koboldEmerald)
                }
                Text(agent.name)
                    .font(.system(size: 15.5, weight: .bold))
                Text(agent.role)
                    .font(.system(size: 13.5))
                    .foregroundColor(.koboldGold)

                // Profile badge
                Text(agent.profile)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.koboldEmerald)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.koboldEmerald.opacity(0.15)))

                Text(agent.instructions)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 180)
                    .lineLimit(3)

                // Status
                HStack(spacing: 4) {
                    Circle().fill(agent.isActive ? Color.koboldEmerald : Color.gray).frame(width: 6, height: 6)
                    Text(agent.isActive ? "Aktiv" : "Inaktiv")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isLeader ? Color.koboldGold.opacity(0.3) : Color.koboldEmerald.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Wähle ein Team aus")
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Teams sind Beratungsgremien — sie diskutieren, widersprechen sich und liefern qualitative Entscheidungen.")
                .font(.system(size: 14.5))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Models

struct AgentTeam: Identifiable, Codable {
    var id: UUID
    var name: String
    var icon: String
    var agents: [TeamAgent]
    var description: String
    var goals: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, icon: String, agents: [TeamAgent], description: String, goals: [String] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.icon = icon; self.agents = agents
        self.description = description; self.goals = goals; self.createdAt = createdAt
    }

    static let defaults: [AgentTeam] = [
        AgentTeam(
            name: "Recherche-Team",
            icon: "magnifyingglass.circle.fill",
            agents: [
                TeamAgent(name: "Koordinator", role: "Teamleiter", instructions: "Plant und delegiert Aufgaben, fasst Ergebnisse zusammen.", profile: "planner"),
                TeamAgent(name: "Web-Analyst", role: "Researcher", instructions: "Durchsucht das Web nach relevanten Informationen.", profile: "researcher"),
                TeamAgent(name: "Fakten-Checker", role: "Validator", instructions: "Prüft Quellen und verifiziert Behauptungen.", profile: "researcher"),
            ],
            description: "Parallele Web-Recherche mit Validierung",
            goals: ["Gründliche Quellenprüfung", "Faktenbasierte Ergebnisse"]
        ),
        AgentTeam(
            name: "Code-Team",
            icon: "chevron.left.forwardslash.chevron.right",
            agents: [
                TeamAgent(name: "Architekt", role: "Lead Developer", instructions: "Entwirft die Architektur und verteilt Coding-Tasks.", profile: "planner"),
                TeamAgent(name: "Frontend", role: "UI/UX Dev", instructions: "Implementiert die Benutzeroberfläche.", profile: "coder"),
                TeamAgent(name: "Backend", role: "API Dev", instructions: "Implementiert Server-Logik und Datenbank.", profile: "coder"),
                TeamAgent(name: "Tester", role: "QA", instructions: "Schreibt Tests und prüft auf Bugs.", profile: "coder"),
            ],
            description: "Full-Stack-Entwicklung mit parallelen Agents",
            goals: ["Saubere Architektur", "Testabdeckung > 80%"]
        ),
        AgentTeam(
            name: "Content-Team",
            icon: "doc.richtext.fill",
            agents: [
                TeamAgent(name: "Editor", role: "Chefredakteur", instructions: "Koordiniert und redigiert alle Inhalte.", profile: "planner"),
                TeamAgent(name: "Texter", role: "Autor", instructions: "Schreibt Texte, Artikel und Blogposts.", profile: "general"),
                TeamAgent(name: "Designer", role: "Grafiker", instructions: "Erstellt Bilder und Illustrationen.", profile: "general"),
            ],
            description: "Content-Erstellung mit Text und Bild",
            goals: ["Konsistenter Tonfall", "SEO-optimiert"]
        ),
    ]
}

struct TeamAgent: Identifiable, Codable {
    var id: UUID
    var name: String
    var role: String
    var instructions: String
    var profile: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, role: String, instructions: String, profile: String = "general", isActive: Bool = true) {
        self.id = id; self.name = name; self.role = role
        self.instructions = instructions; self.profile = profile; self.isActive = isActive
    }
}

struct GroupMessage: Identifiable, Codable {
    var id: UUID
    let content: String
    let isUser: Bool
    let agentName: String
    let timestamp: Date
    var round: Int
    var isStreaming: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool, agentName: String, timestamp: Date = Date(), round: Int = 0, isStreaming: Bool = false) {
        self.id = id; self.content = content; self.isUser = isUser
        self.agentName = agentName; self.timestamp = timestamp
        self.round = round; self.isStreaming = isStreaming
    }
}

// MARK: - AddTeamSheet

struct AddTeamSheet: View {
    let onSave: (AgentTeam) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var agents: [TeamAgent] = [
        TeamAgent(name: "Koordinator", role: "Teamleiter", instructions: "Koordiniert das Team und fasst Ergebnisse zusammen.", profile: "planner")
    ]

    private let profiles = ["general", "researcher", "coder", "planner"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neues Team erstellen").font(.system(size: 19, weight: .bold))

            TextField("Team-Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15.5))

            TextField("Beschreibung (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14.5))

            Text("Agenten").font(.system(size: 15.5, weight: .semibold))

            ForEach($agents) { $agent in
                HStack(spacing: 8) {
                    TextField("Name", text: $agent.name).textFieldStyle(.roundedBorder).frame(width: 100)
                    TextField("Rolle", text: $agent.role).textFieldStyle(.roundedBorder).frame(width: 100)
                    Picker("", selection: $agent.profile) {
                        Text("Allgemein").tag("general")
                        Text("Researcher").tag("researcher")
                        Text("Coder").tag("coder")
                        Text("Planner").tag("planner")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    TextField("Anweisung", text: $agent.instructions).textFieldStyle(.roundedBorder)
                }
                .font(.system(size: 14.5))
            }

            Button(action: { agents.append(TeamAgent(name: "Agent \(agents.count + 1)", role: "Mitarbeiter", instructions: "")) }) {
                Label("Agent hinzufügen", systemImage: "plus")
                    .font(.system(size: 14.5))
                    .foregroundColor(.koboldEmerald)
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.bordered)
                Button("Erstellen") {
                    let team = AgentTeam(name: name.isEmpty ? "Neues Team" : name, icon: "person.3.fill", agents: agents, description: description)
                    onSave(team)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.koboldEmerald)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 650)
    }
}

// MARK: - Team Goals Sheet

struct TeamGoalsSheet: View {
    @Binding var team: AgentTeam
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newGoal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Team-Ziele — \(team.name)").font(.system(size: 19, weight: .bold))
            Text("Ziele steuern die Perspektive und Prioritäten der Agenten im Diskurs.")
                .font(.caption).foregroundColor(.secondary)

            ForEach(Array(team.goals.enumerated()), id: \.offset) { idx, goal in
                HStack {
                    Image(systemName: "target").foregroundColor(.koboldEmerald)
                    Text(goal).font(.system(size: 14.5))
                    Spacer()
                    Button(action: { team.goals.remove(at: idx); onSave() }) {
                        Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Neues Ziel...", text: $newGoal)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addGoal() }
                Button("Hinzufügen") { addGoal() }
                    .buttonStyle(.bordered)
                    .disabled(newGoal.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldEmerald)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private func addGoal() {
        let g = newGoal.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return }
        team.goals.append(g)
        newGoal = ""
        onSave()
    }
}

// MARK: - Agent Edit Sheet

struct AgentEditSheet: View {
    @Binding var agent: TeamAgent
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent bearbeiten").font(.system(size: 19, weight: .bold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption.bold()).foregroundColor(.secondary)
                    TextField("Name", text: $agent.name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rolle").font(.caption.bold()).foregroundColor(.secondary)
                    TextField("Rolle", text: $agent.role).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profil").font(.caption.bold()).foregroundColor(.secondary)
                    Picker("", selection: $agent.profile) {
                        Text("Allgemein").tag("general")
                        Text("Researcher").tag("researcher")
                        Text("Coder").tag("coder")
                        Text("Planner").tag("planner")
                    }
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Anweisungen").font(.caption.bold()).foregroundColor(.secondary)
                TextEditor(text: $agent.instructions)
                    .font(.system(size: 14.5))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(8)
            }

            Toggle("Aktiv", isOn: $agent.isActive)
                .toggleStyle(.switch)

            HStack {
                Spacer()
                Button("Fertig") { onSave(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldEmerald)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
