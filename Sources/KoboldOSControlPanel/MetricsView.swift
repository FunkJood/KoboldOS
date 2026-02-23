import SwiftUI

struct MetricsView: View {
    @ObservedObject var viewModel: RuntimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.koboldEmerald)
                    Text("Metrics").font(.title2.bold())
                    Spacer()
                    GlassButton(title: "Refresh", icon: "arrow.clockwise", isPrimary: false) {
                        Task { await viewModel.loadMetrics() }
                    }
                }

                // Metric grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCard(title: "Chat Requests", value: "\(viewModel.metrics.chatRequests)",
                               subtitle: "Total sent", icon: "message.fill", color: .koboldEmerald)
                    MetricCard(title: "Tool Calls", value: "\(viewModel.metrics.toolCalls)",
                               subtitle: "Executed", icon: "wrench.fill", color: .koboldEmerald)
                    MetricCard(title: "Errors", value: "\(viewModel.metrics.errors)",
                               subtitle: "Failed", icon: "exclamationmark.triangle.fill", color: .red)
                    MetricCard(title: "Tokens", value: "\(viewModel.metrics.tokensTotal)",
                               subtitle: "Generated", icon: "text.alignleft", color: .koboldGold)
                    MetricCard(title: "Uptime", value: formatUptime(viewModel.metrics.uptimeSeconds),
                               subtitle: "Running", icon: "clock.fill", color: .koboldGold)
                    MetricCard(title: "Cache Hits", value: "\(viewModel.metrics.cacheHits)",
                               subtitle: "Reused", icon: "arrow.triangle.2.circlepath", color: .orange)
                }

                // Connection info
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        GlassSectionHeader(title: "Runtime Status", icon: "server.rack")
                        HStack {
                            Text("Daemon").font(.system(size: 15.5))
                            Spacer()
                            GlassStatusBadge(
                                label: viewModel.isConnected ? "Running" : "Stopped",
                                color: viewModel.isConnected ? .koboldEmerald : .red
                            )
                        }
                        HStack {
                            Text("Ollama").font(.system(size: 15.5))
                            Spacer()
                            GlassStatusBadge(
                                label: viewModel.ollamaStatus,
                                color: viewModel.ollamaStatus == "Running" ? .koboldEmerald : .red
                            )
                        }
                        if !viewModel.activeOllamaModel.isEmpty {
                            HStack {
                                Text("Active Model").font(.system(size: 15.5))
                                Spacer()
                                Text(viewModel.activeOllamaModel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.koboldEmerald)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .task { await viewModel.loadMetrics(); await viewModel.checkOllamaStatus() }
    }

    func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
