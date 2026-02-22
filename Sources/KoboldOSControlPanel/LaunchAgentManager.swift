import Foundation
import ServiceManagement

// MARK: - LaunchAgentManager
// Registers the app as a macOS Login Item via SMAppService (macOS 13+).
// This causes KoboldOS to launch automatically at login.

@MainActor
class LaunchAgentManager: ObservableObject {
    static let shared = LaunchAgentManager()

    @Published var status: SMAppService.Status = .notRegistered

    init() {
        refreshStatus()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    func enable() {
        do {
            try SMAppService.mainApp.register()
            refreshStatus()
        } catch {
            print("[LaunchAgent] Failed to enable auto-start: \(error.localizedDescription)")
        }
    }

    func disable() {
        do {
            try SMAppService.mainApp.unregister()
            refreshStatus()
        } catch {
            print("[LaunchAgent] Failed to disable auto-start: \(error.localizedDescription)")
        }
    }

    var statusDescription: String {
        switch status {
        case .enabled:          return "Aktiviert"
        case .requiresApproval: return "Genehmigung erforderlich"
        case .notFound:         return "Nicht verfügbar"
        case .notRegistered:    return "Deaktiviert"
        @unknown default:       return "Unbekannt"
        }
    }
}
