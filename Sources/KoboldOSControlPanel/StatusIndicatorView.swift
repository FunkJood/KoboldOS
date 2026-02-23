import SwiftUI

struct StatusIndicatorView: View {
    let status: String
    let pid: Int?
    let port: Int
    var onRestart: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil

    @State private var pulseGlow: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Pulsing status dot
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.6), radius: pulseGlow ? 5 : 2)
                    if status == "OK" {
                        Circle()
                            .fill(statusColor.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(pulseGlow ? 2.2 : 1.0)
                            .opacity(pulseGlow ? 0 : 0.6)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.primary)
                    if let pid = pid {
                        Text("PID \(pid) · :\(port)")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Port \(port)")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Daemon controls (visible on hover)
                if isHovered {
                    HStack(spacing: 4) {
                        if status != "Stopped" {
                            Button(action: { onStop?() }) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 14.5))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Daemon stoppen")
                        }

                        Button(action: { onRestart?() }) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 14.5))
                                .foregroundColor(.koboldEmerald)
                        }
                        .buttonStyle(.plain)
                        .help(status == "Stopped" ? "Daemon starten" : "Daemon neustarten")
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }

            // Alpha version badge
            HStack(spacing: 4) {
                Text("Alpha v0.2.6")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.koboldGold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.koboldGold.opacity(0.15)))
                    .overlay(Capsule().stroke(Color.koboldGold.opacity(0.3), lineWidth: 0.5))

                Spacer()

                Text("39k LOC")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.koboldSurface.opacity(0.5))
        .cornerRadius(8)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulseGlow = true
            }
        }
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
