import SwiftUI
import UniformTypeIdentifiers
import KoboldCore

// MARK: - TeamView
// Visuelle n8n-artige Workflow-Builder für Agenten-Teams.

struct TeamView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var nodes: [WorkflowNode] = []
    @State private var connections: [WorkflowConnection] = []
    @State private var selectedNodeId: UUID? = nil
    @State private var isRunning = false
    @State private var lastRunOutput = ""  // Stores final workflow output for display
    @State private var showRunOutput = false
    @State private var dragSourceNodeId: UUID? = nil
    @State private var isDraggingPort: Bool = false
    @State private var dragSourceIsOutput: Bool = true
    @State private var portDragLocation: CGPoint = .zero
    // Agent-Builder
    @State private var agentBuilderText: String = ""
    @State private var isAgentBuilding: Bool = false
    @State private var agentBuildStatus: String = ""
    @State private var showImportPicker: Bool = false
    @State private var workflowSuggestionOffset: Int = 0
    @State private var showSavedConfirmation: Bool = false
    @State private var workflowTask: Task<Void, Never>?
    // Canvas zoom & pan
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    // Active project name shown in header
    private var projectName: String {
        viewModel.selectedProject?.name ?? lang.noProjectSelected
    }

    /// Per-project workflow URL
    private var workflowCanvasURL: URL {
        if let pid = viewModel.selectedProjectId {
            return viewModel.workflowURL(for: pid)
        }
        // Fallback for no project selected
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/workflows/workflow_canvas.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            teamHeader
            GlassDivider()
            if viewModel.selectedProjectId == nil {
                // No project selected — hint + workflow suggestions
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 49))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(lang.noProjectSelected)
                        .font(.title3)
                    Text(lang.chooseProject)
                        .font(.body).foregroundColor(.secondary)

                    // Workflow ideas
                    GlassCard(padding: 12, cornerRadius: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(lang.workflowIdeas).font(.system(size: 15.5, weight: .semibold)).foregroundColor(.koboldGold)
                                Spacer()
                                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { workflowSuggestionOffset += 1 } }) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 13.5)).foregroundColor(.koboldGold)
                                }.buttonStyle(.plain).help(lang.loadSuggestions)
                            }
                            ForEach(currentWorkflowSuggestions, id: \.name) { suggestion in
                                Button(action: {
                                    viewModel.newProject()
                                    agentBuilderText = suggestion.description
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: suggestion.icon)
                                            .font(.system(size: 14.5))
                                            .foregroundColor(.koboldGold)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.name)
                                                .font(.system(size: 14.5, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text(suggestion.description)
                                                .font(.system(size: 12.5))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .background(Color.koboldGold.opacity(0.04))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 460)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    workflowCanvas
                    if selectedNodeId != nil {
                        GlassDivider().frame(width: 1).frame(maxHeight: .infinity)
                        nodeInspectorPanel
                            .frame(width: 240)
                    }
                }
            }
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .onAppear { loadWorkflowState() }
        .onChange(of: nodes.count) { saveWorkflowState() }
        .onChange(of: connections.count) { saveWorkflowState() }
        .onChange(of: viewModel.selectedProjectId) {
            // Save current project's canvas, then load the new one
            saveWorkflowState()
            loadWorkflowState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .koboldWorkflowChanged)) { notification in
            if let projectId = notification.object as? String,
               let selected = viewModel.selectedProjectId,
               selected.uuidString.hasPrefix(projectId) || selected.uuidString == projectId {
                loadWorkflowState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .koboldWorkflowRun)) { notification in
            if let projectId = notification.object as? String,
               let selected = viewModel.selectedProjectId,
               selected.uuidString.hasPrefix(projectId) || selected.uuidString == projectId {
                workflowTask = Task { await runWorkflow() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .koboldProjectsChanged)) { _ in
            viewModel.loadProjects()
        }
    }

    // MARK: - Header

    var teamHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(projectName)
                            .font(.headline)
                        GlassStatusBadge(label: "Beta", color: .koboldGold)
                    }
                    Text(lang.connectAgents)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.selectedProject != nil {
                    // Import JSON button
                    GlassButton(title: lang.importLabel, icon: "square.and.arrow.down", isPrimary: false) {
                        showImportPicker = true
                    }
                    GlassButton(
                        title: showSavedConfirmation ? lang.savedLabelExcl : lang.save,
                        icon: showSavedConfirmation ? "checkmark.circle.fill" : "square.and.arrow.down.fill",
                        isPrimary: false
                    ) {
                        saveWorkflowState()
                        showSavedConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showSavedConfirmation = false
                        }
                    }
                    GlassButton(title: "Node +", icon: "plus", isPrimary: false) {
                        addNode()
                    }
                    GlassButton(
                        title: isRunning ? lang.stopLabel : lang.executeLabel,
                        icon: isRunning ? "stop.fill" : "play.fill",
                        isPrimary: true
                    ) {
                        if isRunning {
                            workflowTask?.cancel()
                            workflowTask = nil
                            isRunning = false
                        } else {
                            workflowTask = Task { await runWorkflow() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            // Agent-Builder text field (only when project selected)
            if viewModel.selectedProject != nil {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 14.5))
                        .foregroundColor(.koboldGold)
                    GlassTextField(
                        text: $agentBuilderText,
                        placeholder: lang.workflowIdea,
                        onSubmit: { buildWorkflowWithAgent() }
                    )
                    Button(action: { buildWorkflowWithAgent() }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15.5))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(agentBuilderText.isEmpty ? Color.secondary : Color.koboldEmerald)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(agentBuilderText.trimmingCharacters(in: .whitespaces).isEmpty || isAgentBuilding)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)

                // Agent-Builder status
                if isAgentBuilding || !agentBuildStatus.isEmpty {
                    HStack(spacing: 6) {
                        if isAgentBuilding {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                            Image(systemName: "brain")
                                .font(.system(size: 12.5))
                                .foregroundColor(.koboldGold)
                            Text(lang.creatingWorkflow)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(.koboldGold)
                        } else if !agentBuildStatus.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12.5))
                                .foregroundColor(.koboldEmerald)
                            Text(agentBuildStatus)
                                .font(.system(size: 13.5))
                                .foregroundColor(.koboldEmerald)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }
            }
        }
        .background(Color.koboldPanel)
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importWorkflowJSON(from: url)
            }
        }
        .sheet(isPresented: $showRunOutput) {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                    Text(lang.workflowResult).font(.headline)
                    Spacer()
                    Button(lang.close) { showRunOutput = false }.buttonStyle(.plain)
                }
                ScrollView {
                    Text(lastRunOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(lang.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lastRunOutput, forType: .string)
                    }
                    Spacer()
                }
            }
            .padding()
            .frame(minWidth: 500, minHeight: 300)
        }
    }

    // MARK: - Canvas

    var workflowCanvas: some View {
        GeometryReader { geo in
            ZStack {
                // Dot grid background
                Canvas { ctx, size in
                    let step: CGFloat = 24
                    for x in stride(from: step, to: size.width, by: step) {
                        for y in stride(from: step, to: size.height, by: step) {
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                with: .color(Color.white.opacity(0.07))
                            )
                        }
                    }
                }

                // Connection lines between nodes (custom connections)
                Canvas { ctx, size in
                    for conn in connections {
                        guard let from = nodes.first(where: { $0.id == conn.sourceNodeId }),
                              let to = nodes.first(where: { $0.id == conn.targetNodeId }) else { continue }
                        let fromPt = CGPoint(x: from.x + 130, y: from.y + 35)
                        let toPt = CGPoint(x: to.x, y: to.y + 35)
                        var path = Path()
                        path.move(to: fromPt)
                        path.addCurve(
                            to: toPt,
                            control1: CGPoint(x: fromPt.x + 60, y: fromPt.y),
                            control2: CGPoint(x: toPt.x - 60, y: toPt.y)
                        )

                        // Error-Connections: rote gestrichelte Linie; Normal: grüne durchgezogene
                        let isError = conn.connectionType == .error
                        let lineColor: Color = isError ? .red.opacity(0.6) : .koboldEmerald.opacity(0.5)
                        if isError {
                            ctx.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        } else {
                            ctx.stroke(path, with: .color(lineColor), lineWidth: 2)
                        }

                        // Arrow head (rot für Error, grün für Normal)
                        let arrowColor: Color = isError ? .red.opacity(0.7) : .koboldEmerald.opacity(0.7)
                        let arrowPt = CGPoint(x: toPt.x - 4, y: toPt.y)
                        var arrowPath = Path()
                        arrowPath.move(to: CGPoint(x: arrowPt.x - 8, y: arrowPt.y - 6))
                        arrowPath.addLine(to: arrowPt)
                        arrowPath.addLine(to: CGPoint(x: arrowPt.x - 8, y: arrowPt.y + 6))
                        ctx.stroke(arrowPath, with: .color(arrowColor), lineWidth: 1.5)
                    }
                }

                // Connection preview line (while dragging from port)
                if isDraggingPort, let srcId = dragSourceNodeId,
                   let srcNode = nodes.first(where: { $0.id == srcId }) {
                    let fromPt = dragSourceIsOutput
                        ? CGPoint(x: srcNode.x + 130, y: srcNode.y + 35)
                        : CGPoint(x: srcNode.x, y: srcNode.y + 35)
                    Path { path in
                        path.move(to: fromPt)
                        path.addCurve(
                            to: portDragLocation,
                            control1: CGPoint(x: fromPt.x + 40, y: fromPt.y),
                            control2: CGPoint(x: portDragLocation.x - 40, y: portDragLocation.y)
                        )
                    }
                    .stroke(Color.koboldEmerald.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                // Nodes
                ForEach($nodes) { $node in
                    WorkflowNodeCard(
                        node: $node,
                        isSelected: selectedNodeId == node.id,
                        isRunning: isRunning,
                        onPortDragStart: { nodeId, isOutput in
                            dragSourceNodeId = nodeId
                            dragSourceIsOutput = isOutput
                            isDraggingPort = true
                        },
                        onPortDragEnd: { nodeId, dropPoint in
                            handlePortDrop(sourceNodeId: nodeId, isOutput: dragSourceIsOutput, dropPoint: dropPoint)
                            isDraggingPort = false
                            dragSourceNodeId = nil
                        },
                        onPortDragUpdate: { location in
                            portDragLocation = location
                        },
                        onOpenChat: {
                            // Navigate to the workflow chat session via koboldNavigateToSession
                            let projectId = viewModel.selectedProjectId?.uuidString ?? "default"
                            let wfTaskId = "workflow-\(projectId)"
                            if let session = viewModel.sessions.first(where: { $0.taskId == wfTaskId }) {
                                NotificationCenter.default.post(
                                    name: Notification.Name("koboldNavigateToSession"),
                                    object: nil,
                                    userInfo: ["sessionId": session.id]
                                )
                            }
                        }
                    )
                    .position(x: node.x + 65, y: node.y + 35)
                    .onTapGesture {
                        selectedNodeId = (selectedNodeId == node.id) ? nil : node.id
                    }
                }
            }
            .scaleEffect(canvasScale)
            .offset(canvasOffset)
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "canvas")
            .clipped()
            .contentShape(Rectangle())
            // Pan gesture on background
            .gesture(
                DragGesture()
                    .onChanged { value in
                        canvasOffset = CGSize(
                            width: lastDragOffset.width + value.translation.width,
                            height: lastDragOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastDragOffset = canvasOffset
                    }
            )
            // Zoom via scroll wheel / pinch
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    if event.modifierFlags.contains(.command) {
                        let delta = event.scrollingDeltaY * 0.01
                        canvasScale = max(0.3, min(3.0, canvasScale + delta))
                        return nil
                    }
                    return event
                }
            }
            // Zoom controls overlay
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { canvasScale = max(0.3, canvasScale - 0.1) } }) {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 14.5))
                    }.buttonStyle(.plain)
                    Text(String(format: "%.0f%%", canvasScale * 100))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 36)
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { canvasScale = min(3.0, canvasScale + 0.1) } }) {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 14.5))
                    }.buttonStyle(.plain)
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            canvasScale = 1.0; canvasOffset = .zero; lastDragOffset = .zero
                        }
                    }) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 13.5))
                    }.buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.koboldPanel.opacity(0.9))
                .cornerRadius(8)
                .padding(12)
            }
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    // MARK: - Node Inspector

    var nodeInspectorPanel: some View {
        Group {
            if let id = selectedNodeId, let idx = nodes.firstIndex(where: { $0.id == id }) {
                let nodeTitle = nodes[idx].title
                NodeInspector(
                    node: $nodes[idx],
                    onClose: { selectedNodeId = nil },
                    onDelete: {
                        selectedNodeId = nil
                        connections.removeAll { $0.sourceNodeId == id || $0.targetNodeId == id }
                        if let removeIdx = nodes.firstIndex(where: { $0.id == id }) {
                            nodes.remove(at: removeIdx)
                        }
                        saveWorkflowState()
                    },
                    onOpenChat: {
                        let projectId = viewModel.selectedProjectId?.uuidString ?? "default"
                        let wfTaskId = "workflow-\(projectId)"
                        if let session = viewModel.sessions.first(where: { $0.taskId == wfTaskId }) {
                            NotificationCenter.default.post(
                                name: Notification.Name("koboldNavigateToSession"),
                                object: nil,
                                userInfo: ["sessionId": session.id]
                            )
                        }
                    },
                    incomingConnections: connections.filter { $0.targetNodeId == id },
                    outgoingConnections: connections.filter { $0.sourceNodeId == id },
                    onDeleteConnection: { connId in
                        connections.removeAll { $0.id == connId }
                        saveWorkflowState()
                    },
                    onToggleConnectionType: { connId in
                        if let connIdx = connections.firstIndex(where: { $0.id == connId }) {
                            connections[connIdx].connectionType = connections[connIdx].connectionType == .normal ? .error : .normal
                            saveWorkflowState()
                        }
                    },
                    viewModel: viewModel
                )
            }
        }
        .background(Color.koboldPanel)
    }

    // MARK: - Actions

    // MARK: - Port Connection Drop

    func handlePortDrop(sourceNodeId: UUID, isOutput: Bool, dropPoint: CGPoint) {
        // Find the target node closest to the drop point
        let hitThreshold: CGFloat = 60
        var bestTarget: UUID? = nil
        var bestDist: CGFloat = .infinity

        for node in nodes where node.id != sourceNodeId {
            // Target port position: left port (input) = node.x, right port (output) = node.x + 130
            let targetPt = isOutput
                ? CGPoint(x: node.x, y: node.y + 35)         // drop on input port
                : CGPoint(x: node.x + 130, y: node.y + 35)   // drop on output port
            let dist = hypot(dropPoint.x - targetPt.x, dropPoint.y - targetPt.y)
            if dist < hitThreshold && dist < bestDist {
                bestDist = dist
                bestTarget = node.id
            }
        }

        guard let targetId = bestTarget else { return }

        // Determine source/target based on port type
        let (src, tgt) = isOutput ? (sourceNodeId, targetId) : (targetId, sourceNodeId)

        // Check for duplicate
        let exists = connections.contains { $0.sourceNodeId == src && $0.targetNodeId == tgt }
        guard !exists else { return }

        // Don't allow self-connections
        guard src != tgt else { return }

        connections.append(WorkflowConnection(sourceNodeId: src, targetNodeId: tgt))
        saveWorkflowState()
    }

    func addNode() {
        let y = CGFloat.random(in: 80...280)
        let x = (nodes.last?.x ?? 100) + 180
        let newNode = WorkflowNode(
            type: .agent,
            title: "Agent \(nodes.count + 1)",
            x: min(x, 600),
            y: y
        )
        // Auto-connect to the last node
        if let lastNode = nodes.last {
            connections.append(WorkflowConnection(sourceNodeId: lastNode.id, targetNodeId: newNode.id))
        }
        nodes.append(newNode)
        saveWorkflowState()
    }

    // MARK: - Workflow Suggestions (rotate every 4 hours)

    private struct WorkflowSuggestion {
        let icon: String
        let name: String
        let description: String
    }

    private static let workflowSuggestionSets: [[WorkflowSuggestion]] = [
        [
            WorkflowSuggestion(icon: "envelope.fill", name: "Email-Pipeline", description: "Emails lesen → zusammenfassen → dringende beantworten → Report erstellen"),
            WorkflowSuggestion(icon: "doc.text.magnifyingglass", name: "Code-Review Pipeline", description: "Git Diff lesen → Code analysieren → Verbesserungen vorschlagen → Tests schreiben"),
            WorkflowSuggestion(icon: "newspaper.fill", name: "News-Aggregator", description: "Nachrichten sammeln → filtern → zusammenfassen → als Briefing formatieren"),
        ],
        [
            WorkflowSuggestion(icon: "photo.stack.fill", name: "Bild-Pipeline", description: "Screenshots sammeln → beschreiben → in Ordner sortieren → Thumbnails erstellen"),
            WorkflowSuggestion(icon: "globe", name: "Web-Monitoring", description: "Webseiten prüfen → Änderungen erkennen → Benachrichtigung senden"),
            WorkflowSuggestion(icon: "chart.bar.fill", name: "System-Report", description: "System-Daten sammeln → analysieren → Report erstellen → als PDF speichern"),
        ],
        [
            WorkflowSuggestion(icon: "person.2.fill", name: "Meeting-Assistent", description: "Kalender prüfen → Agenda erstellen → Notizen vorbereiten → Erinnerung senden"),
            WorkflowSuggestion(icon: "folder.fill", name: "Datei-Organizer", description: "Downloads scannen → nach Typ sortieren → alte Dateien archivieren → Report erstellen"),
            WorkflowSuggestion(icon: "text.bubble.fill", name: "Social Media Planner", description: "Content-Ideen generieren → Texte schreiben → Bilder erstellen → Zeitplan erstellen"),
        ],
    ]

    private var currentWorkflowSuggestions: [WorkflowSuggestion] {
        let hour = Calendar.current.component(.hour, from: Date())
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let index = (dayOfYear * 6 + hour / 4 + workflowSuggestionOffset) % Self.workflowSuggestionSets.count
        return Self.workflowSuggestionSets[index]
    }

    // MARK: - JSON Import

    private func importWorkflowJSON(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WorkflowState.self, from: data) else {
            agentBuildStatus = "Import fehlgeschlagen — ungültiges JSON"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { agentBuildStatus = "" }
            return
        }
        nodes = state.nodes
        connections = state.connections
        saveWorkflowState()
        agentBuildStatus = "Workflow importiert: \(state.nodes.count) Nodes, \(state.connections.count) Verbindungen"
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { agentBuildStatus = "" }
    }

    // MARK: - Agent-Builder

    private func buildWorkflowWithAgent() {
        let text = agentBuilderText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isAgentBuilding else { return }
        guard let projectId = viewModel.selectedProjectId else { return }

        agentBuilderText = ""
        isAgentBuilding = true
        agentBuildStatus = "Erstelle Workflow..."

        let prompt = """
        Erstelle einen Workflow mit dem workflow_manage Tool basierend auf dieser Beschreibung: \(text)

        Verwende project_id: \(projectId.uuidString)

        Erstelle passende Nodes (Trigger, Agent-Nodes mit passendem Profil, Output) und verbinde sie.
        """

        viewModel.sendMessage(prompt)

        // Poll for agent completion instead of arbitrary delay
        Task { @MainActor in
            for _ in 0..<60 {  // max 30s
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !viewModel.agentLoading {
                    break
                }
            }
            isAgentBuilding = false
            agentBuildStatus = "Workflow erstellt"
            // Reload workflow state in case agent created nodes
            loadWorkflowState()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            agentBuildStatus = ""
        }
    }

    // MARK: - Workflow Persistence

    private func saveWorkflowState() {
        guard viewModel.selectedProjectId != nil else { return }
        let state = WorkflowState(nodes: nodes, connections: connections)
        let url = workflowCanvasURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: url)
            }
        }
    }

    private func loadWorkflowState() {
        guard viewModel.selectedProjectId != nil else {
            nodes = []
            connections = []
            return
        }
        if let data = try? Data(contentsOf: workflowCanvasURL),
           let state = try? JSONDecoder().decode(WorkflowState.self, from: data),
           !state.nodes.isEmpty {
            nodes = state.nodes
            connections = state.connections
        } else {
            // New project = default workflow
            let (defaultNodes, defaultConns) = WorkflowNode.defaultWorkflow()
            nodes = defaultNodes
            connections = defaultConns
        }
    }

    func runWorkflow() async {
        guard !nodes.isEmpty else { return }
        isRunning = true
        defer {
            isRunning = false
            saveWorkflowState()
        }

        // 1. Reset all nodes to idle with animation
        for i in 0..<nodes.count {
            nodes[i].lastOutput = ""
            nodes[i].executionStatus = .idle
            nodes[i].statusMessage = ""
            nodes[i].executionProgress = 0.0
            nodes[i].errorMessage = ""
        }
        // Yield to let SwiftUI render the reset state
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 2. Build topological execution order — start from root nodes (no incoming edges)
        let targetIds = Set(connections.map { $0.targetNodeId })
        var queue = nodes.filter { !targetIds.contains($0.id) }.map { $0.id }
        var visited = Set<UUID>()

        while !queue.isEmpty {
            guard !Task.isCancelled else { break }
            let currentId = queue.removeFirst()
            guard !visited.contains(currentId) else { continue }
            visited.insert(currentId)

            guard nodes.contains(where: { $0.id == currentId }) else { continue }

            // 2a. Set to WAITING — visible blue glow
            updateNode(id: currentId) { $0.executionStatus = .waiting; $0.statusMessage = "Wartet..." }
            // Give SwiftUI time to render the waiting state
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Gather context from upstream nodes
            let sourceIds = connections.filter { $0.targetNodeId == currentId }.map { $0.sourceNodeId }
            let upstreamOutput = sourceIds.compactMap { sid in
                nodes.first(where: { $0.id == sid })?.lastOutput
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")

            // 2b. Set to RUNNING — visible green pulse
            updateNode(id: currentId) { $0.executionStatus = .running; $0.statusMessage = "Verarbeite..." }
            // Give SwiftUI time to render the running state before executing
            try? await Task.sleep(nanoseconds: 300_000_000)

            do {
                // 2c. Execute based on node type — use ID-based lookup for safety
                guard let safeIdx = nodes.firstIndex(where: { $0.id == currentId }) else { continue }
                let result = try await executeNode(nodeIdx: safeIdx, upstreamOutput: upstreamOutput)

                // 2d. Set to SUCCESS — solid green
                updateNode(id: currentId) {
                    $0.executionStatus = .success
                    $0.statusMessage = String(result.prefix(60))
                    $0.lastOutput = result
                    $0.executionProgress = 1.0
                }
            } catch {
                // 2d. Set to ERROR — red
                updateNode(id: currentId) {
                    $0.executionStatus = .error
                    $0.statusMessage = error.localizedDescription
                    $0.errorMessage = error.localizedDescription
                    $0.lastOutput = "ERROR: \(error.localizedDescription)"
                }

                // Error-Branching: Error-Connections (rote gestrichelte) aktivieren
                let errorConns = connections.filter { $0.sourceNodeId == currentId && $0.connectionType == .error }
                if !errorConns.isEmpty {
                    for ec in errorConns { queue.append(ec.targetNodeId) }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue  // Normale Successors NICHT queuen
                }
            }

            // Pause after completion so user sees the success/error state before moving on
            try? await Task.sleep(nanoseconds: 500_000_000)

            // 2e. Queue downstream nodes — type-specific routing
            let nodeType = nodes.first(where: { $0.id == currentId })?.type
            let nodeOutput = nodes.first(where: { $0.id == currentId })?.lastOutput ?? ""
            let normalConns = connections.filter { $0.sourceNodeId == currentId && $0.connectionType == .normal }

            if nodeType == .condition {
                let conditionResult = nodeOutput
                if conditionResult == "true", let firstConn = normalConns.first {
                    queue.append(firstConn.targetNodeId)
                } else if conditionResult == "false", normalConns.count > 1 {
                    queue.append(normalConns[1].targetNodeId)
                } else if let firstConn = normalConns.first {
                    queue.append(firstConn.targetNodeId)
                }
            } else if nodeType == .switchNode {
                // Switch-Routing: Port-Index aus Output extrahieren
                if nodeOutput.hasPrefix("switch_port:") {
                    let parts = nodeOutput.components(separatedBy: ":")
                    if parts.count >= 3 {
                        let portStr = parts[1]
                        let actualOutput = parts.dropFirst(2).joined(separator: ":")
                        // Echten Output setzen (ohne switch_port: Prefix)
                        updateNode(id: currentId) { $0.lastOutput = actualOutput }
                        if let portIdx = Int(portStr) {
                            // Route zu Connection mit passendem sourcePort
                            let matchedConns = normalConns.filter { $0.sourcePort == portIdx }
                            if let conn = matchedConns.first {
                                queue.append(conn.targetNodeId)
                            } else if let fallback = normalConns.first {
                                queue.append(fallback.targetNodeId) // Fallback auf erste Connection
                            }
                        } else {
                            // "default" — alle Normal-Connections aktivieren
                            queue.append(contentsOf: normalConns.map { $0.targetNodeId })
                        }
                    }
                } else {
                    queue.append(contentsOf: normalConns.map { $0.targetNodeId })
                }
            } else if nodeType == .loop || nodeType == .retry {
                // Loop/Retry: Downstream wird intern gehandhabt, nur Geschwister-Connections weiterleiten
                let siblingConns = normalConns.filter { conn in
                    // Nur Connections die nicht zum Loop-Body gehören (= nicht die erste)
                    conn == normalConns.last || normalConns.count <= 1
                }
                queue.append(contentsOf: siblingConns.map { $0.targetNodeId })
            } else {
                let nextIds = normalConns.map { $0.targetNodeId }
                queue.append(contentsOf: nextIds)
            }
        }
    }

    /// Safely update a node by ID (avoids index-out-of-bounds during async operations)
    private func updateNode(id: UUID, _ update: (inout WorkflowNode) -> Void) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        update(&nodes[idx])
    }

    /// Execute a single node and return its output
    private func executeNode(nodeIdx: Int, upstreamOutput: String) async throws -> String {
        guard nodeIdx < nodes.count else { return "Node nicht mehr verfügbar" }
        let node = nodes[nodeIdx]
        let nodeId = node.id

        switch node.type {
        case .trigger:
            updateNode(id: nodeId) { $0.statusMessage = "Gestartet" }
            return "workflow_started"

        case .input:
            return upstreamOutput

        case .output:
            updateNode(id: nodeId) { $0.statusMessage = "Abgeschlossen" }
            lastRunOutput = upstreamOutput
            showRunOutput = true
            return upstreamOutput

        case .agent:
            updateNode(id: nodeId) { $0.statusMessage = "Agent arbeitet..." }
            var basePrompt = node.prompt.isEmpty
                ? "Aufgabe: \(node.title)\n\nKontext:\n\(String(upstreamOutput.prefix(1000)))"
                : "\(node.prompt)\n\nKontext:\n\(String(upstreamOutput.prefix(1000)))"

            // Inject skill content if selected
            if let skillName = node.skillName, !skillName.isEmpty {
                let skills = await SkillLoader.shared.loadSkills()
                if let skill = skills.first(where: { $0.name == skillName }) {
                    basePrompt = "Nutze folgende Fähigkeit:\n\(skill.content)\n\n\(basePrompt)"
                }
            }
            let prompt = basePrompt

            viewModel.sendWorkflowMessage(prompt, modelOverride: node.modelOverride, agentOverride: node.agentType)

            var waitCount = 0
            while waitCount < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waitCount += 1
                if Task.isCancelled { return "Abgebrochen" }
                // Throttle UI updates: nur alle 5s statt alle 500ms (97% weniger Re-Renders)
                if waitCount % 10 == 0 {
                    updateNode(id: nodeId) {
                        $0.executionProgress = min(0.9, Double(waitCount) / 120.0)
                        $0.statusMessage = "Agent arbeitet... (\(waitCount/2)s)"
                    }
                }
                if let lastMsg = viewModel.workflowLastResponse, !lastMsg.isEmpty {
                    viewModel.workflowLastResponse = nil
                    return lastMsg
                }
            }
            return "Agent-Timeout nach 60s"

        case .tool:
            updateNode(id: nodeId) { $0.statusMessage = "Tool ausführen..." }
            let toolType = node.agentType ?? "shell"
            let toolPrompt = node.prompt.isEmpty ? upstreamOutput : node.prompt
            viewModel.sendWorkflowMessage(
                "Führe das Tool '\(toolType)' aus: \(toolPrompt)\nInput: \(String(upstreamOutput.prefix(500)))",
                modelOverride: node.modelOverride,
                agentOverride: nil
            )
            var toolWait = 0
            while toolWait < 60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                toolWait += 1
                if Task.isCancelled { return "Abgebrochen" }
                // Throttle UI updates: nur alle 5s statt alle 500ms
                if toolWait % 10 == 0 {
                    updateNode(id: nodeId) {
                        $0.executionProgress = min(0.9, Double(toolWait) / 60.0)
                        $0.statusMessage = "Tool arbeitet... (\(toolWait / 2)s)"
                    }
                }
                if let resp = viewModel.workflowLastResponse, !resp.isEmpty {
                    viewModel.workflowLastResponse = nil
                    return resp
                }
            }
            return "Tool-Timeout nach 30s"

        case .condition:
            updateNode(id: nodeId) { $0.statusMessage = "Prüfe Bedingung..." }
            return evaluateCondition(expression: node.conditionExpression, output: upstreamOutput)

        case .delay:
            let seconds = max(1, node.delaySeconds)
            for remaining in stride(from: seconds, through: 1, by: -1) {
                updateNode(id: nodeId) {
                    $0.statusMessage = "Warte... \(remaining)s"
                    $0.executionProgress = 1.0 - (Double(remaining) / Double(seconds))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            updateNode(id: nodeId) { $0.statusMessage = "Fertig" }
            return upstreamOutput

        case .webhook:
            updateNode(id: nodeId) { $0.statusMessage = "Sende Webhook..." }
            return await executeWebhook(node: node, input: upstreamOutput)

        case .formula:
            updateNode(id: nodeId) { $0.statusMessage = "Berechne..." }
            return evaluateFormula(expression: node.prompt, input: upstreamOutput)

        case .merger:
            updateNode(id: nodeId) { $0.statusMessage = "Zusammenführen..." }
            return upstreamOutput

        case .team:
            updateNode(id: nodeId) { $0.statusMessage = "Team berät..." }
            guard let teamIdStr = node.teamId,
                  let team = viewModel.teams.first(where: { $0.id.uuidString == teamIdStr }) else {
                return "Kein Team konfiguriert"
            }
            let activeAgents = team.agents.filter { $0.isActive }
            var results: [(String, String)] = []
            for agent in activeAgents {
                let prompt = "Du bist \(agent.name) (\(agent.role)). \(agent.instructions)\n\nWorkflow-Input: \(upstreamOutput.isEmpty ? node.prompt : upstreamOutput)"
                let result = await viewModel.sendTeamAgentMessage(prompt: prompt, profile: agent.profile)
                results.append((agent.name, result))
            }
            return results.map { "[\($0.0)]: \($0.1)" }.joined(separator: "\n\n---\n\n")

        // MARK: v0.4 — Neue Node-Typen

        case .loop:
            updateNode(id: nodeId) { $0.statusMessage = "Loop startet..." }
            let separator = node.loopSeparator ?? "\n"
            let maxIter = node.loopMaxIterations ?? 100
            let items = upstreamOutput.components(separatedBy: separator).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let limitedItems = Array(items.prefix(maxIter))
            var loopResults: [String] = []
            for (i, item) in limitedItems.enumerated() {
                updateNode(id: nodeId) {
                    $0.statusMessage = "Item \(i+1)/\(limitedItems.count)"
                    $0.executionProgress = Double(i) / Double(limitedItems.count)
                }
                // Für jedes Item: Downstream-Chain ausführen
                let result = try await executeSubChain(fromNodeId: nodeId, input: item.trimmingCharacters(in: .whitespacesAndNewlines))
                loopResults.append(result)
            }
            updateNode(id: nodeId) { $0.statusMessage = "\(loopResults.count) Items verarbeitet" }
            return loopResults.joined(separator: "\n\n---\n\n")

        case .errorHandler:
            // Error-Handler fängt Fehler von Upstream-Nodes auf
            // Wird über Error-Connections aktiviert (nicht normal-flow)
            updateNode(id: nodeId) { $0.statusMessage = "Fehler aufgefangen" }
            if !node.prompt.isEmpty {
                // Prompt als Error-Recovery verwenden
                viewModel.sendWorkflowMessage(
                    "\(node.prompt)\n\nFehler-Kontext:\n\(String(upstreamOutput.prefix(2000)))",
                    modelOverride: node.modelOverride, agentOverride: nil
                )
                var wait = 0
                while wait < 60 {
                    try? await Task.sleep(nanoseconds: 500_000_000); wait += 1
                    if let resp = viewModel.workflowLastResponse, !resp.isEmpty {
                        viewModel.workflowLastResponse = nil; return resp
                    }
                }
                return "Error-Handler Timeout"
            }
            return "error_handled: \(String(upstreamOutput.prefix(500)))"

        case .subWorkflow:
            updateNode(id: nodeId) { $0.statusMessage = "Sub-Workflow laden..." }
            guard let projectIdStr = node.subWorkflowProjectId,
                  let projectId = UUID(uuidString: projectIdStr) else {
                return "Kein Sub-Workflow konfiguriert"
            }
            return try await executeSubWorkflow(projectId: projectId, input: upstreamOutput, depth: 0)

        case .task:
            updateNode(id: nodeId) { $0.statusMessage = "Task ausführen..." }
            let taskRef = node.taskIdRef ?? ""
            let taskPrompt = node.prompt.isEmpty ? upstreamOutput : "\(node.prompt)\n\nKontext:\n\(String(upstreamOutput.prefix(1000)))"
            viewModel.executeTask(taskId: "workflow-task-\(taskRef)", taskName: node.title, prompt: taskPrompt, navigate: false, source: "workflow")
            var taskWait = 0
            while taskWait < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000); taskWait += 1
                if taskWait % 10 == 0 {
                    updateNode(id: nodeId) { $0.statusMessage = "Task läuft... (\(taskWait/2)s)" }
                }
                if let resp = viewModel.workflowLastResponse, !resp.isEmpty {
                    viewModel.workflowLastResponse = nil; return resp
                }
            }
            return "Task-Timeout nach 60s"

        case .retry:
            updateNode(id: nodeId) { $0.statusMessage = "Retry-Loop..." }
            let maxRetries = node.retryCount ?? 3
            let delayBetween = node.retryDelaySeconds ?? 5
            var lastError = "Kein Versuch ausgeführt"
            for attempt in 1...maxRetries {
                updateNode(id: nodeId) { $0.statusMessage = "Versuch \(attempt)/\(maxRetries)" }
                do {
                    let result = try await executeSubChain(fromNodeId: nodeId, input: upstreamOutput)
                    if !result.lowercased().contains("error") && !result.lowercased().contains("timeout") {
                        updateNode(id: nodeId) { $0.statusMessage = "Erfolgreich nach \(attempt) Versuch(en)" }
                        return result
                    }
                    lastError = result
                } catch {
                    lastError = error.localizedDescription
                }
                if attempt < maxRetries {
                    updateNode(id: nodeId) { $0.statusMessage = "Warte \(delayBetween)s vor Retry..." }
                    try? await Task.sleep(nanoseconds: UInt64(delayBetween) * 1_000_000_000)
                }
            }
            throw WorkflowError.retryExhausted(lastError)

        case .switchNode:
            updateNode(id: nodeId) { $0.statusMessage = "Switch evaluieren..." }
            let cases = node.switchCases ?? []
            for sc in cases {
                let result = evaluateCondition(expression: sc.expression, output: upstreamOutput)
                if result == "true" {
                    updateNode(id: nodeId) { $0.statusMessage = "Match: \(sc.label)" }
                    // portIndex wird im runWorkflow() für Routing genutzt
                    return "switch_port:\(sc.portIndex):\(upstreamOutput)"
                }
            }
            // Default: Kein Match → letzer Port oder Durchreichen
            updateNode(id: nodeId) { $0.statusMessage = "Kein Match — Default" }
            return "switch_port:default:\(upstreamOutput)"

        case .note:
            // Note ist ein Pass-Through — gibt Input unverändert weiter
            updateNode(id: nodeId) { $0.statusMessage = node.noteText?.prefix(40).description ?? "Notiz" }
            return upstreamOutput
        }
    }

    // MARK: - Workflow Errors

    enum WorkflowError: LocalizedError {
        case retryExhausted(String)
        case subWorkflowDepthExceeded
        case subWorkflowNotFound(String)

        var errorDescription: String? {
            switch self {
            case .retryExhausted(let last): return "Alle Retry-Versuche fehlgeschlagen: \(last)"
            case .subWorkflowDepthExceeded: return "Sub-Workflow Tiefe überschritten (max 5)"
            case .subWorkflowNotFound(let id): return "Sub-Workflow-Projekt nicht gefunden: \(id)"
            }
        }
    }

    // MARK: - Sub-Chain Execution (für Loop/Retry)

    /// Führt die direkt verbundenen Downstream-Nodes eines Source-Nodes aus
    private func executeSubChain(fromNodeId: UUID, input: String) async throws -> String {
        let downstream = connections.filter { $0.sourceNodeId == fromNodeId && $0.connectionType == .normal }
        guard !downstream.isEmpty else { return input }
        var result = input
        for conn in downstream {
            if let idx = nodes.firstIndex(where: { $0.id == conn.targetNodeId }) {
                result = try await executeNode(nodeIdx: idx, upstreamOutput: result)
            }
        }
        return result
    }

    // MARK: - Sub-Workflow Execution

    /// Lädt und führt einen anderen Workflow inline aus
    private func executeSubWorkflow(projectId: UUID, input: String, depth: Int) async throws -> String {
        guard depth < 5 else { throw WorkflowError.subWorkflowDepthExceeded }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let workflowURL = appSupport.appendingPathComponent("KoboldOS/workflows/\(projectId.uuidString).json")
        guard let data = try? Data(contentsOf: workflowURL),
              let state = try? JSONDecoder().decode(WorkflowState.self, from: data) else {
            throw WorkflowError.subWorkflowNotFound(projectId.uuidString)
        }
        // Find trigger node and start execution from there
        guard let triggerIdx = state.nodes.firstIndex(where: { $0.type == .trigger }) else {
            return "Sub-Workflow hat keinen Trigger-Node"
        }
        // Execute BFS through sub-workflow nodes
        var subOutput = input
        var visited = Set<UUID>()
        var queue: [(idx: Int, input: String)] = [(triggerIdx, input)]
        while !queue.isEmpty {
            let (idx, nodeInput) = queue.removeFirst()
            let subNode = state.nodes[idx]
            guard !visited.contains(subNode.id) else { continue }
            visited.insert(subNode.id)
            // Simplified: nur Agent/Formula/Condition Nodes tatsächlich ausführen
            if subNode.type == .agent || subNode.type == .tool {
                let prompt = subNode.prompt.isEmpty ? nodeInput : "\(subNode.prompt)\n\nKontext:\n\(String(nodeInput.prefix(1000)))"
                viewModel.sendWorkflowMessage(prompt, modelOverride: subNode.modelOverride, agentOverride: subNode.agentType)
                var wait = 0
                while wait < 120 {
                    try? await Task.sleep(nanoseconds: 500_000_000); wait += 1
                    if let resp = viewModel.workflowLastResponse, !resp.isEmpty {
                        viewModel.workflowLastResponse = nil; subOutput = resp; break
                    }
                }
            } else if subNode.type == .formula {
                subOutput = evaluateFormula(expression: subNode.prompt, input: nodeInput)
            } else if subNode.type == .output {
                return subOutput
            } else {
                subOutput = nodeInput
            }
            // Enqueue downstream nodes
            let successors = state.connections
                .filter { $0.sourceNodeId == subNode.id }
                .compactMap { conn in state.nodes.firstIndex(where: { $0.id == conn.targetNodeId }) }
            for nextIdx in successors {
                queue.append((nextIdx, subOutput))
            }
        }
        return subOutput
    }

    // MARK: - Condition Evaluation

    /// String-based condition evaluation — unterstützt diverse Ausdrücke
    private func evaluateCondition(expression: String, output: String) -> String {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        let exprLower = expr.lowercased()
        let outputLower = output.lowercased()

        // contains('text')
        if exprLower.contains("contains(") {
            if let range = expr.range(of: #"contains\(['"](.*?)['"]\)"#, options: .regularExpression) {
                let searchStr = String(expr[range]).replacingOccurrences(of: "contains(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                return outputLower.contains(searchStr.lowercased()) ? "true" : "false"
            }
        }

        // equals('text') — exakter Vergleich
        if exprLower.contains("equals(") {
            if let range = expr.range(of: #"equals\(['"](.*?)['"]\)"#, options: .regularExpression) {
                let compareStr = String(expr[range]).replacingOccurrences(of: "equals(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                return output.trimmingCharacters(in: .whitespacesAndNewlines) == compareStr ? "true" : "false"
            }
        }

        // startsWith('x')
        if exprLower.contains("startswith(") {
            if let range = expr.range(of: #"startswith\(['"](.*?)['"]\)"#, options: [.regularExpression, .caseInsensitive]) {
                let prefix = String(expr[range]).replacingOccurrences(of: "startsWith(", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                return outputLower.hasPrefix(prefix.lowercased()) ? "true" : "false"
            }
        }

        // endsWith('x')
        if exprLower.contains("endswith(") {
            if let range = expr.range(of: #"endswith\(['"](.*?)['"]\)"#, options: [.regularExpression, .caseInsensitive]) {
                let suffix = String(expr[range]).replacingOccurrences(of: "endsWith(", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                return outputLower.hasSuffix(suffix.lowercased()) ? "true" : "false"
            }
        }

        // matches(/regex/)
        if exprLower.contains("matches(") {
            if let range = expr.range(of: #"matches\(/(.+?)/\)"#, options: .regularExpression) {
                let regexStr = String(expr[range]).replacingOccurrences(of: "matches(/", with: "")
                    .replacingOccurrences(of: "/)", with: "")
                if let regex = try? NSRegularExpression(pattern: regexStr, options: .caseInsensitive) {
                    let hasMatch = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
                    return hasMatch ? "true" : "false"
                }
            }
        }

        // isEmpty
        if exprLower == "isempty" || exprLower == "output.isempty" || exprLower == "output.isempty" {
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "true" : "false"
        }

        // length > N / length < N
        if exprLower.contains("length") && exprLower.contains(">") {
            if let numStr = exprLower.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces),
               let threshold = Int(numStr) {
                return output.count > threshold ? "true" : "false"
            }
        }
        if exprLower.contains("length") && exprLower.contains("<") {
            if let numStr = exprLower.components(separatedBy: "<").last?.trimmingCharacters(in: .whitespaces),
               let threshold = Int(numStr) {
                return output.count < threshold ? "true" : "false"
            }
        }

        // json.field == 'value' — einfacher JSON-Feld-Zugriff
        if exprLower.contains("json.") && exprLower.contains("==") {
            let parts = expr.components(separatedBy: "==").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let fieldPath = parts[0].replacingOccurrences(of: "json.", with: "")
                let expected = parts[1].replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                if let data = output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = json[fieldPath] {
                    return "\(value)" == expected ? "true" : "false"
                }
            }
        }

        // Default: treat non-empty output as true
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }

    // MARK: - Formula Evaluation

    /// Formula/Template-Evaluation — unterstützt Variablen, Operationen und JSON-Zugriff
    private func evaluateFormula(expression: String, input: String) -> String {
        var result = expression

        // Template-Variablen ersetzen
        result = result.replacingOccurrences(of: "{{input}}", with: input)
        result = result.replacingOccurrences(of: "{{date}}", with: ISO8601DateFormatter().string(from: Date()))
        result = result.replacingOccurrences(of: "{{length}}", with: "\(input.count)")
        result = result.replacingOccurrences(of: "{{lines}}", with: "\(input.components(separatedBy: "\n").count)")
        result = result.replacingOccurrences(of: "{{timestamp}}", with: "\(Int(Date().timeIntervalSince1970))")
        result = result.replacingOccurrences(of: "{{uuid}}", with: UUID().uuidString)
        result = result.replacingOccurrences(of: "{{random}}", with: "\(Int.random(in: 0...999999))")

        // {{input.fieldName}} — JSON-Feld-Extraktion
        let jsonFieldPattern = #"\{\{input\.(\w+)\}\}"#
        if let regex = try? NSRegularExpression(pattern: jsonFieldPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            if !matches.isEmpty, let data = input.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for match in matches.reversed() {
                    if let keyRange = Range(match.range(at: 1), in: result),
                       let fullRange = Range(match.range, in: result) {
                        let key = String(result[keyRange])
                        let value = json[key].map { "\($0)" } ?? ""
                        result.replaceSubrange(fullRange, with: value)
                    }
                }
            }
        }

        // {{env.KEY}} — Umgebungsvariablen
        let envPattern = #"\{\{env\.(\w+)\}\}"#
        if let regex = try? NSRegularExpression(pattern: envPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let keyRange = Range(match.range(at: 1), in: result) {
                    let key = String(result[keyRange])
                    let value = ProcessInfo.processInfo.environment[key] ?? ""
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: value)
                    }
                }
            }
        }

        // String-Operationen (Prefix-basiert)
        if result.hasPrefix("upper:") { return input.uppercased() }
        if result.hasPrefix("lower:") { return input.lowercased() }
        if result.hasPrefix("trim:") { return input.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.hasPrefix("reverse:") { return String(input.reversed()) }
        if result.hasPrefix("wordcount:") { return "\(input.split(separator: " ").count)" }
        if result.hasPrefix("count:") { return "\(input.count)" }

        // split:SEPARATOR — trennt Input und gibt JSON-Array zurück
        if result.hasPrefix("split:") {
            let sep = String(result.dropFirst(6))
            let parts = input.components(separatedBy: sep.isEmpty ? "\n" : sep)
            if let data = try? JSONSerialization.data(withJSONObject: parts),
               let json = String(data: data, encoding: .utf8) { return json }
        }
        // join:SEPARATOR — verbindet JSON-Array zu String
        if result.hasPrefix("join:") {
            let sep = String(result.dropFirst(5))
            if let data = input.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return arr.joined(separator: sep.isEmpty ? ", " : sep)
            }
        }
        // first:N — erste N Zeichen/Zeilen
        if result.hasPrefix("first:") {
            if let n = Int(result.dropFirst(6)) {
                let lines = input.components(separatedBy: "\n")
                return lines.prefix(n).joined(separator: "\n")
            }
        }
        // last:N — letzte N Zeilen
        if result.hasPrefix("last:") {
            if let n = Int(result.dropFirst(5)) {
                let lines = input.components(separatedBy: "\n")
                return lines.suffix(n).joined(separator: "\n")
            }
        }

        return result
    }

    // MARK: - Webhook Execution

    /// Send HTTP request to webhook URL
    private func executeWebhook(node: WorkflowNode, input: String) async -> String {
        let urlString = node.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            return "Fehler: Ungültige URL '\(urlString)'"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.5"
        request.setValue("KoboldOS/\(version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        // Send upstream output as JSON body
        let body: [String: String] = ["data": input, "source": "KoboldOS Workflow"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if statusCode >= 200 && statusCode < 300 {
                return responseBody.isEmpty ? "OK (\(statusCode))" : String(responseBody.prefix(2000))
            } else {
                return "HTTP \(statusCode): \(String(responseBody.prefix(500)))"
            }
        } catch {
            return "Webhook-Fehler: \(error.localizedDescription)"
        }
    }
}

