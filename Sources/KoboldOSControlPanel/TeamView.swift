import SwiftUI
import UniformTypeIdentifiers

// MARK: - TeamView
// Visuelle n8n-artige Workflow-Builder für Agenten-Teams.

struct TeamView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var nodes: [WorkflowNode] = []
    @State private var connections: [WorkflowConnection] = []
    @State private var selectedNodeId: UUID? = nil
    @State private var isRunning = false
    @State private var runOutput = ""
    @State private var showAddNode = false
    @State private var dragSourceNodeId: UUID? = nil
    @State private var isDraggingPort: Bool = false
    @State private var dragSourceIsOutput: Bool = true
    @State private var portDragLocation: CGPoint = .zero
    // Agent-Builder
    @State private var agentBuilderText: String = ""
    @State private var isAgentBuilding: Bool = false
    @State private var agentBuildStatus: String = ""
    @State private var showImportPicker: Bool = false
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
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/workflow_canvas.json")
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
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Kein Projekt ausgewählt")
                        .font(.title3)
                    Text("Wähle ein Projekt in der Seitenleiste oder erstelle ein neues.")
                        .font(.body).foregroundColor(.secondary)

                    // Workflow ideas
                    GlassCard(padding: 12, cornerRadius: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Workflow-Ideen").font(.system(size: 13, weight: .semibold)).foregroundColor(.koboldGold)
                            ForEach(currentWorkflowSuggestions, id: \.name) { suggestion in
                                Button(action: {
                                    viewModel.newProject()
                                    agentBuilderText = suggestion.description
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: suggestion.icon)
                                            .font(.system(size: 12))
                                            .foregroundColor(.koboldGold)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text(suggestion.description)
                                                .font(.system(size: 10))
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
        .background(Color.koboldBackground)
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
                Task { await runWorkflow() }
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
                    GlassButton(title: "Node +", icon: "plus", isPrimary: false) {
                        addNode()
                    }
                    GlassButton(
                        title: isRunning ? "Läuft..." : "Ausführen",
                        icon: isRunning ? "stop.fill" : "play.fill",
                        isPrimary: true
                    ) {
                        Task { await runWorkflow() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            // Agent-Builder text field (only when project selected)
            if viewModel.selectedProject != nil {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundColor(.koboldGold)
                    GlassTextField(
                        text: $agentBuilderText,
                        placeholder: "Workflow-Idee hier dem Agent zum Bauen geben...",
                        onSubmit: { buildWorkflowWithAgent() }
                    )
                    Button(action: { buildWorkflowWithAgent() }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13))
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
                                .font(.system(size: 10))
                                .foregroundColor(.koboldGold)
                            Text("Erstelle Workflow...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.koboldGold)
                        } else if !agentBuildStatus.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.koboldEmerald)
                            Text(agentBuildStatus)
                                .font(.system(size: 11))
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
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
                    }.buttonStyle(.plain)
                    Text(String(format: "%.0f%%", canvasScale * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 36)
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { canvasScale = min(3.0, canvasScale + 0.1) } }) {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
                    }.buttonStyle(.plain)
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            canvasScale = 1.0; canvasOffset = .zero; lastDragOffset = .zero
                        }
                    }) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                    }.buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.koboldPanel.opacity(0.9))
                .cornerRadius(8)
                .padding(12)
            }
        }
        .background(Color.koboldBackground)
    }

    // MARK: - Node Inspector

    var nodeInspectorPanel: some View {
        Group {
            if let id = selectedNodeId, let idx = nodes.firstIndex(where: { $0.id == id }) {
                NodeInspector(
                    node: $nodes[idx],
                    onClose: { selectedNodeId = nil },
                    onDelete: {
                        connections.removeAll { $0.sourceNodeId == id || $0.targetNodeId == id }
                        nodes.remove(at: idx)
                        selectedNodeId = nil
                        saveWorkflowState()
                    },
                    onOpenChat: {
                        let nodeName = nodes[idx].title
                        viewModel.openWorkflowChat(nodeName: nodeName)
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
        let index = (dayOfYear * 6 + hour / 4) % Self.workflowSuggestionSets.count
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

        let prompt = """
        Erstelle einen Workflow mit dem workflow_manage Tool basierend auf dieser Beschreibung: \(text)

        Verwende project_id: \(projectId.uuidString)

        Erstelle passende Nodes (Trigger, Agent-Nodes mit passendem Profil, Output) und verbinde sie.
        """

        viewModel.sendMessage(prompt)

        // Auto-finish status after a delay (agent works asynchronously)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            isAgentBuilding = false
            agentBuildStatus = "Workflow-Anfrage gesendet"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { agentBuildStatus = "" }
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
        defer { isRunning = false }

        // Clear previous outputs
        for i in 0..<nodes.count { nodes[i].lastOutput = "" }

        // Build execution order from connections (topological traversal)
        // Find root nodes (nodes that are not targets of any connection)
        let targetIds = Set(connections.map { $0.targetNodeId })
        var queue = nodes.filter { !targetIds.contains($0.id) }.map { $0.id }
        var visited = Set<UUID>()

        while !queue.isEmpty {
            let currentId = queue.removeFirst()
            guard !visited.contains(currentId) else { continue }
            visited.insert(currentId)

            guard let nodeIdx = nodes.firstIndex(where: { $0.id == currentId }) else { continue }
            let node = nodes[nodeIdx]

            // Skip input/output nodes for execution
            if node.type != .input && node.type != .output {
                // Gather context from connected source nodes
                let sourceIds = connections.filter { $0.targetNodeId == currentId }.map { $0.sourceNodeId }
                let context = sourceIds.compactMap { sid in
                    nodes.first(where: { $0.id == sid })?.lastOutput
                }.filter { !$0.isEmpty }.joined(separator: "\n\n")

                let prompt = node.prompt.isEmpty
                    ? "Step \(node.title): \(context.isEmpty ? "Start the workflow." : "Based on previous step:\n\(String(context.prefix(500)))")"
                    : "\(node.prompt)\n\nKontext:\n\(context.prefix(500))"

                viewModel.sendWorkflowMessage(prompt, modelOverride: node.modelOverride, agentOverride: node.agentType)
                try? await Task.sleep(nanoseconds: 500_000_000)
                nodes[nodeIdx].lastOutput = "Verarbeitet von \(node.title)"
            }

            // Queue connected target nodes
            let nextIds = connections.filter { $0.sourceNodeId == currentId }.map { $0.targetNodeId }
            queue.append(contentsOf: nextIds)
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
    var agentType: String?                // Per-node agent type (e.g. "coder", "researcher")

    enum CodingKeys: String, CodingKey {
        case id, type, title, prompt, x, y, triggerConfig, conditionExpression, delaySeconds
        case modelOverride, agentType
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

        var color: Color {
            switch self {
            case .trigger:   return .red
            case .input:     return .koboldEmerald
            case .agent:     return .koboldGold
            case .tool:      return .blue
            case .output:    return .purple
            case .condition: return .orange
            case .merger:    return .cyan
            case .delay:     return .gray
            case .webhook:   return .pink
            case .formula:   return .mint
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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Type label bar
                HStack(spacing: 4) {
                    Image(systemName: node.type.icon)
                        .font(.system(size: 9))
                    Text(node.type.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(node.type.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(node.type.color.opacity(0.15))

                // Node title
                Text(node.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
            .frame(width: 130, height: 70)
            .background(Color.koboldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? node.type.color : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
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
            color: isSelected ? node.type.color.opacity(0.4) : .black.opacity(0.3),
            radius: isSelected ? 12 : 4
        )
        .scaleEffect(isRunning ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double.random(in: 0...0.3)),
                   value: isRunning)
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
                    .font(.system(size: 11))
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
                            Text("← Eingang").font(.system(size: 11)).foregroundColor(.secondary)
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
                            Text("→ Ausgang").font(.system(size: 11)).foregroundColor(.secondary)
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

            // Condition expression
            if node.type == .condition {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bedingung").font(.caption).foregroundColor(.secondary)
                    GlassTextField(text: $node.conditionExpression, placeholder: "z.B. output.contains('error')")
                    Text("Wenn wahr: oberer Ausgang. Wenn falsch: unterer Ausgang.")
                        .font(.system(size: 9)).foregroundColor(.secondary)
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
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 60)
                        .padding(6)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                    Text("Variablen: {{input}}, {{date}}, {{env.KEY}}")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            // Agent-specific: type, model, chat
            if node.type == .agent {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent-Typ").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { node.agentType ?? "instructor" },
                        set: { node.agentType = $0 == "instructor" ? nil : $0 }
                    )) {
                        Text("Instructor").tag("instructor")
                        Text("Coder").tag("coder")
                        Text("Researcher").tag("researcher")
                        Text("Planner").tag("planner")
                        Text("Utility").tag("utility")
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

                GlassButton(title: "Chat öffnen", icon: "message.fill", isPrimary: true) {
                    onOpenChat()
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
                            .font(.system(size: 12))
                            .foregroundColor(triggerType.wrappedValue == type ? .white : .secondary)
                            .frame(width: 24, height: 24)
                            .background(triggerType.wrappedValue == type ? Color.red : Color.clear)
                            .cornerRadius(6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(type.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(triggerType.wrappedValue == type ? .primary : .secondary)
                            Text(type.description)
                                .font(.system(size: 9))
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
                    Text("Cron-Ausdruck").font(.system(size: 10, weight: .semibold))
                    let cronBinding = Binding<String>(
                        get: { node.triggerConfig?.cronExpression ?? "" },
                        set: { node.triggerConfig?.cronExpression = $0 }
                    )
                    GlassTextField(text: cronBinding, placeholder: "0 8 * * * (täglich 8 Uhr)")
                    Text("Min Std Tag Mon WTag").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }

            case .webhook:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook-Pfad").font(.system(size: 10, weight: .semibold))
                    let pathBinding = Binding<String>(
                        get: { node.triggerConfig?.webhookPath ?? "" },
                        set: { node.triggerConfig?.webhookPath = $0 }
                    )
                    GlassTextField(text: pathBinding, placeholder: "/hook/mein-workflow")
                    if let path = node.triggerConfig?.webhookPath, !path.isEmpty {
                        Text("URL: http://localhost:8080\(path)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                            .textSelection(.enabled)
                    }
                }

            case .fileWatcher:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Überwachter Pfad").font(.system(size: 10, weight: .semibold))
                    let watchBinding = Binding<String>(
                        get: { node.triggerConfig?.watchPath ?? "" },
                        set: { node.triggerConfig?.watchPath = $0 }
                    )
                    GlassTextField(text: watchBinding, placeholder: "~/Documents/watch")
                }

            case .appEvent:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Event").font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.15), lineWidth: 0.5))
    }
}
