import Foundation

// MARK: - AgentWorkerPool
//
// Manages a pool of pre-initialized AgentLoop workers for concurrent multi-chat execution.
//
// Why a pool?
// - AgentLoop is a Swift Actor — but LLMRunner.shared is also a singleton Actor.
//   Two concurrent AgentLoops both calling LLMRunner.shared.generate() would serialize
//   on the shared actor queue, negating any parallelism.
// - Each pool worker gets its OWN LLMRunner instance, so HTTP calls to Ollama
//   run truly concurrently (limited only by Ollama's OLLAMA_NUM_PARALLEL setting).
//
// Usage:
//   let worker = await AgentWorkerPool.shared.acquire()
//   defer { Task { await AgentWorkerPool.shared.release(worker) } }
//   let stream = await worker.runStreaming(...)

public actor AgentWorkerPool {
    public static let shared = AgentWorkerPool()

    /// Maximum number of concurrent workers. Reads from UserDefaults on init.
    /// Set "kobold.workerPool.size" (1–16) to configure. Default: 4.
    public private(set) var maxWorkers: Int

    private var idleWorkers: [AgentLoop] = []
    private var activeCount: Int = 0

    /// Continuations waiting for a free worker
    private var waiters: [CheckedContinuation<AgentLoop, Never>] = []

    public init(size: Int? = nil) {
        let configured = UserDefaults.standard.integer(forKey: "kobold.workerPool.size")
        let resolved = size ?? (configured > 0 ? configured : 4)
        // Allow up to 16 workers — macOS can schedule them across all available CPU cores.
        self.maxWorkers = max(1, min(resolved, 16))

        // Pre-allocate all workers with dedicated LLMRunner instances.
        // Each worker has its own HTTP connection to Ollama → true multi-core parallelism.
        for i in 0..<self.maxWorkers {
            let runner = LLMRunner()
            let worker = AgentLoop(agentID: "worker-\(i)", llmRunner: runner)
            idleWorkers.append(worker)
        }
        // P12: print entfernt (blocking I/O)
    }

    // MARK: - Acquire / Release

    /// Acquire a free worker. Suspends until one becomes available.
    /// Each caller gets an isolated AgentLoop with its own LLMRunner (no shared-state contamination).
    public func acquire() async -> AgentLoop {
        if let worker = idleWorkers.popLast() {
            activeCount += 1
            // P12: print entfernt
            return worker
        }
        // All workers busy — suspend until release() gives us one
        // P12: print entfernt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release a worker back to the pool after a request completes.
    /// If another request is waiting, reuse the worker immediately.
    public func release(_ worker: AgentLoop) {
        activeCount = max(0, activeCount - 1)
        if let waiter = waiters.first {
            waiters.removeFirst()
            activeCount += 1
            // Reuse existing worker (LLMRunner instance stays warm, avoids allocation overhead)
            // P12: print entfernt
            waiter.resume(returning: worker)
        } else {
            idleWorkers.append(worker)
            // P12: print entfernt
        }
    }

    // MARK: - Status

    public var activeWorkerCount: Int { activeCount }
    public var waitingRequestCount: Int { waiters.count }

    public var statusDescription: String {
        if waiters.isEmpty {
            return "\(activeCount)/\(maxWorkers) aktiv"
        } else {
            return "\(activeCount)/\(maxWorkers) aktiv, \(waiters.count) wartend"
        }
    }

    // MARK: - Reconfigure

    /// Resize the pool (e.g. after user changes settings). Takes effect on next requests.
    public func resize(to newSize: Int) {
        let clamped = max(1, min(newSize, 16))
        maxWorkers = clamped
        UserDefaults.standard.set(clamped, forKey: "kobold.workerPool.size")
        // Add workers if growing
        while idleWorkers.count + activeCount < clamped {
            let idx = idleWorkers.count + activeCount
            let runner = LLMRunner()
            idleWorkers.append(AgentLoop(agentID: "worker-\(idx)", llmRunner: runner))
        }
        // P12: print entfernt
    }
}