// MARK: - WorkflowNode

// MARK: - WorkflowConnection

/// Bedingung für Switch-Node: wird sequenziell gegen Upstream-Output evaluiert
struct SwitchCase: Codable, Identifiable {
    let id: UUID
    var label: String          // z.B. "Enthält Fehler"
    var expression: String     // z.B. "contains('error')"
    var portIndex: Int         // Welcher Output-Port (0, 1, 2, ...)

    init(id: UUID = UUID(), label: String = "", expression: String = "", portIndex: Int = 0) {
        self.id = id; self.label = label; self.expression = expression; self.portIndex = portIndex
    }
}

/// Verbindungstyp: Normal oder Error-Pfad
enum ConnectionType: String, Codable {
    case normal = "normal"
    case error  = "error"
}

struct WorkflowConnection: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceNodeId: UUID
    var targetNodeId: UUID
    var sourcePort: Int  // 0 = right
    var targetPort: Int  // 0 = left
    var connectionType: ConnectionType = .normal  // v0.4: Error-Branching

    init(id: UUID = UUID(), sourceNodeId: UUID, targetNodeId: UUID, sourcePort: Int = 0, targetPort: Int = 0, connectionType: ConnectionType = .normal) {
        self.id = id
        self.sourceNodeId = sourceNodeId
        self.targetNodeId = targetNodeId
        self.sourcePort = sourcePort
        self.targetPort = targetPort
        self.connectionType = connectionType
    }
}

