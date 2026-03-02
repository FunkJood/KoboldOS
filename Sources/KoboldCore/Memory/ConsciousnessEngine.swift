import Foundation

// MARK: - ConsciousnessEngine
// Inspired by Global Workspace Theory (Baars 1988) and LIDA Cognitive Cycle (Franklin & Baars).
// 5-phase cognitive cycle: Perception → Attention → Broadcast → Action → Reflection
// Background actor that monitors agent activity, manages emotional state,
// auto-saves errors/solutions, and consolidates short-term → long-term memory.

public actor ConsciousnessEngine {

    public static let shared = ConsciousnessEngine()

    private var memoryStore: MemoryStore?
    private var coreMemory: CoreMemory?
    private var isRunning = false
    private var cycleCount: Int = 0
    private var lastCycleDate: Date?

    // Perception buffer — recent events from AgentLoop
    private var recentEvents: [CognitiveEvent] = []
    private let maxEventBuffer = 100

    // Emotional state (Circumplex Model — Russell 1980)
    private var currentValence: Float = 0.0     // -1.0 (negative) to +1.0 (positive)
    private var currentArousal: Float = 0.3     // 0.0 (calm) to 1.0 (alert)

    // Self-model metrics
    private var successRate: Float = 1.0
    private var totalInteractions: Int = 0
    private var errorCount: Int = 0
    private var solutionCount: Int = 0

    public init() {}

    // MARK: - Configuration

    public func configure(memoryStore: MemoryStore, coreMemory: CoreMemory) {
        self.memoryStore = memoryStore
        self.coreMemory = coreMemory
    }

    // MARK: - Cognitive Event (perception input)

    public struct CognitiveEvent: Sendable {
        public let type: EventType
        public let content: String
        public let timestamp: Date
        public let metadata: [String: String]

        public enum EventType: String, Sendable {
            case toolSuccess
            case toolError
            case userMessage
            case agentResponse
            case errorResolved
            case patternDetected
        }

        public init(type: EventType, content: String, metadata: [String: String] = [:]) {
            self.type = type
            self.content = content
            self.timestamp = Date()
            self.metadata = metadata
        }
    }

    // MARK: - Event Ingestion (called by AgentLoop after tool execution)

    public func recordEvent(_ event: CognitiveEvent) {
        recentEvents.append(event)
        if recentEvents.count > maxEventBuffer {
            recentEvents.removeFirst(recentEvents.count - maxEventBuffer)
        }
        // Immediate emotional response
        switch event.type {
        case .toolError:
            currentValence = max(-1.0, currentValence - 0.15)
            currentArousal = min(1.0, currentArousal + 0.2)
            totalInteractions += 1
        case .toolSuccess:
            currentValence = min(1.0, currentValence + 0.05)
            currentArousal = max(0.1, currentArousal - 0.05)
            totalInteractions += 1
        case .errorResolved:
            currentValence = min(1.0, currentValence + 0.3)
            currentArousal = min(1.0, currentArousal + 0.1)
        case .userMessage:
            currentArousal = min(1.0, currentArousal + 0.1)
        default:
            break
        }
    }

    // MARK: - Start/Stop Background Cycle

    public func start(intervalSeconds: TimeInterval = 300) {
        guard !isRunning else { return }
        isRunning = true
        print("[ConsciousnessEngine] Gestartet (Intervall: \(Int(intervalSeconds))s)")
        Task { [weak self] in
            while let self = self, await self.isRunning {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard await self.isRunning else { break }
                await self.runCognitiveCycle()
            }
        }
    }

    public func stop() {
        isRunning = false
        print("[ConsciousnessEngine] Gestoppt nach \(cycleCount) Zyklen")
    }

    // MARK: - The Cognitive Cycle (LIDA-inspired)

    private func runCognitiveCycle() async {
        guard let memoryStore = memoryStore, let coreMemory = coreMemory else { return }
        cycleCount += 1
        lastCycleDate = Date()

        // Phase 1: PERCEPTION — gather current state
        let perception = await perceive(memoryStore: memoryStore)

        // Phase 2: ATTENTION — what's important?
        let attentionItems = attend(perception: perception)

        // Phase 3: BROADCAST — update CoreMemory blocks visible to agent
        await broadcast(items: attentionItems, coreMemory: coreMemory)

        // Phase 4: ACTION — execute memory operations
        await act(items: attentionItems, memoryStore: memoryStore)

        // Phase 5: REFLECTION — metacognitive self-assessment
        await reflect(coreMemory: coreMemory)
    }

    // MARK: - Phase 1: Perception

    private struct Perception {
        let recentErrors: [CognitiveEvent]
        let recentSuccesses: [CognitiveEvent]
        let unresolvedErrorCount: Int
        let shortTermCount: Int
        let totalMemories: Int
        let emotionalState: (valence: Float, arousal: Float)
    }

    private func perceive(memoryStore: MemoryStore) async -> Perception {
        let errors = recentEvents.filter { $0.type == .toolError }
        let successes = recentEvents.filter { $0.type == .toolSuccess || $0.type == .errorResolved }
        let unresolved = await memoryStore.unresolvedErrors()
        let stats = await memoryStore.stats()
        let shortTermCount = stats.byType["kurzzeit"] ?? 0

        return Perception(
            recentErrors: errors,
            recentSuccesses: successes,
            unresolvedErrorCount: unresolved.count,
            shortTermCount: shortTermCount,
            totalMemories: stats.total,
            emotionalState: (currentValence, currentArousal)
        )
    }

    // MARK: - Phase 2: Attention (salience detection)

    private enum AttentionItem {
        case consolidateShortTerm
        case emotionalUpdate
        case selfModelUpdate
    }

    private func attend(perception: Perception) -> [AttentionItem] {
        var items: [AttentionItem] = []

        // Short-term consolidation needed?
        if perception.shortTermCount > 20 {
            items.append(.consolidateShortTerm)
        }

        // Emotional state changed significantly?
        if abs(perception.emotionalState.valence) > 0.3 || perception.emotionalState.arousal > 0.7 {
            items.append(.emotionalUpdate)
        }

        // Self-model update every 10 cycles
        if cycleCount % 10 == 0 {
            items.append(.selfModelUpdate)
        }

        return items
    }

    // MARK: - Phase 3: Broadcast (update CoreMemory visible to agent)

    private func broadcast(items: [AttentionItem], coreMemory: CoreMemory) async {
        for item in items {
            switch item {
            case .emotionalUpdate:
                let moodText = describeMood(valence: currentValence, arousal: currentArousal)
                let blockValue = """
                \(moodText)
                Fehler: \(errorCount) | Lösungen: \(solutionCount) | Zyklen: \(cycleCount)
                """
                // Upsert the emotional_state block
                let block = MemoryBlock(
                    label: "emotional_state",
                    value: blockValue,
                    limit: 500,
                    description: "Aktueller emotionaler Kontext — Valenz (positiv/negativ) und Erregung. Auto-aktualisiert.",
                    readOnly: false
                )
                await coreMemory.upsert(block)

            case .selfModelUpdate:
                let modelText = """
                Erfolgsrate: \(String(format: "%.0f", successRate * 100))%
                Interaktionen: \(totalInteractions)
                Fehler gespeichert: \(errorCount)
                Lösungen gefunden: \(solutionCount)
                \(describeMood(valence: currentValence, arousal: currentArousal))
                """
                let block = MemoryBlock(
                    label: "self_model",
                    value: modelText,
                    limit: 1000,
                    description: "Selbstmodell — Leistungskennzahlen, Stärken, Schwächen. Auto-aktualisiert.",
                    readOnly: false
                )
                await coreMemory.upsert(block)

            case .consolidateShortTerm:
                break // Handled in Action phase
            }
        }
    }

    // MARK: - Phase 4: Action (memory operations)

    private func act(items: [AttentionItem], memoryStore: MemoryStore) async {
        for item in items {
            if case .consolidateShortTerm = item {
                let count = await memoryStore.consolidateShortTerm(olderThan: 24)
                if count > 0 {
                    print("[ConsciousnessEngine] \(count) Kurzzeit-Erinnerungen → Langzeit konsolidiert")
                }
            }
        }
        // Clear processed events
        recentEvents.removeAll()
    }

    // MARK: - Phase 5: Reflection (metacognition)

    private func reflect(coreMemory: CoreMemory) async {
        // Update success rate
        let total = Float(errorCount + solutionCount)
        if total > 0 {
            successRate = Float(solutionCount) / total
        }

        // Decay emotional state toward neutral (natural recovery)
        currentValence *= 0.9
        currentArousal = max(0.1, currentArousal * 0.95)

        // Periodic self-reflection note (every 50 cycles ≈ 4 hours at 5min interval)
        if cycleCount % 50 == 0 && cycleCount > 0 {
            let reflectionText = buildReflection()
            let block = MemoryBlock(
                label: "reflection",
                value: reflectionText,
                limit: 1500,
                description: "Letzte Selbstreflexion — metakognitive Notizen. Auto-aktualisiert.",
                readOnly: false
            )
            await coreMemory.upsert(block)
        }
    }

    // MARK: - Public: Record Error/Solution (called by AgentLoop)

    public func recordError(text: String, toolName: String) async {
        guard let memoryStore = memoryStore else { return }
        let tags = ["auto_error", toolName]
        let _ = try? await memoryStore.add(
            text: text, memoryType: "fehler", tags: tags,
            valence: -0.7, arousal: 0.8, source: "auto_error"
        )
        errorCount += 1
        recordEvent(.init(type: .toolError, content: text, metadata: ["toolName": toolName]))
    }

    public func recordSolution(text: String, errorId: String, toolName: String) async {
        guard let memoryStore = memoryStore else { return }
        let tags = ["auto_solution", toolName]
        let _ = try? await memoryStore.add(
            text: text, memoryType: "lösungen", tags: tags,
            valence: 0.8, arousal: 0.6, linkedEntryId: errorId, source: "auto_solution"
        )
        solutionCount += 1
        recordEvent(.init(type: .errorResolved, content: text, metadata: ["resolvedErrorId": errorId, "toolName": toolName]))
    }

    // MARK: - Helpers

    private func describeMood(valence: Float, arousal: Float) -> String {
        // Circumplex model of affect (Russell, 1980)
        let valenceDesc: String
        if valence > 0.5 { valenceDesc = "sehr positiv" }
        else if valence > 0.1 { valenceDesc = "leicht positiv" }
        else if valence > -0.1 { valenceDesc = "neutral" }
        else if valence > -0.5 { valenceDesc = "leicht negativ" }
        else { valenceDesc = "frustriert" }

        let arousalDesc: String
        if arousal > 0.7 { arousalDesc = "hohe Aufmerksamkeit" }
        else if arousal > 0.3 { arousalDesc = "normal" }
        else { arousalDesc = "ruhig" }

        return "Stimmung: \(valenceDesc), \(arousalDesc) (V=\(String(format: "%.1f", valence)), A=\(String(format: "%.1f", arousal)))"
    }

    private func buildReflection() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM.yyyy HH:mm"
        let date = fmt.string(from: Date())
        let unresolvedCount = max(0, errorCount - solutionCount)
        return """
        Selbstreflexion (\(date)):
        - Erfolgsrate: \(String(format: "%.0f", successRate * 100))%
        - \(errorCount) Fehler erkannt, \(solutionCount) Lösungen gefunden
        - Ungelöste Fehler: \(unresolvedCount > 0 ? "\(unresolvedCount) offen" : "keine")
        - \(describeMood(valence: currentValence, arousal: currentArousal))
        - Kognitive Zyklen: \(cycleCount)
        """
    }

    // MARK: - Public State (for UI / API)

    public func getState() -> ConsciousnessState {
        ConsciousnessState(
            valence: currentValence,
            arousal: currentArousal,
            successRate: successRate,
            cycleCount: cycleCount,
            lastCycle: lastCycleDate,
            errorCount: errorCount,
            solutionCount: solutionCount,
            isRunning: isRunning
        )
    }
}

// MARK: - ConsciousnessState (public, serializable)

public struct ConsciousnessState: Sendable, Codable {
    public let valence: Float
    public let arousal: Float
    public let successRate: Float
    public let cycleCount: Int
    public let lastCycle: Date?
    public let errorCount: Int
    public let solutionCount: Int
    public let isRunning: Bool
}
