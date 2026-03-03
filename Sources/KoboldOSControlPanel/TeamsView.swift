import SwiftUI

// MARK: - Team Models

public struct TeamMember: Identifiable, Codable {
    public var id: String = UUID().uuidString
    public var name: String
    public var role: String
    public var systemPrompt: String
}

public struct ManagedTeam: Identifiable, Codable {
    public var id: String = UUID().uuidString
    public var name: String
    public var description: String
    public var routing: String
    public var members: [TeamMember]
}

enum RoutingMode: String, CaseIterable, Identifiable {
    case sequential = "sequential"
    case leader = "leader"
    case roundRobin = "round-robin"
    var id: String { rawValue }
    var label: String {
        switch self { case .sequential: return "Sequenziell"; case .leader: return "Leader"; case .roundRobin: return "Round-Robin" }
    }
    var icon: String {
        switch self { case .sequential: return "arrow.right.arrow.left"; case .leader: return "crown.fill"; case .roundRobin: return "arrow.triangle.2.circlepath" }
    }
    var color: Color {
        switch self { case .sequential: return .blue; case .leader: return .orange; case .roundRobin: return .green }
    }
}

// MARK: - TeamsView

struct TeamsView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var teams: [ManagedTeam] = []
    @State private var isLoading = false
    @State private var errorMsg = ""
    @State private var expandedTeamId: String? = nil
    @State private var showSheet = false
    @State private var editingTeam: ManagedTeam? = nil
    @State private var formName = ""
    @State private var formDesc = ""
    @State private var formRouting: RoutingMode = .sequential
    @State private var showAddMember = false
    @State private var editingMemberId: String? = nil
    @State private var memberName = ""
    @State private var memberRole = ""
    @State private var memberPrompt = ""
    @State private var teamToDelete: ManagedTeam? = nil
    @State private var chatTeam: ManagedTeam? = nil
    // Persistenter Message-Cache: Team-ID → Messages (bleiben beim Schließen/Öffnen erhalten)
    @State private var teamChatCache: [String: [TeamChatMessage]] = [:]

    private var isEditing: Bool { editingTeam != nil }
    private var sheetBg: some View {
        ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) }
    }

    private var lang: AppLanguage { l10n.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lang.teamsTitle).font(.title2.bold())
                        Text(lang.teamsSubtitle).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    GlassButton(title: lang.newTeam, icon: "plus", isPrimary: true) { resetForm(); showSheet = true }
                    GlassButton(title: lang.refresh, icon: "arrow.clockwise", isPrimary: false) { Task { await loadTeams() } }
                }
                if !errorMsg.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(errorMsg).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button(lang.retry) { Task { await loadTeams() } }.font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                if isLoading {
                    GlassProgressBar(value: 0.5, label: lang.loading).padding(.horizontal, 4)
                } else if teams.isEmpty && errorMsg.isEmpty {
                    GlassCard {
                        VStack(spacing: 16) {
                            Image(systemName: "person.3.fill").font(.system(size: 40)).foregroundColor(.secondary)
                            Text(lang.noTeams).font(.headline)
                            Text(lang.noTeamsDesc)
                                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                            GlassButton(title: lang.createFirstTeam, icon: "plus", isPrimary: true) { resetForm(); showSheet = true }
                        }.frame(maxWidth: .infinity).padding()
                    }
                } else {
                    ForEach(teams) { team in teamCard(team) }
                }
            }.padding(24)
        }
        .background(sheetBg)
        .task { await loadTeams() }
        .sheet(isPresented: $showSheet) { teamFormSheet }
        .alert(lang.deleteTeamQ, isPresented: .init(get: { teamToDelete != nil }, set: { if !$0 { teamToDelete = nil } })) {
            Button(lang.cancel, role: .cancel) { teamToDelete = nil }
            Button(lang.delete, role: .destructive) { if let t = teamToDelete { Task { await deleteTeam(t) } } }
        } message: { Text(teamToDelete?.name ?? "") }
        .sheet(item: $chatTeam) { team in
            TeamChatView(team: team, viewModel: viewModel,
                         cachedMessages: teamChatCache[team.id] ?? [],
                         onDismiss: { msgs in teamChatCache[team.id] = msgs })
        }
    }

    // MARK: - Team Card

    func teamCard(_ team: ManagedTeam) -> some View {
        let isExpanded = expandedTeamId == team.id
        let routing = RoutingMode(rawValue: team.routing) ?? .sequential
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(team.name).font(.system(size: 16.5, weight: .semibold))
                        if !team.description.isEmpty {
                            Text(team.description).font(.caption).foregroundColor(.secondary).lineLimit(isExpanded ? nil : 2)
                        }
                    }
                    Spacer()
                    routingBadge(routing)
                }
                HStack(spacing: 16) {
                    Label("\(team.members.count) \(lang.members)", systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Button(action: { chatTeam = team }) {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.cyan)
                    }.buttonStyle(.plain).help(lang.teamGroupChat)
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expandedTeamId = isExpanded ? nil : team.id } }) {
                        Label(isExpanded ? lang.collapse : lang.details, systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.koboldEmerald)
                    }.buttonStyle(.plain)
                    Button(action: { editingTeam = team; formName = team.name; formDesc = team.description; formRouting = routing; showSheet = true }) {
                        Label(lang.edit, systemImage: "pencil").font(.system(size: 13, weight: .medium)).foregroundColor(.koboldGold)
                    }.buttonStyle(.plain)
                    Button(action: { teamToDelete = team }) {
                        Label(lang.delete, systemImage: "trash").font(.system(size: 13, weight: .medium)).foregroundColor(.red)
                    }.buttonStyle(.plain)
                }
                if isExpanded {
                    Divider().background(Color.white.opacity(0.1))
                    GlassSectionHeader(title: lang.members, icon: "person.crop.rectangle.stack")
                    if team.members.isEmpty {
                        Text(lang.noTeamsDesc).font(.caption).foregroundColor(.secondary).padding(.vertical, 4)
                    } else {
                        ForEach(team.members) { member in memberRow(member, teamId: team.id) }
                    }
                    if showAddMember && editingTeam?.id == team.id {
                        addMemberForm(teamId: team.id)
                    } else {
                        GlassButton(title: lang.addMember, icon: "plus", isPrimary: false) {
                            editingTeam = team; resetMemberForm(); showAddMember = true
                        }
                    }
                }
            }
        }
    }

    func routingBadge(_ mode: RoutingMode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode.icon).font(.system(size: 11, weight: .semibold))
            Text(mode.label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(mode.color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(mode.color.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(mode.color.opacity(0.3), lineWidth: 0.5)))
    }

    // MARK: - Member Row & Form

    @ViewBuilder
    func memberRow(_ member: TeamMember, teamId: String) -> some View {
        if editingMemberId == member.id {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mitglied bearbeiten").font(.system(size: 13, weight: .semibold))
                GlassTextField(text: $memberName, placeholder: lang.memberNamePH)
                GlassTextField(text: $memberRole, placeholder: lang.memberRolePH)
                Text(lang.systemPrompt).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                TextEditor(text: $memberPrompt).font(.system(size: 14)).frame(minHeight: 60, maxHeight: 120)
                    .padding(6).background(Color.black.opacity(0.2)).cornerRadius(8).scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    GlassButton(title: lang.cancel, isPrimary: false) { editingMemberId = nil; resetMemberForm() }
                    GlassButton(title: "Speichern", icon: "checkmark", isPrimary: true,
                                isDisabled: memberName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await saveMember(memberId: member.id, teamId: teamId) }
                    }
                }
            }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cpu.fill").font(.system(size: 14)).foregroundColor(.koboldEmerald).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.name).font(.system(size: 14.5, weight: .semibold))
                        Text(member.role).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                    }
                    if !member.systemPrompt.isEmpty {
                        Text(member.systemPrompt).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Button(action: {
                    memberName = member.name; memberRole = member.role; memberPrompt = member.systemPrompt
                    showAddMember = false; editingMemberId = member.id
                }) {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 16)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Bearbeiten")
                Button(action: { Task { await removeMember(memberId: member.id, teamId: teamId) } }) {
                    Image(systemName: "minus.circle.fill").font(.system(size: 16)).foregroundColor(.red.opacity(0.7))
                }.buttonStyle(.plain).help(lang.removeMember)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        }
    }

    func addMemberForm(teamId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.newMember).font(.system(size: 14.5, weight: .semibold))
            GlassTextField(text: $memberName, placeholder: lang.memberNamePH)
            GlassTextField(text: $memberRole, placeholder: lang.memberRolePH)
            Text(lang.systemPrompt).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            TextEditor(text: $memberPrompt).font(.system(size: 14)).frame(minHeight: 60, maxHeight: 120)
                .padding(6).background(Color.black.opacity(0.2)).cornerRadius(8).scrollContentBackground(.hidden)
            HStack {
                Spacer()
                GlassButton(title: lang.cancel, isPrimary: false) { showAddMember = false; resetMemberForm() }
                GlassButton(title: lang.addItem, icon: "plus", isPrimary: true,
                            isDisabled: memberName.trimmingCharacters(in: .whitespaces).isEmpty) { Task { await addMember(teamId: teamId) } }
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Team Form Sheet (Create & Edit)

    var teamFormSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(isEditing ? lang.editTeam : lang.newTeam).font(.title3.bold())
                    Spacer()
                    Button(action: { showSheet = false; resetForm() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                    }.buttonStyle(.plain)
                }.padding(.top, 20)
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.teamName).font(.system(size: 14.5, weight: .semibold))
                    GlassTextField(text: $formName, placeholder: "z.B. Research Team")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.description_).font(.system(size: 14.5, weight: .semibold))
                    GlassTextField(text: $formDesc, placeholder: "Was macht dieses Team?", isMultiline: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.routingMode).font(.system(size: 14.5, weight: .semibold))
                    Text(lang.routingDesc).font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(RoutingMode.allCases) { mode in
                            let sel = formRouting == mode
                            Button(action: { formRouting = mode }) {
                                HStack(spacing: 5) {
                                    Image(systemName: mode.icon).font(.system(size: 13))
                                    Text(mode.label).font(.system(size: 13.5, weight: sel ? .semibold : .regular))
                                }
                                .foregroundColor(sel ? mode.color : .secondary)
                                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(sel ? mode.color.opacity(0.15) : Color.white.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? mode.color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Spacer()
                    GlassButton(title: lang.cancel, isPrimary: false) { showSheet = false; resetForm() }
                    GlassButton(title: isEditing ? lang.save : lang.create, icon: isEditing ? "checkmark" : "plus", isPrimary: true,
                                isDisabled: formName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { isEditing ? await updateTeam() : await createTeam() }
                    }
                }
            }.padding(24)
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(sheetBg)
    }

    // MARK: - Helpers

    func resetForm() { formName = ""; formDesc = ""; formRouting = .sequential; editingTeam = nil }
    func resetMemberForm() { memberName = ""; memberRole = ""; memberPrompt = "" }

    // MARK: - API

    func loadTeams() async {
        guard viewModel.isConnected else { errorMsg = lang.daemonDisconnected; return }
        guard let url = URL(string: viewModel.baseURL + "/teams") else { errorMsg = lang.invalidUrl; return }
        isLoading = true; errorMsg = ""
        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                errorMsg = "Fehler beim Laden (Status \((resp as? HTTPURLResponse)?.statusCode ?? 0))"; isLoading = false; return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["teams"] as? [[String: Any]] { teams = arr.compactMap { parseTeam($0) } }
        } catch { errorMsg = "Netzwerkfehler: \(error.localizedDescription)" }
        isLoading = false
    }

    func createTeam() async {
        let name = formName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "create", "data": ["name": name, "description": formDesc.trimmingCharacters(in: .whitespaces),
                                          "routing": formRouting.rawValue, "members": [] as [[String: Any]]] as [String: Any]])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Erstellen fehlgeschlagen: \(error.localizedDescription)" }
        showSheet = false; resetForm(); await loadTeams()
    }

    func updateTeam() async {
        guard let team = editingTeam else { return }
        let name = formName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update", "id": team.id, "data": ["name": name, "description": formDesc.trimmingCharacters(in: .whitespaces),
                                                          "routing": formRouting.rawValue] as [String: Any]])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Aktualisierung fehlgeschlagen: \(error.localizedDescription)" }
        showSheet = false; resetForm(); await loadTeams()
    }

    func deleteTeam(_ team: ManagedTeam) async {
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "delete", "id": team.id])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Loeschen fehlgeschlagen: \(error.localizedDescription)" }
        teamToDelete = nil; await loadTeams()
    }

    func addMember(teamId: String) async {
        guard let team = teams.first(where: { $0.id == teamId }) else { return }
        let name = memberName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        var updated = team.members
        updated.append(TeamMember(name: name, role: memberRole.trimmingCharacters(in: .whitespaces), systemPrompt: memberPrompt.trimmingCharacters(in: .whitespaces)))
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update", "id": teamId, "data": ["members": updated.map { memberDict($0) }] as [String: Any]])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Mitglied hinzufuegen fehlgeschlagen: \(error.localizedDescription)" }
        showAddMember = false; resetMemberForm(); await loadTeams()
    }

    func saveMember(memberId: String, teamId: String) async {
        guard let team = teams.first(where: { $0.id == teamId }) else { return }
        let name = memberName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        let updated = team.members.map { m -> TeamMember in
            if m.id == memberId {
                return TeamMember(id: m.id, name: name, role: memberRole.trimmingCharacters(in: .whitespaces), systemPrompt: memberPrompt.trimmingCharacters(in: .whitespaces))
            }
            return m
        }
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update", "id": teamId, "data": ["members": updated.map { memberDict($0) }] as [String: Any]])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
        editingMemberId = nil; resetMemberForm(); await loadTeams()
    }

    func removeMember(memberId: String, teamId: String) async {
        guard let team = teams.first(where: { $0.id == teamId }) else { return }
        let updated = team.members.filter { $0.id != memberId }
        guard let url = URL(string: viewModel.baseURL + "/teams") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": "update", "id": teamId, "data": ["members": updated.map { memberDict($0) }] as [String: Any]])
        do { _ = try await URLSession.shared.data(for: req) } catch { errorMsg = "Entfernen fehlgeschlagen: \(error.localizedDescription)" }
        await loadTeams()
    }

    // MARK: - JSON Helpers

    func memberDict(_ m: TeamMember) -> [String: Any] { ["id": m.id, "name": m.name, "role": m.role, "systemPrompt": m.systemPrompt] }

    func parseTeam(_ dict: [String: Any]) -> ManagedTeam? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        let membersArr = dict["members"] as? [[String: Any]] ?? []
        return ManagedTeam(id: id, name: name, description: dict["description"] as? String ?? "",
                         routing: dict["routing"] as? String ?? "sequential", members: membersArr.compactMap { parseMember($0) })
    }

    func parseMember(_ dict: [String: Any]) -> TeamMember? {
        guard let name = dict["name"] as? String else { return nil }
        return TeamMember(id: dict["id"] as? String ?? UUID().uuidString, name: name,
                          role: dict["role"] as? String ?? "", systemPrompt: dict["systemPrompt"] as? String ?? "")
    }
}

