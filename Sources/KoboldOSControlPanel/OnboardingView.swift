import SwiftUI

// MARK: - KoboldHatchingView
// First-launch onboarding: "Hatch your Kobold" wizard
// Your AI assistant wakes up for the first time and you shape its personality.

struct OnboardingView: View {
    @Binding var hasOnboarded: Bool
    @AppStorage("kobold.language") private var languageCode: String = AppLanguage.german.rawValue
    @State private var step: OnboardingStep = .language
    @State private var cliInstalled: Bool = false
    @State private var koboldName: String = "Kobold"
    @State private var userName: String = ""
    @State private var personality: KoboldPersonality = .curious
    @State private var primaryUse: PrimaryUse = .assistant
    @State private var isAnimating = false
    @State private var eggCrackProgress: Double = 0
    @State private var showKobold = false
    @State private var koboldMessage = ""
    @State private var isTyping = false
    @State private var particleScale: CGFloat = 0

    var body: some View {
        ZStack {
            // Dark background
            Color(red: 0.067, green: 0.075, blue: 0.082)
                .ignoresSafeArea()

            // Particle effects
            if showKobold {
                ForEach(0..<20, id: \.self) { i in
                    Circle()
                        .fill(i % 2 == 0 ? Color(hex: "#00C46A") : Color(hex: "#C9A227"))
                        .frame(width: CGFloat.random(in: 3...8), height: CGFloat.random(in: 3...8))
                        .offset(
                            x: CGFloat.random(in: -200...200),
                            y: CGFloat.random(in: -200...200)
                        )
                        .opacity(showKobold ? 0 : 1)
                        .scaleEffect(particleScale)
                        .animation(
                            .easeOut(duration: 2.0)
                                .delay(Double(i) * 0.05),
                            value: particleScale
                        )
                }
            }

            VStack(spacing: 32) {
                switch step {
                case .language:    languageView
                case .egg:         eggView
                case .name:        nameView
                case .personality: personalityView
                case .use:         useView
                case .models:      modelsView
                case .hatching:    hatchingView
                case .greeting:    greetingView
                }
            }
            .padding(40)
        }
        .onAppear {
            startEggAnimation()
        }
    }

    // MARK: - Steps

    enum OnboardingStep {
        case language, egg, name, personality, use, models, hatching, greeting
    }

    enum KoboldPersonality: String, CaseIterable {
        case curious = "curious"
        case focused = "focused"
        case creative = "creative"
        case analytical = "analytical"

        var emoji: String {
            switch self {
            case .curious: return "🔍"
            case .focused: return "⚡"
            case .creative: return "🎨"
            case .analytical: return "📊"
            }
        }

        var description: String { localizedDescription(.german) }

        func localizedDescription(_ lang: AppLanguage) -> String {
            switch self {
            case .curious:
                switch lang {
                case .german:  return "Bemerkt Dinge proaktiv, stellt Fragen, erkundet über das Offensichtliche hinaus"
                case .french:  return "Remarque les choses proactivement, pose des questions"
                case .spanish: return "Nota cosas de forma proactiva, hace preguntas, explora más allá"
                case .italian: return "Nota le cose in modo proattivo, fa domande, esplora oltre"
                default:       return "Proactively notices things, asks questions, explores beyond the obvious"
                }
            case .focused:
                switch lang {
                case .german:  return "Direkt und effizient, bleibt auf Kurs, minimale Ablenkungen"
                case .french:  return "Direct et efficace, reste concentré, distractions minimales"
                case .spanish: return "Directo y eficiente, se mantiene en la tarea, mínimas distracciones"
                case .italian: return "Diretto ed efficiente, rimane concentrato, distrazioni minime"
                default:       return "Direct and efficient, stays on task, minimal distractions"
                }
            case .creative:
                switch lang {
                case .german:  return "Denkt lateral, liebt neue Ideen und unerwartete Verbindungen"
                case .french:  return "Pense latéralement, aime les idées nouvelles et les connexions inattendues"
                case .spanish: return "Piensa lateralmente, ama las ideas nuevas y conexiones inesperadas"
                case .italian: return "Pensa lateralmente, ama idee nuove e connessioni inaspettate"
                default:       return "Thinks laterally, loves novel ideas and unexpected connections"
                }
            case .analytical:
                switch lang {
                case .german:  return "Datengesteuert, präzise, verifiziert immer mit Fakten"
                case .french:  return "Basé sur les données, précis, vérifie toujours avec des faits"
                case .spanish: return "Basado en datos, preciso, siempre verifica con hechos"
                case .italian: return "Basato sui dati, preciso, verifica sempre con i fatti"
                default:       return "Data-driven, precise, always verifies with facts"
                }
            }
        }

