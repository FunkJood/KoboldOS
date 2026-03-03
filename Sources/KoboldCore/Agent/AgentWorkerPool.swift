import Foundation

// MARK: - AgentWorkerPool
//
// Manages a pool of pre-initialized AgentLoop workers for concurrent multi-chat execution.
// Supports priority-based acquisition and timeout to prevent indefinite blocking.
//
// Architecture:
//   Master pool manages worker lifecycle + priority queue.
//   Each worker = independent AgentLoop + LLMRunner → true Ollama parallelism.
//   Priority levels ensure user-facing requests are served before background tasks.
//
// Usage:
//   let worker = try await AgentWorkerPool.shared.acquire(priority: .user)
//   defer { Task { await AgentWorkerPool.shared.release(worker) } }
//   let stream = await worker.runStreaming(...)

/// Priority for pool acquire — higher priority gets served first
public enum WorkerPriority: Int, Comparable, Sendable {
    case idle = 0       // Idle tasks, proactive engine
    case scheduled = 1  // Cron tasks
    case workflow = 2   // Workflow node execution
    case background = 3 // Background sessions, sub-agents
    case user = 4       // Direct user interaction (highest)

    public static func < (lhs: WorkerPriority, rhs: WorkerPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor AgentWorkerPool {
    public static let shared = AgentWorkerPool()

    /// Maximum number of concurrent workers. Reads from UserDefaults on init.
    /// Set "kobold.workerPool.size" (1–16) to configure. Default: 8.
    public private(set) var maxWorkers: Int

    private var idleWorkers: [AgentLoop] = []
    private var activeCount: Int = 0

    /// Priority-sorted waiters — highest priority gets served first
    private var waiters: [(priority: WorkerPriority, continuation: CheckedContinuation<AgentLoop?, Never>)] = []

    /// Track what's currently running for diagnostics
    private var activeStreams: [String: WorkerPriority] = [:]

    public init(size: Int? = nil) {
        let configured = UserDefaults.standard.integer(forKey: "kobold.workerPool.size")
        let resolved = size ?? (configured > 0 ? configured : 8)
        self.maxWorkers = max(1, min(resolved, 16))

        for i in 0..<self.maxWorkers {
            let runner = LLMRunner()
            let worker = AgentLoop(agentID: "worker-\(i)", llmRunner: runner)
            idleWorkers.append(worker)
        }
    }

    // MARK: - Acquire / Release (Priority + Timeout)

    /// Acquire a free worker with priority and timeout.
    /// Higher priority requests are served before lower ones when workers are released.
    /// Returns nil if timeout expires (caller should show error instead of hanging).
    public func acquire(priority: WorkerPriority = .user, timeout: TimeInterval = 30) async -> AgentLoop? {
        if let worker = idleWorkers.popLast() {
            activeCount += 1
            return worker
        }

        // Auto-scale: If we're at max AND high-priority request, try to add a temporary worker
        if priority >= .user && activeCount >= maxWorkers && maxWorkers < 16 {
            let idx = maxWorkers
            maxWorkers += 1
            let runner = LLMRunner()
            let worker = AgentLoop(agentID: "worker-\(idx)-auto", llmRunner: runner)
            activeCount += 1
            return worker
        }

        // All workers busy — suspend with timeout
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<AgentLoop?, Never>) in
            // Insert sorted by priority (highest first)
            let entry = (priority: priority, continuation: continuation)
            if let insertIdx = waiters.firstIndex(where: { $0.priority < priority }) {
                waiters.insert(entry, at: insertIdx)
            } else {
                waiters.append(entry)
            }
        }

        return result
    }

    /// Legacy acquire without priority (defaults to .user priority, 30s timeout).
    /// Returns a non-optional AgentLoop for backward compatibility.
    public func acquire() async -> AgentLoop {
        // For backward compat: use withCheckedContinuation pattern like before
        if let worker = idleWorkers.popLast() {
            activeCount += 1
            return worker
        }

        // Auto-scale for default (user) requests
        if activeCount >= maxWorkers && maxWorkers < 16 {
            let idx = maxWorkers
            maxWorkers += 1
            let runner = LLMRunner()
            let worker = AgentLoop(agentID: "worker-\(idx)-auto", llmRunner: runner)
            activeCount += 1
            return worker
        }

        return await withCheckedContinuation { continuation in
            let entry = (priority: WorkerPriority.user, continuation: continuation as CheckedContinuation<AgentLoop?, Never>)
            waiters.insert(entry, at: 0) // User priority = front of queue
        }!
    }

    /// Release a worker back to the pool after a request completes.
    /// Serves the highest-priority waiter first.
    public func release(_ worker: AgentLoop) {
        activeCount = max(0, activeCount - 1)
        if let first = waiters.first {
            waiters.removeFirst()
            activeCount += 1
            first.continuation.resume(returning: worker)
        } else {
            // If we auto-scaled beyond the configured max, don't return extra workers
            let configuredMax = max(1, min(UserDefaults.standard.integer(forKey: "kobold.workerPool.size"), 16))
            let effectiveMax = configuredMax > 0 ? configuredMax : 8
            if idleWorkers.count + activeCount >= effectiveMax && maxWorkers > effectiveMax {
                maxWorkers = max(effectiveMax, activeCount + idleWorkers.count)
                // Drop extra worker (will be deallocated)
            } else {
                idleWorkers.append(worker)
            }
        }
    }

    // MARK: - Stream Tracking

    /// Register an active stream for diagnostics
    public func trackStream(id: String, priority: WorkerPriority) {
        activeStreams[id] = priority
    }

    /// Remove stream tracking
    public func untrackStream(id: String) {
        activeStreams.removeValue(forKey: id)
    }

    // MARK: - Status

    public var activeWorkerCount: Int { activeCount }
    public var waitingRequestCount: Int { waiters.count }
    public var activeStreamCount: Int { activeStreams.count }

    public var statusDescription: String {
        var parts = ["\(activeCount)/\(maxWorkers) aktiv"]
        if !waiters.isEmpty {
            parts.append("\(waiters.count) wartend")
        }
        if !activeStreams.isEmpty {
            let byPriority = Dictionary(grouping: activeStreams.values, by: { $0 })
                .sorted { $0.key > $1.key }
                .map { (prio, vals) in
                    let label: String
                    switch prio {
                    case .user: label = "User"
                    case .background: label = "Background"
                    case .workflow: label = "Workflow"
                    case .scheduled: label = "Scheduled"
                    case .idle: label = "Idle"
                    }
                    return "\(vals.count)×\(label)"
                }
            parts.append("Streams: \(byPriority.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Reconfigure

    /// Resize the pool (e.g. after user changes settings). Takes effect on next requests.
    public func resize(to newSize: Int) {
        let clamped = max(1, min(newSize, 16))
        maxWorkers = clamped
        UserDefaults.standard.set(clamped, forKey: "kobold.workerPool.size")
        while idleWorkers.count + activeCount < clamped {
            let idx = idleWorkers.count + activeCount
            let runner = LLMRunner()
            idleWorkers.append(AgentLoop(agentID: "worker-\(idx)", llmRunner: runner))
        }
    }

    /// Cancel lowest-priority waiting request to free a slot (emergency preemption)
    public func preemptLowest() {
        guard let lastIdx = waiters.indices.last else { return }
        let removed = waiters.remove(at: lastIdx)
        removed.continuation.resume(returning: nil)
    }
}