// MARK: - WorkflowNode

// MARK: - NodeExecutionStatus

enum NodeExecutionStatus: String, Codable {
    case idle     // Grau — nicht aktiv
    case waiting  // Blau — wartet auf Upstream
    case running  // Grün-pulsierend — wird gerade ausgeführt
    case success  // Grün — erfolgreich abgeschlossen
    case error    // Rot — Fehler aufgetreten

    var color: Color {
        switch self {
        case .idle:    return .gray
        case .waiting: return .blue
        case .running: return .green
        case .success: return .green
        case .error:   return .red
        }
    }

    var icon: String {
        switch self {
        case .idle:    return "circle"
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.circle.fill"
        }
    }
}

struct WorkflowNode: Identifiable, Codable {
    let id: UUID
    var type: NodeType
    var title: String
    var prompt: String
    var x: CGFloat
    var y: CGFloat
    var lastOutput: String = ""
    var triggerConfig: TriggerConfig?
    var conditionExpression: String = ""  // For condition nodes: e.g. "output.contains('error')"
    var delaySeconds: Int = 0             // For delay nodes
    var modelOverride: String?            // Per-node model (e.g. "llama3.2", "gpt-4o")
    var agentType: String?                // Per-node agent type (e.g. "coder", "web")
    var teamId: String?                   // For team nodes: which team to consult
    var skillName: String?                 // For agent nodes: which skill to inject

