import SwiftUI

// MARK: - VoiceView ("Sprechen"-Tab — Bidirektionale Sprachkommunikation)

@available(macOS 14.0, *)
struct VoiceView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @StateObject private var recorder = AudioRecordingManager.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var sttManager = STTManager.shared
    @ObservedObject private var elConversation = ElevenLabsConversationManager.shared

    // State
    @State private var transcript: [VoiceTranscriptEntry] = []
    @State private var voiceState: VoiceState = .idle
    @State private var pulseAnimation = false
    @State private var waveformValues: [Float] = Array(repeating: 0, count: 30)
    @State private var lastHandledMessageCount = 0
    @State private var sessionCharacters: Int = 0  // ElevenLabs-Zeichen in dieser Session
    @State private var dotAnimation = false  // Typing-Indicator Dots

    // Settings
    @AppStorage("kobold.voice.vadEnabled") private var vadEnabled = false
    @AppStorage("kobold.voice.autoRespond") private var autoRespond = true
    @AppStorage("kobold.voice.silenceTimeout") private var silenceTimeout: Double = 0.7
    @AppStorage("kobold.elevenlabs.enabled") private var elevenLabsEnabled = false
    @AppStorage("kobold.voice.mode") private var voiceMode: String = "native"
    @AppStorage("kobold.voice.micSensitivity") private var micSensitivity: Double = 7.0

    private var isElevenLabsLive: Bool { voiceMode == "elevenlabs_live" }

    enum VoiceState: Equatable {
        case idle
        case listening       // Continuous VAD aktiv, wartet auf Sprache
        case recording       // Sprache erkannt / manuelle Aufnahme
        case transcribing
        case thinking        // Agent verarbeitet
        case speaking        // TTS spielt
    }

    struct VoiceTranscriptEntry: Identifiable {
        let id = UUID()
        let role: String  // "user" oder "assistant"
        let text: String
        let timestamp: Date
        var characters: Int = 0  // ElevenLabs-Zeichenverbrauch (nur TTS-Nachrichten)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Oben: Transkript (scrollbar, volle Breite wie Chat)
            transcriptPanel
            // Typing/Processing-Indicator (groß, zentriert, nur bei Verarbeitung)
            if isProcessing {
                processingIndicator
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            GlassDivider()
            // Unten: Voice-Steuerung (kompakt, fixiert wie Chat-Eingabe)
            voicePanel
        }
        .animation(.easeInOut(duration: 0.3), value: isProcessing)
        .onAppear {
            recorder.onSpeechCaptured = handleSpeechCaptured
            recorder.checkMicrophonePermission()
            lastHandledMessageCount = viewModel.messages.count
            setupElevenLabsCallbacks()
            if !isElevenLabsLive && vadEnabled && sttManager.isModelLoaded && recorder.hasMicrophonePermission {
                startContinuousVAD()
            }
        }
        .onDisappear {
            recorder.stopContinuousListening()
            recorder.onSpeechCaptured = nil
            if elConversation.isActive { elConversation.disconnect() }
            voiceState = .idle
        }
        .onChange(of: recorder.audioLevel) { _, level in
            updateWaveform(level: level)
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording && voiceState == .idle { voiceState = .listening }
        }
        .onChange(of: recorder.vadDetected) { _, detected in
            if detected && (voiceState == .listening || voiceState == .idle) {
                voiceState = .recording
            }
            if detected && voiceState == .speaking {
                print("[Voice] User spricht während TTS → Interrupt")
                ttsManager.stop()
                voiceState = .recording
            }
        }
        .onChange(of: ttsManager.isSpeaking) { _, speaking in
            if speaking {
                recorder.vadThresholdMultiplier = 3.0
            } else {
                recorder.vadThresholdMultiplier = 1.0
                if voiceState == .speaking {
                    if vadEnabled && recorder.continuousListening {
                        voiceState = .listening
                    } else {
                        voiceState = .idle
                    }
                }
            }
        }
        .onChange(of: viewModel.messages.count) { _, newCount in
            if newCount > lastHandledMessageCount {
                lastHandledMessageCount = newCount
                handleNewMessage()
            }
        }
        .onChange(of: vadEnabled) { _, enabled in
            if enabled && !isElevenLabsLive && !recorder.isRecording && sttManager.isModelLoaded && recorder.hasMicrophonePermission {
                startContinuousVAD()
            } else if !enabled && recorder.continuousListening {
                recorder.stopContinuousListening()
                voiceState = .idle
            }
        }
        .onChange(of: elConversation.audioLevel) { _, level in
            if isElevenLabsLive { updateWaveform(level: level) }
        }
        .onChange(of: elConversation.state) { _, newState in
            guard isElevenLabsLive else { return }
            switch newState {
            case .disconnected: voiceState = .idle
            case .connecting: voiceState = .thinking
            case .listening: voiceState = .listening
            case .userSpeaking: voiceState = .recording
            case .agentSpeaking: voiceState = .speaking
            case .error: voiceState = .idle
            }
        }
        .onChange(of: voiceMode) { _, newMode in
            if newMode == "elevenlabs_live" {
                recorder.stopContinuousListening()
            } else {
                if elConversation.isActive { elConversation.disconnect() }
            }
            voiceState = .idle
        }
    }

    // MARK: - Voice Panel (Unten — kompakt)

    private var voicePanel: some View {
        VStack(spacing: 4) {
            // Hauptleiste: [Picker links] [Waveform mitte] [Button rechts] [Status]
            HStack(spacing: 10) {
                // Mode Picker (linksbündig, kompakt)
                Picker("", selection: $voiceMode) {
                    Text("Nativ").tag("native")
                    Text("ElevenLabs").tag("elevenlabs_live")
                }
                .pickerStyle(.segmented)
                .frame(width: 170)

                // Waveform (mitte, flexibel)
                waveformView
                    .frame(height: 44)

                // Multi-Funktions-Button (rechts)
                mainButton

                // Status-Dot
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 65)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Quick Settings + Warnungen (nur bei Bedarf, eine Zeile)
            if showExtras {
                HStack(spacing: 12) {
                    if !isElevenLabsLive {
                        Toggle(isOn: $vadEnabled) {
                            HStack(spacing: 3) {
                                Image(systemName: "waveform.badge.mic").font(.system(size: 9))
                                Text("VAD").font(.system(size: 10))
                            }
                        }
                        .toggleStyle(.switch).controlSize(.mini)

                        Toggle(isOn: $autoRespond) {
                            HStack(spacing: 3) {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                                Text("TTS").font(.system(size: 10))
                            }
                        }
                        .toggleStyle(.switch).controlSize(.mini)
                    }

                    // Mikrofon-Empfindlichkeit Slider (für BEIDE Modi)
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill").font(.system(size: 8)).foregroundColor(.secondary)
                        Slider(value: $micSensitivity, in: 1...10, step: 1)
                            .frame(width: 70)
                            .controlSize(.mini)
                        Text("\(Int(micSensitivity))").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).frame(width: 12)
                    }
                    .help(isElevenLabsLive ? "Mikrofon-Verstärkung: 1 (leise) bis 10 (laut)" : "Mikrofon-Empfindlichkeit: 1 (unempfindlich) bis 10 (sehr empfindlich)")

                    if isElevenLabsLive && elConversation.isActive {
                        HStack(spacing: 2) {
                            Circle().fill(Color.purple).frame(width: 5, height: 5)
                            Text("Live").font(.system(size: 9, weight: .medium)).foregroundColor(.purple)
                        }
                    }

                    Spacer()

                    if sessionCharacters > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "character.cursor.ibeam").font(.system(size: 8))
                            Text("\(sessionCharacters) Zeichen")
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            // Warnungen (nur wenn nötig)
            warningBadges
                .padding(.horizontal, 12)
        }
    }

    /// Zeigt Extras nur wenn relevant (Toggles, Credits, Warnungen)
    private var showExtras: Bool {
        !isElevenLabsLive || elConversation.isActive || sessionCharacters > 0
    }

    // MARK: - Warning Badges

    @ViewBuilder
    private var warningBadges: some View {
        if isElevenLabsLive {
            if elConversation.agentId.isEmpty {
                warningBadge(icon: "exclamationmark.triangle.fill", color: .orange,
                             text: "Agent-ID fehlt → Einstellungen → Sprache & Audio")
            }
            if elConversation.apiKey.isEmpty {
                warningBadge(icon: "exclamationmark.triangle.fill", color: .orange,
                             text: "ElevenLabs API-Key fehlt → Einstellungen → Sprache & Audio")
            }
            if case .error(let msg) = elConversation.state {
                warningBadge(icon: "xmark.octagon.fill", color: .red, text: msg)
            }
        } else if !sttManager.isModelLoaded {
            warningBadge(icon: "exclamationmark.triangle.fill", color: .orange,
                         text: "Whisper-Modell nicht geladen → Einstellungen → Sprache")
        }
        if !recorder.hasMicrophonePermission {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill").foregroundColor(.red).font(.caption)
                Text(l10n.language.micMissing).font(.caption).foregroundColor(.secondary)
                Button("Öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }.font(.caption)
            }.padding(.bottom, 4)
        }
    }

    private func warningBadge(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.caption)
            Text(text).font(.caption).foregroundColor(.secondary)
        }.padding(.bottom, 4)
    }

    // MARK: - Waveform

    private var waveformView: some View {
        Canvas { context, size in
            let barCount = waveformValues.count
            let barWidth = size.width / CGFloat(barCount) * 0.55
            let spacing = size.width / CGFloat(barCount)
            let midY = size.height / 2

            for i in 0..<barCount {
                let raw = CGFloat(waveformValues[i])
                // Verstärkter Ausschlag — quadratische Kurve für dramatischere Peaks
                let boosted = min(pow(raw, 0.6) * 1.3, 1.0)
                // Organische Variation: benachbarte Bars leicht variieren
                let seed = CGFloat(i * 7 + Int(raw * 100)) / 100.0
                let jitter = 0.85 + 0.15 * sin(seed * 3.14)
                let value = boosted * jitter

                let barHeight = max(3, value * size.height)
                let x = CGFloat(i) * spacing + spacing / 2 - barWidth / 2
                let y = midY - barHeight / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let rr = RoundedRectangle(cornerRadius: barWidth / 2)

                let color: Color
                if isElevenLabsLive {
                    switch elConversation.state {
                    case .agentSpeaking: color = .purple.opacity(0.5 + Double(value) * 0.5)
                    case .userSpeaking:  color = .koboldGold.opacity(0.5 + Double(value) * 0.5)
                    case .listening:     color = .koboldEmerald.opacity(0.2 + Double(value) * 0.5)
                    default:             color = .purple.opacity(0.2 + Double(value) * 0.3)
                    }
                } else {
                    switch voiceState {
                    case .speaking:   color = .blue.opacity(0.6 + Double(value) * 0.4)
                    case .recording:  color = .koboldGold.opacity(0.5 + Double(value) * 0.5)
                    case .listening:  color = .koboldEmerald.opacity(0.2 + Double(value) * 0.5)
                    case .thinking:   color = .orange.opacity(0.3 + Double(value) * 0.4)
                    default:          color = .koboldEmerald.opacity(0.3 + Double(value) * 0.3)
                    }
                }

                context.fill(rr.path(in: rect), with: .color(color))

                // Glow-Effekt für aktive Bars (> 30% Ausschlag)
                if value > 0.3 {
                    let glowRect = CGRect(x: x - 1, y: y - 1, width: barWidth + 2, height: barHeight + 2)
                    let glowRR = RoundedRectangle(cornerRadius: (barWidth + 2) / 2)
                    context.fill(glowRR.path(in: glowRect), with: .color(color.opacity(0.15)))
                }
            }
        }
    }

    // MARK: - Multi-Funktions-Button

    private var mainButton: some View {
        Button(action: handleButtonPress) {
            ZStack {
                Circle()
                    .stroke(buttonRingColor, lineWidth: 2)
                    .frame(width: 40, height: 40)
                    .scaleEffect(pulseAnimation && (voiceState == .idle || voiceState == .listening) ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: pulseAnimation)

                Circle()
                    .fill(buttonFillColor)
                    .frame(width: 34, height: 34)

                Image(systemName: buttonIcon)
                    .font(.system(size: 16))
                    .foregroundColor(buttonIconColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPressButton)
        .keyboardShortcut(.space, modifiers: [])
        .onAppear { pulseAnimation = true }
    }

    private var buttonIcon: String {
        if isElevenLabsLive {
            switch elConversation.state {
            case .disconnected:   return "phone.fill"
            case .connecting:     return "ellipsis"
            case .listening:      return "ear.fill"
            case .userSpeaking:   return "waveform"
            case .agentSpeaking:  return "stop.circle.fill"
            case .error:          return "exclamationmark.triangle.fill"
            }
        }
        switch voiceState {
        case .idle:          return "mic.fill"
        case .listening:     return "ear.fill"
        case .recording:     return "stop.fill"
        case .transcribing:  return "waveform"
        case .thinking:      return "xmark.circle.fill"
        case .speaking:      return "stop.circle.fill"
        }
    }

    private var buttonRingColor: Color {
        if isElevenLabsLive {
            switch elConversation.state {
            case .disconnected:   return .purple
            case .connecting:     return .orange
            case .listening:      return .koboldEmerald
            case .userSpeaking:   return .koboldGold
            case .agentSpeaking:  return .purple
            case .error:          return .red
            }
        }
        switch voiceState {
        case .idle:          return .koboldGold
        case .listening:     return .koboldEmerald
        case .recording:     return .red
        case .transcribing:  return .orange
        case .thinking:      return .orange
        case .speaking:      return .blue
        }
    }

    private var buttonFillColor: Color {
        if isElevenLabsLive {
            switch elConversation.state {
            case .disconnected:   return Color.purple.opacity(0.15)
            case .connecting:     return Color.orange.opacity(0.3)
            case .listening:      return Color.koboldEmerald.opacity(0.15)
            case .userSpeaking:   return Color.koboldGold.opacity(0.3)
            case .agentSpeaking:  return Color.purple.opacity(0.3)
            case .error:          return Color.red.opacity(0.15)
            }
        }
        switch voiceState {
        case .idle:          return Color.koboldGold.opacity(0.15)
        case .listening:     return Color.koboldEmerald.opacity(0.15)
        case .recording:     return Color.red.opacity(0.8)
        case .transcribing:  return Color.orange.opacity(0.3)
        case .thinking:      return Color.orange.opacity(0.3)
        case .speaking:      return Color.blue.opacity(0.3)
        }
    }

    private var buttonIconColor: Color {
        if isElevenLabsLive {
            switch elConversation.state {
            case .disconnected:   return .purple
            case .connecting:     return .orange
            case .listening:      return .koboldEmerald
            case .userSpeaking:   return .koboldGold
            case .agentSpeaking:  return .purple
            case .error:          return .red
            }
        }
        switch voiceState {
        case .idle:          return .koboldGold
        case .listening:     return .koboldEmerald
        case .recording:     return .white
        case .transcribing:  return .orange
        case .thinking:      return .orange
        case .speaking:      return .blue
        }
    }

    private var canPressButton: Bool {
        if isElevenLabsLive {
            if case .connecting = elConversation.state { return false }
            return recorder.hasMicrophonePermission && !elConversation.agentId.isEmpty && !elConversation.apiKey.isEmpty
        }
        switch voiceState {
        case .transcribing: return false
        default: return sttManager.isModelLoaded && recorder.hasMicrophonePermission
        }
    }

    // MARK: - Button Actions

    private func handleButtonPress() {
        if isElevenLabsLive {
            handleElevenLabsButtonPress()
        } else {
            handleNativeButtonPress()
        }
    }

    private func handleNativeButtonPress() {
        switch voiceState {
        case .idle:
            if vadEnabled {
                startContinuousVAD()
            } else {
                voiceState = .recording
                recorder.startRecording()
            }
        case .listening:
            recorder.stopContinuousListening()
            voiceState = .idle
        case .recording:
            if recorder.continuousListening {
                recorder.flushSpeechSegment()
            } else {
                recorder.stopRecording()
            }
        case .transcribing:
            break
        case .thinking:
            viewModel.cancelAgent()
            if vadEnabled && recorder.continuousListening {
                voiceState = .listening
            } else {
                voiceState = .idle
            }
        case .speaking:
            ttsManager.stop()
            if vadEnabled && recorder.continuousListening {
                voiceState = .listening
            } else {
                voiceState = .idle
            }
        }
    }

    private func handleElevenLabsButtonPress() {
        switch elConversation.state {
        case .disconnected, .error:
            Task { await elConversation.connect() }
        case .connecting:
            break
        case .listening, .userSpeaking, .agentSpeaking:
            elConversation.disconnect()
        }
    }

    private func startContinuousVAD() {
        voiceState = .listening
        recorder.onSpeechCaptured = handleSpeechCaptured
        recorder.startContinuousListening()
    }

    // MARK: - Quick Settings

    private var quickSettings: some View {
        HStack(spacing: 16) {
            if !isElevenLabsLive {
                Toggle(isOn: $vadEnabled) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.badge.mic").font(.caption)
                        Text("VAD").font(.caption)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)

                Toggle(isOn: $autoRespond) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill").font(.caption)
                        Text("Auto-TTS").font(.caption)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }

            if isElevenLabsLive && elConversation.isActive {
                HStack(spacing: 3) {
                    Circle().fill(Color.purple).frame(width: 6, height: 6)
                    Text("Live").font(.system(size: 10, weight: .medium)).foregroundColor(.purple)
                }
            }

            if !isElevenLabsLive && elevenLabsEnabled {
                HStack(spacing: 3) {
                    Circle().fill(Color.koboldEmerald).frame(width: 6, height: 6)
                    Text("ElevenLabs TTS").font(.system(size: 10)).foregroundColor(.koboldEmerald)
                }
            }

            Spacer()

            // Session-Credits (wenn ElevenLabs aktiv)
            if sessionCharacters > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "character.cursor.ibeam").font(.system(size: 9))
                    Text("\(sessionCharacters) Zeichen")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Transcript Panel (Oben — volle Breite wie Chat)

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.bubble.fill").foregroundColor(.koboldGold)
                Text(l10n.language.conversation).font(.headline)
                Spacer()
                if sessionCharacters > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard").font(.system(size: 10))
                        Text("Session: \(sessionCharacters) Zeichen")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                if !transcript.isEmpty {
                    Button(action: { transcript.removeAll(); sessionCharacters = 0 }) {
                        Image(systemName: "trash").font(.caption).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            GlassDivider()

            if transcript.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text(l10n.language.pressRecordHint)
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.5))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(transcript) { entry in
                                transcriptBubble(entry).id(entry.id)
                            }
                        }.padding(12)
                    }
                    .onChange(of: transcript.count) { _, _ in
                        if let lastId = transcript.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func transcriptBubble(_ entry: VoiceTranscriptEntry) -> some View {
        let isUser = entry.role == "user"
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"

        return HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // Header: Name + Zeit + Credits
                HStack(spacing: 4) {
                    Image(systemName: isUser ? "person.fill" : "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(isUser ? .koboldGold : .koboldEmerald)
                    Text(isUser ? "Du" : "Kobold")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isUser ? .koboldGold : .koboldEmerald)
                    Spacer()
                    // Credit-Anzeige pro Nachricht
                    if entry.characters > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "character.cursor.ibeam")
                                .font(.system(size: 8))
                            Text("\(entry.characters)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(.secondary.opacity(0.5))
                    }
                    Text(fmt.string(from: entry.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                // Text
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color.koboldGold.opacity(0.08) : Color.koboldEmerald.opacity(0.06))
            )
            if !isUser { Spacer(minLength: 60) }
        }
    }

    // MARK: - Voice Pipeline

    private func handleSpeechCaptured(audioURL: URL) {
        voiceState = .transcribing

        Task.detached(priority: .userInitiated) {
            let transcribedText = await STTManager.shared.transcribe(audioURL: audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            await MainActor.run {
                guard let text = transcribedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if self.vadEnabled && self.recorder.continuousListening {
                        self.voiceState = .listening
                    } else {
                        self.voiceState = .idle
                    }
                    return
                }

                self.transcript.append(VoiceTranscriptEntry(role: "user", text: text, timestamp: Date()))
                self.voiceState = .thinking
                self.viewModel.sendVoiceMessage(text)
            }
        }
    }

    private func handleNewMessage() {
        guard let lastMsg = viewModel.messages.last else { return }
        guard case .assistant(let text) = lastMsg.kind else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard voiceState == .thinking else { return }

        // Credit-Tracking: Zeichen der Agent-Antwort (TTS-Kosten)
        let charCount = (elevenLabsEnabled || isElevenLabsLive) ? text.count : 0
        sessionCharacters += charCount

        transcript.append(VoiceTranscriptEntry(role: "assistant", text: text, timestamp: Date(), characters: charCount))

        if autoRespond {
            voiceState = .speaking
            TTSManager.shared.speak(text)
        } else {
            if vadEnabled && recorder.continuousListening {
                voiceState = .listening
            } else {
                voiceState = .idle
            }
        }
    }

    private func updateWaveform(level: Float) {
        waveformValues.removeFirst()
        waveformValues.append(level)
    }

    // MARK: - ElevenLabs Callbacks

    private func setupElevenLabsCallbacks() {
        elConversation.onUserTranscript = { [self] text in
            guard isElevenLabsLive else { return }
            transcript.append(VoiceTranscriptEntry(role: "user", text: text, timestamp: Date()))
        }
        elConversation.onAgentResponse = { [self] text in
            guard isElevenLabsLive else { return }
            let chars = text.count
            sessionCharacters += chars
            transcript.append(VoiceTranscriptEntry(role: "assistant", text: text, timestamp: Date(), characters: chars))
        }
        elConversation.onConversationEnd = { [self] in
            guard isElevenLabsLive else { return }
            voiceState = .idle
        }
    }

    private var statusText: String {
        if isElevenLabsLive { return elConversation.statusText }
        switch voiceState {
        case .idle:          return "Bereit"
        case .listening:     return "Hört zu…"
        case .recording:     return "Aufnahme…"
        case .transcribing:  return "Verarbeite…"
        case .thinking:      return "Denkt…"
        case .speaking:      return "Spricht…"
        }
    }

    // MARK: - Processing Indicator (große zentrierte Sprechblase)

    /// Zeigt Indicator bei: transcribing, thinking, speaking (Native) oder connecting (ElevenLabs)
    private var isProcessing: Bool {
        if isElevenLabsLive {
            if case .connecting = elConversation.state { return true }
            return false
        }
        switch voiceState {
        case .transcribing, .thinking, .speaking: return true
        default: return false
        }
    }

    private var processingLabel: String {
        if isElevenLabsLive { return "Verbinde…" }
        switch voiceState {
        case .transcribing: return "Transkribiere…"
        case .thinking:     return "Kobold denkt…"
        case .speaking:     return "Kobold spricht…"
        default:            return "Verarbeite…"
        }
    }

    private var processingColor: Color {
        if isElevenLabsLive { return .purple }
        switch voiceState {
        case .transcribing: return .orange
        case .thinking:     return .koboldGold
        case .speaking:     return .blue
        default:            return .orange
        }
    }

    private var processingIndicator: some View {
        HStack(spacing: 12) {
            // Animierte Punkte (Sprechblasen-Style)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(processingColor)
                        .frame(width: 10, height: 10)
                        .scaleEffect(dotAnimation ? 1.0 : 0.4)
                        .opacity(dotAnimation ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                            value: dotAnimation
                        )
                }
            }

            Text(processingLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(processingColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(processingColor.opacity(0.08))
                .overlay(Capsule().stroke(processingColor.opacity(0.15), lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear { dotAnimation = true }
        .onDisappear { dotAnimation = false }
    }

    private var statusColor: Color {
        if isElevenLabsLive {
            switch elConversation.state {
            case .disconnected:   return .secondary
            case .connecting:     return .orange
            case .listening:      return .koboldEmerald
            case .userSpeaking:   return .koboldGold
            case .agentSpeaking:  return .purple
            case .error:          return .red
            }
        }
        switch voiceState {
        case .idle:          return .koboldEmerald
        case .listening:     return .koboldEmerald
        case .recording:     return .red
        case .transcribing:  return .orange
        case .thinking:      return .orange
        case .speaking:      return .blue
        }
    }
}
