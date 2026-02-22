import SwiftUI

// MARK: - KoboldOS Glass Design System
// Inspired by: MVP GlassUI, OpenClaw dark theme, AgentZero dashboard, Ollama minimal UI

// MARK: - GlassBackground

struct GlassBackground: View {
    var opacity: Double = 0.15
    var cornerRadius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(opacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassCard

struct GlassCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 16

    init(padding: CGFloat = 16, cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(GlassBackground(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - GlassButton

struct GlassButton: View {
    let title: String
    var icon: String? = nil
    var isPrimary: Bool = true
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var buttonColor: Color {
        if isDisabled { return Color.white.opacity(0.1) }
        if isDestructive { return Color.red.opacity(0.8) }
        if isPrimary { return Color.koboldEmerald }
        return Color.white.opacity(0.15)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(buttonColor.opacity(isPressed ? 0.7 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .pressEvents(onPress: { isPressed = true }, onRelease: { isPressed = false })
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - GlassTextField

struct GlassTextField: View {
    @Binding var text: String
    var placeholder: String = "Type here..."
    var isMultiline: Bool = false
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isMultiline {
                // axis: .vertical → Enter submits, Shift+Enter adds line (macOS 14+)
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            } else {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            }
        }
        .textFieldStyle(.plain)
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isFocused ? 0.12 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? Color.koboldEmerald.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        // Make the entire box tappable (not just the text character line)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { isFocused = true }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - GlassChatBubble

struct GlassChatBubble: View {
    let message: String
    let isUser: Bool
    let timestamp: Date
    var isLoading: Bool = false
    @State private var showCopy = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Bubble
                Group {
                    if isLoading {
                        LoadingDots()
                    } else {
                        Text(message)
                            .font(.system(size: 14))
                            .foregroundColor(isUser ? .white : .primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Group {
                        if isUser {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color.koboldEmerald)
                        } else {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )

                // Copy + Timestamp row
                HStack(spacing: 6) {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if showCopy && !isLoading && !message.isEmpty {
                        CopyButton(text: message, copied: $copied)
                    }
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { showCopy = hovering }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - CopyButton (reusable)

struct CopyButton: View {
    let text: String
    @Binding var copied: Bool

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(copied ? .koboldEmerald : .secondary)
        }
        .buttonStyle(.plain)
        .help("Kopieren")
    }
}

// MARK: - Loading Dots Animation

struct LoadingDots: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.primary.opacity(i < dotCount ? 0.8 : 0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

// MARK: - GlassStatusBadge

struct GlassStatusBadge: View {
    let label: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
                .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
        )
    }
}

// MARK: - GlassProgressBar

struct GlassProgressBar: View {
    let value: Double // 0.0 to 1.0
    var label: String? = nil
    var color: Color = .koboldEmerald

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                HStack {
                    Text(label).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(value * 100))%").font(.caption.weight(.medium))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * value)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - GlassDivider

struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.15), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

// MARK: - GlassSection Header

struct GlassSectionHeader: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.koboldEmerald)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - PressEvents ViewModifier

struct PressEvents: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressEvents(onPress: onPress, onRelease: onRelease))
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var icon: String
    var color: Color = .koboldEmerald

    var body: some View {
        GlassCard(padding: 14, cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - ToolCallBubble (Goldfarben, einklappbar)

struct ToolCallBubble: View {
    let toolName: String
    let args: String
    @State private var expanded = false
    @State private var showCopy = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.fill").font(.caption2).foregroundColor(.koboldGold)
                        Text(toolName).font(.system(size: 12, weight: .semibold)).foregroundColor(.koboldGold)
                        Spacer()
                        if showCopy {
                            CopyButton(text: "\(toolName): \(args)", copied: $copied)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if expanded && !args.isEmpty {
                    Text(args)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.koboldGold.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.koboldGold.opacity(0.3), lineWidth: 0.5)))
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            Spacer(minLength: 80)
        }
    }
}

// MARK: - ToolResultBubble (Grün/Rot, einklappbar)

struct ToolResultBubble: View {
    let toolName: String
    let output: String
    let success: Bool
    @State private var expanded = false
    @State private var showCopy = false
    @State private var copied = false
    var color: Color { success ? .koboldEmerald : .red }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption2).foregroundColor(color)
                        Text("\(toolName) \(success ? "✓" : "✗")").font(.system(size: 12, weight: .semibold)).foregroundColor(color)
                        Spacer()
                        if showCopy {
                            CopyButton(text: output, copied: $copied)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(output.count > 600 ? String(output.prefix(600)) + "…" : output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 0.5)))
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            Spacer(minLength: 80)
        }
    }
}

// MARK: - TerminalResultBubble (Shell output, terminal-style)

struct TerminalResultBubble: View {
    let command: String
    let output: String
    let success: Bool
    @State private var expanded = true
    @State private var showCopy = false
    @State private var copied = false

    /// Extract exit code from ShellTool output format "Exit code: N"
    private var exitCode: String? {
        if let range = output.range(of: #"Exit code: \d+"#, options: .regularExpression) {
            return String(output[range])
        }
        return nil
    }

    /// The command shown after the "$ " prompt — extracted from first line or passed explicitly
    private var displayCommand: String {
        // ShellTool prepends "$ command\n" to output, but we get the command separately
        if !command.isEmpty { return command }
        // Fallback: extract from first line if it starts with "$ "
        let first = output.components(separatedBy: .newlines).first ?? ""
        if first.hasPrefix("$ ") { return String(first.dropFirst(2)) }
        return ""
    }

    /// Output body without the "$ command" header line (ShellTool prepends it)
    private var bodyText: String {
        var lines = output.components(separatedBy: .newlines)
        // Remove the "$ command" line ShellTool prepends
        if let first = lines.first, first.hasPrefix("$ ") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // Header bar — collapsible
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                            .foregroundColor(success ? .koboldEmerald : .red)
                        Text("Terminal")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(success ? .koboldEmerald : .red)
                        Spacer()
                        if showCopy {
                            CopyButton(text: output, copied: $copied)
                        }
                        if let code = exitCode {
                            Text(code)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(success ? .secondary : .red)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if expanded {
                    // Terminal body
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Prompt line
                            HStack(spacing: 0) {
                                Text("$ ")
                                    .foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.4))
                                Text(displayCommand)
                                    .foregroundColor(.white)
                            }
                            .font(.system(size: 12, design: .monospaced))

                            if !bodyText.isEmpty {
                                Text(bodyText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(red: 0.78, green: 0.78, blue: 0.78))
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 300)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.08))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(success ? Color.koboldEmerald.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            Spacer(minLength: 40)
        }
    }
}

// MARK: - ThoughtBubble (gedimmt, kursiv, einklappbar)

struct ThoughtBubble: View {
    let text: String
    var thinkingLabel: String = "Denkt nach..."
    @State private var expanded = false
    @State private var showCopy = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(.caption2).foregroundColor(.secondary)
                        Text(thinkingLabel).font(.system(size: 12, weight: .medium)).italic().foregroundColor(.secondary)
                        Spacer()
                        if showCopy {
                            CopyButton(text: text, copied: $copied)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(text)
                        .font(.system(size: 12)).italic()
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(8)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5)))
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            Spacer(minLength: 80)
        }
    }
}

