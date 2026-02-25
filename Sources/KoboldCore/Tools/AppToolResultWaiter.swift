import Foundation

// MARK: - AppToolResultWaiter
// Thread-safe async waiter for app tool results (Terminal/Browser actions)
// Uses actor isolation + atomic flag to prevent double-resume crashes

public actor AppToolResultWaiter {
    public static let shared = AppToolResultWaiter()

    private var results: [String: String] = [:]
    private var continuations: [String: CheckedContinuation<String?, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var errorResults: [String: String] = [:]
    /// Tracks whether a continuation has already been resumed (prevents double-resume crash)
    private var resumed: Set<String> = []

    public func waitForResult(id: String, timeout: TimeInterval = 30) async -> String? {
        // Check for cached error results first
        if let errorResult = errorResults.removeValue(forKey: id) {
            return "[Fehler: \(errorResult)]"
        }

        // Check for cached results
        if let result = results.removeValue(forKey: id) {
            return result
        }

        return await withCheckedContinuation { continuation in
            self.continuations[id] = continuation
            self.resumed.remove(id) // ensure clean state
            self.timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self else { return }
                await self.resumeIfNeeded(id: id, value: nil)
            }
        }
    }

    public func deliverResult(id: String, result: String) {
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        resumeIfNeeded(id: id, value: result)
    }

    /// Delivers an error result
    public func deliverError(id: String, error: String) {
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        resumeIfNeeded(id: id, value: "[Fehler: \(error)]")
    }

    /// Atomically resumes a continuation exactly once, preventing double-resume crashes
    private func resumeIfNeeded(id: String, value: String?) {
        // Actor isolation guarantees this check-and-set is atomic
        guard !resumed.contains(id) else {
            // Already resumed - store result for later pickup if non-nil
            if let value = value {
                results[id] = value
            }
            return
        }
        resumed.insert(id)
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: value)
        } else if let value = value {
            // No continuation yet - cache the result
            results[id] = value
        }
        // Cleanup
        timeoutTasks.removeValue(forKey: id)
    }

    /// Cleanup old entries to prevent memory leaks
    public func cleanup(id: String) {
        results.removeValue(forKey: id)
        errorResults.removeValue(forKey: id)
        resumed.remove(id)
        continuations.removeValue(forKey: id)
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
    }

    /// Check if a session ID is valid
    public func isValidSessionId(_ sessionId: String) -> Bool {
        return UUID(uuidString: sessionId) != nil
    }
}
