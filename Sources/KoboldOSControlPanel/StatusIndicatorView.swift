import SwiftUI

struct StatusIndicatorView: View {
    let status: String
    let pid: Int?
    let port: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.primary)
                if let pid = pid {
                    Text("PID \(pid) · :\(port)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text("Port \(port)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.koboldSurface.opacity(0.5))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status {
        case "OK":        return .koboldEmerald
        case "Starting":  return .koboldGold
        case "Stopped":   return .secondary
        default:          return .koboldRed
        }
    }

    private var statusLabel: String {
        switch status {
        case "OK":        return "Daemon aktiv"
        case "Starting":  return "Startet..."
        case "Stopped":   return "Gestoppt"
        default:          return status
        }
    }
}