// MARK: - ConfidenceBadge

struct ConfidenceBadge: View {
    let value: Double

    private var color: Color {
        if value >= 0.8 { return .koboldEmerald }
        if value >= 0.5 { return .koboldGold }
        return .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }
}

// MARK: - AgentStepBubble (kleine Statuszeile zwischen Bubbles)

struct AgentStepBubble: View {
    let stepNumber: Int
    let description: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundColor(.koboldEmerald)
            Text("Schritt \(stepNumber)").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Text(description).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

// MARK: - SubAgentSpawnBubble

struct SubAgentSpawnBubble: View {
    let profile: String
    let task: String

    var profileEmoji: String {
        switch profile.lowercased() {
        case "coder", "developer": return "💻"
        case "researcher":         return "📚"
        case "planner":            return "📋"
        case "instructor":         return "🎯"
        default:                   return "🤖"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(profileEmoji).font(.system(size: 10))
            Text("Sub-Agent").font(.system(size: 10, weight: .semibold)).foregroundColor(.cyan)
            Text(profile.capitalized).font(.system(size: 10, weight: .bold)).foregroundColor(.cyan)
            Text("gestartet").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.cyan.opacity(0.08))
                .overlay(Capsule().stroke(Color.cyan.opacity(0.2), lineWidth: 0.5))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

// MARK: - SubAgentResultBubble

struct SubAgentResultBubble: View {
    let profile: String
    let output: String
    let success: Bool
    @State private var expanded = false
    @State private var showCopy = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.caption2).foregroundColor(.cyan)
                        Text("\(profile.capitalized) \(success ? "✓" : "✗")")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.cyan)
                        Spacer()
                        if showCopy {
                            CopyButton(text: output, copied: $copied)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(output.count > 800 ? String(output.prefix(800)) + "…" : output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cyan.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.2), lineWidth: 0.5))
            )
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            Spacer(minLength: 80)
        }
    }
}

// MARK: - ThinkingPanelBubble (Combined thinking window)

struct ThinkingPanelBubble: View {
    let entries: [ThinkingEntry]
    let isLive: Bool
    @State private var expanded: Bool

