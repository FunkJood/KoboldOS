import SwiftUI

// MARK: - MenuBarPopoverView (disabled)
// Removed: was running a parallel MenuBarViewModel + SystemMetricsMonitor
// that competed with the main app for daemon access and Main Thread time.

struct MenuBarPopoverView: View {
    var body: some View {
        EmptyView()
    }
}
