import SwiftUI

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
                // No project selected — hint
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Kein Projekt ausgewählt")
                        .font(.title3)
                    Text("Wähle ein Projekt in der Seitenleiste oder erstelle ein neues.")
                        .font(.body).foregroundColor(.secondary)
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
    }

    // MARK: - Header

    var teamHeader: some View {
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
        .background(Color.koboldPanel)
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
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "canvas")
            .clipped()
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
                    }
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

                viewModel.sendMessage(prompt)
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

    enum CodingKeys: String, CodingKey {
        case id, type, title, prompt, x, y
    }

    init(id: UUID = UUID(), type: NodeType, title: String, prompt: String = "", x: CGFloat, y: CGFloat) {
        self.id = id; self.type = type; self.title = title
        self.prompt = prompt; self.x = x; self.y = y
    }

    static func defaultWorkflow() -> ([WorkflowNode], [WorkflowConnection]) {
        let input  = WorkflowNode(type: .input,  title: "Nutzer-Input", x: 60,  y: 160)
        let instr  = WorkflowNode(type: .agent,  title: "Instructor",   x: 260, y: 160)
        let coder  = WorkflowNode(type: .agent,  title: "Coder",        x: 460, y: 100)
        let output = WorkflowNode(type: .output, title: "Antwort",      x: 660, y: 160)
        let connections = [
            WorkflowConnection(sourceNodeId: input.id, targetNodeId: instr.id),
            WorkflowConnection(sourceNodeId: instr.id, targetNodeId: coder.id),
            WorkflowConnection(sourceNodeId: coder.id, targetNodeId: output.id),
        ]
        return ([input, instr, coder, output], connections)
    }

    enum NodeType: String, CaseIterable, Codable {
        case input     = "Input"
        case agent     = "Agent"
        case tool      = "Tool"
        case output    = "Output"
        case condition = "Condition"
        case merger    = "Merger"
        case delay     = "Delay"
        case webhook   = "Webhook"

        var color: Color {
            switch self {
            case .input:     return .koboldEmerald
            case .agent:     return .koboldGold
            case .tool:      return .blue
            case .output:    return .purple
            case .condition: return .orange
            case .merger:    return .cyan
            case .delay:     return .gray
            case .webhook:   return .pink
            }
        }
        var icon: String {
            switch self {
            case .input:     return "arrow.right.circle"
            case .agent:     return "brain"
            case .tool:      return "wrench.fill"
            case .output:    return "checkmark.circle.fill"
            case .condition: return "arrow.triangle.branch"
            case .merger:    return "arrow.triangle.merge"
            case .delay:     return "clock.fill"
            case .webhook:   return "antenna.radiowaves.left.and.right"
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

            // Open a live chat for this agent node (not saved to history)
            if node.type == .agent {
                GlassButton(title: "Chat öffnen", icon: "message.fill", isPrimary: true) {
                    onOpenChat()
                }
                Text("Chat wird nicht in der Verlaufsliste gespeichert.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            GlassButton(title: "Node löschen", icon: "trash", isDestructive: true) {
                onDelete()
            }
        }
        .padding(16)
    }
}
