import Foundation

// MARK: - WorkflowManageTool — Agent can create visual workflows with nodes, connections, triggers

public struct WorkflowManageTool: Tool, Sendable {

    public let name = "workflow_manage"
    public let description = "Create visual workflows with nodes, connections and triggers. Also manage projects."
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "action": ToolSchemaProperty(
                    type: "string",
                    description: "Action: create_project, add_node, connect, set_trigger, list_nodes, delete_node, run, create, list, delete",
                    enumValues: ["create_project", "add_node", "connect", "set_trigger", "list_nodes", "delete_node", "run", "create", "list", "delete"],
                    required: true
                ),
                "project_id": ToolSchemaProperty(
                    type: "string",
                    description: "Project ID (prefix or full UUID)"
                ),
                "name": ToolSchemaProperty(
                    type: "string",
                    description: "Name (for project or workflow)"
                ),
                "description": ToolSchemaProperty(
                    type: "string",
                    description: "Description"
                ),
                "node_type": ToolSchemaProperty(
                    type: "string",
                    description: "Node type: Trigger, Input, Agent, Tool, Output, Condition, Merger, Delay, Webhook, Formula"
                ),
                "title": ToolSchemaProperty(
                    type: "string",
                    description: "Node title"
                ),
                "prompt": ToolSchemaProperty(
                    type: "string",
                    description: "Node prompt/instruction"
                ),
                "agent_type": ToolSchemaProperty(
                    type: "string",
                    description: "Agent type for node: general, coder, web"
                ),
                "model_override": ToolSchemaProperty(
                    type: "string",
                    description: "Model override for node (e.g. llama3.2, gpt-4o)"
                ),
                "source_node_id": ToolSchemaProperty(
                    type: "string",
                    description: "Source node ID for connect"
                ),
                "target_node_id": ToolSchemaProperty(
                    type: "string",
                    description: "Target node ID for connect"
                ),
                "node_id": ToolSchemaProperty(
                    type: "string",
                    description: "Node ID (for set_trigger, delete_node)"
                ),
                "trigger_type": ToolSchemaProperty(
                    type: "string",
                    description: "Trigger type: Manual, Zeitplan, Webhook, Datei-Watcher, App-Event"
                ),
                "cron_expression": ToolSchemaProperty(
                    type: "string",
                    description: "Cron expression for Zeitplan trigger (e.g. '0 8 * * *')"
                ),
                "webhook_path": ToolSchemaProperty(
                    type: "string",
                    description: "Webhook path (e.g. '/hook/my-workflow')"
                ),
                "watch_path": ToolSchemaProperty(
                    type: "string",
                    description: "File path to watch for Datei-Watcher trigger"
                ),
                "event_name": ToolSchemaProperty(
                    type: "string",
                    description: "Event name for App-Event trigger (app_start, new_message, task_complete, error, memory_update)"
                ),
                "condition_expression": ToolSchemaProperty(
                    type: "string",
                    description: "Condition expression for Condition nodes"
                ),
                "delay_seconds": ToolSchemaProperty(
                    type: "string",
                    description: "Delay in seconds for Delay nodes"
                ),
                "steps": ToolSchemaProperty(
                    type: "string",
                    description: "JSON array of workflow step objects (legacy create)"
                ),
                "id": ToolSchemaProperty(
                    type: "string",
                    description: "Workflow ID (legacy delete)"
                )
            ],
            required: ["action"]
        )
    }

    public init() {}

    // MARK: - File URLs

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS")
    }

    private var projectsFileURL: URL { appSupportDir.appendingPathComponent("projects.json") }
    private var legacyWorkflowsURL: URL { appSupportDir.appendingPathComponent("workflows.json") }

    private func workflowURL(for projectId: String) -> URL {
        appSupportDir.appendingPathComponent("workflows/\(projectId).json")
    }

    // MARK: - Validate

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
        switch action {
        case "create_project":
            guard let n = arguments["name"], !n.isEmpty else {
                throw ToolError.missingRequired("name")
            }
        case "add_node":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
            guard let nt = arguments["node_type"], !nt.isEmpty else {
                throw ToolError.missingRequired("node_type")
            }
        case "connect":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
            guard let s = arguments["source_node_id"], !s.isEmpty else {
                throw ToolError.missingRequired("source_node_id")
            }
            guard let t = arguments["target_node_id"], !t.isEmpty else {
                throw ToolError.missingRequired("target_node_id")
            }
        case "set_trigger":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
            guard let nid = arguments["node_id"], !nid.isEmpty else {
                throw ToolError.missingRequired("node_id")
            }
        case "list_nodes":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
        case "delete_node":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
            guard let nid = arguments["node_id"], !nid.isEmpty else {
                throw ToolError.missingRequired("node_id")
            }
        case "run":
            guard let pid = arguments["project_id"], !pid.isEmpty else {
                throw ToolError.missingRequired("project_id")
            }
        case "create":
            guard let n = arguments["name"], !n.isEmpty else {
                throw ToolError.missingRequired("name")
            }
        case "delete":
            guard let i = arguments["id"], !i.isEmpty else {
                throw ToolError.missingRequired("id")
            }
        case "list":
            break
        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }

    // MARK: - Execute

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {

        // ─── Visual Workflow Actions ───────────────────────────────

        case "create_project":
            return createProject(arguments: arguments)

        case "add_node":
            return addNode(arguments: arguments)

        case "connect":
            return connectNodes(arguments: arguments)

        case "set_trigger":
            return setTrigger(arguments: arguments)

        case "list_nodes":
            return listNodes(arguments: arguments)

        case "delete_node":
            return deleteNode(arguments: arguments)

        case "run":
            return runWorkflow(arguments: arguments)

        // ─── Legacy Flat Workflow Actions ──────────────────────────

        case "create":
            return legacyCreate(arguments: arguments)

        case "list":
            return legacyList()

        case "delete":
            return legacyDelete(arguments: arguments)

        default:
            throw ToolError.invalidParameter("action", "unknown: \(action)")
        }
    }

    // MARK: - Create Project

    private func createProject(arguments: [String: String]) -> String {
        let name = arguments["name"] ?? "Neues Projekt"
        let desc = arguments["description"] ?? ""
        let projectId = UUID().uuidString
        let now = Date().timeIntervalSinceReferenceDate

        var projects = loadProjectsList()
        let project: [String: Any] = [
            "id": projectId,
            "name": name,
            "description": desc,
            "createdAt": now,
            "updatedAt": now
        ]
        projects.insert(project, at: 0)
        saveProjectsList(projects)

        // Create default workflow: Trigger → Output
        let triggerId = UUID().uuidString
        let outputId = UUID().uuidString
        let defaultNodes: [[String: Any]] = [
            makeNodeDict(id: triggerId, type: "Trigger", title: "Start", prompt: "", x: 60, y: 160,
                        triggerConfig: ["type": "Manual", "cronExpression": "", "webhookPath": "", "watchPath": "", "eventName": "", "httpMethod": "POST"]),
            makeNodeDict(id: outputId, type: "Output", title: "Antwort", prompt: "", x: 460, y: 160)
        ]
        let defaultConns: [[String: Any]] = [
            makeConnectionDict(sourceId: triggerId, targetId: outputId)
        ]
        saveWorkflowState(nodes: defaultNodes, connections: defaultConns, projectId: projectId)

        NotificationCenter.default.post(name: Notification.Name("koboldProjectsChanged"), object: nil)

        let prefix = String(projectId.prefix(8))
        return "Projekt '\(name)' erstellt (ID: \(prefix)). Nutze project_id '\(prefix)' fuer add_node, connect, set_trigger, list_nodes, run."
    }

    // MARK: - Add Node

    private func addNode(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }
        let nodeType = arguments["node_type"] ?? "Agent"
        let validTypes = ["Trigger", "Input", "Agent", "Tool", "Output", "Condition", "Merger", "Delay", "Webhook", "Formula"]
        guard validTypes.contains(nodeType) else {
            return "Ungültiger node_type '\(nodeType)'. Erlaubt: \(validTypes.joined(separator: ", "))"
        }

        let title = arguments["title"] ?? nodeType
        let prompt = arguments["prompt"] ?? ""
        let agentType = arguments["agent_type"]
        let modelOverride = arguments["model_override"]
        let conditionExpr = arguments["condition_expression"] ?? ""
        let delaySec = Int(arguments["delay_seconds"] ?? "0") ?? 0

        var (nodes, connections) = loadWorkflowState(projectId: projectId)

        // Auto-layout: horizontal chain
        let x = 60.0 + Double(nodes.count) * 200.0
        let y = 160.0

        let nodeId = UUID().uuidString
        var nodeDict = makeNodeDict(id: nodeId, type: nodeType, title: title, prompt: prompt, x: x, y: y)

        if !conditionExpr.isEmpty { nodeDict["conditionExpression"] = conditionExpr }
        if delaySec > 0 { nodeDict["delaySeconds"] = delaySec }
        if let at = agentType, !at.isEmpty { nodeDict["agentType"] = at }
        if let mo = modelOverride, !mo.isEmpty { nodeDict["modelOverride"] = mo }

        // Auto-add trigger config for trigger nodes
        if nodeType == "Trigger" {
            nodeDict["triggerConfig"] = [
                "type": "Manual", "cronExpression": "", "webhookPath": "",
                "watchPath": "", "eventName": "", "httpMethod": "POST"
            ]
        }

        nodes.append(nodeDict)

        // Auto-connect to previous node if there is one
        if nodes.count >= 2 {
            let prevNode = nodes[nodes.count - 2]
            if let prevId = prevNode["id"] as? String {
                connections.append(makeConnectionDict(sourceId: prevId, targetId: nodeId))
            }
        }

        saveWorkflowState(nodes: nodes, connections: connections, projectId: projectId)
        notifyWorkflowChanged(projectId)

        let prefix = String(nodeId.prefix(8))
        return "Node '\(title)' (\(nodeType)) hinzugefügt (ID: \(prefix)). Position: \(Int(x)),\(Int(y)). Auto-connected zu vorherigem Node."
    }

    // MARK: - Connect Nodes

    private func connectNodes(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }
        guard let sourcePrefix = arguments["source_node_id"],
              let targetPrefix = arguments["target_node_id"] else {
            return "source_node_id und target_node_id werden benötigt."
        }

        var (nodes, connections) = loadWorkflowState(projectId: projectId)

        guard let sourceId = resolveNodeId(sourcePrefix, in: nodes) else {
            return "Source-Node '\(sourcePrefix)' nicht gefunden."
        }
        guard let targetId = resolveNodeId(targetPrefix, in: nodes) else {
            return "Target-Node '\(targetPrefix)' nicht gefunden."
        }
        guard sourceId != targetId else {
            return "Source und Target dürfen nicht gleich sein."
        }

        // Check for duplicate
        let duplicate = connections.contains { conn in
            (conn["sourceNodeId"] as? String) == sourceId && (conn["targetNodeId"] as? String) == targetId
        }
        if duplicate { return "Diese Verbindung existiert bereits." }

        connections.append(makeConnectionDict(sourceId: sourceId, targetId: targetId))
        saveWorkflowState(nodes: nodes, connections: connections, projectId: projectId)
        notifyWorkflowChanged(projectId)

        return "Verbindung erstellt: \(String(sourceId.prefix(8))) → \(String(targetId.prefix(8)))"
    }

    // MARK: - Set Trigger

    private func setTrigger(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }
        guard let nodePrefix = arguments["node_id"] else {
            return "node_id wird benötigt."
        }

        var (nodes, connections) = loadWorkflowState(projectId: projectId)

        guard let nodeId = resolveNodeId(nodePrefix, in: nodes),
              let idx = nodes.firstIndex(where: { ($0["id"] as? String) == nodeId }) else {
            return "Node '\(nodePrefix)' nicht gefunden."
        }

        let triggerType = arguments["trigger_type"] ?? "Manual"
        let validTriggers = ["Manual", "Zeitplan", "Webhook", "Datei-Watcher", "App-Event"]
        guard validTriggers.contains(triggerType) else {
            return "Ungültiger trigger_type. Erlaubt: \(validTriggers.joined(separator: ", "))"
        }

        let triggerConfig: [String: Any] = [
            "type": triggerType,
            "cronExpression": arguments["cron_expression"] ?? "",
            "webhookPath": arguments["webhook_path"] ?? "",
            "watchPath": arguments["watch_path"] ?? "",
            "eventName": arguments["event_name"] ?? "",
            "httpMethod": "POST"
        ]

        nodes[idx]["triggerConfig"] = triggerConfig
        saveWorkflowState(nodes: nodes, connections: connections, projectId: projectId)
        notifyWorkflowChanged(projectId)

        return "Trigger '\(triggerType)' auf Node '\(nodes[idx]["title"] as? String ?? "")' konfiguriert."
    }

    // MARK: - List Nodes

    private func listNodes(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }

        let (nodes, connections) = loadWorkflowState(projectId: projectId)
        if nodes.isEmpty { return "Keine Nodes im Workflow." }

        var lines: [String] = ["Nodes (\(nodes.count)):"]
        for node in nodes {
            let id = String((node["id"] as? String ?? "").prefix(8))
            let type = node["type"] as? String ?? "?"
            let title = node["title"] as? String ?? "?"
            let at = node["agentType"] as? String
            let mo = node["modelOverride"] as? String
            var extras: [String] = []
            if let at = at, !at.isEmpty { extras.append("agent=\(at)") }
            if let mo = mo, !mo.isEmpty { extras.append("model=\(mo)") }
            if let tc = node["triggerConfig"] as? [String: Any], let tt = tc["type"] as? String {
                extras.append("trigger=\(tt)")
            }
            let extrasStr = extras.isEmpty ? "" : " [\(extras.joined(separator: ", "))]"
            lines.append("  • \(title) (\(type)) ID:\(id)\(extrasStr)")
        }

        if !connections.isEmpty {
            lines.append("\nConnections (\(connections.count)):")
            for conn in connections {
                let src = String((conn["sourceNodeId"] as? String ?? "").prefix(8))
                let tgt = String((conn["targetNodeId"] as? String ?? "").prefix(8))
                lines.append("  \(src) → \(tgt)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Delete Node

    private func deleteNode(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }
        guard let nodePrefix = arguments["node_id"] else {
            return "node_id wird benötigt."
        }

        var (nodes, connections) = loadWorkflowState(projectId: projectId)

        guard let nodeId = resolveNodeId(nodePrefix, in: nodes),
              let idx = nodes.firstIndex(where: { ($0["id"] as? String) == nodeId }) else {
            return "Node '\(nodePrefix)' nicht gefunden."
        }

        let title = nodes[idx]["title"] as? String ?? "?"
        nodes.remove(at: idx)

        // Remove all connections involving this node
        connections.removeAll { conn in
            (conn["sourceNodeId"] as? String) == nodeId || (conn["targetNodeId"] as? String) == nodeId
        }

        saveWorkflowState(nodes: nodes, connections: connections, projectId: projectId)
        notifyWorkflowChanged(projectId)

        return "Node '\(title)' und zugehörige Connections gelöscht."
    }

    // MARK: - Run Workflow

    private func runWorkflow(arguments: [String: String]) -> String {
        guard let projectId = resolveProjectId(arguments["project_id"] ?? "") else {
            return "Projekt nicht gefunden."
        }

        NotificationCenter.default.post(
            name: Notification.Name("koboldWorkflowRun"),
            object: projectId
        )

        return "Workflow-Ausführung gestartet."
    }

    // MARK: - Legacy Actions

    private func legacyCreate(arguments: [String: String]) -> String {
        guard let name = arguments["name"] else { return "name wird benötigt." }
        let desc = arguments["description"] ?? ""
        let stepsJSON = arguments["steps"] ?? "[]"
        let workflow = WorkflowDefinition(
            id: UUID().uuidString, name: name, description: desc,
            steps: stepsJSON, createdAt: ISO8601DateFormatter().string(from: Date())
        )
        var workflows = loadLegacyWorkflows()
        workflows.append(workflow)
        saveLegacyWorkflows(workflows)
        return "Workflow '\(name)' erstellt (ID: \(workflow.id.prefix(8)))."
    }

    private func legacyList() -> String {
        let workflows = loadLegacyWorkflows()
        if workflows.isEmpty { return "Keine Workflows vorhanden." }
        let lines = workflows.map { w in
            "• \(w.name) — \(w.description.isEmpty ? "Keine Beschreibung" : w.description) (ID: \(w.id.prefix(8)))"
        }
        return "Workflows (\(workflows.count)):\n" + lines.joined(separator: "\n")
    }

    private func legacyDelete(arguments: [String: String]) -> String {
        guard let id = arguments["id"] else { return "id wird benötigt." }
        var workflows = loadLegacyWorkflows()
        guard let idx = workflows.firstIndex(where: { $0.id.hasPrefix(id) || $0.id == id }) else {
            return "Workflow mit ID '\(id)' nicht gefunden."
        }
        let name = workflows[idx].name
        workflows.remove(at: idx)
        saveLegacyWorkflows(workflows)
        return "Workflow '\(name)' gelöscht."
    }

    // MARK: - Visual Workflow File I/O

    private func loadProjectsList() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: projectsFileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private func saveProjectsList(_ projects: [[String: Any]]) {
        let dir = projectsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: projects, options: .sortedKeys) {
            try? data.write(to: projectsFileURL, options: .atomic)
        }
    }

    private func loadWorkflowState(projectId: String) -> (nodes: [[String: Any]], connections: [[String: Any]]) {
        let url = workflowURL(for: projectId)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = state["nodes"] as? [[String: Any]],
              let connections = state["connections"] as? [[String: Any]] else {
            return ([], [])
        }
        return (nodes, connections)
    }

    private func saveWorkflowState(nodes: [[String: Any]], connections: [[String: Any]], projectId: String) {
        let url = workflowURL(for: projectId)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state: [String: Any] = ["nodes": nodes, "connections": connections]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Resolve Helpers

    private func resolveProjectId(_ prefix: String) -> String? {
        let projects = loadProjectsList()
        for p in projects {
            if let id = p["id"] as? String, id.hasPrefix(prefix) || id == prefix {
                return id
            }
        }
        return nil
    }

    private func resolveNodeId(_ prefix: String, in nodes: [[String: Any]]) -> String? {
        for node in nodes {
            if let id = node["id"] as? String {
                let idUpper = id.uppercased()
                let prefixUpper = prefix.uppercased()
                if idUpper.hasPrefix(prefixUpper) || idUpper == prefixUpper { return id }
            }
        }
        return nil
    }

    // MARK: - Dict Builders

    private func makeNodeDict(id: String, type: String, title: String, prompt: String, x: Double, y: Double,
                              triggerConfig: [String: Any]? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "type": type,
            "title": title,
            "prompt": prompt,
            "x": x,
            "y": y,
            "conditionExpression": "",
            "delaySeconds": 0
        ]
        if let tc = triggerConfig { dict["triggerConfig"] = tc }
        return dict
    }

    private func makeConnectionDict(sourceId: String, targetId: String) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "sourceNodeId": sourceId,
            "targetNodeId": targetId,
            "sourcePort": 0,
            "targetPort": 0
        ]
    }

    private func notifyWorkflowChanged(_ projectId: String) {
        NotificationCenter.default.post(
            name: Notification.Name("koboldWorkflowChanged"),
            object: projectId
        )
    }

    // MARK: - Legacy Persistence

    private func loadLegacyWorkflows() -> [WorkflowDefinition] {
        guard let data = try? Data(contentsOf: legacyWorkflowsURL),
              let workflows = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) else {
            return []
        }
        return workflows
    }

    private func saveLegacyWorkflows(_ workflows: [WorkflowDefinition]) {
        let dir = legacyWorkflowsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(workflows) {
            try? data.write(to: legacyWorkflowsURL)
        }
    }
}

// MARK: - WorkflowDefinition Model (Legacy)

public struct WorkflowDefinition: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var steps: String  // JSON array string
    public var createdAt: String

    public init(id: String, name: String, description: String, steps: String, createdAt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.createdAt = createdAt
    }
}
