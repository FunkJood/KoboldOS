import Foundation

// MARK: - CrashMonitor — Self-protecting system with safe mode

public actor CrashMonitor {

    public static let shared = CrashMonitor()

    private var crashCount: Int = 0
    private var lastCrashTimestamp: UInt64 = 0
    private var safeModeActive: Bool = false

    private let maxCrashes: Int = 3
    private let timeWindowNanos: UInt64 = 60_000_000_000 // 60s

    private init() {}

    // MARK: - Public API

    public func recordCrash() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastCrashTimestamp > timeWindowNanos { crashCount = 0 }
        crashCount += 1
        lastCrashTimestamp = now
        if crashCount >= maxCrashes { safeModeActive = true }
        print("[CrashMonitor] Crash recorded (\(crashCount)/\(maxCrashes))\(safeModeActive ? " — Safe mode activated" : "")")
    }

    public func shouldEnterSafeMode() -> Bool { safeModeActive }
    public func isSafeModeActive() -> Bool { safeModeActive }
    public func getCrashCount() -> Int { crashCount }

    public func activateSafeMode() {
        safeModeActive = true
        print("[CrashMonitor] Safe mode manually activated")
    }

    public func resetSafeMode() {
        crashCount = 0
        lastCrashTimestamp = 0
        safeModeActive = false
        print("[CrashMonitor] Safe mode reset")
    }

    // Backward compatibility
    public func reset() { resetSafeMode() }
    public func enterSafeMode() { activateSafeMode() }
}