// MARK: - Team Chat View

struct TeamChatMessage: Identifiable {
    let id = UUID()
    let agentName: String
    let content: String
    let timestamp: Date
    let isSystem: Bool
    let targetAgent: String?  // nil = System, "@Alle" = Gruppe, "Name" = direkt

    init(agentName: String, content: String, timestamp: Date = Date(), isSystem: Bool, targetAgent: String? = nil) {
        self.agentName = agentName; self.content = content; self.timestamp = timestamp
        self.isSystem = isSystem; self.targetAgent = targetAgent
    }
}

struct TeamChatView: View {
    let team: ManagedTeam
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var messages: [TeamChatMessage] = []
    @State private var taskInput = ""
    @State private var isRunning = false
    @State private var maxRounds: Double = 5
    @State private var selectedRouting: RoutingMode
    @State private var chatTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    // Typing Indicator
    @State private var typingAgent: String? = nil
    @State private var dotsPhase: Int = 0
    @State private var dotsTask: Task<Void, Never>? = nil

    // Zusätzliche Einstellungen
    @State private var outputLength: String = "normal" // "kurz", "normal", "ausfuehrlich"
    @State private var showSummary: Bool = true
    @State private var debateIntensity: String = "kritisch" // "konstruktiv", "kritisch", "aggressiv"
    @State private var showSettings = false

