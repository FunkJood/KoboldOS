import SwiftUI

// MARK: - TeamsGroupView
// Parallele AI Agents in Gruppenchats, Organigramm mit Anweisungen

struct TeamsGroupView: View {
    @ObservedObject var viewModel: RuntimeViewModel

    @State private var teams: [AgentTeam] = AgentTeam.defaults
    @State private var selectedTeamId: UUID? = nil
    @State private var showAddTeam = false
    @State private var showOrgChart = false
    @State private var groupChatInput: String = ""
    @State private var groupMessages: [GroupMessage] = []

    var body: some View {
        HSplitView {
            // Left: Team list
            teamListPanel
                .frame(minWidth: 240, maxWidth: 300)

            // Right: Team detail or org chart
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
    }

    private var selectedTeam: AgentTeam? {
        teams.first { $0.id == selectedTeamId }
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
                    ForEach(teams) { team in
                        teamRow(team)
                    }
                }
                .padding(8)
            }
        }
        .background(Color.koboldPanel.opacity(0.5))
        .sheet(isPresented: $showAddTeam) {
            AddTeamSheet { newTeam in
                teams.append(newTeam)
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
    }

    // MARK: - Group Chat

    private func groupChatView(team: AgentTeam) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: team.icon).font(.system(size: 18)).foregroundColor(.koboldEmerald)
                Text(team.name).font(.system(size: 18.5, weight: .bold))
                Spacer()
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

            // Agent badges
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
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groupMessages) { msg in
                        groupMessageBubble(msg)
                    }
                    if groupMessages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
                            Text("Sende eine Nachricht an das Team").font(.system(size: 15.5)).foregroundColor(.secondary)
                            Text("Alle Agenten arbeiten parallel an deiner Anfrage.").font(.caption).foregroundColor(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(16)
            }

            // Input
            HStack(spacing: 10) {
                TextField("Nachricht an das Team...", text: $groupChatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(10)
                    .onSubmit { sendGroupMessage(team: team) }

                Button(action: { sendGroupMessage(team: team) }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .disabled(groupChatInput.trimmingCharacters(in: .whitespaces).isEmpty)
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
                        .font(.system(size: 15.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.koboldEmerald.opacity(0.15))
                        .cornerRadius(12)
                    Text(msg.timestamp, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                ZStack {
                    Circle().fill(Color.koboldGold.opacity(0.15)).frame(width: 28, height: 28)
                    Text(String(msg.agentName.prefix(1))).font(.system(size: 12.5, weight: .bold)).foregroundColor(.koboldGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg.agentName).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldGold)
                    Text(msg.content)
                        .font(.system(size: 15.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                    Text(msg.timestamp, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer(minLength: 60)
            }
        }
    }

    private func sendGroupMessage(team: AgentTeam) {
        let text = groupChatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        groupMessages.append(GroupMessage(content: text, isUser: true, agentName: "Du"))
        groupChatInput = ""

        // Simulate agent responses (Mock)
        for agent in team.agents {
            let delay = Double.random(in: 0.5...2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                groupMessages.append(GroupMessage(
                    content: "[\(agent.role)] Arbeite an: \(text.prefix(50))...",
                    isUser: false,
                    agentName: agent.name
                ))
            }
        }
    }

    // MARK: - Org Chart

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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            GlassDivider()

            ScrollView {
                VStack(spacing: 24) {
                    // Leader
                    if let leader = team.agents.first {
                        orgNode(agent: leader, isLeader: true)
                    }

                    // Connection lines
                    if team.agents.count > 1 {
                        Rectangle()
                            .fill(Color.koboldEmerald.opacity(0.3))
                            .frame(width: 2, height: 30)
                    }

                    // Members
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(team.agents.dropFirst()) { agent in
                            VStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.koboldEmerald.opacity(0.3))
                                    .frame(width: 2, height: 20)
                                orgNode(agent: agent, isLeader: false)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            }
        }
    }

    private func orgNode(agent: TeamAgent, isLeader: Bool) -> some View {
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
            Text(agent.instructions)
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 160)
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Wähle ein Team aus")
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Oder erstelle ein neues Team mit parallelen AI-Agenten.")
                .font(.system(size: 14.5))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Models

struct AgentTeam: Identifiable {
    let id = UUID()
    var name: String
    var icon: String
    var agents: [TeamAgent]
    var description: String

    static let defaults: [AgentTeam] = [
        AgentTeam(
            name: "Recherche-Team",
            icon: "magnifyingglass.circle.fill",
            agents: [
                TeamAgent(name: "Koordinator", role: "Teamleiter", instructions: "Plant und delegiert Aufgaben, fasst Ergebnisse zusammen."),
                TeamAgent(name: "Web-Analyst", role: "Researcher", instructions: "Durchsucht das Web nach relevanten Informationen."),
                TeamAgent(name: "Fakten-Checker", role: "Validator", instructions: "Prüft Quellen und verifiziert Behauptungen."),
            ],
            description: "Parallele Web-Recherche mit Validierung"
        ),
        AgentTeam(
            name: "Code-Team",
            icon: "chevron.left.forwardslash.chevron.right",
            agents: [
                TeamAgent(name: "Architekt", role: "Lead Developer", instructions: "Entwirft die Architektur und verteilt Coding-Tasks."),
                TeamAgent(name: "Frontend", role: "UI/UX Dev", instructions: "Implementiert die Benutzeroberfläche."),
                TeamAgent(name: "Backend", role: "API Dev", instructions: "Implementiert Server-Logik und Datenbank."),
                TeamAgent(name: "Tester", role: "QA", instructions: "Schreibt Tests und prüft auf Bugs."),
            ],
            description: "Full-Stack-Entwicklung mit parallelen Agents"
        ),
        AgentTeam(
            name: "Content-Team",
            icon: "doc.richtext.fill",
            agents: [
                TeamAgent(name: "Editor", role: "Chefredakteur", instructions: "Koordiniert und redigiert alle Inhalte."),
                TeamAgent(name: "Texter", role: "Autor", instructions: "Schreibt Texte, Artikel und Blogposts."),
                TeamAgent(name: "Designer", role: "Grafiker", instructions: "Erstellt Bilder und Illustrationen."),
            ],
            description: "Content-Erstellung mit Text und Bild"
        ),
    ]
}

struct TeamAgent: Identifiable {
    let id = UUID()
    var name: String
    var role: String
    var instructions: String
    var isActive: Bool = true
}

struct GroupMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let agentName: String
    let timestamp: Date = Date()
}

// MARK: - AddTeamSheet

struct AddTeamSheet: View {
    let onSave: (AgentTeam) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var agents: [TeamAgent] = [
        TeamAgent(name: "Agent 1", role: "Teamleiter", instructions: "Koordiniert das Team.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neues Team erstellen").font(.system(size: 19, weight: .bold))

            TextField("Team-Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15.5))

            Text("Agenten").font(.system(size: 15.5, weight: .semibold))

            ForEach($agents) { $agent in
                HStack(spacing: 8) {
                    TextField("Name", text: $agent.name).textFieldStyle(.roundedBorder).frame(width: 100)
                    TextField("Rolle", text: $agent.role).textFieldStyle(.roundedBorder).frame(width: 100)
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
                    let team = AgentTeam(name: name.isEmpty ? "Neues Team" : name, icon: "person.3.fill", agents: agents, description: "")
                    onSave(team)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.koboldEmerald)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 550)
    }
}