    // v0.4 — Erweiterte Workflow-Properties
    var loopSeparator: String?            // Loop: Trennzeichen (default "\n")
    var loopMaxIterations: Int?           // Loop: Sicherheitslimit (default 100)
    var subWorkflowProjectId: String?     // SubWorkflow: Ziel-Projekt UUID
    var taskIdRef: String?                // Task: Referenz auf ScheduledTask
    var retryCount: Int?                  // Retry: Anzahl Versuche (default 3)
    var retryDelaySeconds: Int?           // Retry: Pause zwischen Versuchen (default 5s)
    var switchCases: [SwitchCase]?        // Switch: Bedingungen + Port-Index
    var noteText: String?                 // Note: Freitext

    // Execution state (not persisted)
    var executionStatus: NodeExecutionStatus = .idle
    var statusMessage: String = ""
    var executionProgress: Double = 0.0
    var errorMessage: String = ""

    enum CodingKeys: String, CodingKey {
        case id, type, title, prompt, x, y, triggerConfig, conditionExpression, delaySeconds
        case modelOverride, agentType, teamId, skillName
        case loopSeparator, loopMaxIterations, subWorkflowProjectId, taskIdRef
        case retryCount, retryDelaySeconds, switchCases, noteText
    }

    init(id: UUID = UUID(), type: NodeType, title: String, prompt: String = "", x: CGFloat, y: CGFloat) {
        self.id = id; self.type = type; self.title = title
        self.prompt = prompt; self.x = x; self.y = y
    }

