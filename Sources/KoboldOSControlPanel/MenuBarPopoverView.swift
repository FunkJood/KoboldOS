import SwiftUI

// MARK: - MenuBarPopoverView
// Compact popover shown from menu bar with Stats and Chat tabs.

struct MenuBarPopoverView: View {
    @EnvironmentObject var runtimeManager: RuntimeManager
    @StateObject private var viewModel = MenuBarViewModel()
    @StateObject private var sysMonitor = SystemMetricsMonitor()
    @State private var selectedTab: MenuBarTab = .stats

    enum MenuBarTab: String, CaseIterable {
        case stats = "Status"
        case chat = "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab switcher
            header

            Divider()

            // Content
            switch selectedTab {
            case .stats:
                statsView
            case .chat:
                chatContent
            }

            // Footer
            footer
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .frame(width: 380, height: 520)
        .onAppear { sysMonitor.update() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runtimeManager.healthStatus == "OK" ? Color.koboldEmerald : Color.red)
                    .frame(width: 8, height: 8)

                Text("KoboldOS")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { MenuBarController.shared.showMainWindow() }) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 14.5))
                        .foregroundColor(.koboldEmerald)
                }
                .buttonStyle(.plain)
                .help("Hauptfenster öffnen")
            }

            // Tab switcher
            Picker("", selection: $selectedTab) {
                ForEach(MenuBarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.koboldPanel)
    }

    // MARK: - Stats View

    private var statsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Daemon status
                statusRow(icon: "server.rack", label: "Daemon", value: runtimeManager.healthStatus,
                          color: runtimeManager.healthStatus == "OK" ? .koboldEmerald : .red)

                // Ollama model
                let model = UserDefaults.standard.string(forKey: "kobold.ollamaModel") ?? "—"
                statusRow(icon: "cpu.fill", label: "Modell", value: model, color: .koboldGold)

                Divider().opacity(0.3)

                // System metrics
                Text("System").font(.system(size: 13.5, weight: .semibold)).foregroundColor(.secondary)

                HStack(spacing: 12) {
                    miniMetric(label: "CPU", value: String(format: "%.0f%%", sysMonitor.cpuUsage),
                               progress: sysMonitor.cpuUsage / 100,
                               color: sysMonitor.cpuUsage > 80 ? .red : sysMonitor.cpuUsage > 60 ? .orange : .koboldEmerald)

                    miniMetric(label: "RAM", value: String(format: "%.1f/%.0f GB", sysMonitor.ramUsedGB, sysMonitor.ramTotalGB),
                               progress: sysMonitor.ramTotalGB > 0 ? sysMonitor.ramUsedGB / sysMonitor.ramTotalGB : 0,
                               color: sysMonitor.ramUsedGB / max(1, sysMonitor.ramTotalGB) > 0.85 ? .red : .koboldEmerald)

                    miniMetric(label: "Disk", value: String(format: "%.0f GB frei", sysMonitor.diskFreeGB),
                               progress: sysMonitor.diskTotalGB > 0 ? (sysMonitor.diskTotalGB - sysMonitor.diskFreeGB) / sysMonitor.diskTotalGB : 0,
                               color: sysMonitor.diskFreeGB < 20 ? .red : .koboldGold)
                }

                Divider().opacity(0.3)

                // Quick actions
                Text("Schnellzugriff").font(.system(size: 13.5, weight: .semibold)).foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    quickAction(icon: "bubble.left.and.bubble.right.fill", label: "Chat") {
                        selectedTab = .chat
                    }
                    quickAction(icon: "brain.fill", label: "Gedächtnis") {
                        MenuBarController.shared.showMainWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.memory)
                        }
                    }
                    quickAction(icon: "gearshape.fill", label: "Einstellungen") {
                        MenuBarController.shared.showMainWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: .koboldNavigateSettings, object: nil)
                        }
                    }
                    quickAction(icon: "checklist", label: "Aufgaben") {
                        MenuBarController.shared.showMainWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: .koboldNavigate, object: SidebarTab.tasks)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func statusRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14.5))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func miniMetric(label: String, value: String, progress: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
            ProgressView(value: min(1, max(0, progress)))
                .tint(color)
            Text(value).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.primary).lineLimit(1)
        }
    }

    private func quickAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18.5))
                    .foregroundColor(.koboldEmerald)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.koboldSurface)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            // Messages
            if viewModel.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            Divider()

            // Input + clear
            HStack(spacing: 6) {
                inputBar
                Button(action: { viewModel.messages.removeAll() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13.5))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Verlauf leeren")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Frag mich etwas...")
                .font(.system(size: 15.5))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.messages) { msg in
                        MenuBarMessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Nachricht...", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 15.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.koboldSurface)
                .cornerRadius(8)
                .onSubmit {
                    viewModel.sendMessage()
                }
                .disabled(viewModel.isStreaming)

            if viewModel.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            } else {
                Button(action: { viewModel.sendMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23))
                        .foregroundColor(viewModel.inputText.isEmpty ? .secondary : .koboldEmerald)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.inputText.isEmpty)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("⌘+Shift+K öffnet Hauptfenster")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
            Text("v0.2.6")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.koboldPanel)
    }
}

// MARK: - MenuBarMessageBubble

struct MenuBarMessageBubble: View {
    let message: MenuBarMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 14.5))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(message.role == "user" ? Color.koboldEmerald.opacity(0.2) : Color.koboldSurface)
                    )
                    .textSelection(.enabled)

                if message.role == "assistant", let confidence = message.confidence {
                    HStack(spacing: 3) {
                        Image(systemName: "gauge.medium")
                            .font(.system(size: 9))
                        Text("\(Int(confidence * 100))%")
                            .font(.system(size: 11.5))
                    }
                    .foregroundColor(confidence >= 0.8 ? .koboldEmerald : confidence >= 0.5 ? .koboldGold : .red)
                    .padding(.trailing, 4)
                }
            }

            if message.role == "assistant" { Spacer(minLength: 40) }
        }
    }
}

// MARK: - MenuBarViewModel

@MainActor
class MenuBarViewModel: ObservableObject {
    @Published var messages: [MenuBarMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false

    private var streamTask: Task<Void, Never>?

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        messages.append(MenuBarMessage(role: "user", content: text))
        isStreaming = true

        let port = UserDefaults.standard.integer(forKey: "kobold.port")
        let daemonPort = port > 0 ? port : 8080
        let urlStr = "http://localhost:\(daemonPort)/agent"

        streamTask = Task {
            defer { isStreaming = false }

            guard let url = URL(string: urlStr) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let token = UserDefaults.standard.string(forKey: "kobold.authToken") ?? "kobold-secret"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120

            let body: [String: Any] = ["message": text, "agent_type": "general"]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    messages.append(MenuBarMessage(role: "assistant", content: "Fehler: Daemon nicht erreichbar"))
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let answer = json["output"] as? String, !answer.isEmpty {
                    let confidence = json["confidence"] as? Double
                    messages.append(MenuBarMessage(role: "assistant", content: answer, confidence: confidence))
                } else {
                    messages.append(MenuBarMessage(role: "assistant", content: "Keine Antwort erhalten"))
                }
            } catch {
                messages.append(MenuBarMessage(role: "assistant", content: "Fehler: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - MenuBarMessage

struct MenuBarMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    var confidence: Double? = nil
}
