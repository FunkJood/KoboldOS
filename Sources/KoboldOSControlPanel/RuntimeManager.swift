import Foundation
import SwiftUI
import Combine
import KoboldCore

// MARK: - BackendConfig

struct BackendConfig: Sendable {
    var port: Int = 8080
    var authToken: String = "kobold-secret"
    var ollamaURL: String = "http://localhost:11434"
}

// MARK: - RuntimeManager
// Runs the KoboldCore DaemonListener IN-PROCESS — no subprocess required.
// This makes the app fully self-contained and distributable.

@MainActor
class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    @Published var healthStatus: String = "Starting"
    @Published var daemonPID: Int? = nil
    @Published var showErrorAlert: Bool = false
    @Published var errorMessage: String? = nil

    @AppStorage("kobold.port") var port: Int = 8080

    private var daemonTask: Task<Void, Never>? = nil
    private var healthTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var didPlayBootSound = false

    private init() {
        startHealthMonitor()
    }

    var baseURL: String { "http://localhost:\(port)" }

    // MARK: - In-Process Daemon

    func startDaemon() {
        guard daemonTask == nil else { return }

        let listenPort = port
        let token = "kobold-secret"

        daemonTask = Task.detached(priority: .background) {
            let daemon = DaemonListener(port: listenPort, authToken: token)
            await daemon.start()
        }

        daemonPID = Int(ProcessInfo.processInfo.processIdentifier)
        healthStatus = "Starting"
        print("[RuntimeManager] DaemonListener started in-process on port \(port)")
    }

    func stopDaemon() {
        daemonTask?.cancel()
        daemonTask = nil
        daemonPID = nil
        healthStatus = "Stopped"
    }

    func retryConnection() {
        showErrorAlert = false
        stopDaemon()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            startDaemon()
        }
    }

    // MARK: - Health Monitor

    private func startHealthMonitor() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pingHealth()
            }
        }
    }

    private func pingHealth() async {
        guard let url = URL(string: baseURL + "/health") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                healthStatus = "Error"; return
            }
            // Verify the responding daemon belongs to OUR process
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = json["pid"] as? Int,
               pid != Int(ProcessInfo.processInfo.processIdentifier) {
                // A DIFFERENT process (old instance) is on port 8080
                print("⚠️ Port \(port) occupied by PID \(pid), ours is \(ProcessInfo.processInfo.processIdentifier) — restarting daemon")
                healthStatus = "Stale"
                // Kill old process and restart our daemon
                kill(pid_t(pid), SIGTERM)
                stopDaemon()
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    startDaemon()
                }
                return
            }
            healthStatus = "OK"
            MenuBarController.shared.updateStatusIcon(healthy: true)
            if !didPlayBootSound {
                didPlayBootSound = true
                SoundManager.shared.play(.boot)
            }
        } catch {
            MenuBarController.shared.updateStatusIcon(healthy: false)
            if daemonTask != nil {
                if healthStatus == "Starting" { return }
                healthStatus = "Unreachable"
            }
        }
    }
}