    static func defaultWorkflow() -> ([WorkflowNode], [WorkflowConnection]) {
        var trigger = WorkflowNode(type: .trigger, title: "Start", x: 60, y: 160)
        trigger.triggerConfig = TriggerConfig(type: .manual)
        let instr  = WorkflowNode(type: .agent,   title: "Instructor",  x: 260, y: 160)
        let coder  = WorkflowNode(type: .agent,   title: "Coder",       x: 460, y: 100)
        let output = WorkflowNode(type: .output,   title: "Antwort",    x: 660, y: 160)
        let connections = [
            WorkflowConnection(sourceNodeId: trigger.id, targetNodeId: instr.id),
            WorkflowConnection(sourceNodeId: instr.id, targetNodeId: coder.id),
            WorkflowConnection(sourceNodeId: coder.id, targetNodeId: output.id),
        ]
        return ([trigger, instr, coder, output], connections)
    }

    // MARK: - Trigger Configuration

    struct TriggerConfig: Codable {
        var type: TriggerType
        var cronExpression: String = ""     // For .cron: "0 8 * * *"
        var webhookPath: String = ""        // For .webhook: "/hook/my-workflow"
        var watchPath: String = ""          // For .fileWatcher: "/path/to/watch"
        var eventName: String = ""          // For .appEvent: "app_start", "memory_update", etc.
        var httpMethod: String = "POST"     // For .webhook

        enum TriggerType: String, Codable, CaseIterable {
            case manual      = "Manual"
            case cron        = "Zeitplan"
            case webhook     = "Webhook"
            case fileWatcher = "Datei-Watcher"
            case appEvent    = "App-Event"

            var icon: String {
                switch self {
                case .manual:      return "play.circle.fill"
                case .cron:        return "clock.badge.checkmark"
                case .webhook:     return "antenna.radiowaves.left.and.right"
                case .fileWatcher: return "folder.badge.gearshape"
                case .appEvent:    return "app.badge.fill"
                }
            }
            var description: String {
                switch self {
                case .manual:      return "Manuell per Klick starten"
                case .cron:        return "Zeitgesteuert (Cron-Ausdruck)"
                case .webhook:     return "HTTP-Endpoint empfängt Daten"
                case .fileWatcher: return "Reagiert auf Dateiänderungen"
                case .appEvent:    return "Reagiert auf App-Events"
                }
            }
        }
    }