    init(entries: [ThinkingEntry], isLive: Bool) {
        self.entries = entries
        self.isLive = isLive
        // Live (active) panels start expanded, old messages start collapsed
        self._expanded = State(initialValue: isLive)
    }

    private var hasSubAgentActivity: Bool {
        entries.contains { $0.type == .subAgentSpawn || $0.type == .subAgentResult }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // Header — collapsible toggle
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.koboldGold)
                        Image(systemName: "brain")
                            .font(.system(size: 11))
                            .foregroundColor(.koboldGold)
                        Text(isLive ? "Denkt... (\(entries.count) Schritte)" : "\(entries.count) Schritte")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.koboldGold)
                        if isLive {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        }
                        Spacer()
                        if !isLive {
                            Button(action: { copyAllSteps() }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Alle Schritte kopieren")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onChange(of: entries.count) {
                    // Auto-expand when sub-agent events arrive
                    if hasSubAgentActivity && !expanded {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
                    }
                }

                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entries) { entry in
                                thinkingRow(entry)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.koboldGold.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.koboldGold.opacity(0.2), lineWidth: 0.5))
            )
            Spacer(minLength: 80)
        }
    }

    @ViewBuilder
    func thinkingRow(_ entry: ThinkingEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: entry.icon)
                .font(.system(size: 10))
                .foregroundColor(colorFor(entry))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                if !entry.toolName.isEmpty {
                    Text(entry.toolName)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(colorFor(entry))
                }
                Text(entry.content.count > 200 ? String(entry.content.prefix(200)) + "..." : entry.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    func colorFor(_ entry: ThinkingEntry) -> Color {
        switch entry.type {
        case .thought:       return .koboldGold
        case .toolCall:      return .blue
        case .toolResult:    return entry.success ? .koboldEmerald : .red
        case .subAgentSpawn: return .purple
        case .subAgentResult: return entry.success ? .koboldEmerald : .orange
        case .agentStep:     return .secondary
        }
    }

    private func copyAllSteps() {
        let text = entries.map { entry in
            let prefix: String
            switch entry.type {
            case .thought:       prefix = "💭"
            case .toolCall:      prefix = "🔧 \(entry.toolName)"
            case .toolResult:    prefix = entry.success ? "✅ \(entry.toolName)" : "❌ \(entry.toolName)"
            case .subAgentSpawn: prefix = "👤 \(entry.toolName)"
            case .subAgentResult: prefix = "📋 \(entry.toolName)"
            case .agentStep:     prefix = "→"
            }
            return "\(prefix): \(entry.content)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - NotificationPopover

struct NotificationPopover: View {
    @ObservedObject var viewModel: RuntimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bell.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.koboldGold)
                Text("Benachrichtigungen")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !viewModel.notifications.isEmpty {
                    Button(action: { viewModel.clearNotifications() }) {
                        Text("Alle löschen")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if viewModel.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Keine Benachrichtigungen")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.notifications) { notif in
                            NotificationRow(notification: notif, onTap: {
                                if let target = notif.navigationTarget {
                                    viewModel.navigateToTarget(target)
                                }
                            }, onDismiss: {
                                viewModel.removeNotification(notif)
                            })
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 350)
            }
        }
        .frame(width: 320)
        .background(Color.koboldPanel)
    }
}

struct NotificationRow: View {
    let notification: KoboldNotification
    var onTap: (() -> Void)? = nil
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notification.icon)
                .font(.system(size: 14))
                .foregroundColor(notification.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text(notification.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                HStack(spacing: 4) {
                    Text(notification.timestamp, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                    if notification.navigationTarget != nil {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.koboldEmerald.opacity(0.6))
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isHovered ? Color.koboldSurface.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - ToolStatusRow

struct ToolStatusRow: View {
    let name: String
    let description: String
    let isEnabled: Bool
    let errorCount: Int
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isEnabled ? .koboldEmerald : .red.opacity(0.7))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            if errorCount > 0 {
                GlassStatusBadge(label: "\(errorCount) err", color: .orange)
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle?($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - SubAgentActivityBanner (always visible outside collapsed panel)

struct SubAgentActivityBanner: View {
    let entries: [ThinkingEntry]

    private var activeSubAgents: [ThinkingEntry] {
        // Show spawned sub-agents that haven't returned yet
        let spawned = entries.filter { $0.type == .subAgentSpawn }
        let finished = Set(entries.filter { $0.type == .subAgentResult }.map { $0.toolName })
        return spawned.filter { !finished.contains($0.toolName) }
    }

    var body: some View {
        if !activeSubAgents.isEmpty {
            ForEach(activeSubAgents) { agent in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.cyan)
                    Text("Sub-Agent aktiv: \(agent.toolName.capitalized)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.cyan)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.2), lineWidth: 0.5))
                )
                .padding(.horizontal, 16)
            }
        }
    }
}
