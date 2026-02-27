import SwiftUI

// MARK: - KoboldOS Glass Design System
// Inspired by: MVP GlassUI, OpenClaw dark theme, AgentZero dashboard, Ollama minimal UI

// MARK: - Clover Background Pattern

/// Zartes Kleeblatt-Muster als Hintergrund für die Content-Area
struct CloverPatternBackground: View {
    var color: Color = .koboldEmerald
    var opacity: Double = 0.025
    var size: CGFloat = 28
    var spacing: CGFloat = 60

    var body: some View {
        Canvas { context, canvasSize in
            let cols = Int(canvasSize.width / spacing) + 2
            let rows = Int(canvasSize.height / spacing) + 2

            for row in 0..<rows {
                for col in 0..<cols {
                    let offsetX: CGFloat = row.isMultiple(of: 2) ? spacing / 2 : 0
                    let x = CGFloat(col) * spacing + offsetX
                    let y = CGFloat(row) * spacing
                    let center = CGPoint(x: x, y: y)
                    let leafSize = size * 0.38
                    let petalDist = size * 0.22

                    // 3 Blätter (Kleeblatt)
                    for angle in [0.0, 2.094, 4.189] { // 0°, 120°, 240° in radians
                        let lx = center.x + cos(angle - .pi / 2) * petalDist
                        let ly = center.y + sin(angle - .pi / 2) * petalDist
                        let leafRect = CGRect(
                            x: lx - leafSize / 2,
                            y: ly - leafSize / 2,
                            width: leafSize,
                            height: leafSize
                        )
                        let leaf = Path(ellipseIn: leafRect)
                        context.fill(leaf, with: .color(color.opacity(opacity)))
                    }

                    // Stiel
                    var stem = Path()
                    stem.move(to: CGPoint(x: center.x, y: center.y + size * 0.05))
                    stem.addLine(to: CGPoint(x: center.x + size * 0.08, y: center.y + size * 0.35))
                    context.stroke(stem, with: .color(color.opacity(opacity * 0.7)), lineWidth: 1)
                }
            }
        }
        .drawingGroup() // GPU-accelerated rendering for repeated pattern
        .allowsHitTesting(false)
    }
}

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
                if let icon { Image(systemName: icon).font(.system(size: 15.5, weight: .medium)) }
                Text(title).font(.system(size: 15.5, weight: .semibold))
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
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            } else {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            }
        }
        .font(.system(size: 16.5))
        .textFieldStyle(.plain)
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
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
    var isStreaming: Bool = false
    @State private var showCopy = false
    @State private var copied = false
    @State private var streamPulse = false
    // isSpeaking removed — TTSManager.shared.isSpeaking is the single source of truth
    @AppStorage("kobold.chat.fontSize") private var chatFontSize: Double = 16.5

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Bubble
                Group {
                    if isLoading {
                        LoadingDots()
                    } else if isUser {
                        // User messages: plain text (no markdown rendering needed)
                        Text(message)
                            .font(.system(size: CGFloat(chatFontSize)))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                    } else {
                        // Assistant messages: rich text with markdown, code blocks, images, links
                        RichTextView(text: message, isUser: false, fontSize: CGFloat(chatFontSize))
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
                        .stroke(
                            isStreaming ? Color.koboldEmerald.opacity(streamPulse ? 0.6 : 0.15) : Color.white.opacity(0.1),
                            lineWidth: isStreaming ? 1.5 : 0.5
                        )
                        .animation(isStreaming ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : .default, value: streamPulse)
                )
                .onAppear { if isStreaming { streamPulse = true } }
                .onDisappear { streamPulse = false }
                .onChange(of: isStreaming) {
                    if isStreaming { streamPulse = true } else { streamPulse = false }
                }

                // Copy + TTS + Timestamp row
                HStack(spacing: 6) {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if showCopy && !isLoading && !message.isEmpty {
                        CopyButton(text: message, copied: $copied)

                        // TTS Speaker-Button (nur bei Assistant-Nachrichten)
                        if !isUser {
                            Button(action: {
                                if TTSManager.shared.isSpeaking {
                                    TTSManager.shared.stop()
                                } else {
                                    TTSManager.shared.speak(message)
                                }
                            }) {
                                Image(systemName: TTSManager.shared.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(TTSManager.shared.isSpeaking ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(TTSManager.shared.isSpeaking ? "Vorlesen stoppen" : "Vorlesen")
                        }
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
                .font(.system(size: 12.5))
                .foregroundColor(copied ? .koboldEmerald : .secondary)
        }
        .buttonStyle(.plain)
        .help("Kopieren")
    }
}

// MARK: - Loading Dots Animation

struct LoadingDots: View {
    @State private var dotCount = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.primary.opacity(i < dotCount ? 0.8 : 0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .onAppear {
            animationTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { break }
                    dotCount = (dotCount + 1) % 4
                }
            }
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
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

// MARK: - CircularGaugeView (animated ring gauge for CPU/RAM)

struct CircularGaugeView: View {
    let value: Double
    let label: String
    let valueText: String
    var color: Color = .koboldEmerald
    var lineWidth: CGFloat = 8
    var size: CGFloat = 80

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(value, 1.0))
                    .stroke(
                        AngularGradient(gradient: Gradient(colors: [color.opacity(0.6), color]), center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: value)
                Text(valueText)
                    .font(.system(size: size * 0.18, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
        }
    }
}

// MARK: - FuturisticBox (Settings cards with glow + gradient accents)

struct FuturisticBox<Content: View>: View {
    let icon: String
    let title: String
    let accentColor: Color
    let content: Content

    init(icon: String, title: String, accent: Color = .koboldEmerald, @ViewBuilder content: () -> Content) {
        self.icon = icon; self.title = title; self.accentColor = accent; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with gradient accent line
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [accentColor, accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .shadow(color: accentColor.opacity(0.5), radius: 4)
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
            }

            // Gradient divider
            Rectangle()
                .fill(LinearGradient(colors: [accentColor.opacity(0.6), accentColor.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            content
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.koboldPanel)
                // Subtle gradient overlay
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.04), .clear, .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                // Border with glow
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [accentColor.opacity(0.25), Color.white.opacity(0.08), accentColor.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
        )
        .shadow(color: accentColor.opacity(0.08), radius: 8, x: 0, y: 2)
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
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(.koboldEmerald)
            }
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
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
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
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
                        Text(toolName).font(.system(size: 14.5, weight: .semibold)).foregroundColor(.koboldGold)
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
                        .font(.system(size: 13.5, design: .monospaced))
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
                        Text("\(toolName) \(success ? "✓" : "✗")").font(.system(size: 14.5, weight: .semibold)).foregroundColor(color)
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
                        .font(.system(size: 13.5, design: .monospaced))
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

// MARK: - DiffResultBubble (Claude Code-style green/red diff display)

private enum DiffLineType {
    case added, removed, context, header, hunk

    var prefix: String {
        switch self {
        case .added: return "+"
        case .removed: return "-"
        case .context, .header, .hunk: return " "
        }
    }

    var textColor: Color {
        switch self {
        case .added: return .green
        case .removed: return Color(.sRGB, red: 1.0, green: 0.35, blue: 0.35, opacity: 1.0)
        case .hunk: return Color.blue.opacity(0.7)
        case .header: return .secondary
        case .context: return .secondary.opacity(0.8)
        }
    }

    var bgColor: Color {
        switch self {
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        default: return .clear
        }
    }
}

private struct DiffLine: Identifiable {
    let id: Int
    let text: String
    let type: DiffLineType
}

struct DiffResultBubble: View {
    let output: String
    let success: Bool
    @State private var expanded = true
    @State private var showCopy = false
    @State private var copied = false
    @State private var cachedLines: [DiffLine] = []
    @State private var cachedPath = ""
    @State private var cachedAdded = 0
    @State private var cachedRemoved = 0
    @State private var didParse = false

    private func parseIfNeeded() {
        guard !didParse else { return }
        let parts = output.components(separatedBy: "\n__DIFF__\n")
        let summary = parts.first ?? output
        let diffText = parts.count > 1 ? parts[1] : ""
        let rawLines = diffText.components(separatedBy: "\n")

        if let range = summary.range(of: "to: ") {
            cachedPath = String(summary[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        var result: [DiffLine] = []
        for (i, line) in rawLines.enumerated() {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                result.append(DiffLine(id: i, text: line, type: .header))
            } else if line.hasPrefix("@@") {
                result.append(DiffLine(id: i, text: line, type: .hunk))
            } else if line.hasPrefix("+") {
                result.append(DiffLine(id: i, text: String(line.dropFirst()), type: .added))
            } else if line.hasPrefix("-") {
                result.append(DiffLine(id: i, text: String(line.dropFirst()), type: .removed))
            } else if line.hasPrefix(" ") {
                result.append(DiffLine(id: i, text: String(line.dropFirst()), type: .context))
            } else if !line.isEmpty {
                result.append(DiffLine(id: i, text: line, type: .context))
            }
        }
        cachedLines = result
        cachedAdded = result.filter { $0.type == .added }.count
        cachedRemoved = result.filter { $0.type == .removed }.count
        didParse = true
    }

    private var shortPath: String {
        let p = cachedPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .font(.caption2).foregroundColor(.koboldEmerald)
                        Text(shortPath.isEmpty ? "file" : (shortPath as NSString).lastPathComponent)
                            .font(.system(size: 14.5, weight: .semibold)).foregroundColor(.koboldEmerald)
                            .lineLimit(1)
                        if cachedAdded > 0 {
                            Text("+\(cachedAdded)")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        if cachedRemoved > 0 {
                            Text("-\(cachedRemoved)")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        Spacer()
                        if showCopy { CopyButton(text: output, copied: $copied) }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if !shortPath.isEmpty {
                    Text(shortPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if expanded && !cachedLines.isEmpty {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(cachedLines) { line in
                                HStack(spacing: 0) {
                                    // +/- gutter
                                    Text(line.type == .added ? "+" : line.type == .removed ? "-" : " ")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(line.type.textColor)
                                        .frame(width: 16, alignment: .center)
                                    // Line content
                                    Text(line.text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(line.type.textColor)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.type.bgColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 350)
                    .background(Color.black.opacity(0.35))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.koboldEmerald.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.koboldEmerald.opacity(0.18), lineWidth: 0.5)))
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { showCopy = h } }
            .onAppear { parseIfNeeded() }
            Spacer(minLength: 80)
        }
    }
}

// MARK: - InteractiveBubble (Yes/No or multi-choice buttons from agent)

struct InteractiveBubble: View {
    let text: String
    let options: [InteractiveOption]
    let isAnswered: Bool
    let selectedOptionId: String?
    let onSelect: (InteractiveOption) -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: 16.5))
                    .foregroundColor(.primary)
                HStack(spacing: 10) {
                    ForEach(options) { option in
                        Button(action: { if !isAnswered { onSelect(option) } }) {
                            HStack(spacing: 6) {
                                if let icon = option.icon {
                                    Image(systemName: icon).font(.system(size: 14.5))
                                }
                                Text(option.label).font(.system(size: 15.5, weight: .semibold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(optionBackground(for: option))
                            .overlay(optionBorder(for: option))
                            .foregroundColor(isSelected(option) ? .koboldEmerald : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAnswered)
                        .opacity(isAnswered && selectedOptionId != option.id ? 0.4 : 1.0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16).fill(Color.koboldEmerald.opacity(0.06)))
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.koboldEmerald.opacity(0.2), lineWidth: 0.5))
            Spacer(minLength: 60)
        }
    }

    private func isSelected(_ option: InteractiveOption) -> Bool {
        isAnswered && selectedOptionId == option.id
    }

    private func optionBackground(for option: InteractiveOption) -> some View {
        let selected = isSelected(option)
        return RoundedRectangle(cornerRadius: 10)
            .fill(Color.koboldEmerald.opacity(selected ? 0.25 : 0.1))
    }

    private func optionBorder(for option: InteractiveOption) -> some View {
        let selected = isSelected(option)
        return RoundedRectangle(cornerRadius: 10)
            .stroke(Color.koboldEmerald.opacity(selected ? 0.6 : 0.3), lineWidth: 1)
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
                            .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(success ? .koboldEmerald : .red)
                        Spacer()
                        if showCopy {
                            CopyButton(text: output, copied: $copied)
                        }
                        if let code = exitCode {
                            Text(code)
                                .font(.system(size: 12.5, design: .monospaced))
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
                            .font(.system(size: 14.5, design: .monospaced))

                            if !bodyText.isEmpty {
                                Text(bodyText)
                                    .font(.system(size: 13.5, design: .monospaced))
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
                        Text(thinkingLabel).font(.system(size: 14.5, weight: .medium)).italic().foregroundColor(.secondary)
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
                        .font(.system(size: 14.5)).italic()
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
                .font(.system(size: 11.5))
                .foregroundColor(color)
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
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
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11.5)).foregroundColor(.koboldEmerald)
            Text("Schritt \(stepNumber)").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            Text(description).font(.system(size: 12.5)).foregroundColor(.secondary).lineLimit(1)
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
        case "web":                return "🌐"
        case "general":            return "🧠"
        default:                   return "🤖"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(profileEmoji).font(.system(size: 12.5))
            Text("Sub-Agent").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.cyan)
            Text(profile.capitalized).font(.system(size: 12.5, weight: .bold)).foregroundColor(.cyan)
            Text("gestartet").font(.system(size: 12.5)).foregroundColor(.secondary)
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
                            .font(.system(size: 14.5, weight: .semibold)).foregroundColor(.cyan)
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
                        .font(.system(size: 13.5, design: .monospaced))
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

// MARK: - ImageBubble (Eingebettetes Bild im Chat)

struct ImageBubble: View {
    let path: String
    let caption: String
    @State private var loadedImage: NSImage?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = loadedImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 300)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    .onTapGesture { openImage() }
                    .contextMenu {
                        Button("Im Finder zeigen") { openImage() }
                        Button("Kopieren") { copyImage(img) }
                    }
            } else if let error = loadError {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            } else {
                ProgressView()
                    .frame(width: 100, height: 60)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { loadImage() }
    }

    private func loadImage() {
        // Expand ~ in path
        let expandedPath = (path as NSString).expandingTildeInPath

        // Try 1: Direct file path
        if FileManager.default.fileExists(atPath: expandedPath) {
            // Use Data-based loading (supports more formats than NSImage(contentsOfFile:))
            if let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
               let img = NSImage(data: data), img.isValid {
                loadedImage = img
                return
            }
            // Try CGImageSource for exotic formats
            let url = URL(fileURLWithPath: expandedPath) as CFURL
            if let source = CGImageSourceCreateWithURL(url, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                loadedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return
            }
        }

        // Try 2: Base64-encoded data
        if path.hasPrefix("data:image/") {
            if let commaIdx = path.firstIndex(of: ",") {
                let base64 = String(path[path.index(after: commaIdx)...])
                if let data = Data(base64Encoded: base64), let img = NSImage(data: data) {
                    loadedImage = img
                    return
                }
            }
        }

        // Try 3: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            Task {
                if let url = URL(string: path),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let img = NSImage(data: data) {
                    await MainActor.run { loadedImage = img }
                } else {
                    await MainActor.run { loadError = "URL konnte nicht geladen werden: \(path)" }
                }
            }
            return
        }

        loadError = "Bild nicht gefunden: \(path)"
    }

    private func openImage() {
        let expandedPath = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
        }
    }

    private func copyImage(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
}

// MARK: - ThinkingPanelBubble (Combined thinking window)

struct ThinkingPanelBubble: View {
    let entries: [ThinkingEntry]
    let isLive: Bool
    var isNewest: Bool = false
    @State private var expanded: Bool
    @State private var pulse = false
    @State private var verbIndex = Int.random(in: 0..<ThinkingPlaceholderBubble.thinkingVerbs.count)
    @State private var verbTimer: Task<Void, Never>?
    @State private var scrollDebounceTask: Task<Void, Never>?

    init(entries: [ThinkingEntry], isLive: Bool, isNewest: Bool = false) {
        self.entries = entries
        self.isLive = isLive
        self.isNewest = isNewest
        self._expanded = State(initialValue: isLive || isNewest)
    }

    private var hasSubAgentActivity: Bool {
        entries.contains { $0.type == .subAgentSpawn || $0.type == .subAgentResult }
    }

    private var thinkingVerb: String {
        ThinkingPlaceholderBubble.thinkingVerbs[verbIndex % ThinkingPlaceholderBubble.thinkingVerbs.count]
    }

    private func startVerbRotation() {
        verbTimer?.cancel()
        guard isLive else { return } // Nur bei aktiver Anzeige rotieren
        verbTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s rotation (weniger CPU)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.3)) {
                    verbIndex = (verbIndex + 1) % ThinkingPlaceholderBubble.thinkingVerbs.count
                }
            }
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // Header — collapsible toggle (live: not collapsible)
                if !entries.isEmpty {
                    Button(action: {
                        // Allow collapse even during streaming — user should control visibility
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.koboldGold)
                            Image(systemName: "brain")
                                .font(.system(size: 13.5))
                                .foregroundColor(.koboldGold)
                            Text(isLive ? "\(entries.count) Schritte" : "\(entries.count) Schritte")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(.koboldGold)
                            Spacer()
                            if !isLive {
                                Button(action: { copyAllSteps() }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Alle Schritte kopieren")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Stream content — always expanded when live
                if expanded && !entries.isEmpty {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(entries) { entry in
                                    thinkingRow(entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .frame(maxHeight: isLive ? 500 : 300)
                        .onChange(of: entries.count) {
                            if isLive && !expanded {
                                withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
                            }
                            if hasSubAgentActivity && !expanded {
                                withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
                            }
                            // Debounced scroll — avoid 10-20 scroll ops/sec during tool-heavy tasks
                            scrollDebounceTask?.cancel()
                            scrollDebounceTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                guard !Task.isCancelled, isLive, let lastEntry = entries.last else { return }
                                scrollProxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Warte-Sprüche am unteren Rand (nur live)
                if isLive {
                    if !entries.isEmpty {
                        Divider().opacity(0.3).padding(.vertical, 4)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 14.5))
                            .foregroundColor(.koboldGold)
                            .scaleEffect(pulse ? 1.1 : 0.95)
                            // Single animation — NO dual repeatForever (was causing infinite re-render loop)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)
                        Text(thinkingVerb)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.koboldGold)
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.koboldGold.opacity(isLive ? 0.08 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.koboldGold.opacity(isLive ? (pulse ? 0.7 : 0.2) : 0.2), lineWidth: isLive ? 1.5 : 0.5)
                    )
                    // REMOVED: .animation(.repeatForever) on border — dual infinite animations caused 100% CPU
            )
            Spacer(minLength: 80)
        }
        .onAppear {
            if isLive {
                pulse = true
                startVerbRotation()
            }
        }
        .onDisappear {
            verbTimer?.cancel()
            scrollDebounceTask?.cancel()
            pulse = false
        }
    }

    @ViewBuilder
    func thinkingRow(_ entry: ThinkingEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: entry.icon)
                .font(.system(size: 12.5))
                .foregroundColor(colorFor(entry))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                if !entry.toolName.isEmpty {
                    Text(entry.toolName)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(colorFor(entry))
                }
                if isLive {
                    TypewriterText(fullText: entry.content, speed: 0.008)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(entry.content.count > 200 ? String(entry.content.prefix(200)) + "..." : entry.content)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
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

// MARK: - TypewriterText (character-by-character streaming effect)

struct TypewriterText: View {
    let fullText: String
    let speed: Double // seconds per character (used to derive chunk timing)

    @State private var visibleCount: Int = 0
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        Text(String(fullText.prefix(visibleCount)))
            .onAppear { startTyping() }
            .onDisappear { timerTask?.cancel(); timerTask = nil }
            .onChange(of: fullText) {
                if visibleCount < fullText.count { startTyping() }
            }
    }

    private func startTyping() {
        // Guard: don't restart if already typing (prevents onChange spam creating new Tasks)
        if timerTask != nil && visibleCount < fullText.count { return }
        timerTask?.cancel()
        if visibleCount >= fullText.count { return }
        timerTask = Task { @MainActor in
            while visibleCount < fullText.count && !Task.isCancelled {
                // Bigger chunks + slower tick = fewer MainActor wakeups
                // 32 chars / 80ms → ~3 updates/sec (much less CPU than 16/60ms)
                let step = min(32, fullText.count - visibleCount)
                visibleCount += step
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            }
            timerTask = nil // Mark as done so next call can start fresh
        }
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
                    .font(.system(size: 15.5))
                    .foregroundColor(.koboldGold)
                Text("Benachrichtigungen")
                    .font(.system(size: 15.5, weight: .semibold))
                Spacer()
                if !viewModel.notifications.isEmpty {
                    Button(action: { viewModel.clearNotifications() }) {
                        Text("Alle löschen")
                            .font(.system(size: 13.5))
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
                        .font(.system(size: 25))
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
                .font(.system(size: 16.5))
                .foregroundColor(notification.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(.primary)
                Text(notification.message)
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                HStack(spacing: 4) {
                    Text(notification.timestamp, style: .relative)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary.opacity(0.7))
                    if notification.navigationTarget != nil {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(.koboldEmerald.opacity(0.6))
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5))
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
                .font(.system(size: 16.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15.5, weight: .semibold))
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

// MARK: - ThinkingPlaceholderBubble (sofort sichtbar, bevor Steps ankommen)

struct ThinkingPlaceholderBubble: View {
    @State private var pulse = false

    static let thinkingVerbs = [
        "Denkt...", "Grübelt...", "Brütet...", "Fermentiert...", "Kocht...",
        "Brainstormt...", "Meditiert...", "Philosophiert...", "Rechnet...",
        "Kombiniert...", "Jongliert...", "Bastelt...", "Schmiedet...",
        "Tüftelt...", "Analysiert...", "Puzzelt...", "Braut zusammen...",
        "Destilliert...", "Spinnt Fäden...", "Zaubert...", "Berechnet...",
        "Knobelt...", "Forscht...", "Träumt...", "Schraubt...",
        "Entschlüsselt...", "Hexenwerk...", "Alchemie...",
        "Betet zum Modell...", "Orakelt...", "Prophezeit...",
    ]
    private var verb: String {
        Self.thinkingVerbs[abs(Int(Date().timeIntervalSince1970 * 3).hashValue) % Self.thinkingVerbs.count]
    }

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 15.5))
                    .foregroundColor(.koboldGold)
                    .scaleEffect(pulse ? 1.1 : 0.95)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                Text(verb)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(.koboldGold)
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.koboldGold.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.koboldGold.opacity(0.2), lineWidth: 0.5))
            )
            Spacer(minLength: 80)
        }
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
    }
}

// MARK: - AgentChecklistItem

struct AgentChecklistItem: Identifiable {
    let id = UUID()
    let text: String
    var isCompleted: Bool

    init(_ text: String, isCompleted: Bool = false) {
        self.text = text
        self.isCompleted = isCompleted
    }

    init(from string: String) {
        if string.hasPrefix("[x] ") || string.hasPrefix("[X] ") {
            self.text = String(string.dropFirst(4))
            self.isCompleted = true
        } else if string.hasPrefix("[ ] ") {
            self.text = String(string.dropFirst(4))
            self.isCompleted = false
        } else {
            self.text = string
            self.isCompleted = false
        }
    }
}

// MARK: - AgentChecklistOverlay (sticky checklist at bottom of chat)

struct AgentChecklistOverlay: View {
    let items: [AgentChecklistItem]
    private var completedCount: Int { items.filter(\.isCompleted).count }
    private var progress: Double { items.isEmpty ? 0 : Double(completedCount) / Double(items.count) }

    init(items strings: [String]) {
        self.items = strings.map { AgentChecklistItem(from: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 14.5, weight: .semibold)).foregroundColor(.koboldEmerald)
                Text("Fortschritt").font(.system(size: 14.5, weight: .semibold))
                Spacer()
                Text("\(completedCount)/\(items.count)")
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.koboldEmerald)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3).fill(Color.koboldEmerald)
                        .frame(width: geo.size.width * progress)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }.frame(height: 4)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14.5))
                        .foregroundColor(item.isCompleted ? .koboldEmerald : .secondary)
                    Text(item.text)
                        .font(.system(size: 13.5))
                        .foregroundColor(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted, color: .secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.koboldPanel.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.koboldEmerald.opacity(0.3), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: -2)
        .padding(.horizontal, 16).padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - SubAgentActivityBanner (always visible outside collapsed panel)

struct SubAgentActivityBanner: View {
    let entries: [ThinkingEntry]

    private var activeSubAgents: [ThinkingEntry] {
        // Only check recent entries to avoid O(n) scan of entire history
        let recent = entries.suffix(30)
        let spawned = recent.filter { $0.type == .subAgentSpawn }
        let finished = Set(recent.filter { $0.type == .subAgentResult }.map { $0.toolName })
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
                        .font(.system(size: 12.5))
                        .foregroundColor(.cyan)
                    Text("Sub-Agent aktiv: \(agent.toolName.capitalized)")
                        .font(.system(size: 13.5, weight: .semibold))
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

// MARK: - Rich Text Renderer (Markdown, Links, Code Blocks, Images)

/// Parsed block from assistant markdown text
private enum RichBlock: Identifiable {
    case text(String)
    case codeBlock(lang: String, code: String)
    case image(url: URL, alt: String)

    var id: String {
        switch self {
        case .text(let t): return "t-\(t.hashValue)"
        case .codeBlock(_, let c): return "c-\(c.hashValue)"
        case .image(let u, _): return "i-\(u.absoluteString)"
        }
    }
}

/// Parse markdown text into rich blocks (code blocks, images, text)
private func parseRichBlocks(_ text: String) -> [RichBlock] {
    var blocks: [RichBlock] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    var currentText: [String] = []

    while i < lines.count {
        let line = lines[i]

        // Code block: ```lang ... ```
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            // Flush accumulated text
            if !currentText.isEmpty {
                blocks.append(.text(currentText.joined(separator: "\n")))
                currentText = []
            }
            let lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            blocks.append(.codeBlock(lang: lang, code: codeLines.joined(separator: "\n")))
            i += 1
            continue
        }

        // Image: ![alt](url) or standalone image URL
        if let range = line.range(of: #"!\[([^\]]*)\]\(([^)]+)\)"#, options: .regularExpression) {
            if !currentText.isEmpty {
                blocks.append(.text(currentText.joined(separator: "\n")))
                currentText = []
            }
            let match = String(line[range])
            let altRange = match.range(of: #"\[([^\]]*)\]"#, options: .regularExpression)!
            let urlRange = match.range(of: #"\(([^)]+)\)"#, options: .regularExpression)!
            let alt = String(match[altRange]).dropFirst().dropLast()
            let urlStr = String(match[urlRange]).dropFirst().dropLast()
            if let url = URL(string: String(urlStr)) {
                blocks.append(.image(url: url, alt: String(alt)))
            }
            i += 1
            continue
        }

        currentText.append(line)
        i += 1
    }

    if !currentText.isEmpty {
        blocks.append(.text(currentText.joined(separator: "\n")))
    }
    return blocks
}

/// Render a markdown text block as AttributedString (supports bold, italic, code, links)
/// PERF: Skips expensive markdown parsing for strings >4KB to prevent Main Thread freeze.
private func markdownAttributedString(_ text: String, isUser: Bool, fontSize: CGFloat = 16.5) -> AttributedString {
    // Skip markdown parsing for large strings — it's O(n²) and blocks Main Thread
    if text.count > 4000 {
        var attr = AttributedString(text)
        attr.font = .system(size: fontSize)
        attr.foregroundColor = isUser ? .white : .primary
        return attr
    }
    do {
        var attr = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        attr.font = .system(size: fontSize)
        attr.foregroundColor = isUser ? .white : .primary
        return attr
    } catch {
        var attr = AttributedString(text)
        attr.font = .system(size: fontSize)
        attr.foregroundColor = isUser ? .white : .primary
        return attr
    }
}

/// Rich text view that renders markdown blocks including code, images, and formatted text
/// PERF: Blocks are cached via @State so parseRichBlocks isn't re-called on every SwiftUI rerender.
struct RichTextView: View {
    let text: String
    let isUser: Bool
    var fontSize: CGFloat = 16.5
    @State private var cachedBlocks: [RichBlock] = []
    @State private var cachedText: String = ""

    var body: some View {
        let blocks = cachedBlocks
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .text(let t):
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(markdownAttributedString(t, isUser: isUser, fontSize: fontSize))
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                NSWorkspace.shared.open(url)
                                return .handled
                            })
                    }
                case .codeBlock(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        // Header bar
                        HStack {
                            Text(lang.isEmpty ? "Code" : lang)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.14))

                        // Code content
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 14.5, design: .monospaced))
                                .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.9))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))

                case .image(let url, let alt):
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 400, maxHeight: 300)
                                .cornerRadius(10)
                                .overlay(alignment: .bottomLeading) {
                                    if !alt.isEmpty {
                                        Text(alt)
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(4)
                                            .padding(6)
                                    }
                                }
                        case .failure:
                            HStack(spacing: 6) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .foregroundColor(.secondary)
                                Link(alt.isEmpty ? url.lastPathComponent : alt, destination: url)
                                    .font(.system(size: 14.5))
                            }
                        default:
                            ProgressView()
                                .frame(width: 200, height: 120)
                        }
                    }
                }
            }
        }
        .onAppear { reparse() }
        .onChange(of: text) { reparse() }
    }

    private func reparse() {
        guard text != cachedText else { return }
        cachedText = text
        cachedBlocks = parseRichBlocks(text)
    }
}

// MARK: - String Chunking for Large Text Rendering

extension String {
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}