    enum NodeType: String, CaseIterable, Codable {
        case trigger     = "Trigger"
        case input       = "Input"
        case agent       = "Agent"
        case tool        = "Tool"
        case output      = "Output"
        case condition   = "Condition"
        case merger      = "Merger"
        case delay       = "Delay"
        case webhook     = "Webhook"
        case formula     = "Formula"
        case team        = "Team"
        // v0.4 — Erweiterte Workflow-Nodes
        case loop        = "Loop"
        case errorHandler = "Error-Handler"
        case subWorkflow = "Sub-Workflow"
        case task        = "Task"
        case retry       = "Retry"
        case switchNode  = "Switch"
        case note        = "Note"

        var color: Color {
            switch self {
            case .trigger:      return .red
            case .input:        return .koboldEmerald
            case .agent:        return .koboldGold
            case .tool:         return .koboldEmerald
            case .output:       return .koboldGold
            case .condition:    return .orange
            case .merger:       return .koboldEmerald
            case .delay:        return .gray
            case .webhook:      return .koboldGold
            case .formula:      return .koboldEmerald
            case .team:         return .purple
            case .loop:         return .cyan
            case .errorHandler: return .red.opacity(0.8)
            case .subWorkflow:  return .purple.opacity(0.7)
            case .task:         return .teal
            case .retry:        return .orange
            case .switchNode:   return .yellow
            case .note:         return .gray.opacity(0.6)
            }
        }
        var icon: String {
            switch self {
            case .trigger:      return "bolt.circle.fill"
            case .input:        return "arrow.right.circle"
            case .agent:        return "brain"
            case .tool:         return "wrench.fill"
            case .output:       return "checkmark.circle.fill"
            case .condition:    return "arrow.triangle.branch"
            case .merger:       return "arrow.triangle.merge"
            case .delay:        return "clock.fill"
            case .webhook:      return "antenna.radiowaves.left.and.right"
            case .formula:      return "function"
            case .team:         return "person.3.fill"
            case .loop:         return "repeat"
            case .errorHandler: return "exclamationmark.shield.fill"
            case .subWorkflow:  return "arrow.triangle.swap"
            case .task:         return "checkmark.rectangle.stack.fill"
            case .retry:        return "arrow.clockwise.circle.fill"
            case .switchNode:   return "arrow.triangle.branch"
            case .note:         return "text.bubble.fill"
            }
        }
    }
}

// MARK: - WorkflowState (Codable wrapper for persistence)

struct WorkflowState: Codable {
    var nodes: [WorkflowNode]
    var connections: [WorkflowConnection]
}

// MARK: - WorkflowNodeCard

struct WorkflowNodeCard: View {
    @Binding var node: WorkflowNode
    let isSelected: Bool
    let isRunning: Bool
    var onPortDragStart: ((UUID, Bool) -> Void)? = nil  // (nodeId, isOutputPort)
    var onPortDragEnd: ((UUID, CGPoint) -> Void)? = nil  // (nodeId, globalPosition)
    var onPortDragUpdate: ((CGPoint) -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil  // Navigate to workflow chat session
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @GestureState private var dragStart: CGPoint? = nil

    /// Only THIS node is actively running
    private var isNodeRunning: Bool { node.executionStatus == .running }

    /// Border color based on execution status
    private var borderColor: Color {
        if isSelected { return node.type.color }
        switch node.executionStatus {
        case .idle:    return Color.white.opacity(0.12)
        case .waiting: return Color.blue.opacity(0.5)
        case .running: return Color.green.opacity(0.8)
        case .success: return Color.green.opacity(0.6)
        case .error:   return Color.red.opacity(0.7)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Type label bar
                HStack(spacing: 4) {
                    Image(systemName: node.type.icon)
                        .font(.system(size: 11.5))
                    Text(node.type.rawValue.uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundColor(node.type.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(node.type.color.opacity(0.15))

                // Node title
                Text(node.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, node.executionStatus == .idle ? 8 : 4)

                // Mini status bar (only when not idle)
                if node.executionStatus != .idle {
                    HStack(spacing: 3) {
                        if isNodeRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: node.executionStatus.icon)
                                .font(.system(size: 9))
                                .foregroundColor(node.executionStatus.color)
                        }
                        Text(node.statusMessage.isEmpty ? node.executionStatus.rawValue : node.statusMessage)
                            .font(.system(size: 9.5))
                            .foregroundColor(node.executionStatus.color)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)

                    // Progress bar
                    if node.executionProgress > 0 && node.executionProgress < 1 {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(node.executionStatus.color.opacity(0.6))
                                .frame(width: geo.size.width * node.executionProgress, height: 2)
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    }

                    // Chat link — visible from execution start for agent/tool nodes
                    if (node.executionStatus == .running || node.executionStatus == .success || node.executionStatus == .error),
                       (node.type == .agent || node.type == .tool || node.type == .team),
                       let openChat = onOpenChat {
                        Button(action: openChat) {
                            HStack(spacing: 3) {
                                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                    .font(.system(size: 8))
                                Text(lang.openChat)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.koboldGold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.koboldGold.opacity(0.1))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 4)
                    }
                }
            }
            .frame(width: 130)
            .frame(minHeight: 70)
            .background(Color.koboldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : (node.executionStatus == .idle ? 1 : 1.5))
            )
            .cornerRadius(8)

            // Left port (input) — draggable for connections
            PortCircle(color: node.type.color)
                .offset(x: -65, y: 0)
                .gesture(
                    DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            onPortDragStart?(node.id, false)
                            onPortDragUpdate?(value.location)
                        }
                        .onEnded { value in
                            onPortDragEnd?(node.id, value.location)
                        }
                )

            // Right port (output) — draggable for connections
            PortCircle(color: node.type.color)
                .offset(x: 65, y: 0)
                .gesture(
                    DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            onPortDragStart?(node.id, true)
                            onPortDragUpdate?(value.location)
                        }
                        .onEnded { value in
                            onPortDragEnd?(node.id, value.location)
                        }
                )
        }
        .shadow(
            color: isNodeRunning ? Color.green.opacity(0.5) :
                   (isSelected ? node.type.color.opacity(0.4) :
                   (node.executionStatus == .success ? Color.green.opacity(0.3) :
                   (node.executionStatus == .error ? Color.red.opacity(0.3) : .black.opacity(0.3)))),
            radius: isNodeRunning ? 16 : (isSelected ? 12 : 4)
        )
        // Running indicator: static green glow (kein repeatForever — spart GPU)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(isNodeRunning ? 0.6 : 0), lineWidth: 2)
        )
        .gesture(
            DragGesture()
                .updating($dragStart) { value, state, _ in
                    if state == nil {
                        state = CGPoint(x: node.x, y: node.y)
                    }
                }
                .onChanged { value in
                    if let start = dragStart {
                        node.x = start.x + value.translation.width
                        node.y = start.y + value.translation.height
                    }
                }
        )
    }
}

// MARK: - PortCircle

struct PortCircle: View {
    let color: Color
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(hovering ? color.opacity(0.9) : color)
            .frame(width: hovering ? 14 : 10, height: hovering ? 14 : 10)
            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: hovering ? 2 : 1))
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .onHover { h in hovering = h }
    }
}

// MARK: - NodeInspector