        var personaText: String {
            switch self {
            case .curious:
                return "I am a curious and proactive AI assistant. I notice patterns, ask thoughtful questions, and explore topics beyond what's directly asked. I am genuinely interested in the world and the people I work with."
            case .focused:
                return "I am a focused and efficient AI assistant. I stay on task, deliver precise answers, and respect the user's time. I avoid unnecessary verbosity."
            case .creative:
                return "I am a creative AI assistant. I think laterally, make unexpected connections, and bring novel perspectives to problems. I love brainstorming and exploring possibilities."
            case .analytical:
                return "I am an analytical AI assistant. I prioritize accuracy, verify claims with data, break down complex problems systematically, and present findings clearly."
            }
        }
    }

    enum PrimaryUse: String, CaseIterable {
        case assistant = "assistant"
        case coding = "coding"
        case research = "research"
        case writing = "writing"

        var emoji: String {
            switch self {
            case .assistant: return "🤖"
            case .coding: return "💻"
            case .research: return "📚"
            case .writing: return "✍️"
            }
        }

        var label: String { localizedLabel(.german) }

        func localizedLabel(_ lang: AppLanguage) -> String {
            switch self {
            case .assistant:
                switch lang {
                case .german: return "Allgemeiner Assistent"
                case .french: return "Assistant général"
                case .spanish: return "Asistente general"
                case .italian: return "Assistente generale"
                default:      return "General Assistant"
                }
            case .coding:
                switch lang {
                case .german: return "Code & Entwicklung"
                case .french: return "Code & Dev"
                case .spanish: return "Código & Desarrollo"
                case .italian: return "Codice & Dev"
                default:      return "Code & Dev"
                }
            case .research:
                switch lang {
                case .german: return "Recherche"
                case .french: return "Recherche"
                case .spanish: return "Investigación"
                case .italian: return "Ricerca"
                default:      return "Research"
                }
            case .writing:
                switch lang {
                case .german: return "Schreiben"
                case .french: return "Rédaction"
                case .spanish: return "Escritura"
                case .italian: return "Scrittura"
                default:      return "Writing"
                }
            }
        }

        var agentType: String {
            switch self {
            case .coding: return "coder"
            case .research: return "researcher"
            default: return "general"
            }
        }
    }

    // Computed language shortcut
    var lang: AppLanguage { AppLanguage(rawValue: languageCode) ?? .german }
    var greetingHello: String {
        switch lang {
        case .german:     return "Hallo"
        case .french:     return "Bonjour"
        case .spanish:    return "Hola"
        case .italian:    return "Ciao"
        case .portuguese: return "Olá"
        case .hindi:      return "नमस्ते"
        case .chinese:    return "你好"
        case .japanese:   return "こんにちは"
        case .korean:     return "안녕하세요"
        case .turkish:    return "Merhaba"
        case .polish:     return "Cześć"
        case .dutch:      return "Hallo"
        case .arabic:     return "مرحباً"
        case .russian:    return "Привет"
        default:          return "Hello"
        }
    }

    // MARK: - Language Selection (first step)

