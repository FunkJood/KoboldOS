import SwiftUI
import UniformTypeIdentifiers
import KoboldCore

// MARK: - TeamView
// Visuelle n8n-artige Workflow-Builder für Agenten-Teams.

struct TeamView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
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
        viewModel.selectedProject?.name ?? "Kein Projekt ausgewählt"
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
                    Text("Kein Projekt ausgewählt")
                        .font(.title3)
                    Text("Wähle ein Projekt in der Seitenleiste oder erstelle ein neues.")
                        .font(.body).foregroundColor(.secondary)

                    // Workflow ideas
                    GlassCard(padding: 12, cornerRadius: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Workflow-Ideen").font(.system(size: 15.5, weight: .semibold)).foregroundColor(.koboldGold)
                                Spacer()
                                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { workflowSuggestionOffset += 1 } }) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 13.5)).foregroundColor(.koboldGold)
                                }.buttonStyle(.plain).help("Neue Vorschläge laden")
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
                    Text("Verbinde Agenten zu Workflows")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.selectedProject != nil {
                    // Import JSON button
                    GlassButton(title: "Import", icon: "square.and.arrow.down", isPrimary: false) {
                        showImportPicker = true
                    }
                    GlassButton(
                        title: showSavedConfirmation ? "Gespeichert!" : "Speichern",
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
                        title: isRunning ? "Stop" : "Ausführen",
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
                        placeholder: "Workflow-Idee hier dem Agent zum Bauen geben...",
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
                            Text("Erstelle Workflow...")
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
                    Text("Workflow-Ergebnis").font(.headline)
                    Spacer()
                    Button("Schließen") { showRunOutput = false }.buttonStyle(.plain)
                }
                ScrollView {
                    Text(lastRunOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Kopieren") {
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
                        ctx.stroke(path, with: .color(Color.koboldEmerald.opacity(0.5)), lineWidth: 2)

                        // Arrow head
                        let arrowPt = CGPoint(x: toPt.x - 4, y: toPt.y)
                        var arrowPath = Path()
                        arrowPath.move(to: CGPoint(x: arrowPt.x - 8, y: arrowPt.y - 6))
                        arrowPath.addLine(to: arrowPt)
                        arrowPath.addLine(to: CGPoint(x: arrowPt.x - 8, y: arrowPt.y + 6))
                        ctx.stroke(arrowPath, with: .color(Color.koboldEmerald.opacity(0.7)), lineWidth: 1.5)
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
                        viewModel.openWorkflowChat(nodeName: nodeTitle)
                    },
                    incomingConnections: connections.filter { $0.targetNodeId == id },
                    outgoingConnections: connections.filter { $0.sourceNodeId == id },
                    onDeleteConnection: { connId in
                        connections.removeAll { $0.id == connId }
                        saveWorkflowState()
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

        // 1. Reset all nodes to idle
        for i in 0..<nodes.count {
            nodes[i].lastOutput = ""
            nodes[i].executionStatus = .idle
            nodes[i].statusMessage = ""
            nodes[i].executionProgress = 0.0
            nodes[i].errorMessage = ""
        }

        // 2. Build topological execution order
        let targetIds = Set(connections.map { $0.targetNodeId })
        var queue = nodes.filter { !targetIds.contains($0.id) }.map { $0.id }
        var visited = Set<UUID>()

        while !queue.isEmpty {
            guard !Task.isCancelled else { break }
            let currentId = queue.removeFirst()
            guard !visited.contains(currentId) else { continue }
            visited.insert(currentId)

            guard nodes.contains(where: { $0.id == currentId }) else { continue }

            // 2a. Set to waiting
            updateNode(id: currentId) { $0.executionStatus = .waiting; $0.statusMessage = "Wartet..." }

            // Gather context from upstream nodes
            let sourceIds = connections.filter { $0.targetNodeId == currentId }.map { $0.sourceNodeId }
            let upstreamOutput = sourceIds.compactMap { sid in
                nodes.first(where: { $0.id == sid })?.lastOutput
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")

            // 2b. Set to running
            updateNode(id: currentId) { $0.executionStatus = .running; $0.statusMessage = "Verarbeite..." }

            do {
                // 2c. Execute based on node type — use ID-based lookup for safety
                guard let safeIdx = nodes.firstIndex(where: { $0.id == currentId }) else { continue }
                let result = try await executeNode(nodeIdx: safeIdx, upstreamOutput: upstreamOutput)

                // 2d. Set to success
                updateNode(id: currentId) {
                    $0.executionStatus = .success
                    $0.statusMessage = String(result.prefix(60))
                    $0.lastOutput = result
                    $0.executionProgress = 1.0
                }
            } catch {
                // 2d. Set to error
                updateNode(id: currentId) {
                    $0.executionStatus = .error
                    $0.statusMessage = error.localizedDescription
                    $0.errorMessage = error.localizedDescription
                }
            }

            // Small delay for visual feedback
            try? await Task.sleep(nanoseconds: 200_000_000)

            // 2e. Queue downstream nodes — for condition nodes, handle branching
            let nodeType = nodes.first(where: { $0.id == currentId })?.type
            if nodeType == .condition {
                let outConns = connections.filter { $0.sourceNodeId == currentId }
                let conditionResult = nodes.first(where: { $0.id == currentId })?.lastOutput ?? ""
                if conditionResult == "true", let firstConn = outConns.first {
                    queue.append(firstConn.targetNodeId)
                } else if conditionResult == "false", outConns.count > 1 {
                    queue.append(outConns[1].targetNodeId)
                } else if let firstConn = outConns.first {
                    queue.append(firstConn.targetNodeId)
                }
            } else {
                let nextIds = connections.filter { $0.sourceNodeId == currentId }.map { $0.targetNodeId }
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
        }
    }

    // MARK: - Condition Evaluation

    /// Simple string-based condition evaluation
    private func evaluateCondition(expression: String, output: String) -> String {
        let expr = expression.trimmingCharacters(in: .whitespaces).lowercased()

        if expr.contains("contains(") {
            // output.contains("error") → check if output contains the string
            if let range = expr.range(of: #"contains\(['"](.*?)['"]\)"#, options: .regularExpression) {
                let searchStr = String(expr[range]).replacingOccurrences(of: "contains(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                return output.lowercased().contains(searchStr) ? "true" : "false"
            }
        }

        if expr == "output.isempty" || expr == "output.isEmpty" {
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "true" : "false"
        }

        if expr.contains("length") && expr.contains(">") {
            // output.length > 100
            if let numStr = expr.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces),
               let threshold = Int(numStr) {
                return output.count > threshold ? "true" : "false"
            }
        }

        if expr.contains("length") && expr.contains("<") {
            if let numStr = expr.components(separatedBy: "<").last?.trimmingCharacters(in: .whitespaces),
               let threshold = Int(numStr) {
                return output.count < threshold ? "true" : "false"
            }
        }

        // Default: treat non-empty output as true
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }

    // MARK: - Formula Evaluation

    /// Simple formula/template evaluation
    private func evaluateFormula(expression: String, input: String) -> String {
        var result = expression
        // Replace template variables
        result = result.replacingOccurrences(of: "{{input}}", with: input)
        result = result.replacingOccurrences(of: "{{date}}", with: ISO8601DateFormatter().string(from: Date()))
        result = result.replacingOccurrences(of: "{{length}}", with: "\(input.count)")
        result = result.replacingOccurrences(of: "{{lines}}", with: "\(input.components(separatedBy: "\n").count)")

        // Replace {{env.KEY}} with environment variables
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

        // Simple string operations
        if result.hasPrefix("upper:") { return input.uppercased() }
        if result.hasPrefix("lower:") { return input.lowercased() }
        if result.hasPrefix("trim:") { return input.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.hasPrefix("reverse:") { return String(input.reversed()) }
        if result.hasPrefix("wordcount:") { return "\(input.split(separator: " ").count)" }

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

struct WorkflowConnection: Identifiable, Codable {
    let id: UUID
    var sourceNodeId: UUID
    var targetNodeId: UUID
    var sourcePort: Int  // 0 = right
    var targetPort: Int  // 0 = left

    init(id: UUID = UUID(), sourceNodeId: UUID, targetNodeId: UUID, sourcePort: Int = 0, targetPort: Int = 0) {
        self.id = id
        self.sourceNodeId = sourceNodeId
        self.targetNodeId = targetNodeId
        self.sourcePort = sourcePort
        self.targetPort = targetPort
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

    // Execution state (not persisted)
    var executionStatus: NodeExecutionStatus = .idle
    var statusMessage: String = ""
    var executionProgress: Double = 0.0
    var errorMessage: String = ""

    enum CodingKeys: String, CodingKey {
        case id, type, title, prompt, x, y, triggerConfig, conditionExpression, delaySeconds
        case modelOverride, agentType, teamId, skillName
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
        case trigger   = "Trigger"
        case input     = "Input"
        case agent     = "Agent"
        case tool      = "Tool"
        case output    = "Output"
        case condition = "Condition"
        case merger    = "Merger"
        case delay     = "Delay"
        case webhook   = "Webhook"
        case formula   = "Formula"
        case team      = "Team"

        var color: Color {
            switch self {
            case .trigger:   return .red
            case .input:     return .koboldEmerald
            case .agent:     return .koboldGold
            case .tool:      return .koboldEmerald
            case .output:    return .koboldGold
            case .condition: return .orange
            case .merger:    return .koboldEmerald
            case .delay:     return .gray
            case .webhook:   return .koboldGold
            case .formula:   return .koboldEmerald
            case .team:      return .purple
            }
        }
        var icon: String {
            switch self {
            case .trigger:   return "bolt.circle.fill"
            case .input:     return "arrow.right.circle"
            case .agent:     return "brain"
            case .tool:      return "wrench.fill"
            case .output:    return "checkmark.circle.fill"
            case .condition: return "arrow.triangle.branch"
            case .merger:    return "arrow.triangle.merge"
            case .delay:     return "clock.fill"
            case .webhook:   return "antenna.radiowaves.left.and.right"
            case .formula:   return "function"
            case .team:      return "person.3.fill"
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
    @ObservedObject var viewModel: RuntimeViewModel

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                GlassTextField(text: $node.title, placeholder: "Node-Name")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $node.prompt)
                    .font(.system(size: 13.5))
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
            }

            // Connections section
            if !incomingConnections.isEmpty || !outgoingConnections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verbindungen").font(.caption).foregroundColor(.secondary)
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
                            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.koboldGold)
                            Text("→ Ausgang").font(.system(size: 13.5)).foregroundColor(.secondary)
                            Spacer()
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
                    Text("Bedingung").font(.caption).foregroundColor(.secondary)
                    GlassTextField(text: $node.conditionExpression, placeholder: "z.B. output.contains('error')")
                    Text("Wenn wahr: oberer Ausgang. Wenn falsch: unterer Ausgang.")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }

            // Delay
            if node.type == .delay {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verzögerung (Sekunden)").font(.caption).foregroundColor(.secondary)
                    TextField("", value: $node.delaySeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            // Formula
            if node.type == .formula {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Formel").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $node.prompt)
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(minHeight: 60)
                        .padding(6)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                    Text("Variablen: {{input}}, {{date}}, {{env.KEY}}")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }

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

                GlassButton(title: "Chat öffnen", icon: "message.fill", isPrimary: true) {
                    onOpenChat()
                }
            }

            // Team-specific: team selection
            if node.type == .team {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Team auswählen").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { node.teamId ?? "" },
                        set: { node.teamId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Kein Team").tag("")
                        ForEach(viewModel.teams) { team in
                            Text("\(team.name) (\(team.agents.count) Agenten)").tag(team.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
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

            GlassButton(title: "Node löschen", icon: "trash", isDestructive: true) {
                onDelete()
            }
        }
        .padding(16)
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
                        Text("Fehler").tag("error")
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
                TextField("Suchen...", text: $searchText)
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
    @State private var skills: [Skill] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fähigkeit").font(.caption).foregroundColor(.secondary)
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