struct NodeInspector: View {
    @Binding var node: WorkflowNode
    let onClose: () -> Void
    let onDelete: () -> Void
    let onOpenChat: () -> Void
    var incomingConnections: [WorkflowConnection] = []
    var outgoingConnections: [WorkflowConnection] = []
    var onDeleteConnection: ((UUID) -> Void)? = nil
    var onToggleConnectionType: ((UUID) -> Void)? = nil
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Node").font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Typ").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $node.type) {
                    ForEach(WorkflowNode.NodeType.allCases, id: \.self) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.menu)
            }

            // Kontextsensitiver Datenfluss-Banner
            dataFlowBanner

            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Name", tooltip: "Anzeigename des Nodes im Canvas. Hat keinen Einfluss auf die Ausführung.")
                GlassTextField(text: $node.title, placeholder: "Node-Name")
            }

            if node.type != .note {
                VStack(alignment: .leading, spacing: 6) {
                    LabelWithTooltip(label: "Prompt", tooltip: promptTooltipText)
                    TextEditor(text: $node.prompt)
                        .font(.system(size: 13.5))
                        .frame(minHeight: 80)
                        .padding(6)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                }
            }

            // Connections section
            if !incomingConnections.isEmpty || !outgoingConnections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.connectionsLabel).font(.caption).foregroundColor(.secondary)
                    ForEach(incomingConnections) { conn in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.koboldEmerald)
                            Text("← Eingang").font(.system(size: 13.5)).foregroundColor(.secondary)
                            Spacer()
                            Button(action: { onDeleteConnection?(conn.id) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2).foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(outgoingConnections) { conn in
                        HStack(spacing: 4) {
                            Image(systemName: conn.connectionType == .error ? "exclamationmark.triangle.fill" : "arrow.right")
                                .font(.caption2)
                                .foregroundColor(conn.connectionType == .error ? .red : .koboldGold)
                            Text(conn.connectionType == .error ? "→ Fehler-Pfad" : "→ Ausgang")
                                .font(.system(size: 13.5))
                                .foregroundColor(conn.connectionType == .error ? .red : .secondary)
                            Spacer()
                            // Toggle zwischen Normal und Error-Pfad
                            Button(action: { onToggleConnectionType?(conn.id) }) {
                                Image(systemName: conn.connectionType == .error ? "checkmark.circle" : "exclamationmark.shield")
                                    .font(.caption2).foregroundColor(.orange.opacity(0.8))
                                    .help(conn.connectionType == .error ? "Zu Normal-Verbindung ändern" : "Zu Fehler-Pfad ändern")
                            }
                            .buttonStyle(.plain)
                            Button(action: { onDeleteConnection?(conn.id) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2).foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Trigger-specific configuration
            if node.type == .trigger {
                triggerConfigSection
            }

            // Tool selection
            if node.type == .tool {
                ToolSelectionGrid(selectedTool: Binding(
                    get: { node.agentType ?? "shell" },
                    set: { node.agentType = $0 }
                ))
            }

            // Condition expression
            if node.type == .condition {
                VStack(alignment: .leading, spacing: 6) {
                    LabelWithTooltip(label: "Bedingung", tooltip: "Ausdruck der den Upstream-Output prüft. Verfügbar: contains('text'), isEmpty, length > N, startsWith('x'), endsWith('x'), matches(/regex/), equals('x'), json.field == 'value'")
                    GlassTextField(text: $node.conditionExpression, placeholder: "z.B. contains('error')")
                    Text("Wahr → oberer Ausgang. Falsch → unterer Ausgang.")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }

            // Delay
            if node.type == .delay {
                VStack(alignment: .leading, spacing: 6) {
                    LabelWithTooltip(label: "Verzögerung (Sek.)", tooltip: "Wartezeit in Sekunden bevor der Output an den nächsten Node weitergegeben wird. Der Upstream-Output wird unverändert durchgereicht.")
                    TextField("", value: $node.delaySeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            // Formula
            if node.type == .formula {
                VStack(alignment: .leading, spacing: 6) {
                    LabelWithTooltip(label: "Formel", tooltip: "Template mit Variablen: {{input}}, {{date}}, {{length}}, {{lines}}, {{env.KEY}}, {{uuid}}, {{timestamp}}, {{random}}, {{input.fieldName}} für JSON-Felder. Operationen: upper:, lower:, trim:, split:, join:, first:N, last:N, count:")
                    TextEditor(text: $node.prompt)
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(minHeight: 60)
                        .padding(6)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                    Text("{{input}} = Upstream-Output. Operationen: upper:, lower:, split:, first:N")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }

            // v0.4 — Neue Node-Typ-Konfigurationen
            newNodeTypeConfig

            // Agent-specific: type, model, chat
            if node.type == .agent {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent-Typ").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { node.agentType ?? "general" },
                        set: { node.agentType = $0 == "general" ? nil : $0 }
                    )) {
                        Text("General").tag("general")
                        Text("Coder").tag("coder")
                        Text("Web").tag("web")
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Modell").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { node.modelOverride ?? "" },
                        set: { node.modelOverride = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Standard").tag("")
                        ForEach(viewModel.loadedModels, id: \.name) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                }

                SkillPickerSection(selectedSkill: Binding(
                    get: { node.skillName ?? "" },
                    set: { node.skillName = $0.isEmpty ? nil : $0 }
                ))

                GlassButton(title: lang.openChat, icon: "message.fill", isPrimary: true) {
                    onOpenChat()
                }
            }

            // Team-specific: team selection
            if node.type == .team {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.selectTeam).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { node.teamId ?? "" },
                        set: { node.teamId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Kein Team").tag("")
                        if !viewModel.managedTeams.isEmpty {
                            Section("Eigene Teams") {
                                ForEach(viewModel.managedTeams) { team in
                                    Text("\(team.name) (\(team.members.count) Mitglieder)").tag(team.id)
                                }
                            }
                        }
                        Section("Standard-Teams") {
                            ForEach(viewModel.teams) { team in
                                Text("\(team.name) (\(team.agents.count) Agenten)").tag(team.id.uuidString)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .onAppear { Task { await viewModel.loadManagedTeams() } }
                }

                if let teamIdStr = node.teamId,
                   let team = viewModel.teams.first(where: { $0.id.uuidString == teamIdStr }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agenten:").font(.caption.bold()).foregroundColor(.secondary)
                        ForEach(team.agents) { agent in
                            HStack(spacing: 4) {
                                Circle().fill(agent.isActive ? Color.koboldEmerald : .gray).frame(width: 6, height: 6)
                                Text(agent.name).font(.system(size: 12.5))
                                Text("(\(agent.role))").font(.system(size: 11.5)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Spacer()

            GlassButton(title: "\(lang.delete) Node", icon: "trash", isDestructive: true) {
                onDelete()
            }
        }
        .padding(16)
    }

    // MARK: - Tooltips & Datenfluss-Banner

    /// Kontextabhängiger Tooltip für das Prompt-Feld
    private var promptTooltipText: String {
        switch node.type {
        case .agent:
            return "Anweisung für diesen Agent-Node. Wird MIT dem Upstream-Output kombiniert (nicht ersetzt). Der Upstream-Output erscheint als 'Kontext:' unter dem Prompt."
        case .tool:
            return "Beschreibung was das Tool tun soll. Der Agent entscheidet basierend auf diesem Prompt + Input welche Aktion ausgeführt wird."
        case .formula:
            return "Template mit Variablen. {{input}} wird durch den Upstream-Output ersetzt. Siehe Formel-Hilfe unten."
        case .errorHandler:
            return "Recovery-Prompt: Wird ausgeführt wenn ein vorgelagerter Node einen Fehler wirft. Der Fehler-Kontext wird als Input übergeben."
        case .task:
            return "Aufgabe für den Task. Wird mit dem Upstream-Output als Kontext kombiniert."
        case .subWorkflow:
            return "Optionaler Prompt der dem Sub-Workflow als Startinput übergeben wird. Leer = Upstream-Output wird direkt weitergegeben."
        default:
            return "Anweisung oder Konfiguration für diesen Node."
        }
    }

    /// Kontextsensitiver Datenfluss-Banner
    @ViewBuilder
    private var dataFlowBanner: some View {
        let info: (icon: String, text: String, color: Color) = {
            switch node.type {
            case .agent:    return ("brain", "Prompt + Upstream-Output werden als Kontext kombiniert", .koboldGold)
            case .tool:     return ("wrench.fill", "Agent entscheidet welches Tool basierend auf Prompt + Input", .koboldEmerald)
            case .condition: return ("arrow.triangle.branch", "Upstream-Output wird gegen den Ausdruck geprüft", .orange)
            case .formula:  return ("function", "{{input}} wird durch den Upstream-Output ersetzt", .koboldEmerald)
            case .loop:     return ("repeat", "Input wird am Trennzeichen gesplittet, jedes Item einzeln verarbeitet", .cyan)
            case .errorHandler: return ("exclamationmark.shield.fill", "Wird NUR bei Fehler aktiviert (rote Verbindung)", .red)
            case .subWorkflow: return ("arrow.triangle.swap", "Upstream-Output → Sub-Workflow Input → Sub-Workflow Output zurück", .purple)
            case .switchNode: return ("arrow.triangle.branch", "Cases werden sequenziell geprüft, erster Match bestimmt Output-Port", .yellow)
            case .retry:    return ("arrow.clockwise.circle.fill", "Downstream-Nodes werden N-mal wiederholt bei Fehler", .orange)
            case .merger:   return ("arrow.triangle.merge", "Alle Upstream-Outputs werden zusammengeführt (mit \\n\\n getrennt)", .koboldEmerald)
            case .note:     return ("text.bubble.fill", "Pass-Through: Input wird unverändert an den nächsten Node weitergegeben", .gray)
            default:        return ("info.circle", "Daten fließen von links nach rechts durch verbundene Nodes", .secondary)
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: info.icon).font(.system(size: 11)).foregroundColor(info.color)
            Text(info.text).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(8)
        .background(info.color.opacity(0.06))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(info.color.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - Neue Node-Typ Konfiguration (v0.4)

    @ViewBuilder
    private var newNodeTypeConfig: some View {
        if node.type == .loop {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Trennzeichen", tooltip: "Der Upstream-Output wird an diesem Zeichen gesplittet. Jedes resultierende Item wird einzeln durch die Downstream-Nodes geschickt. Standard: Zeilenumbruch (\\n)")
                GlassTextField(text: Binding(
                    get: { node.loopSeparator ?? "\\n" },
                    set: { node.loopSeparator = $0 == "\\n" ? nil : $0 }
                ), placeholder: "\\n")
            }
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Max. Iterationen", tooltip: "Sicherheitslimit: Loop bricht nach dieser Anzahl Items ab. Verhindert Endlosschleifen bei großen Datenmengen.")
                Stepper(value: Binding(
                    get: { node.loopMaxIterations ?? 100 },
                    set: { node.loopMaxIterations = $0 }
                ), in: 1...10000) {
                    Text("\(node.loopMaxIterations ?? 100)").font(.system(size: 13, design: .monospaced))
                }
            }
        }

        if node.type == .errorHandler {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fängt Fehler von allen über rote Verbindungen angeschlossenen Nodes auf.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
                Text("Ohne Prompt: Gibt Fehlertext weiter. Mit Prompt: Agent verarbeitet den Fehler.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary.opacity(0.7))
            }
            .padding(8)
            .background(Color.red.opacity(0.06))
            .cornerRadius(6)
        }

        if node.type == .subWorkflow {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Ziel-Projekt", tooltip: "Wähle welches Projekt als Sub-Workflow ausgeführt wird. Der Upstream-Output wird als Start-Input übergeben. Max. Verschachtelungstiefe: 5.")
                Picker("", selection: Binding(
                    get: { node.subWorkflowProjectId ?? "" },
                    set: { node.subWorkflowProjectId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Projekt wählen...").tag("")
                    ForEach(viewModel.projects.filter { $0.id != viewModel.selectedProjectId }) { project in
                        Text(project.name).tag(project.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        if node.type == .task {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Task-Referenz", tooltip: "Name oder ID der auszuführenden Aufgabe. Der Task wird als Background-Session gestartet und der Workflow wartet auf das Ergebnis (max 60s).")
                GlassTextField(text: Binding(
                    get: { node.taskIdRef ?? "" },
                    set: { node.taskIdRef = $0.isEmpty ? nil : $0 }
                ), placeholder: "Task-Name")
            }
        }

        if node.type == .retry {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Anzahl Versuche", tooltip: "Wie oft die nachfolgenden Nodes bei Fehler erneut ausgeführt werden. Bei Erfolg wird sofort fortgefahren.")
                Stepper(value: Binding(
                    get: { node.retryCount ?? 3 },
                    set: { node.retryCount = $0 }
                ), in: 1...10) {
                    Text("\(node.retryCount ?? 3)x").font(.system(size: 13, design: .monospaced))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Pause (Sek.)", tooltip: "Wartezeit in Sekunden zwischen den Retry-Versuchen. Gibt dem System Zeit sich zu erholen.")
                Stepper(value: Binding(
                    get: { node.retryDelaySeconds ?? 5 },
                    set: { node.retryDelaySeconds = $0 }
                ), in: 1...60) {
                    Text("\(node.retryDelaySeconds ?? 5)s").font(.system(size: 13, design: .monospaced))
                }
            }
        }

        if node.type == .switchNode {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Switch-Cases", tooltip: "Bedingungen werden der Reihe nach geprüft. Der erste Match bestimmt welcher Output-Port aktiviert wird. Jeder Port muss mit einer Verbindung zu einem anderen Node verbunden sein.")
                ForEach(Array((node.switchCases ?? []).enumerated()), id: \.element.id) { idx, sc in
                    HStack(spacing: 4) {
                        Text("Port \(sc.portIndex)").font(.system(size: 11, design: .monospaced)).foregroundColor(.yellow)
                        GlassTextField(text: Binding(
                            get: { node.switchCases?[safe: idx]?.expression ?? "" },
                            set: { if node.switchCases != nil { node.switchCases?[idx].expression = $0 } }
                        ), placeholder: "Ausdruck")
                        Button(action: { node.switchCases?.remove(at: idx) }) {
                            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button(action: {
                    let nextPort = (node.switchCases?.count ?? 0)
                    if node.switchCases == nil { node.switchCases = [] }
                    node.switchCases?.append(SwitchCase(label: "Case \(nextPort+1)", expression: "", portIndex: nextPort))
                }) {
                    Label("Case hinzufügen", systemImage: "plus.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.yellow)
            }
        }

        if node.type == .note {
            VStack(alignment: .leading, spacing: 6) {
                LabelWithTooltip(label: "Notiz", tooltip: "Freitext-Notiz zur Dokumentation. Wird im Canvas als Tooltip angezeigt. Hat keinen Einfluss auf den Datenfluss — Input wird unverändert durchgereicht.")
                TextEditor(text: Binding(
                    get: { node.noteText ?? "" },
                    set: { node.noteText = $0 }
                ))
                    .font(.system(size: 13))
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
            }
        }

        // Letzter Output (Data Preview)
        if !node.lastOutput.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                LabelWithTooltip(label: "Letzter Output", tooltip: "Ergebnis der letzten Ausführung dieses Nodes. Kann kopiert werden.")
                ScrollView {
                    Text(node.lastOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(Color.black.opacity(0.15))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Trigger Config

    @ViewBuilder
    private var triggerConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trigger-Typ").font(.caption).foregroundColor(.secondary)

            let triggerType = Binding<WorkflowNode.TriggerConfig.TriggerType>(
                get: { node.triggerConfig?.type ?? .manual },
                set: { newType in
                    if node.triggerConfig == nil {
                        node.triggerConfig = WorkflowNode.TriggerConfig(type: newType)
                    } else {
                        node.triggerConfig?.type = newType
                    }
                }
            )

            ForEach(WorkflowNode.TriggerConfig.TriggerType.allCases, id: \.self) { type in
                Button(action: { triggerType.wrappedValue = type }) {
                    HStack(spacing: 8) {
                        Image(systemName: type.icon)
                            .font(.system(size: 14.5))
                            .foregroundColor(triggerType.wrappedValue == type ? .white : .secondary)
                            .frame(width: 24, height: 24)
                            .background(triggerType.wrappedValue == type ? Color.red : Color.clear)
                            .cornerRadius(6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(type.rawValue)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(triggerType.wrappedValue == type ? .primary : .secondary)
                            Text(type.description)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if triggerType.wrappedValue == type {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(triggerType.wrappedValue == type ? Color.red.opacity(0.1) : Color.clear)
                .cornerRadius(8)
            }

            // Type-specific fields
            switch triggerType.wrappedValue {
            case .cron:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cron-Ausdruck").font(.system(size: 12.5, weight: .semibold))
                    let cronBinding = Binding<String>(
                        get: { node.triggerConfig?.cronExpression ?? "" },
                        set: { node.triggerConfig?.cronExpression = $0 }
                    )
                    GlassTextField(text: cronBinding, placeholder: "0 8 * * * (täglich 8 Uhr)")
                    Text("Min Std Tag Mon WTag").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.secondary)
                }

            case .webhook:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook-Pfad").font(.system(size: 12.5, weight: .semibold))
                    let pathBinding = Binding<String>(
                        get: { node.triggerConfig?.webhookPath ?? "" },
                        set: { node.triggerConfig?.webhookPath = $0 }
                    )
                    GlassTextField(text: pathBinding, placeholder: "/hook/mein-workflow")
                    if let path = node.triggerConfig?.webhookPath, !path.isEmpty {
                        Text("URL: http://localhost:8080\(path)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                            .textSelection(.enabled)
                    }
                }

            case .fileWatcher:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Überwachter Pfad").font(.system(size: 12.5, weight: .semibold))
                    let watchBinding = Binding<String>(
                        get: { node.triggerConfig?.watchPath ?? "" },
                        set: { node.triggerConfig?.watchPath = $0 }
                    )
                    GlassTextField(text: watchBinding, placeholder: "~/Documents/watch")
                }

            case .appEvent:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Event").font(.system(size: 12.5, weight: .semibold))
                    let eventBinding = Binding<String>(
                        get: { node.triggerConfig?.eventName ?? "" },
                        set: { node.triggerConfig?.eventName = $0 }
                    )
                    Picker("", selection: eventBinding) {
                        Text("App-Start").tag("app_start")
                        Text("Neue Nachricht").tag("new_message")
                        Text("Task fertig").tag("task_complete")
                        Text(lang.errorLabel).tag("error")
                        Text("Memory-Update").tag("memory_update")
                    }
                    .pickerStyle(.menu)
                }

            case .manual:
                Text("Workflow wird manuell über den Play-Button gestartet.")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.15), lineWidth: 0.5))
    }
}

// MARK: - Tool Selection Grid (categorized, all 46 tools)

private struct ToolCategory: Identifiable {
    let id: String
    let label: String
    let tools: [(id: String, icon: String, label: String)]
}

private let allToolCategories: [ToolCategory] = [
    ToolCategory(id: "basis", label: "Basis", tools: [
        (id: "shell",       icon: "terminal.fill",                 label: "Shell-Befehl"),
        (id: "file",        icon: "doc.fill",                      label: "Datei lesen/schreiben"),
        (id: "http",        icon: "network",                       label: "HTTP-Request"),
        (id: "browser",     icon: "globe",                         label: "Web-Suche"),
        (id: "applescript", icon: "applescript",                    label: "AppleScript"),
    ]),
    ToolCategory(id: "komm", label: "Kommunikation", tools: [
        (id: "telegram_send", icon: "paperplane.fill",             label: "Telegram"),
        (id: "email",         icon: "envelope.fill",               label: "E-Mail"),
        (id: "sms_send",      icon: "message.fill",                label: "SMS"),
        (id: "slack_api",     icon: "number",                      label: "Slack"),
        (id: "whatsapp_api",  icon: "phone.bubble.fill",           label: "WhatsApp"),
    ]),
    ToolCategory(id: "apis", label: "APIs & Verbindungen", tools: [
        (id: "github_api",      icon: "chevron.left.forwardslash.chevron.right", label: "GitHub"),
        (id: "google_api",      icon: "magnifyingglass",           label: "Google"),
        (id: "microsoft_api",   icon: "envelope.badge.fill",       label: "Microsoft"),
        (id: "soundcloud_api",  icon: "waveform",                  label: "SoundCloud"),
        (id: "notion_api",      icon: "doc.text.fill",             label: "Notion"),
        (id: "huggingface_api", icon: "cpu",                       label: "HuggingFace"),
        (id: "reddit_api",      icon: "bubble.left.and.bubble.right.fill", label: "Reddit"),
        (id: "suno_api",        icon: "music.note",                label: "Suno AI"),
        (id: "uber_api",        icon: "car.fill",                  label: "Uber"),
        (id: "lieferando_api",  icon: "takeoutbag.and.cup.and.straw.fill", label: "Lieferando"),
    ]),
    ToolCategory(id: "medien", label: "Medien", tools: [
        (id: "speak",          icon: "speaker.wave.3.fill",        label: "Text vorlesen"),
        (id: "generate_image", icon: "photo.artframe",             label: "Bild generieren"),
        (id: "vision_load",    icon: "eye.fill",                   label: "Bild analysieren"),
        (id: "playwright",     icon: "theatermasks.fill",          label: "Browser-Bot"),
    ]),
    ToolCategory(id: "memory", label: "Gedächtnis", tools: [
        (id: "memory_save",            icon: "brain.head.profile",  label: "Erinnerung speichern"),
        (id: "memory_recall",          icon: "brain",               label: "Erinnerung abrufen"),
        (id: "core_memory_append",     icon: "text.badge.plus",     label: "Core Memory +"),
        (id: "core_memory_replace",    icon: "text.badge.checkmark",label: "Core Memory ersetzen"),
        (id: "archival_memory_search", icon: "archivebox.fill",     label: "Archiv durchsuchen"),
    ]),
    ToolCategory(id: "macos", label: "macOS", tools: [
        (id: "calendar",       icon: "calendar",                   label: "Kalender"),
        (id: "contacts",       icon: "person.2.fill",              label: "Kontakte"),
        (id: "screen_control", icon: "display",                    label: "Bildschirm"),
        (id: "app_terminal",   icon: "rectangle.topthird.inset.filled", label: "App-Terminal"),
    ]),
    ToolCategory(id: "infra", label: "IoT & Infra", tools: [
        (id: "caldav",   icon: "calendar.badge.clock",             label: "CalDAV"),
        (id: "mqtt",     icon: "antenna.radiowaves.left.and.right.circle.fill", label: "MQTT"),
        (id: "rss",      icon: "dot.radiowaves.up.forward",       label: "RSS-Feed"),
        (id: "webhook",  icon: "antenna.radiowaves.left.and.right", label: "Webhook"),
        (id: "secrets",  icon: "key.fill",                         label: "Secrets"),
    ]),
    ToolCategory(id: "system", label: "System", tools: [
        (id: "notify_user",      icon: "bell.fill",                label: "Benachrichtigung"),
        (id: "checklist",        icon: "checklist",                label: "Checkliste"),
        (id: "task_manage",      icon: "list.bullet.rectangle",    label: "Task-Verwaltung"),
        (id: "workflow_manage",  icon: "arrow.triangle.branch",    label: "Workflow-Verwaltung"),
        (id: "settings",         icon: "gearshape.fill",           label: "Einstellungen lesen"),
    ]),
    ToolCategory(id: "agenten", label: "Agenten", tools: [
        (id: "call_subordinate",  icon: "person.badge.plus",       label: "Sub-Agent"),
        (id: "delegate_parallel", icon: "person.3.sequence.fill",  label: "Parallel delegieren"),
        (id: "skill_write",       icon: "doc.badge.gearshape",     label: "Skill erstellen"),
    ]),
]

struct ToolSelectionGrid: View {
    @Binding var selectedTool: String
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var searchText = ""

    private var filteredCategories: [ToolCategory] {
        if searchText.isEmpty { return allToolCategories }
        let q = searchText.lowercased()
        return allToolCategories.compactMap { cat in
            let filtered = cat.tools.filter {
                $0.id.lowercased().contains(q) || $0.label.lowercased().contains(q)
            }
            return filtered.isEmpty ? nil : ToolCategory(id: cat.id, label: cat.label, tools: filtered)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tool / Integration").font(.caption).foregroundColor(.secondary)

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                TextField(lang.searchDots, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(Color.black.opacity(0.2))
            .cornerRadius(5)

            // Categorized grid
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredCategories) { cat in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cat.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 3) {
                                ForEach(cat.tools, id: \.id) { tool in
                                    Button(action: { selectedTool = tool.id }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: tool.icon)
                                                .font(.system(size: 11.5))
                                                .frame(width: 15)
                                            Text(tool.label)
                                                .font(.system(size: 11.5))
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 5).padding(.vertical, 3)
                                        .background(selectedTool == tool.id ? Color.koboldEmerald.opacity(0.2) : Color.koboldSurface)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(selectedTool == tool.id ? Color.koboldEmerald : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }
}

// MARK: - Skill Picker Section (for Agent nodes)

struct SkillPickerSection: View {
    @Binding var selectedSkill: String
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var skills: [Skill] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.skill).font(.caption).foregroundColor(.secondary)
            Picker("", selection: $selectedSkill) {
                Text("Keine").tag("")
                ForEach(skills) { skill in
                    Text(skill.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .tag(skill.name)
                }
            }
            .pickerStyle(.menu)

            if !selectedSkill.isEmpty,
               let skill = skills.first(where: { $0.name == selectedSkill }) {
                Text(String(skill.content.prefix(120)) + "...")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(6)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .task {
            skills = await SkillLoader.shared.loadSkills().filter { $0.isEnabled }
        }
    }
}