    // Persistenz
    var cachedMessages: [TeamChatMessage]
    var onDismiss: (([TeamChatMessage]) -> Void)?

    init(team: ManagedTeam, viewModel: RuntimeViewModel,
         cachedMessages: [TeamChatMessage] = [], onDismiss: (([TeamChatMessage]) -> Void)? = nil) {
        self.team = team
        self.viewModel = viewModel
        self.cachedMessages = cachedMessages
        self.onDismiss = onDismiss
        _selectedRouting = State(initialValue: RoutingMode(rawValue: team.routing) ?? .sequential)
        _messages = State(initialValue: cachedMessages)
    }

    private let agentColors: [Color] = [.cyan, .orange, .green, .purple, .pink, .yellow, .mint, .indigo]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.title2).foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name).font(.headline)
                    Text("\(team.members.count) Agenten · \(selectedRouting.label)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: -6) {
                    ForEach(Array(team.members.prefix(5).enumerated()), id: \.offset) { idx, member in
                        Text(String(member.name.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(agentColors[idx % agentColors.count]))
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    }
                }
                if !messages.isEmpty && !isRunning {
                    Button(action: { deliverResultToSession() }) {
                        Label("An Chat senden", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.cyan)
                    }.buttonStyle(.plain)
                }
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
                Button(action: { onDismiss?(messages); dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.black.opacity(0.3))

            Divider().background(Color.white.opacity(0.1))

            if messages.isEmpty && !isRunning {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "person.3.sequence.fill").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
                    Text(lang.teamGroupChat).font(.title3.bold())
                    Text(lang.teamChatDesc)
                        .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lang.routingModes).font(.system(size: 13, weight: .semibold))
                        routingExplanation(icon: "arrow.right.arrow.left", title: lang.sequential,
                            desc: lang.routingDesc, color: .blue)
                        routingExplanation(icon: "crown.fill", title: lang.leaderMode,
                            desc: lang.routingDesc, color: .orange)
                        routingExplanation(icon: "arrow.triangle.2.circlepath", title: lang.roundRobin,
                            desc: lang.routingDesc, color: .green)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
                    .frame(maxWidth: 450)
                    Spacer()
                }
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { msg in
                                chatBubble(msg).id(msg.id)
                            }
                            // Typing Indicator
                            if let agent = typingAgent {
                                HStack(alignment: .top, spacing: 10) {
                                    let idx = team.members.firstIndex(where: { $0.name == agent }) ?? 0
                                    Text(String(agent.prefix(1)).uppercased())
                                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(agentColors[idx % agentColors.count]))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(agent).font(.system(size: 13, weight: .semibold))
                                        HStack(spacing: 4) {
                                            ForEach(0..<3, id: \.self) { i in
                                                Circle().fill(Color.secondary)
                                                    .frame(width: 6, height: 6)
                                                    .opacity(dotsPhase == i ? 1.0 : 0.3)
                                            }
                                            Text("denkt nach...").font(.system(size: 12)).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
                                .id("typing")
                                .onAppear {
                                    dotsTask?.cancel()
                                    dotsTask = Task { @MainActor in
                                        while !Task.isCancelled && typingAgent != nil {
                                            try? await Task.sleep(nanoseconds: 400_000_000)
                                            if typingAgent != nil {
                                                withAnimation(.easeInOut(duration: 0.3)) { dotsPhase = (dotsPhase + 1) % 3 }
                                            }
                                        }
                                    }
                                }
                                .onDisappear { dotsTask?.cancel() }
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.1))

            // Eingabe
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Picker("", selection: $selectedRouting) {
                        ForEach(RoutingMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented).frame(width: 260).disabled(isRunning)

                    HStack(spacing: 6) {
                        Text(lang.rounds).font(.system(size: 12)).foregroundColor(.secondary)
                        Slider(value: $maxRounds, in: 1...5, step: 1).frame(width: 100).disabled(isRunning)
                        Text("\(Int(maxRounds))").font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 24)
                    }
                }

                HStack(spacing: 8) {
                    TextField(lang.taskForTeam, text: $taskInput)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                        .disabled(isRunning)
                        .onSubmit { if !taskInput.isEmpty && !isRunning { startChat() } }

                    Button(action: { isRunning ? stopChat() : startChat() }) {
                        Image(systemName: isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 16))
                            .foregroundColor(isRunning ? .red : .cyan)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(taskInput.trimmingCharacters(in: .whitespaces).isEmpty && !isRunning)
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.2))

            // Einstellungen (aufklappbar)
            if showSettings {
                Divider().background(Color.white.opacity(0.1))
                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Antwort-Laenge").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                            Picker("", selection: $outputLength) {
                                Text("Kurz").tag("kurz")
                                Text("Normal").tag("normal")
                                Text("Ausfuehrlich").tag("ausfuehrlich")
                            }.pickerStyle(.segmented).frame(width: 220)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Diskussions-Stil").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                            Picker("", selection: $debateIntensity) {
                                Text("Konstruktiv").tag("konstruktiv")
                                Text("Kritisch").tag("kritisch")
                                Text("Aggressiv").tag("aggressiv")
                            }.pickerStyle(.segmented).frame(width: 220)
                        }
                        Toggle("Zusammenfassung", isOn: $showSummary)
                            .toggleStyle(.switch).font(.system(size: 12))
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.15))
            }
        }
        .frame(minWidth: 800, minHeight: 650)
        .background(
            ZStack {
                Color(nsColor: NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
                LinearGradient(colors: [Color.cyan.opacity(0.015), .clear, Color.purple.opacity(0.01)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
    }

    // MARK: - Chat Bubble (mit Adressierung)

    private func chatBubble(_ msg: TeamChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if msg.isSystem {
                Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                let idx = team.members.firstIndex(where: { $0.name == msg.agentName }) ?? 0
                Text(String(msg.agentName.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(agentColors[idx % agentColors.count]))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(msg.agentName).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(msg.isSystem ? .secondary : .primary)
                    // Adressierung anzeigen
                    if let target = msg.targetAgent {
                        HStack(spacing: 2) {
                            Image(systemName: target == "@Alle" ? "person.3.fill" : "arrowshape.turn.up.right.fill")
                                .font(.system(size: 9))
                            Text(target).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(target == "@Alle" ? .cyan.opacity(0.8) : .orange.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    Spacer()
                    Text(formatTime(msg.timestamp)).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text(msg.content).font(.system(size: 14))
                    .foregroundColor(msg.isSystem ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(msg.isSystem ? Color.white.opacity(0.02) : Color.white.opacity(0.04)))
    }

    private func routingExplanation(icon: String, title: String, desc: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
                Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date)
    }

    // MARK: - Start / Stop

    private func startChat() {
        guard !taskInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let task = taskInput
        taskInput = ""
        isRunning = true
        chatTask = Task { await runTeamDebate(task: task) }
    }

    private func stopChat() {
        chatTask?.cancel()
        chatTask = nil
        isRunning = false
        messages.append(TeamChatMessage(agentName: "System", content: "Diskussion vom User gestoppt.", isSystem: true))
    }

    // MARK: - Team Debate Engine

    /// Kritisches Debatt-Verhalten — Agents MÜSSEN widersprechen, korrigieren, hinterfragen
    private func buildTeamPrompt(member: TeamMember, task: String, context: String,
                                  addressTo: String, memberList: String) -> String {
        let intensityRules: String
        switch debateIntensity {
        case "konstruktiv":
            intensityRules = """
            - Sei konstruktiv und loesungsorientiert. Baue auf Vorschlaegen anderer auf.
            - Bringe eigene Ideen ein, aber bleibe respektvoll und kooperativ.
            - Wenn du Bedenken hast, formuliere sie als Fragen, nicht als Kritik.
            """
        case "aggressiv":
            intensityRules = """
            - Hinterfrage ALLES aggressiv. Jeder Vorschlag hat Schwaechen — finde sie.
            - Spiele den Advocatus Diaboli. Akzeptiere KEINE Aussage ohne Beweis.
            - Sei direkt und scharf in deiner Kritik. Schone niemanden.
            """
        default: // "kritisch"
            intensityRules = """
            - Sei EHRLICH, DIREKT und KRITISCH. Stimme NIEMALS einfach zu.
            - Wenn du Fehler oder falsche Annahmen erkennst: KORRIGIERE sie sofort.
            - Bringe EIGENE Gegenargumente und alternative Ansaetze ein.
            - Hinterfrage: Gibt es Risiken, Nachteile, blinde Flecken?
            - Lobe NUR wenn etwas tatsaechlich gut ist.
            """
        }

        let lengthHint: String
        switch outputLength {
        case "kurz": lengthHint = "Antworte SEHR kurz (max 1-2 Saetze)."
        case "ausfuehrlich": lengthHint = "Antworte ausfuehrlich (5-8 Saetze) mit Begruendungen und Beispielen."
        default: lengthHint = "Antworte praezise (max 3-4 Saetze)."
        }

        return """
        TEAM-DISKUSSION — VERHALTENSREGELN:
        \(intensityRules)

        ADRESSIERUNG — WICHTIG:
        - Beginne JEDE Nachricht mit @Name: wenn du ein bestimmtes Mitglied ansprichst
        - Beginne mit @Alle: wenn du dich an die ganze Gruppe wendest
        - Reagiere gezielt auf vorherige Beitraege, nicht pauschal auf alles

        TEAM-MITGLIEDER:
        \(memberList)

        DEINE ROLLE: Du bist \(member.name) (\(member.role)). \(member.systemPrompt)
        RICHTE DICH AN: \(addressTo)

        AUFGABE: \(task)

        \(context.isEmpty ? "" : "BISHERIGE DISKUSSION:\n\(context)")

        \(lengthHint) Beginne mit @Name: oder @Alle:
        """
    }

    private func runTeamDebate(task: String) async {
        let rounds = Int(maxRounds)
        let memberList = team.members.enumerated().map { idx, m in
            "- \(m.name) (\(m.role))\(idx == 0 && selectedRouting == .leader ? " [LEADER]" : "")"
        }.joined(separator: "\n")

        messages.append(TeamChatMessage(agentName: "System",
            content: "Aufgabe: \"\(task)\" — \(selectedRouting.label), \(rounds) Runden, \(team.members.count) Agenten",
            isSystem: true))

        for round in 1...rounds {
            guard !Task.isCancelled else { return }

            let speakers = speakersForRound(round: round, totalRounds: rounds)

            for (speakerIdx, addressTarget) in speakers {
                guard !Task.isCancelled else { return }
                let member = team.members[speakerIdx]

                // Kontext: Letzte 6 Nicht-System-Nachrichten
                let recentContext = messages.filter { !$0.isSystem }.suffix(6).map { msg in
                    let target = msg.targetAgent.map { " (\($0))" } ?? ""
                    return "\(msg.agentName)\(target): \(msg.content)"
                }.joined(separator: "\n")

                let prompt = buildTeamPrompt(
                    member: member, task: task, context: recentContext,
                    addressTo: addressTarget, memberList: memberList)

                typingAgent = member.name
                let response = await callAgent(prompt: prompt)
                typingAgent = nil
                guard !Task.isCancelled else { return }

                // Parse @Name: Adressierung aus der Antwort
                let (cleanText, parsedTarget) = parseAddressing(response)
                let displayTarget = parsedTarget ?? addressTarget

                messages.append(TeamChatMessage(
                    agentName: member.name, content: cleanText,
                    isSystem: false, targetAgent: displayTarget))
            }

            if round < rounds {
                messages.append(TeamChatMessage(agentName: "System",
                    content: "— Runde \(round)/\(rounds) —", isSystem: true))
            }
        }

        messages.append(TeamChatMessage(agentName: "System",
            content: "Diskussion abgeschlossen nach \(rounds) Runden.", isSystem: true))

        // Zusammenfassung generieren wenn gewuenscht
        if showSummary && !Task.isCancelled {
            typingAgent = "Zusammenfassung"
            let allMessages = messages.filter { !$0.isSystem }.map { "\($0.agentName): \($0.content)" }.joined(separator: "\n")
            let summaryPrompt = "Fasse die folgende Team-Diskussion in einem klaren, strukturierten Ergebnis zusammen. Nenne die wichtigsten Punkte, Entscheidungen und offene Fragen:\n\nAUFGABE: \(task)\n\nDISKUSSION:\n\(allMessages)\n\nGib eine praezise Zusammenfassung mit Ergebnis/Empfehlung."
            let summary = await callAgent(prompt: summaryPrompt)
            typingAgent = nil
            guard !Task.isCancelled else { isRunning = false; return }
            messages.append(TeamChatMessage(agentName: "Ergebnis", content: summary, isSystem: false, targetAgent: "@Alle"))
        }

        isRunning = false
    }

    // MARK: - Routing: Wer spricht wen an?

    /// Gibt (memberIndex, addressTarget) Paare zurueck — routing-abhaengig
    private func speakersForRound(round: Int, totalRounds: Int) -> [(Int, String)] {
        let count = team.members.count
        guard count > 0 else { return [] }

        switch selectedRouting {
        case .sequential:
            // Reihum: Jeder spricht den vorherigen Sprecher an
            return (0..<count).map { idx in
                let prevName = idx == 0
                    ? (messages.filter { !$0.isSystem }.last?.agentName ?? "@Alle")
                    : team.members[idx - 1].name
                let target = idx == 0 && round == 1 ? "@Alle" : "@\(prevName)"
                return (idx, target)
            }

        case .leader:
            // Leader spricht zuerst an @Alle, dann antwortet EIN gezieltes Mitglied
            var pairs: [(Int, String)] = [(0, "@Alle")]  // Leader zuerst
            if count > 1 {
                // Rotiere: In jeder Runde antwortet ein anderes Mitglied
                let responderIdx = 1 + ((round - 1) % (count - 1))
                pairs.append((responderIdx, "@\(team.members[0].name)"))
            }
            return pairs

        case .roundRobin:
            // Wechselnde Paare debattieren — max 2 Sprecher pro Runde
            if count <= 2 {
                return (0..<count).map { idx in
                    let otherIdx = (idx + 1) % max(count, 1)
                    return (idx, "@\(team.members[otherIdx].name)")
                }
            }
            let a = ((round - 1) * 2) % count
            let b = ((round - 1) * 2 + 1) % count
            return [
                (a, "@\(team.members[b].name)"),
                (b, "@\(team.members[a].name)")
            ]
        }
    }

    // MARK: - Parse @Name: Adressierung

    private func parseAddressing(_ text: String) -> (cleanText: String, target: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Suche nach @Name: oder @Alle: am Anfang
        if let match = trimmed.range(of: #"^@(\w+):\s*"#, options: .regularExpression) {
            let target = String(trimmed[match].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "")
            let clean = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (clean.isEmpty ? trimmed : clean, "@\(target)")
        }
        return (trimmed, nil)
    }

    // MARK: - Ergebnis an Chat-Session senden

    private func deliverResultToSession() {
        let agentMessages = messages.filter { !$0.isSystem }
        guard !agentMessages.isEmpty else { return }

        // Ergebnis-Text zusammenbauen
        var resultText = "## Team-Diskussion: \(team.name)\n\n"
        resultText += "**Routing:** \(selectedRouting.label) | **Runden:** \(Int(maxRounds)) | **Agenten:** \(team.members.count)\n\n"

        for msg in agentMessages {
            let target = msg.targetAgent.map { " \($0)" } ?? ""
            resultText += "**\(msg.agentName)**\(target): \(msg.content)\n\n"
        }

        // Als neue Session im RuntimeViewModel ablegen
        let sessionName = "Team: \(team.name)"
        viewModel.sendTeamResult(teamName: sessionName, result: resultText)
    }

    // MARK: - Agent API Call (non-blocking)

    private func callAgent(prompt: String) async -> String {
        guard let url = URL(string: viewModel.baseURL + "/agent") else { return "..." }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45  // Kurzer Timeout fuer schnelle Runden
        let body: [String: Any] = ["message": prompt, "agent_type": "general"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json["output"] as? String ?? json["response"] as? String ?? json["text"] as? String ?? "..."
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        } catch {
            return "[Fehler: \(error.localizedDescription)]"
        }
        return "..."
    }
}