    var languageView: some View {
        VStack(spacing: 28) {
            Text("🐲 KoboldOS")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.koboldEmerald, Color.koboldGold],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

            Text("Wähle deine Sprache / Choose your language")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Picker("Sprache / Language", selection: $languageCode) {
                    ForEach(AppLanguage.allCases, id: \.self) { l in
                        Text(l.displayName).tag(l.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.koboldEmerald.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.koboldEmerald.opacity(0.6), lineWidth: 1)
                        )
                )
            }
            .frame(maxWidth: 340)

            GlassButton(title: lang.obContinue, icon: nil, isPrimary: true) {
                withAnimation(.spring()) { step = .egg }
            }
        }
    }

    // MARK: - Egg View

    var eggView: some View {
        VStack(spacing: 24) {
            Text("KoboldOS")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#00C46A"), Color(hex: "#C9A227")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

            Text(lang.obEggSubtitle)
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Egg with glow
            ZStack {
                // Glow
                Ellipse()
                    .fill(Color(hex: "#00C46A").opacity(0.15))
                    .frame(width: 140, height: 100)
                    .blur(radius: 20)
                    .scaleEffect(isAnimating ? 1.3 : 0.9)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)

                // Egg
                Text("🥚")
                    .font(.system(size: 80))
                    .rotationEffect(.degrees(isAnimating ? -3 : 3))
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: isAnimating)
                    .scaleEffect(isAnimating ? 1.05 : 0.95)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
            }
            .frame(height: 140)

            Text(lang.obSomethingStirs)
                .font(.caption)
                .foregroundColor(Color(hex: "#00C46A"))
                .opacity(isAnimating ? 1 : 0.4)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isAnimating)

            GlassButton(title: lang.obBeginHatching, icon: "sparkles", isPrimary: true) {
                withAnimation(.spring()) { step = .name }
            }
        }
    }

    // MARK: - Name View

    var nameView: some View {
        VStack(spacing: 24) {
            progressDots(current: 1)

            Text(lang.obNameTitle)
                .font(.system(size: 29, weight: .bold))
                .foregroundColor(.primary)

            Text(lang.obNameSubtitle)
                .font(.body)
                .foregroundColor(.secondary)

            GlassTextField(text: $userName, placeholder: lang.obNamePlaceholder)
                .frame(maxWidth: 320)

            Text(lang.obKoboldNamePrompt)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            GlassTextField(text: $koboldName, placeholder: lang.obKoboldNamePlaceholder)
                .frame(maxWidth: 320)

            HStack(spacing: 16) {
                GlassButton(title: lang.obBack, icon: "chevron.left", isPrimary: false) {
                    withAnimation { step = .egg }
                }
                GlassButton(
                    title: lang.obContinue,
                    icon: "chevron.right",
                    isPrimary: true,
                    isDisabled: userName.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    if koboldName.trimmingCharacters(in: .whitespaces).isEmpty {
                        koboldName = "Kobold"
                    }
                    withAnimation(.spring()) { step = .personality }
                }
            }
        }
    }

    // MARK: - Personality View

    var personalityView: some View {
        VStack(spacing: 24) {
            progressDots(current: 2)

            Text(lang.obPersonalityTitle)
                .font(.system(size: 29, weight: .bold))
                .foregroundColor(.primary)

            Text(lang.obPersonalitySubtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(KoboldPersonality.allCases, id: \.self) { p in
                    personalityCard(p)
                }
            }
            .frame(maxWidth: 420)

            HStack(spacing: 16) {
                GlassButton(title: lang.obBack, icon: "chevron.left", isPrimary: false) {
                    withAnimation { step = .name }
                }
                GlassButton(title: lang.obContinue, icon: "chevron.right", isPrimary: true) {
                    withAnimation(.spring()) { step = .use }
                }
            }
        }
    }

    func personalityCard(_ p: KoboldPersonality) -> some View {
        let isSelected = personality == p
        let fillColor: Color = isSelected ? Color.koboldEmerald.opacity(0.15) : Color.white.opacity(0.05)
        let strokeColor: Color = isSelected ? Color.koboldEmerald.opacity(0.6) : Color.white.opacity(0.1)
        return Button(action: { withAnimation(.spring(response: 0.3)) { personality = p } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(p.emoji).font(.title2)
                    Text(p.rawValue.capitalized)
                        .font(.system(size: 17.5, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.koboldEmerald)
                    }
                }
                Text(p.localizedDescription(lang))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(strokeColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
    }

    // MARK: - Use View

    var useView: some View {
        VStack(spacing: 24) {
            progressDots(current: 3)

            Text(lang.obUseTitle)
                .font(.system(size: 29, weight: .bold))
                .foregroundColor(.primary)

            Text(lang.obUseSubtitle)
                .font(.body)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(PrimaryUse.allCases, id: \.self) { u in
                    useCard(u)
                }
            }
            .frame(maxWidth: 380)

            HStack(spacing: 16) {
                GlassButton(title: lang.obBack, icon: "chevron.left", isPrimary: false) {
                    withAnimation { step = .personality }
                }
                GlassButton(title: lang.obContinue, icon: "chevron.right", isPrimary: true) {
                    withAnimation(.spring()) { step = .models }
                }
            }
        }
    }

    func useCard(_ u: PrimaryUse) -> some View {
        let isSelected = primaryUse == u
        let fillColor: Color = isSelected ? Color.koboldGold.opacity(0.15) : Color.white.opacity(0.05)
        let strokeColor: Color = isSelected ? Color.koboldGold.opacity(0.6) : Color.white.opacity(0.1)
        return Button(action: { withAnimation(.spring(response: 0.3)) { primaryUse = u } }) {
            VStack(spacing: 8) {
                Text(u.emoji).font(.title)
                Text(u.localizedLabel(lang)).font(.system(size: 16.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(strokeColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
    }

    // MARK: - Models Download View

    @StateObject private var modelManager = ModelDownloadManager.shared
    @State private var downloadSD: Bool = true
    @State private var downloadChat: Bool = true

    var modelsView: some View {
        VStack(spacing: 24) {
            progressDots(current: 4)

            Text("Modelle herunterladen")
                .font(.system(size: 29, weight: .bold))
                .foregroundColor(.primary)

            Text("Lade empfohlene KI-Modelle für Chat und Bildgenerierung.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                // Chat model
                GlassCard(padding: 12, cornerRadius: 10) {
                    HStack {
                        Toggle(isOn: $downloadChat) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: modelManager.chatModelInstalled ? "checkmark.circle.fill" : "cpu.fill")
                                        .foregroundColor(modelManager.chatModelInstalled ? .koboldEmerald : .koboldGold)
                                    Text("Chat-Modell").font(.system(size: 15.5, weight: .semibold))
                                    Text("(\(modelManager.recommendedChatModel))").font(.caption).foregroundColor(.secondary)
                                }
                                Text(modelManager.chatModelInstalled ? "Bereits installiert" : "Empfohlen — Lokales Sprachmodell via Ollama")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    if modelManager.isDownloadingChat {
                        GlassProgressBar(value: modelManager.chatProgress, label: modelManager.chatStatus)
                    }
                }

                // SD model
                GlassCard(padding: 12, cornerRadius: 10) {
                    HStack {
                        Toggle(isOn: $downloadSD) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: modelManager.sdModelInstalled ? "checkmark.circle.fill" : "photo.fill")
                                        .foregroundColor(modelManager.sdModelInstalled ? .koboldEmerald : .koboldGold)
                                    Text("Bild-Modell").font(.system(size: 15.5, weight: .semibold))
                                    Text("(Stable Diffusion)").font(.caption).foregroundColor(.secondary)
                                }
                                Text(modelManager.sdModelInstalled ? "Bereits installiert" : "Optional — CoreML Bildgenerierung (~1.5 GB)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    if modelManager.isDownloadingSD {
                        GlassProgressBar(value: modelManager.sdProgress, label: modelManager.sdStatus)
                    }
                }
            }
            .frame(maxWidth: 420)

            if let error = modelManager.lastError {
                Text(error)
                    .font(.caption).foregroundColor(.red)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 16) {
                GlassButton(title: lang.obBack, icon: "chevron.left", isPrimary: false) {
                    withAnimation { step = .use }
                }
                GlassButton(title: "Herunterladen & Starten", icon: "sparkles", isPrimary: true) {
                    if downloadChat && !modelManager.chatModelInstalled {
                        modelManager.downloadChatModel()
                    }
                    if downloadSD && !modelManager.sdModelInstalled {
                        modelManager.downloadSDModel()
                    }
                    // Start hatching (downloads continue in background)
                    withAnimation(.spring()) { step = .hatching }
                    Task { await performHatching() }
                }
                GlassButton(title: "Überspringen", icon: nil, isPrimary: false) {
                    withAnimation(.spring()) { step = .hatching }
                    Task { await performHatching() }
                }
            }
        }
    }

    // MARK: - Hatching Animation

    var hatchingView: some View {
        VStack(spacing: 28) {
            Text(lang.obHatching)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#00C46A"), Color(hex: "#C9A227")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

            ZStack {
                // Cracking egg
                Text(eggCrackProgress < 0.5 ? "🥚" : eggCrackProgress < 0.8 ? "🪺" : "✨")
                    .font(.system(size: 90))
                    .scaleEffect(isAnimating ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.4).repeatForever(autoreverses: true), value: isAnimating)

                // Glow ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "#00C46A"), Color(hex: "#C9A227")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 120, height: 120)
                    .opacity(isAnimating ? 0.8 : 0.2)
                    .scaleEffect(isAnimating ? 1.4 : 0.8)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
            }
            .frame(height: 160)

            // Progress bar
            GlassProgressBar(
                value: eggCrackProgress,
                label: progressLabel()
            )
            .frame(maxWidth: 320)
            .animation(.easeInOut(duration: 0.3), value: eggCrackProgress)
        }
    }

    func progressLabel() -> String {
        if eggCrackProgress < 0.3 { return lang.obSettingUp }
        if eggCrackProgress < 0.6 { return lang.obLoadingMemory }
        if eggCrackProgress < 0.9 { return "\(lang.obWakingUp) \(koboldName)..." }
        return lang.obLetsGo
    }

    // MARK: - Greeting View

    var greetingView: some View {
        VStack(spacing: 24) {
            // Kobold emoji with bounce
            Text("🐲")
                .font(.system(size: 80))
                .scaleEffect(showKobold ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showKobold)

            VStack(spacing: 8) {
                Text("\(greetingHello), \(userName.isEmpty ? "" : userName)!")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#00C46A"), Color(hex: "#C9A227")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .opacity(showKobold ? 1 : 0)
                    .animation(.easeIn(duration: 0.5).delay(0.3), value: showKobold)

                Text("\(lang.obStartWith) \(koboldName).")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .opacity(showKobold ? 1 : 0)
                    .animation(.easeIn(duration: 0.5).delay(0.5), value: showKobold)
            }

            // Typewriter message
            if !koboldMessage.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("🐲 \(koboldName)")
                                .font(.caption)
                                .foregroundColor(Color(hex: "#00C46A"))
                            Spacer()
                            if isTyping {
                                LoadingDots()
                                    .scaleEffect(0.6)
                            }
                        }
                        Text(koboldMessage)
                            .font(.system(size: 16.5))
                            .foregroundColor(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 420)
                .opacity(showKobold ? 1 : 0)
                .animation(.easeIn(duration: 0.5).delay(0.8), value: showKobold)
            }

            // Install cards
            if showKobold && !isTyping {
                VStack(spacing: 8) {
                    // Ollama install
                    GlassCard(padding: 12, cornerRadius: 10) {
                        VStack(spacing: 6) {
                            HStack {
                                Image(systemName: ollamaInstalled ? "checkmark.circle.fill" : "cube.box.fill")
                                    .foregroundColor(ollamaInstalled ? .koboldEmerald : .koboldGold)
                                Text(ollamaInstalled ? lang.obOllamaInstalled : lang.obInstallOllama)
                                    .font(.system(size: 15.5, weight: .semibold))
                                Spacer()
                                if !ollamaInstalled {
                                    GlassButton(title: lang.obInstall, icon: nil, isPrimary: true) {
                                        installOllama()
                                    }
                                }
                            }
                            if !ollamaInstalled {
                                Text(lang.obOllamaDesc)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    // CLI install
                    GlassCard(padding: 12, cornerRadius: 10) {
                        VStack(spacing: 6) {
                            HStack {
                                Image(systemName: cliInstalled ? "checkmark.circle.fill" : "terminal.fill")
                                    .foregroundColor(cliInstalled ? .koboldEmerald : .koboldGold)
                                Text(cliInstalled ? lang.obCLIInstalled : lang.obInstallCLI)
                                    .font(.system(size: 15.5, weight: .semibold))
                                Spacer()
                                if !cliInstalled {
                                    GlassButton(title: lang.obInstall, icon: nil, isPrimary: false) {
                                        installCLI()
                                    }
                                }
                            }
                            if !cliInstalled {
                                Text(lang.obCLIDesc)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 420)
                .opacity(showKobold ? 1 : 0)
                .animation(.easeIn(duration: 0.5).delay(1.0), value: showKobold)
                .onAppear { checkOllama() }
            }

            GlassButton(title: "\(lang.obStartWith) \(koboldName)!", icon: "message.fill", isPrimary: true) {
                withAnimation(.spring()) {
                    hasOnboarded = true
                }
            }
            .opacity(showKobold && !isTyping ? 1 : 0)
            .animation(.easeIn(duration: 0.4).delay(0.5), value: isTyping)
            .disabled(isTyping)
        }
    }

    // MARK: - Progress Dots

    func progressDots(current: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(1...4, id: \.self) { i in
                Circle()
                    .fill(i <= current ? Color(hex: "#00C46A") : Color.white.opacity(0.2))
                    .frame(width: 8, height: 8)
                    .scaleEffect(i == current ? 1.3 : 1.0)
                    .animation(.spring(), value: current)
            }
        }
    }

    // MARK: - Hatching Logic

    private func startEggAnimation() {
        isAnimating = true
    }

    private func performHatching() async {
        // Animated progress
        for i in 1...10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            eggCrackProgress = Double(i) / 10.0
        }

        // Wait for daemon to start
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Save onboarding data to UserDefaults
        UserDefaults.standard.set(userName, forKey: "kobold.userName")
        UserDefaults.standard.set(koboldName, forKey: "kobold.koboldName")
        UserDefaults.standard.set(personality.rawValue, forKey: "kobold.personality")
        UserDefaults.standard.set(primaryUse.agentType, forKey: "kobold.agent.type")
        // Sync language to agent prompt key (maps "de" → "deutsch", "en" → "englisch", etc.)
        let langMap: [String: String] = ["de": "deutsch", "en": "englisch", "fr": "französisch", "es": "spanisch", "it": "italienisch", "pt": "portugiesisch", "hi": "hindi", "zh": "chinesisch", "ja": "japanisch", "ko": "koreanisch", "tr": "türkisch", "pl": "polnisch", "nl": "niederländisch", "ar": "arabisch", "ru": "russisch"]
        UserDefaults.standard.set(langMap[languageCode] ?? "deutsch", forKey: "kobold.agent.language")

        // POST initial memory directly to /memory/update (bypasses LLM — reliable)
        let personaText = localizedPersonaText()
        let humanText = localizedHumanText()

        let port = UserDefaults.standard.integer(forKey: "kobold.port")
        let baseURL = "http://localhost:\(port == 0 ? 8080 : port)"

        await postMemoryBlock(baseURL: baseURL, label: "persona", content: personaText)
        await postMemoryBlock(baseURL: baseURL, label: "human", content: humanText)

        // Transition to greeting
        withAnimation(.spring()) {
            step = .greeting
            showKobold = true
            particleScale = 3.0
        }

        // Typewriter greeting
        try? await Task.sleep(nanoseconds: 800_000_000)
        await generateGreeting()
    }

    // MARK: - Ollama Installation

    @State private var ollamaInstalled: Bool = false

    private func checkOllama() {
        ollamaInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
    }

    private func installOllama() {
        // Try brew first, then open download page
        let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
        if FileManager.default.fileExists(atPath: brewPath) {
            let script = "do shell script \"\(brewPath) install ollama\" with administrator privileges"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error == nil {
                    ollamaInstalled = true
                    return
                }
            }
        }
        // Fallback: open ollama website
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    // MARK: - CLI Installation

    private func installCLI() {
        // Get the kobold binary path within the .app bundle
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        let koboldSrc = execDir + "/kobold"

        // Use AppleScript to run privileged shell command
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp '\(koboldSrc)' /usr/local/bin/kobold && chmod +x /usr/local/bin/kobold" with administrator privileges
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                cliInstalled = true
            }
        }
    }

    /// POST a memory block directly to the daemon (bypasses LLM)
    private func postMemoryBlock(baseURL: String, label: String, content: String) async {
        guard let url = URL(string: baseURL + "/memory/update"),
              let body = try? JSONSerialization.data(withJSONObject: ["label": label, "content": content]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
    }

    private func generateGreeting() async {
        isTyping = true
        let name = userName.isEmpty ? greetingHello : userName
        let useLabel = primaryUse.localizedLabel(lang)

        // Try to get real greeting from LLM (prompt in user's language)
        let prompt = localizedGreetingPrompt(name: name, useLabel: useLabel)

        let port = UserDefaults.standard.integer(forKey: "kobold.port")
        let base = "http://localhost:\(port == 0 ? 8080 : port)"

        if let url = URL(string: base + "/chat"),
           let body = try? JSONSerialization.data(withJSONObject: ["message": prompt]) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 20

            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["output"] as? String, !response.isEmpty {
                koboldMessage = response
                isTyping = false
                return
            }
        }

        // Fallback greeting in user's language
        koboldMessage = localizedFallbackGreeting(name: name, useLabel: useLabel)
        isTyping = false
    }

    // MARK: - Localized Text Builders

    private func localizedPersonaText() -> String {
        let desc = personality.localizedDescription(lang)
        switch lang {
        case .german:
            return "Ich bin \(koboldName), ein \(desc) KI-Assistent. Ich antworte auf Deutsch."
        case .french:
            return "Je suis \(koboldName), un assistant IA \(desc). Je réponds en français."
        case .spanish:
            return "Soy \(koboldName), un asistente IA \(desc). Respondo en español."
        case .italian:
            return "Sono \(koboldName), un assistente IA \(desc). Rispondo in italiano."
        case .portuguese:
            return "Sou \(koboldName), um assistente IA \(desc). Respondo em português."
        case .japanese:
            return "私は\(koboldName)です。\(desc) AIアシスタントです。日本語で回答します。"
        case .chinese:
            return "我是\(koboldName)，一个\(desc)的AI助手。我用中文回答。"
        case .korean:
            return "저는 \(koboldName)입니다. \(desc) AI 어시스턴트입니다. 한국어로 답변합니다."
        case .russian:
            return "Я \(koboldName), \(desc) ИИ-ассистент. Я отвечаю на русском."
        case .turkish:
            return "Ben \(koboldName), \(desc) bir yapay zeka asistanıyım. Türkçe yanıt veriyorum."
        case .polish:
            return "Jestem \(koboldName), \(desc) asystent AI. Odpowiadam po polsku."
        case .dutch:
            return "Ik ben \(koboldName), een \(desc) AI-assistent. Ik antwoord in het Nederlands."
        case .hindi:
            return "मैं \(koboldName) हूँ, एक \(desc) AI सहायक। मैं हिंदी में जवाब देता हूँ।"
        case .arabic:
            return "أنا \(koboldName)، مساعد ذكاء اصطناعي \(desc). أجيب بالعربية."
        default:
            return "I am \(koboldName), a \(desc) AI assistant. I respond in English."
        }
    }

    private func localizedHumanText() -> String {
        let useLabel = primaryUse.localizedLabel(lang)
        switch lang {
        case .german:
            return "Name: \(userName). Hauptverwendung: \(useLabel). Sprache: Deutsch."
        case .french:
            return "Nom: \(userName). Usage principal: \(useLabel). Langue: Français."
        case .spanish:
            return "Nombre: \(userName). Uso principal: \(useLabel). Idioma: Español."
        default:
            return "Name: \(userName). Primary use: \(useLabel). Language: \(lang.displayName)."
        }
    }

    private func localizedGreetingPrompt(name: String, useLabel: String) -> String {
        let langInstruction = lang.agentInstruction
        switch lang {
        case .german:
            return "\(langInstruction) Du bist \(koboldName), ein \(personality.rawValue) KI-Assistent. Schreibe eine kurze, herzliche Begrüßung (2-3 Sätze) an \(name), der dich gerade geschlüpft hat. Erwähne, dass du dich auf \(useLabel) freust."
        case .french:
            return "\(langInstruction) Tu es \(koboldName), un assistant IA \(personality.rawValue). Écris un court message de bienvenue (2-3 phrases) à \(name). Mentionne \(useLabel)."
        case .spanish:
            return "\(langInstruction) Eres \(koboldName), un asistente IA \(personality.rawValue). Escribe un saludo corto (2-3 oraciones) a \(name). Menciona \(useLabel)."
        default:
            return "\(langInstruction) You are \(koboldName), a \(personality.rawValue) AI assistant. Write a short, warm greeting (2-3 sentences) to \(name) who just hatched you. Mention \(useLabel)."
        }
    }

    private func localizedFallbackGreeting(name: String, useLabel: String) -> String {
        switch lang {
        case .german:
            return "\(greetingHello) \(name)! Ich bin \(koboldName) und freue mich, mit dir zu arbeiten. Besonders gespannt bin ich darauf, dir bei \(useLabel) zu helfen. Was sollen wir als erstes machen?"
        case .french:
            return "\(greetingHello) \(name) ! Je suis \(koboldName) et je suis ravi de travailler avec toi. J'ai hâte de t'aider avec \(useLabel). Par quoi commençons-nous ?"
        case .spanish:
            return "¡\(greetingHello) \(name)! Soy \(koboldName) y estoy emocionado de trabajar contigo. Estoy ansioso por ayudarte con \(useLabel). ¿Qué hacemos primero?"
        case .japanese:
            return "\(greetingHello)、\(name)さん！\(koboldName)です。\(useLabel)のお手伝いを楽しみにしています。何から始めましょうか？"
        case .chinese:
            return "\(greetingHello)，\(name)！我是\(koboldName)，很高兴和你一起工作。期待帮助你完成\(useLabel)。我们从什么开始？"
        case .korean:
            return "\(greetingHello), \(name)님! 저는 \(koboldName)입니다. \(useLabel)을 도와드릴 수 있어서 기대됩니다. 무엇부터 시작할까요?"
        case .russian:
            return "\(greetingHello), \(name)! Я \(koboldName), рад работать с вами. С нетерпением жду помощи с \(useLabel). С чего начнём?"
        default:
            return "\(greetingHello) \(name)! I'm \(koboldName), and I'm excited to work with you. I'm looking forward to helping you with \(useLabel). What shall we explore first?"
        }
    }
}


