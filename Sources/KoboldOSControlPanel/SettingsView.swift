import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import EventKit
import Contacts
@preconcurrency import UserNotifications
import CoreImage
import KoboldCore

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @StateObject private var launchAgent = LaunchAgentManager.shared
    @StateObject private var agentsStore = AgentsStore.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var toolEnv = ToolEnvironment.shared

    @State private var selectedSection: String = "Allgemein"
    @State private var ollamaModels: [String] = []
    @State private var isLoadingModels = false

    // General
    @AppStorage("kobold.showAdvancedStats") private var showAdvancedStats: Bool = false
    @AppStorage("kobold.port") private var daemonPort: Int = 8080

    // Permissions
    @AppStorage("kobold.autonomyLevel") private var autonomyLevel: Int = 2
    @AppStorage("kobold.perm.shell")        private var permShell: Bool = true
    @AppStorage("kobold.perm.fileWrite")    private var permFileWrite: Bool = true
    @AppStorage("kobold.perm.network")      private var permNetwork: Bool = true
    @AppStorage("kobold.perm.confirmAdmin") private var permConfirmAdmin: Bool = true

    // Permissions — extended
    @AppStorage("kobold.perm.selfCheck")     private var permSelfCheck: Bool = false
    @AppStorage("kobold.perm.createFiles")   private var permCreateFiles: Bool = true
    @AppStorage("kobold.perm.deleteFiles")   private var permDeleteFiles: Bool = false
    @AppStorage("kobold.perm.installPkgs")   private var permInstallPkgs: Bool = false
    @AppStorage("kobold.perm.modifyMemory")  private var permModifyMemory: Bool = true
    @AppStorage("kobold.perm.notifications") private var permNotifications: Bool = true
    @AppStorage("kobold.perm.calendar")      private var permCalendar: Bool = true
    @AppStorage("kobold.perm.contacts")      private var permContacts: Bool = false
    @AppStorage("kobold.perm.mail")          private var permMail: Bool = false
    // kobold.shell.customBlacklist used via direct UserDefaults binding in permissions section

    // Sounds
    @AppStorage("kobold.sounds.enabled") private var soundsEnabled: Bool = true
    @AppStorage("kobold.sounds.volume") private var soundsVolume: Double = 0.5

    // Updates
    @AppStorage("kobold.autoCheckUpdates") private var autoCheckUpdates: Bool = true

    // Shell tier toggles
    @AppStorage("kobold.shell.safeTier") private var shellSafeTier: Bool = true
    @AppStorage("kobold.shell.normalTier") private var shellNormalTier: Bool = false
    @AppStorage("kobold.shell.powerTier") private var shellPowerTier: Bool = false

    // A2A settings
    @AppStorage("kobold.a2a.enabled") private var a2aEnabled: Bool = false
    @AppStorage("kobold.a2a.port") private var a2aPort: Int = 8081
    @AppStorage("kobold.a2a.allowMemoryRead") private var a2aAllowMemoryRead: Bool = true
    @AppStorage("kobold.a2a.allowMemoryWrite") private var a2aAllowMemoryWrite: Bool = false
    @AppStorage("kobold.a2a.allowTools") private var a2aAllowTools: Bool = true
    @AppStorage("kobold.a2a.allowFiles") private var a2aAllowFiles: Bool = false
    @AppStorage("kobold.a2a.allowShell") private var a2aAllowShell: Bool = false
    @AppStorage("kobold.a2a.trustedAgents") private var a2aTrustedAgents: String = ""
    @AppStorage("kobold.a2a.token") private var a2aToken: String = ""
    @State private var a2aRemoteToken: String = ""

    // Memory settings (AgentZero-style)
    @AppStorage("kobold.memory.recallEnabled") private var memoryRecallEnabled: Bool = true
    @AppStorage("kobold.memory.recallInterval") private var memoryRecallInterval: Int = 3
    @AppStorage("kobold.memory.maxSearch") private var memoryMaxSearch: Int = 12
    @AppStorage("kobold.memory.maxResults") private var memoryMaxResults: Int = 5
    @AppStorage("kobold.memory.similarityThreshold") private var memorySimilarity: Double = 0.7
    @AppStorage("kobold.memory.memorizeEnabled") private var memoryMemorizeEnabled: Bool = true
    @AppStorage("kobold.memory.consolidation") private var memoryConsolidation: Bool = true
    @AppStorage("kobold.memory.autoFragments") private var memoryAutoFragments: Bool = true
    @AppStorage("kobold.memory.autoSolutions") private var memoryAutoSolutions: Bool = true

    // Profile
    @AppStorage("kobold.profile.name") private var profileName: String = ""
    @AppStorage("kobold.profile.email") private var profileEmail: String = ""
    @AppStorage("kobold.profile.avatar") private var profileAvatar: String = "person.crop.circle.fill"

    // Menu bar
    @AppStorage("kobold.menuBar.enabled") private var menuBarEnabled: Bool = false
    @AppStorage("kobold.menuBar.hideMainWindow") private var menuBarHideOnClose: Bool = true

    // Working directory
    @AppStorage("kobold.defaultWorkDir") private var defaultWorkDir: String = "~/Documents/KoboldOS"

    private let sections = ["Konto", "Allgemein", "Agent", "Modelle", "Gedächtnis", "Proaktiv", "Berechtigungen", "Datenschutz & Sicherheit", "A2A", "Verbindungen", "Fernsteuerung", "Telegram", "Skills", "Über"]

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections, id: \.self) { section in
                    Button(action: {
                        selectedSection = section
                        if section == "Modelle" { loadModels() }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: iconForSection(section))
                                .frame(width: 16)
                                .foregroundColor(selectedSection == section ? .koboldEmerald : .secondary)
                            Text(section)
                                .fontWeight(selectedSection == section ? .semibold : .regular)
                                .foregroundColor(selectedSection == section ? .koboldEmerald : .primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(selectedSection == section ? Color.koboldSurface : Color.clear)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 220) // Same width as main sidebar
            .background(Color.koboldPanel)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedSection {
                    case "Konto":                   profileSection()
                    case "Allgemein":                generalSection()
                    case "Agent":                    agentPersonalitySection(); memoryPolicySection()
                    case "Modelle":                  modelsSection()
                    case "Gedächtnis":               memorySettingsSection()
                    case "Proaktiv":                 proactiveSettingsSection()
                    case "Berechtigungen":           permissionsSection()
                    case "Datenschutz & Sicherheit": securitySection()
                    case "A2A":                      a2aSection()
                    case "Verbindungen":             connectionsSection()
                    case "Fernsteuerung":            remoteControlSection()
                    case "Telegram":                 telegramSection()
                    case "Skills":                   skillsSettingsSection()
                    default:                         aboutSection()
                    }
                    Spacer(minLength: 40)
                }
                .padding(24)
            }
        }
        .background(Color.koboldBackground)
        .onAppear { launchAgent.refreshStatus() }
    }

    private func iconForSection(_ s: String) -> String {
        switch s {
        case "Konto":                   return "person.crop.circle.fill"
        case "Allgemein":               return "gear"
        case "Agent":                   return "person.fill.viewfinder"
        case "Modelle":                 return "cpu.fill"
        case "Gedächtnis":              return "brain.head.profile"
        case "Proaktiv":                return "lightbulb.fill"
        case "Berechtigungen":          return "shield.lefthalf.filled"
        case "Datenschutz & Sicherheit": return "lock.shield.fill"
        case "A2A":                     return "arrow.left.arrow.right"
        case "Verbindungen":            return "link.circle.fill"
        case "Fernsteuerung":           return "globe"
        case "Telegram":                return "paperplane.fill"
        case "Skills":                  return "sparkles"
        default:                        return "info.circle.fill"
        }
    }

    // MARK: - Save Confirmation Button

    @State private var saveConfirmed: String? = nil

    @ViewBuilder
    func settingsSaveButton(section: String) -> some View {
        HStack {
            Spacer()
            Button(action: {
                // @AppStorage auto-saves, so just show confirmation
                withAnimation(.easeInOut(duration: 0.2)) { saveConfirmed = section }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if saveConfirmed == section { saveConfirmed = nil }
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: saveConfirmed == section ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.system(size: 12))
                    Text(saveConfirmed == section ? "Gespeichert" : "Speichern")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(saveConfirmed == section ? .koboldEmerald : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(saveConfirmed == section ? Color.koboldEmerald.opacity(0.15) : Color.koboldSurface)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Konto & Profil

    @ViewBuilder
    private func profileSection() -> some View {
        sectionTitle("Konto & Profil")

        GroupBox {
            HStack(spacing: 20) {
                // Avatar
                Image(systemName: profileAvatar)
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(colors: [.koboldGold, .koboldEmerald], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 72, height: 72)
                    .background(Color.koboldSurface)
                    .cornerRadius(20)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.caption).foregroundColor(.secondary)
                        TextField("Dein Name", text: $profileName)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("E-Mail").font(.caption).foregroundColor(.secondary)
                        TextField("deine@email.de", text: $profileEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Spacer()
            }
            .padding()
        }

        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Avatar", systemImage: "person.crop.circle").font(.subheadline.bold())
                    let avatars = ["person.crop.circle.fill", "lizard.fill", "hare.fill", "bird.fill", "ant.fill", "tortoise.fill"]
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(avatars, id: \.self) { icon in
                            Button(action: { profileAvatar = icon }) {
                                Image(systemName: icon)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(profileAvatar == icon ? Color.koboldEmerald.opacity(0.2) : Color.koboldSurface)
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(profileAvatar == icon ? Color.koboldEmerald : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("KoboldOS Account", systemImage: "cloud.fill").font(.subheadline.bold())
                    Text("Cloud-Sync, Backup und Multi-Device Support werden in einer zukünftigen Version verfügbar.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Anmelden") {}
                        .buttonStyle(.borderedProminent)
                        .tint(.koboldEmerald)
                        .disabled(true)
                    Text("Coming in v0.3").font(.caption2).foregroundColor(.secondary)
                }
                .padding()
            }
            settingsSaveButton(section: "Konto")
        }
    }

    // MARK: - Allgemein

    @ViewBuilder
    private func generalSection() -> some View {
        sectionTitle("Allgemeine Einstellungen")

        // Language
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sprache", systemImage: "globe").font(.subheadline.bold())
                Text("Steuert die Interface-Sprache und die Antwortsprache des Agenten.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { l10n.language },
                    set: { l10n.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding()
        }

        // Row 1: Verbindung + Darstellung (two columns)
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Verbindung", systemImage: "network").font(.subheadline.bold())
                    HStack {
                        Text("Daemon-Port")
                        Spacer()
                        Text("\(daemonPort)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(viewModel.isConnected ? Color.koboldEmerald : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.isConnected ? "Verbunden" : "Getrennt")
                                .foregroundColor(viewModel.isConnected ? .koboldEmerald : .red)
                        }
                    }
                    Button("Verbindung prüfen") { Task { await viewModel.testHealth() } }
                        .buttonStyle(.bordered)
                }
                .padding()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Darstellung", systemImage: "paintbrush.fill").font(.subheadline.bold())
                    Toggle("Erweiterte Statistiken im Dashboard", isOn: $showAdvancedStats)
                        .toggleStyle(.switch)
                }
                .padding()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sounds", systemImage: "speaker.wave.2.fill").font(.subheadline.bold())
                    Toggle("Systemsounds aktivieren", isOn: $soundsEnabled)
                        .toggleStyle(.switch)
                    if soundsEnabled {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundColor(.secondary)
                            Slider(value: $soundsVolume, in: 0.1...1.0, step: 0.1)
                            Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                            Text("\(Int(soundsVolume * 100))%")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(width: 35, alignment: .trailing)
                        }
                    }
                }
                .padding()
            }
        }

        // Row 2: Arbeitsverzeichnis (full width)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Standard-Arbeitsverzeichnis", systemImage: "folder.fill").font(.subheadline.bold())
                Text("Hier speichert der Agent neue Projekte und Dateien.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Text(defaultWorkDir)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Ändern…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Auswählen"
                        if panel.runModal() == .OK, let url = panel.url {
                            defaultWorkDir = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Öffnen") {
                        let expanded = NSString(string: defaultWorkDir).expandingTildeInPath
                        let url = URL(fileURLWithPath: expanded)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }

        // Row 3: Menüleiste + Autostart (two columns)
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Menüleiste", systemImage: "menubar.rectangle").font(.subheadline.bold())
                    Toggle("In Menüleiste anzeigen", isOn: Binding(
                        get: { menuBarEnabled },
                        set: { enabled in
                            if enabled { MenuBarController.shared.enable() }
                            else { MenuBarController.shared.disable() }
                            menuBarEnabled = enabled
                        }
                    ))
                    .toggleStyle(.switch)
                    if menuBarEnabled {
                        Toggle("Beim Schließen minimieren", isOn: $menuBarHideOnClose)
                            .toggleStyle(.switch)
                    }
                }
                .padding()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Autostart", systemImage: "power").font(.subheadline.bold())
                    Toggle("Mit macOS starten", isOn: Binding(
                        get: { launchAgent.isEnabled },
                        set: { enabled in
                            if enabled { launchAgent.enable() } else { launchAgent.disable() }
                        }
                    ))
                    .toggleStyle(.switch)
                    if launchAgent.status == .requiresApproval {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("In Systemeinstellungen genehmigen.")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                }
                .padding()
            }
        }

        // Row 3: Updates (full width)
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Updates", systemImage: "arrow.down.circle.fill").font(.subheadline.bold())

                HStack {
                    Text("Aktuelle Version")
                    Spacer()
                    Text("Alpha v\(UpdateManager.currentVersion)")
                        .foregroundColor(.koboldEmerald).fontWeight(.medium)
                }

                Toggle("Automatisch beim Start suchen", isOn: $autoCheckUpdates)
                    .toggleStyle(.switch)

                // Status display
                switch updateManager.state {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Suche nach Updates…").font(.caption).foregroundColor(.secondary)
                    }
                case .upToDate:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("KoboldOS ist aktuell.").font(.caption).foregroundColor(.green)
                    }
                case .available(let version):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.koboldGold)
                            Text("Neue Version verfügbar: v\(version)")
                                .font(.callout).fontWeight(.medium).foregroundColor(.koboldGold)
                        }
                        if let notes = updateManager.releaseNotes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(4)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.koboldSurface))
                        }
                        Button("Update installieren & neustarten") {
                            Task { await updateManager.downloadAndInstall() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.koboldEmerald)
                    }
                case .downloading(let percent):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Lade herunter…").font(.caption)
                            Spacer()
                            Text("\(Int(percent * 100))%").font(.caption).foregroundColor(.secondary)
                        }
                        ProgressView(value: percent)
                            .tint(.koboldEmerald)
                    }
                case .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installiere Update… App startet gleich neu.")
                            .font(.caption).foregroundColor(.koboldGold)
                    }
                case .error(let msg):
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        Text(msg).font(.caption).foregroundColor(.red)
                    }
                }

                HStack {
                    Button("Nach Updates suchen") {
                        Task { await updateManager.checkForUpdates() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(updateManager.state == .checking)

                    Spacer()
                }
            }
            .padding()
        }

        // Row 3b: Onboarding + Debug (side by side)
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Einrichtungsassistent", systemImage: "wand.and.stars").font(.subheadline.bold())
                    Text("Zeigt den Hatching-Wizard erneut.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Onboarding zurücksetzen") {
                        UserDefaults.standard.set(false, forKey: "kobold.hasOnboarded")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Debug-Modus", systemImage: "ladybug.fill").font(.subheadline.bold())
                    Toggle("Verbose Logging",
                           isOn: AppStorageToggle("kobold.log.verbose", default: false))
                        .toggleStyle(.switch)
                    Toggle("Raw Prompts anzeigen",
                           isOn: AppStorageToggle("kobold.dev.showRawPrompts", default: false))
                        .toggleStyle(.switch)
                }
                .padding()
            }
        }

        // Row 5: Verfügbare Tools
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Verfügbare Tools", systemImage: "wrench.and.screwdriver.fill").font(.subheadline.bold())
                    Spacer()
                    if toolEnv.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Erneut scannen") { Task { await toolEnv.scan() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if toolEnv.tools.isEmpty {
                    Text("Noch nicht gescannt.").font(.caption).foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(toolEnv.tools) { tool in
                            HStack(spacing: 4) {
                                Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundColor(tool.isAvailable ? .green : .red.opacity(0.6))
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name).font(.caption).fontWeight(.medium)
                                    if let ver = tool.version {
                                        Text(ver).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                                    } else if !tool.isAvailable {
                                        Text("Nicht installiert").font(.system(size: 9)).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(4)
                        }
                    }
                }

                // Python Download
                if !(toolEnv.tools.first(where: { $0.id == "python3" })?.isAvailable ?? true) {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Python 3.12 herunterladen").font(.caption).fontWeight(.medium)
                            Text("Standalone Python (~17 MB) in App Support installieren").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let progress = toolEnv.pythonDownloadProgress {
                            ProgressView(value: progress).frame(width: 80).tint(.koboldEmerald)
                        } else {
                            Button("Installieren") {
                                Task { try? await toolEnv.downloadPython() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.koboldEmerald)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding()
            .onAppear {
                if toolEnv.tools.isEmpty {
                    Task { await toolEnv.scan() }
                }
            }
        }

        // API-Tester
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("API-Tester", systemImage: "curlybraces").font(.subheadline.bold())
                HStack(spacing: 8) {
                    ForEach(["/health", "/metrics", "/memory", "/models"], id: \.self) { path in
                        Button(path) { testEndpoint(path) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Logs exportieren") { exportLogs() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
                if !rawResponseText.isEmpty {
                    ScrollView {
                        Text(rawResponseText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
        settingsSaveButton(section: "Allgemein")
    }

    // MARK: - Modelle

    @ViewBuilder
    private func modelsSection() -> some View {
        sectionTitle("Modelle & Backend")

        // Ollama connection
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Ollama Backend", systemImage: "server.rack").font(.subheadline.bold())
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.ollamaStatus == "Running" ? Color.koboldEmerald : Color.red)
                            .frame(width: 8, height: 8)
                        Text(viewModel.ollamaStatus)
                            .foregroundColor(viewModel.ollamaStatus == "Running" ? .koboldEmerald : .red)
                    }
                }
                HStack {
                    Text("API").foregroundColor(.secondary)
                    Spacer()
                    Text("http://localhost:11434")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Ollama prüfen") { Task { await viewModel.checkOllamaStatus() } }
                        .buttonStyle(.bordered)
                    Button("Modellbibliothek") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.ai/library")!)
                    }
                    .buttonStyle(.bordered)
                    Button("Ollama installieren") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.ai")!)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }

        // Per-agent model pickers
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Modell pro Agent", systemImage: "person.3.fill").font(.subheadline.bold())
                Text("Jeder Agent kann ein eigenes Modell nutzen. Leer = primäres Modell.")
                    .font(.caption).foregroundColor(.secondary)

                ForEach($agentsStore.configs) { $config in
                    HStack(spacing: 10) {
                        Text(config.emoji).font(.title3)
                        Text(config.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 80, alignment: .leading)

                        // Provider picker (compact)
                        Picker("", selection: $config.provider) {
                            Text("Ollama").tag("ollama")
                            Text("OpenAI").tag("openai")
                            Text("Anthropic").tag("anthropic")
                            Text("Groq").tag("groq")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        .onChange(of: config.provider) {
                            config.modelName = ""  // Reset model on provider change
                            agentsStore.save()
                        }

                        // Model picker (adapts to provider)
                        if config.provider == "ollama" {
                            if ollamaModels.isEmpty {
                                TextField("Modellname", text: $config.modelName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                                    .onChange(of: config.modelName) { agentsStore.save() }
                            } else {
                                Picker("", selection: $config.modelName) {
                                    Text("— Standard —").tag("")
                                    ForEach(ollamaModels, id: \.self) { m in
                                        Text(m).tag(m)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .onChange(of: config.modelName) { agentsStore.save() }
                            }
                        } else {
                            let models = cloudModels(for: config.provider)
                            Picker("", selection: $config.modelName) {
                                Text("— Standard —").tag("")
                                ForEach(models, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: config.modelName) { agentsStore.save() }
                        }

                        // Provider badge
                        if config.provider != "ollama" {
                            Text(config.provider.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(providerBadgeColor(config.provider))
                                .cornerRadius(3)
                        }

                        // Vision badge
                        if config.supportsVision {
                            Image(systemName: "eye.fill")
                                .font(.caption)
                                .foregroundColor(.koboldEmerald)
                                .help("Vision aktiviert")
                        }
                    }
                    if config.id != agentsStore.configs.last?.id {
                        Divider()
                    }
                }
            }
            .padding()
        }

        // Cloud API Provider
        Text("Cloud API-Provider").font(.headline).padding(.top, 8)
        Text("Cloud-LLM-Backends für Agenten. API-Keys werden lokal gespeichert.")
            .font(.caption).foregroundColor(.secondary)

        // OpenAI
        providerCard(
            name: "OpenAI",
            icon: "brain.head.profile",
            color: .green,
            keyBinding: $openaiKey,
            baseURLBinding: $openaiBaseURL,
            defaultURL: "https://api.openai.com",
            models: ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o1"],
            provider: "openai"
        )

        // Anthropic
        providerCard(
            name: "Anthropic",
            icon: "sparkles",
            color: .orange,
            keyBinding: $anthropicKey,
            baseURLBinding: $anthropicBaseURL,
            defaultURL: "https://api.anthropic.com",
            models: ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-20250514"],
            provider: "anthropic"
        )

        // Groq
        providerCard(
            name: "Groq",
            icon: "bolt.fill",
            color: .blue,
            keyBinding: $groqKey,
            baseURLBinding: $groqBaseURL,
            defaultURL: "https://api.groq.com",
            models: ["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"],
            provider: "groq"
        )
        settingsSaveButton(section: "Modelle")
    }

    @AppStorage("kobold.provider.openai.key") private var openaiKey: String = ""
    @AppStorage("kobold.provider.openai.baseURL") private var openaiBaseURL: String = "https://api.openai.com"
    @AppStorage("kobold.provider.anthropic.key") private var anthropicKey: String = ""
    @AppStorage("kobold.provider.anthropic.baseURL") private var anthropicBaseURL: String = "https://api.anthropic.com"
    @AppStorage("kobold.provider.groq.key") private var groqKey: String = ""
    @AppStorage("kobold.provider.groq.baseURL") private var groqBaseURL: String = "https://api.groq.com"

    @State private var testingProvider: String = ""
    @State private var providerTestResult: String = ""

    @ViewBuilder
    private func providerCard(name: String, icon: String, color: Color,
                               keyBinding: Binding<String>, baseURLBinding: Binding<String>,
                               defaultURL: String, models: [String], provider: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .frame(width: 20)
                    Label(name, systemImage: "").font(.subheadline.bold())
                    Spacer()
                    // Status badge
                    if keyBinding.wrappedValue.isEmpty {
                        GlassStatusBadge(label: "Nicht konfiguriert", color: .secondary)
                    } else {
                        GlassStatusBadge(label: "Konfiguriert", color: .koboldEmerald)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API-Key").font(.caption).foregroundColor(.secondary)
                    SecureField("sk-...", text: keyBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Basis-URL").font(.caption).foregroundColor(.secondary)
                    TextField(defaultURL, text: baseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                HStack(spacing: 8) {
                    Text("Modelle:").font(.caption).foregroundColor(.secondary)
                    ForEach(models, id: \.self) { m in
                        Text(m)
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.koboldSurface)
                            .cornerRadius(4)
                    }
                }

                HStack {
                    Button("Verbindung testen") {
                        testProvider(name: provider, key: keyBinding.wrappedValue)
                    }
                    .buttonStyle(.bordered)
                    .disabled(keyBinding.wrappedValue.isEmpty)

                    if testingProvider == provider {
                        ProgressView().controlSize(.small)
                    }
                    if !providerTestResult.isEmpty && testingProvider == provider {
                        Text(providerTestResult)
                            .font(.caption)
                            .foregroundColor(providerTestResult.contains("OK") ? .koboldEmerald : .red)
                    }
                }
            }
            .padding()
        }
    }

    private func testProvider(name: String, key: String) {
        testingProvider = name
        providerTestResult = ""
        Task {
            do {
                let result = try await LLMRunner.shared.generate(
                    messages: [["role": "user", "content": "Say OK"]],
                    provider: name, model: "", apiKey: key
                )
                providerTestResult = result.isEmpty ? "Fehler: Leere Antwort" : "OK — Verbindung erfolgreich"
            } catch {
                providerTestResult = "Fehler: \(error.localizedDescription.prefix(80))"
            }
            // Clear after 5s
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if testingProvider == name { testingProvider = "" }
        }
    }

    // MARK: - Berechtigungen

    @ViewBuilder
    private func permissionsSection() -> some View {
        sectionTitle("Berechtigungen & Autonomie")

        // Autonomy level
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Autonomie-Level", systemImage: "dial.high.fill").font(.subheadline.bold())
                Text("Bestimmt, was der Agent ohne Rückfrage ausführen darf.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("", selection: $autonomyLevel) {
                    Text("1 — Sicher").tag(1)
                    Text("2 — Normal").tag(2)
                    Text("3 — Vollständig").tag(3)
                }
                .pickerStyle(.segmented)
                .onChange(of: autonomyLevel) { _, newValue in applyAutonomyPreset(newValue) }

                HStack(alignment: .top, spacing: 12) {
                    autonomyCard(level: 1, title: "Sicher",
                                 desc: "Alles bestätigen. Keine Shell, keine Datei-Schreibzugriffe.",
                                 color: .koboldEmerald)
                    autonomyCard(level: 2, title: "Normal",
                                 desc: "Shell & Dateien in erlaubten Pfaden. Admin-Aktionen bestätigen.",
                                 color: .koboldGold)
                    autonomyCard(level: 3, title: "Vollständig",
                                 desc: "Alle Tools aktiv. Fragt nur bei destruktiven Aktionen.",
                                 color: .red)
                }
            }
            .padding()
        }

        // Individual permissions
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Einzelne Berechtigungen", systemImage: "checklist").font(.subheadline.bold())
                Text("Überschreibt den Autonomie-Level für spezifische Bereiche.")
                    .font(.caption).foregroundColor(.secondary)

                permToggle("Shell-Ausführung",
                           detail: "Erlaubt bash/zsh Befehle auszuführen",
                           icon: "terminal.fill", color: .koboldGold,
                           binding: $permShell)
                Divider()
                permToggle("Datei-Schreibzugriff",
                           detail: "Erlaubt Dateien zu erstellen und zu ändern",
                           icon: "folder.fill", color: .blue,
                           binding: $permFileWrite)
                Divider()
                permToggle("Dateien erstellen",
                           detail: "Erlaubt neue Dateien anzulegen",
                           icon: "doc.badge.plus", color: .blue,
                           binding: $permCreateFiles)
                Divider()
                permToggle("Dateien löschen",
                           detail: "Erlaubt Dateien zu entfernen",
                           icon: "trash.fill", color: .red,
                           binding: $permDeleteFiles)
                Divider()
                permToggle("Netzwerkzugriff",
                           detail: "Erlaubt HTTP-Anfragen und Browser-Tool",
                           icon: "network", color: .purple,
                           binding: $permNetwork)
                Divider()
                permToggle("Pakete installieren",
                           detail: "Erlaubt npm install, pip install etc.",
                           icon: "shippingbox.fill", color: .orange,
                           binding: $permInstallPkgs)
                Divider()
                permToggle("Gedächtnis ändern",
                           detail: "Erlaubt Memory-Blöcke zu bearbeiten",
                           icon: "brain.fill", color: .cyan,
                           binding: $permModifyMemory)
                Divider()
                permToggle("Self-Check (Level 3)",
                           detail: "Agent prüft + verbessert sich selbst",
                           icon: "checkmark.shield.fill", color: .koboldEmerald,
                           binding: $permSelfCheck)
                Divider()
                permToggle("Benachrichtigungen",
                           detail: "Erlaubt dem Agent macOS-Benachrichtigungen zu senden",
                           icon: "bell.fill", color: .indigo,
                           binding: $permNotifications)
                Divider()
                permToggle("Kalender & Erinnerungen",
                           detail: "Events lesen/erstellen, Erinnerungen verwalten",
                           icon: "calendar", color: .red,
                           binding: $permCalendar)
                Divider()
                permToggle("Kontakte",
                           detail: "Kontakte durchsuchen und lesen",
                           icon: "person.crop.rectangle.stack.fill", color: .blue,
                           binding: $permContacts)
                Divider()
                permToggle("Mail & Nachrichten",
                           detail: "Emails lesen/senden, iMessage lesen/senden via AppleScript",
                           icon: "envelope.fill", color: .blue,
                           binding: $permMail)
                Divider()
                permToggle("Admin-Aktionen bestätigen",
                           detail: "Fragt nach bei sudo, rm -rf, kritischen Aktionen",
                           icon: "exclamationmark.shield.fill", color: .red,
                           binding: $permConfirmAdmin)
            }
            .padding()
        }

        // Apple System Permissions — Request macOS access
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Apple Systemzugriff", systemImage: "apple.logo").font(.subheadline.bold())
                Text("Fordere macOS-Systemzugriff an. Diese Berechtigungen werden vom Betriebssystem verwaltet.")
                    .font(.caption).foregroundColor(.secondary)

                systemPermRow(title: "Kalender & Erinnerungen", icon: "calendar", color: .red,
                              detail: "Termine erstellen, lesen und Erinnerungen verwalten") {
                    requestCalendarAccess()
                }
                Divider()
                systemPermRow(title: "Kontakte", icon: "person.crop.rectangle.stack.fill", color: .blue,
                              detail: "Kontakte durchsuchen und lesen") {
                    requestContactsAccess()
                }
                Divider()
                systemPermRow(title: "Mail & Nachrichten (AppleScript)", icon: "envelope.fill", color: .indigo,
                              detail: "AppleScript-Zugriff für Mail, Messages, Safari, Finder") {
                    requestAppleScriptAccess()
                }
                Divider()
                systemPermRow(title: "Benachrichtigungen", icon: "bell.fill", color: .orange,
                              detail: "Push-Benachrichtigungen auf deinem Mac") {
                    requestNotificationAccess()
                }
                Divider()
                HStack {
                    Image(systemName: "gearshape.fill").foregroundColor(.secondary)
                    Text("Weitere Berechtigungen findest du unter")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Systemeinstellungen → Datenschutz") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    .font(.caption).buttonStyle(.link)
                }
            }
            .padding()
        }

        // Shell Permissions — 3 Tier Toggles (Blacklist-System)
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Shell-Berechtigungen (Blacklist)", systemImage: "terminal.fill").font(.subheadline.bold())
                Text("Tiers bestimmen den Zugriffslevel. Power-Tier erlaubt alles ausser Blacklist (sudo, rm -rf /, etc.).")
                    .font(.caption).foregroundColor(.secondary)

                shellTierCard(
                    title: "Sicher",
                    icon: "checkmark.shield.fill",
                    color: .koboldEmerald,
                    commands: "ls, pwd, cat, head, tail, wc, echo, whoami, date, uname, sw_vers, uptime, which",
                    description: "Nur lesende Info-Befehle (Allowlist)",
                    isOn: $shellSafeTier
                )
                shellTierCard(
                    title: "Normal",
                    icon: "gearshape.fill",
                    color: .koboldGold,
                    commands: "+ grep, find, sort, mkdir, cp, mv, touch, git, open, pbcopy",
                    description: "Dateisystem & Git (Allowlist, keine Pipes)",
                    isOn: $shellNormalTier
                )
                shellTierCard(
                    title: "Power",
                    icon: "bolt.fill",
                    color: .red,
                    commands: "Alles erlaubt ausser Blacklist — inkl. Pipes, Redirects, python3, curl, npm, etc.",
                    description: "Voller Zugriff (nur Blacklist-Schutz)",
                    isOn: $shellPowerTier
                )
            }
            .padding()
        }

        // Custom blacklist
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Benutzerdefinierte Blacklist", systemImage: "xmark.shield.fill").font(.subheadline.bold())
                Text("Zusätzlich blockierte Befehle (kommagetrennt). Werden IMMER blockiert, unabhängig vom Tier.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("z.B. docker, terraform, ansible", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "kobold.shell.customBlacklist") ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.shell.customBlacklist") }
                ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding()
        }

        // Custom Allowlist
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Benutzerdefinierte Whitelist", systemImage: "checkmark.shield.fill").font(.subheadline.bold())
                Text("Zusätzlich erlaubte Befehle (kommagetrennt). Werden auch in Safe/Normal-Tier erlaubt.")
                    .font(.caption).foregroundColor(.secondary)
                TextField("z.B. python3, node, cargo, docker", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "kobold.shell.customAllowlist") ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.shell.customAllowlist") }
                ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding()
        }

        // macOS permissions
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("macOS System-Berechtigungen", systemImage: "apple.logo").font(.subheadline.bold())
                Text("Diese Berechtigungen werden vom macOS-System verwaltet.")
                    .font(.caption).foregroundColor(.secondary)

                macOSPermRow("Kamera", icon: "camera.fill",
                             detail: "Für Bild-Aufnahmen und Vision") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                Divider()
                macOSPermRow("Mikrofon", icon: "mic.fill",
                             detail: "Für Audio-Aufnahmen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Divider()
                macOSPermRow("Bildschirmaufnahme", icon: "rectangle.dashed",
                             detail: "Für Screenshot-Tool") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .padding()
        }
        settingsSaveButton(section: "Berechtigungen")
    }

    private func shellTierCard(title: String, icon: String, color: Color, commands: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(isOn.wrappedValue ? color : .secondary)
                .frame(width: 32, height: 32)
                .background((isOn.wrappedValue ? color : Color.secondary).opacity(0.12))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.caption).foregroundColor(.secondary)
                Text(commands)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(color)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(isOn.wrappedValue ? color.opacity(0.06) : Color.koboldSurface.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn.wrappedValue ? color.opacity(0.3) : Color.clear, lineWidth: 1))
    }

    private func autonomyCard(level: Int, title: String, desc: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(level)").font(.title2.bold()).foregroundColor(color)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            Text(desc).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(autonomyLevel == level ? color.opacity(0.12) : Color.koboldSurface.opacity(0.4))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(autonomyLevel == level ? color.opacity(0.5) : Color.clear, lineWidth: 1))
    }

    private func permToggle(_ title: String, detail: String, icon: String, color: Color, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func macOSPermRow(_ title: String, icon: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Öffnen", action: action)
                .buttonStyle(.bordered)
                .font(.caption)
        }
    }

    private func applyAutonomyPreset(_ level: Int) {
        switch level {
        case 1:
            permShell = false; permFileWrite = false
            permNetwork = false; permConfirmAdmin = true
        case 2:
            permShell = true; permFileWrite = true
            permNetwork = true; permConfirmAdmin = true
        case 3:
            permShell = true; permFileWrite = true
            permNetwork = true; permConfirmAdmin = false
        default: break
        }
    }

    // MARK: - System Permission Helpers

    @ViewBuilder
    private func systemPermRow(title: String, icon: String, color: Color, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Berechtigung anfragen") { action() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func requestCalendarAccess() {
        Task {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
                _ = try? await store.requestFullAccessToReminders()
            } else {
                store.requestAccess(to: .event) { _, _ in }
                store.requestAccess(to: .reminder) { _, _ in }
            }
        }
    }

    private func requestContactsAccess() {
        Task {
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
        }
    }

    private func requestAppleScriptAccess() {
        // Trigger AppleScript permission by running a harmless script
        let script = NSAppleScript(source: "tell application \"System Events\" to return name of first process")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    private func requestNotificationAccess() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
    }

    // MARK: - Datenschutz & Sicherheit

    @AppStorage("kobold.data.persistAfterDelete") private var persistDataAfterDelete: Bool = true

    @ViewBuilder
    private func securitySection() -> some View {
        sectionTitle("Datenschutz & Sicherheit")

        // Datenpersistenz
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Datenpersistenz", systemImage: "externaldrive.fill").font(.subheadline.bold())
                Text("Steuere ob Daten (Gedächtnis, Chat-Verlauf, Skills) auch nach dem Löschen der App erhalten bleiben.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Daten über App-Löschung hinaus speichern", isOn: $persistDataAfterDelete)
                    .toggleStyle(.switch)
                Text(persistDataAfterDelete
                     ? "Daten bleiben in ~/Library/Application Support/KoboldOS/ erhalten."
                     : "Alle Daten werden beim Deinstallieren der App entfernt.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding()
        }

        // Safe Mode
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Safe Mode", systemImage: "lock.shield.fill").font(.subheadline.bold())
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Status: \(viewModel.safeModeActive ? "Aktiv" : "Deaktiviert")")
                        Text(viewModel.safeModeActive
                             ? "Eingeschränkter Modus — kritische Tools deaktiviert."
                             : "Normalbetrieb — alle Tools verfügbar.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(viewModel.safeModeActive ? Color.red : Color.koboldEmerald)
                        .frame(width: 10, height: 10)
                }
            }
            .padding()
        }

        // Daemon Auth
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Daemon-Authentifizierung", systemImage: "key.fill").font(.subheadline.bold())
                Text("Bearer-Token für API-Anfragen an den lokalen Daemon.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    SecureField("Bearer Token", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.authToken") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.authToken") }
                    ))
                        .textFieldStyle(.roundedBorder)
                    Button("Neu generieren") {
                        let newToken = UUID().uuidString
                        UserDefaults.standard.set(newToken, forKey: "kobold.authToken")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        let token = UserDefaults.standard.string(forKey: "kobold.authToken") ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Token kopieren")
                }
            }
            .padding()
        }

        // Cloud API Keys (quick access — also editable under Modelle)
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Cloud API-Keys", systemImage: "cloud.fill").font(.subheadline.bold())
                Text("API-Keys für Cloud-Provider. Werden lokal in UserDefaults gespeichert.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(openaiKey.isEmpty ? Color.red : Color.koboldEmerald).frame(width: 6, height: 6)
                            Text("OpenAI").font(.caption.bold())
                        }
                        SecureField("sk-...", text: $openaiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(anthropicKey.isEmpty ? Color.red : Color.koboldEmerald).frame(width: 6, height: 6)
                            Text("Anthropic").font(.caption.bold())
                        }
                        SecureField("sk-ant-...", text: $anthropicKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(groqKey.isEmpty ? Color.red : Color.koboldEmerald).frame(width: 6, height: 6)
                            Text("Groq").font(.caption.bold())
                        }
                        SecureField("gsk_...", text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .padding()
        }

        // Secrets
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Secrets & API-Keys", systemImage: "lock.rectangle.stack.fill").font(.subheadline.bold())
                SecretsManagementView()
            }
            .padding()
        }

        // Datensicherung (merged from former standalone tab)
        Text("Datensicherung").font(.headline).padding(.top, 8)
        backupContent()
        settingsSaveButton(section: "Sicherheit")
    }

    @ViewBuilder
    private func backupContent() -> some View {
        // Create backup
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Backup erstellen", systemImage: "arrow.down.doc.fill").font(.subheadline.bold())
                Text("Wähle aus, welche Daten gesichert werden sollen:")
                    .font(.caption).foregroundColor(.secondary)

                // Category checkmarks
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    Toggle("Gedächtnis", isOn: $backupMemories)
                    Toggle("Secrets & API-Keys", isOn: $backupSecrets)
                    Toggle("Chats & Sessions", isOn: $backupChats)
                    Toggle("Skills", isOn: $backupSkills)
                    Toggle("Einstellungen", isOn: $backupSettings)
                    Toggle("Aufgaben", isOn: $backupTasks)
                    Toggle("Workflows", isOn: $backupWorkflows)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                HStack(spacing: 12) {
                    Button(action: createBackup) {
                        HStack(spacing: 6) {
                            if isCreatingBackup {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text("Backup erstellen")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldEmerald)
                    .disabled(isCreatingBackup)

                    Button("Backup-Ordner öffnen") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("KoboldOS/Backups")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(.bordered)
                }

                if !backupStatusMessage.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: backupStatusMessage.contains("Fehler") ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(backupStatusMessage.contains("Fehler") ? .red : .koboldEmerald)
                        Text(backupStatusMessage)
                            .font(.caption).foregroundColor(backupStatusMessage.contains("Fehler") ? .red : .koboldEmerald)
                    }
                }
            }
            .padding()
        }

        // Existing backups
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Vorhandene Backups", systemImage: "clock.arrow.circlepath").font(.subheadline.bold())

                if backups.isEmpty {
                    Text("Keine Backups vorhanden.")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(backups) { backup in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(.koboldGold)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(backup.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(backup.formattedDate)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Wiederherstellen") {
                                restoreBackup(backup)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            Button(action: { deleteBackup(backup) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        if backup.id != backups.last?.id { Divider() }
                    }
                }
            }
            .padding()
        }
        .onAppear { loadBackups() }
    }

    // MARK: - A2A (Agent-to-Agent)

    @ViewBuilder
    private func a2aSection() -> some View {
        sectionTitle("Agent-to-Agent (A2A)")

        // Master toggle
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("A2A Server", systemImage: "arrow.left.arrow.right").font(.subheadline.bold())
                    Spacer()
                    GlassStatusBadge(label: a2aEnabled ? "Aktiv" : "Inaktiv", color: a2aEnabled ? .koboldEmerald : .secondary)
                }
                Text("Ermöglicht anderen KI-Agenten, sich mit deinem KoboldOS zu verbinden und Aufgaben auszutauschen.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Toggle("A2A aktivieren", isOn: $a2aEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)
                    Text("Port:").font(.caption).foregroundColor(.secondary)
                    TextField("8081", value: $a2aPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .padding()
        }

        // Permissions grid — what connected agents can access
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Berechtigungen für verbundene Agenten", systemImage: "shield.lefthalf.filled").font(.subheadline.bold())
                Text("Steuere, was externe Agenten auf deinem System tun dürfen. Gedächtnis ist standardmäßig nur lesbar — unser Agent entscheidet, was behalten wird.")
                    .font(.caption).foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    a2aPermCard(title: "Tools nutzen", icon: "wrench.fill", color: .koboldGold,
                                desc: "Agent darf Tools aufrufen (Browser, etc.)", isOn: $a2aAllowTools)
                    a2aPermCard(title: "Gedächtnis lesen", icon: "brain.fill", color: .cyan,
                                desc: "Agent darf Memory-Blöcke lesen", isOn: $a2aAllowMemoryRead)
                    a2aPermCard(title: "Gedächtnis schreiben", icon: "brain.head.profile", color: .orange,
                                desc: "Agent darf Memory-Blöcke direkt ändern", isOn: $a2aAllowMemoryWrite)
                    a2aPermCard(title: "Dateizugriff", icon: "folder.fill", color: .blue,
                                desc: "Agent darf Dateien lesen und schreiben", isOn: $a2aAllowFiles)
                    a2aPermCard(title: "Shell-Zugriff", icon: "terminal.fill", color: .red,
                                desc: "Agent darf Shell-Befehle ausführen", isOn: $a2aAllowShell)
                }
            }
            .padding()
        }

        // Quick Connect — Token Exchange
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Schnellverbindung (Token)", systemImage: "link.badge.plus").font(.subheadline.bold())
                Text("Generiere einen Token und teile ihn mit einem anderen Agenten für eine direkte A2A-Verbindung.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dein Token").font(.caption).foregroundColor(.secondary)
                        HStack {
                            TextField("Token wird generiert...", text: $a2aToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .disabled(true)
                            Button("Generieren") {
                                a2aToken = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24).description
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.koboldEmerald)
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(a2aToken, forType: .string)
                            }) {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            .disabled(a2aToken.isEmpty)
                            .help("Token kopieren")
                        }
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token des anderen Agenten").font(.caption).foregroundColor(.secondary)
                        HStack {
                            TextField("Token einfügen...", text: $a2aRemoteToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button("Verbinden") {
                                // Add to trusted agents
                                if !a2aRemoteToken.isEmpty {
                                    let existing = a2aTrustedAgents.trimmingCharacters(in: .whitespacesAndNewlines)
                                    a2aTrustedAgents = existing.isEmpty ? a2aRemoteToken : existing + "\n" + a2aRemoteToken
                                    a2aRemoteToken = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.koboldGold)
                            .disabled(a2aRemoteToken.isEmpty)
                        }
                    }
                }
            }
            .padding()
        }

        // Trusted agents
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Vertrauenswürdige Agenten", systemImage: "checkmark.shield.fill").font(.subheadline.bold())
                Text("URLs oder Tokens von Agenten die sich ohne Bestätigung verbinden dürfen (eine pro Zeile).")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $a2aTrustedAgents)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 80)
                    .padding(6)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                    .scrollContentBackground(.hidden)
                Text("z.B. http://192.168.1.100:8081, http://localhost:9090")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding()
        }

        // Info
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Protokoll", systemImage: "doc.text").font(.subheadline.bold())
                Text("KoboldOS nutzt das Google A2A Protokoll. Jeder A2A-kompatible Agent kann sich verbinden.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text("Agent Card:").font(.caption).foregroundColor(.secondary)
                    Text("http://localhost:\(a2aPort)/.well-known/agent.json")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.koboldEmerald)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        settingsSaveButton(section: "A2A")
    }

    private func a2aPermCard(title: String, icon: String, color: Color, desc: String, isOn: Binding<Bool>) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(isOn.wrappedValue ? color : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(desc).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(color)
            }
            .padding(6)
        }
    }

    // MARK: - Verbindungen (formerly Extensions)

    @ViewBuilder
    private func connectionsSection() -> some View {
        sectionTitle("Verbindungen")

        // Info banner
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
            Text("Verbindungen werden in zukünftigen Versionen verfügbar sein. Du kannst bereits jetzt APIs über den Browser-Tool nutzen.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 0.5))
        )

        let connectionItems: [(String, String, Color, String)] = [
            ("Google", "magnifyingglass", .blue, "Google Suche, Drive, Kalender, Gmail"),
            ("GitHub", "chevron.left.forwardslash.chevron.right", .purple, "Repositories, Issues, Pull Requests"),
            ("Slack", "number", .green, "Nachrichten senden, Kanäle lesen"),
            ("Notion", "doc.text.fill", .primary, "Seiten lesen und bearbeiten"),
            ("SoundCloud", "waveform", .orange, "Tracks, Playlists, Statistiken"),
            ("Instagram", "camera.fill", .pink, "Posts, Stories, Analytics"),
            ("Spotify", "music.note", .green, "Playlists, Tracks, Wiedergabe"),
            ("iMessage", "message.fill", .blue, "Nachrichten lesen und senden"),
        ]

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
            ForEach(connectionItems, id: \.0) { item in
                GroupBox {
                    HStack(spacing: 10) {
                        Image(systemName: item.1)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(item.2)
                            .frame(width: 36, height: 36)
                            .background(item.2.opacity(0.12))
                            .cornerRadius(10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0)
                                .font(.system(size: 14, weight: .semibold))
                            Text(item.3)
                                .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text("Geplant")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .padding(4)
                }
                .opacity(0.6)
            }
        }
        settingsSaveButton(section: "Verbindungen")
    }

    // MARK: - Gedächtnis

    @ViewBuilder
    private func memorySettingsSection() -> some View {
        sectionTitle("Gedächtnis-Einstellungen")

        // Core Memory blocks
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Speicherlimits", systemImage: "ruler.fill").font(.subheadline.bold())
                    HStack { Text("Persona-Block"); Spacer(); Text("2000 Zeichen").foregroundColor(.secondary) }.font(.system(size: 13))
                    HStack { Text("Human-Block"); Spacer(); Text("2000 Zeichen").foregroundColor(.secondary) }.font(.system(size: 13))
                    HStack { Text("Knowledge-Block"); Spacer(); Text("3000 Zeichen").foregroundColor(.secondary) }.font(.system(size: 13))
                }
                .padding()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Auto-Speichern", systemImage: "arrow.clockwise").font(.subheadline.bold())
                    Toggle("Automatisch sichern", isOn: AppStorageToggle("kobold.memory.autosave", default: true))
                        .toggleStyle(.switch)
                    Text("Speichert bei jeder Aktualisierung.").font(.caption).foregroundColor(.secondary)
                }
                .padding()
            }
        }

        // Recall settings (AgentZero-style)
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Memory Recall", systemImage: "magnifyingglass").font(.subheadline.bold())
                Text("Automatisches Abrufen relevanter Erinnerungen vor jeder Antwort.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Memory Recall aktivieren", isOn: $memoryRecallEnabled)
                    .toggleStyle(.switch).tint(.koboldEmerald)

                if memoryRecallEnabled {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Abruf-Intervall").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $memoryRecallInterval) {
                                Text("Jede Nachricht").tag(1)
                                Text("Alle 2").tag(2)
                                Text("Alle 3").tag(3)
                                Text("Alle 5").tag(5)
                            }.pickerStyle(.menu).frame(width: 150)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max. Suchergebnisse").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $memoryMaxSearch) {
                                Text("5").tag(5); Text("8").tag(8); Text("12").tag(12); Text("20").tag(20)
                            }.pickerStyle(.menu).frame(width: 80)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max. Ergebnisse").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $memoryMaxResults) {
                                Text("3").tag(3); Text("5").tag(5); Text("8").tag(8); Text("10").tag(10)
                            }.pickerStyle(.menu).frame(width: 80)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ähnlichkeits-Schwelle: \(String(format: "%.1f", memorySimilarity))").font(.caption).foregroundColor(.secondary)
                        Slider(value: $memorySimilarity, in: 0.3...0.95, step: 0.05)
                            .tint(.koboldEmerald)
                    }
                }
            }
            .padding()
        }

        // Memorization settings
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Automatisches Merken", systemImage: "brain.fill").font(.subheadline.bold())
                Text("Agent extrahiert automatisch wichtige Informationen aus Gesprächen.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Automatisches Merken aktivieren", isOn: $memoryMemorizeEnabled)
                    .toggleStyle(.switch).tint(.koboldEmerald)

                if memoryMemorizeEnabled {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Toggle("Fakten extrahieren", isOn: $memoryAutoFragments)
                                .toggleStyle(.switch)
                            Text("Speichert wichtige Fakten aus Gesprächen").font(.caption2).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Toggle("Lösungen merken", isOn: $memoryAutoSolutions)
                                .toggleStyle(.switch)
                            Text("Speichert Problem/Lösung-Paare").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Toggle("Intelligente Konsolidierung", isOn: $memoryConsolidation)
                        .toggleStyle(.switch)
                    Text("Fasst ähnliche Erinnerungen zusammen und vermeidet Duplikate (LLM-basiert).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding()
        }

        // Export / Import
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Export / Import", systemImage: "square.and.arrow.up").font(.subheadline.bold())
                HStack(spacing: 8) {
                    Button("Exportieren") { exportMemory() }.buttonStyle(.bordered)
                    Button("Importieren") { importMemory() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Zurücksetzen") { resetMemory() }.buttonStyle(.bordered).foregroundColor(.red)
                }
            }
            .padding()
        }
        settingsSaveButton(section: "Gedächtnis")
    }

    private func exportMemory() {
        Task {
            guard let url = URL(string: viewModel.baseURL + "/memory"),
                  let (data, _) = try? await viewModel.authorizedData(from: url) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "koboldos-memory.json"
            if panel.runModal() == .OK, let saveURL = panel.url {
                try? data.write(to: saveURL)
            }
        }
    }

    private func importMemory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let blocks = json["blocks"] as? [[String: Any]] else { return }
                for block in blocks {
                    guard let label = block["label"] as? String,
                          let content = block["content"] as? String else { continue }
                    guard let reqURL = URL(string: viewModel.baseURL + "/memory/update"),
                          let body = try? JSONSerialization.data(withJSONObject: ["label": label, "content": content]) else { continue }
                    var req = viewModel.authorizedRequest(url: reqURL, method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
    }

    private func resetMemory() {
        Task {
            for label in ["persona", "human"] {
                guard let url = URL(string: viewModel.baseURL + "/memory/update"),
                      let body = try? JSONSerialization.data(withJSONObject: ["label": label, "content": ""]) else { continue }
                var req = viewModel.authorizedRequest(url: url, method: "POST")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    // MARK: - Skills

    @State private var skills: [SkillDisplay] = []

    struct SkillDisplay: Identifiable {
        let id = UUID()
        let name: String
        let filename: String
        var isEnabled: Bool
    }

    // MARK: - Fernsteuerung (WebApp)

    @AppStorage("kobold.webapp.enabled") private var webAppEnabled: Bool = false
    @AppStorage("kobold.webapp.port") private var webAppPort: Int = 8090
    @AppStorage("kobold.webapp.username") private var webAppUsername: String = "admin"
    @AppStorage("kobold.webapp.password") private var webAppPassword: String = ""
    @State private var webAppRunning = false
    @State private var tunnelRunning = false
    @State private var tunnelURL: String = ""
    @State private var cloudflaredInstalled = false
    @State private var cloudflaredInstalling = false

    @ViewBuilder
    private func remoteControlSection() -> some View {
        sectionTitle("Fernsteuerung (WebApp)")

        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("WebApp-Server", systemImage: "globe").font(.subheadline.bold())
                Text("Starte eine Web-Oberfläche die dein KoboldOS spiegelt — als Fernbedienung von jedem Gerät.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("WebApp aktivieren", isOn: $webAppEnabled)
                    .toggleStyle(.switch)
                    .tint(.koboldEmerald)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port").font(.caption.bold()).foregroundColor(.secondary)
                        TextField("Port", value: $webAppPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Benutzername").font(.caption.bold()).foregroundColor(.secondary)
                        TextField("Benutzername", text: $webAppUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Passwort").font(.caption.bold()).foregroundColor(.secondary)
                        SecureField("Passwort", text: $webAppPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                }

                if webAppPassword.isEmpty {
                    Label("Bitte ein Passwort setzen bevor du den Server startest.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }

                HStack(spacing: 12) {
                    if webAppEnabled && !webAppPassword.isEmpty {
                        Button(webAppRunning ? "Server stoppen" : "Server starten") {
                            if webAppRunning {
                                WebAppServer.shared.stop()
                                webAppRunning = false
                                tunnelRunning = false
                                tunnelURL = ""
                            } else {
                                let dPort = UserDefaults.standard.integer(forKey: "kobold.port")
                                let dToken = UserDefaults.standard.string(forKey: "kobold.authToken") ?? ""
                                WebAppServer.shared.start(
                                    port: webAppPort,
                                    daemonPort: dPort == 0 ? 8080 : dPort,
                                    daemonToken: dToken,
                                    username: webAppUsername,
                                    password: webAppPassword
                                )
                                webAppRunning = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(webAppRunning ? .red : .koboldEmerald)
                    }

                    if webAppRunning {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 8, height: 8)
                            Text("http://localhost:\(webAppPort)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.koboldEmerald)
                        }

                        Button("Im Browser öffnen") {
                            if let url = URL(string: "http://localhost:\(webAppPort)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding()
        }

        // Cloudflare Tunnel Section
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cloudflare Tunnel", systemImage: "network").font(.subheadline.bold())
                Text("Erstelle einen sicheren Tunnel zum Internet — zugreifbar von jedem Gerät, auch unterwegs. Kein Port-Forwarding nötig.")
                    .font(.caption).foregroundColor(.secondary)

                if !cloudflaredInstalled {
                    HStack(spacing: 12) {
                        Label("cloudflared nicht installiert", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                        Button(cloudflaredInstalling ? "Installiere..." : "Mit Homebrew installieren") {
                            cloudflaredInstalling = true
                            WebAppServer.installCloudflared { success in
                                DispatchQueue.main.async {
                                    cloudflaredInstalling = false
                                    cloudflaredInstalled = success
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cloudflaredInstalling)
                    }
                } else if webAppRunning {
                    HStack(spacing: 12) {
                        Button(tunnelRunning ? "Tunnel stoppen" : "Tunnel starten") {
                            if tunnelRunning {
                                WebAppServer.shared.stopTunnel()
                                tunnelRunning = false
                                tunnelURL = ""
                            } else {
                                WebAppServer.shared.startTunnel(localPort: webAppPort)
                                tunnelRunning = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tunnelRunning ? .red : .blue)

                        if tunnelRunning && tunnelURL.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Tunnel wird erstellt...")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    if !tunnelURL.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Circle().fill(Color.blue).frame(width: 8, height: 8)
                                Text(tunnelURL)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .textSelection(.enabled)
                            }

                            HStack(spacing: 8) {
                                Button("URL kopieren") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tunnelURL, forType: .string)
                                }
                                .buttonStyle(.bordered).controlSize(.small)

                                Button("Im Browser öffnen") {
                                    if let url = URL(string: tunnelURL) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }

                            // QR Code
                            Text("QR-Code zum Scannen mit dem Handy:")
                                .font(.caption).foregroundColor(.secondary)
                            if let qrImage = generateQRCode(from: tunnelURL) {
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .background(Color.white)
                                    .cornerRadius(12)
                                    .padding(.top, 4)
                            }
                        }
                    }
                } else {
                    Text("Starte zuerst den WebApp-Server um den Tunnel zu aktivieren.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .onAppear {
            cloudflaredInstalled = WebAppServer.isCloudflaredInstalled()
            webAppRunning = WebAppServer.shared.isRunning
            tunnelRunning = WebAppServer.shared.isTunnelRunning
            tunnelURL = WebAppServer.shared.tunnelURL ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("koboldTunnelURLReady"))) { notif in
            if let url = notif.object as? String {
                tunnelURL = url
            }
        }
    }

    /// Generate QR code as NSImage
    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = output.transformed(by: scale)
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Telegram Bot

    @AppStorage("kobold.telegram.token") private var telegramToken: String = ""
    @AppStorage("kobold.telegram.chatId") private var telegramChatId: String = ""
    @State private var telegramRunning = false
    @State private var telegramBotName = ""
    @State private var telegramStats: (received: Int, sent: Int) = (0, 0)

    @ViewBuilder
    private func telegramSection() -> some View {
        sectionTitle("Telegram Bot")

        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Telegram-Verbindung", systemImage: "paperplane.fill").font(.subheadline.bold())
                Text("Verbinde deinen KoboldOS-Agent mit Telegram. Chatte von unterwegs per Handy mit deinem Agent.")
                    .font(.caption).foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bot-Token (von @BotFather)").font(.caption.bold()).foregroundColor(.secondary)
                    SecureField("z.B. 123456:ABC-DEF1234...", text: $telegramToken)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Deine Chat-ID").font(.caption.bold()).foregroundColor(.secondary)
                        Text("(optional — leer = alle erlauben)").font(.caption2).foregroundColor(.secondary)
                    }
                    TextField("z.B. 123456789", text: $telegramChatId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                HStack(spacing: 12) {
                    Button(telegramRunning ? "Bot stoppen" : "Bot starten") {
                        if telegramRunning {
                            TelegramBot.shared.stop()
                            telegramRunning = false
                            telegramBotName = ""
                        } else {
                            guard !telegramToken.isEmpty else { return }
                            let chatId = Int64(telegramChatId) ?? 0
                            TelegramBot.shared.start(token: telegramToken, allowedChatId: chatId)
                            telegramRunning = true
                            // Poll for bot name
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                telegramBotName = TelegramBot.shared.botUsername
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(telegramRunning ? .red : .koboldEmerald)
                    .disabled(telegramToken.isEmpty)

                    if telegramRunning {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 8, height: 8)
                            if !telegramBotName.isEmpty {
                                Text("@\(telegramBotName)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.koboldEmerald)
                            } else {
                                Text("Verbinde...")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if telegramRunning {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.received)").font(.title3.bold()).foregroundColor(.koboldEmerald)
                            Text("Empfangen").font(.caption2).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.sent)").font(.title3.bold()).foregroundColor(.blue)
                            Text("Gesendet").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                        telegramStats = TelegramBot.shared.stats
                        if telegramBotName.isEmpty {
                            telegramBotName = TelegramBot.shared.botUsername
                        }
                    }
                }
            }
            .padding()
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("So geht's", systemImage: "questionmark.circle.fill").font(.subheadline.bold())
                Text("""
                1. Öffne Telegram und suche @BotFather
                2. Sende /newbot und folge den Anweisungen
                3. Kopiere den Bot-Token hierher
                4. Optional: Sende /start an deinen Bot, dann sende /status um deine Chat-ID zu erfahren
                5. Klicke "Bot starten" — fertig!
                """)
                    .font(.caption).foregroundColor(.secondary)
            }.padding()
        }
        .onAppear {
            telegramRunning = TelegramBot.shared.isRunning
            telegramBotName = TelegramBot.shared.botUsername
        }
    }

    @ViewBuilder
    private func skillsSettingsSection() -> some View {
        sectionTitle("Skills")

        // Verwalten box FIRST (above active skills)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Skills verwalten", systemImage: "folder.fill").font(.subheadline.bold())
                Text("Importiere .md Dateien als Skills oder lege sie manuell in den Skills-Ordner.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button("Skill importieren") {
                        importSkillFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldEmerald)

                    Button("Skills-Ordner öffnen") {
                        let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("KoboldOS/Skills")
                        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(skillsDir)
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                    Button(action: { loadSkillsList() }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.koboldEmerald)
                    .help("Skills neu laden")
                }
            }
            .padding()
        }

        // Active Skills list
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Aktive Skills", systemImage: "sparkles").font(.subheadline.bold())
                Text("Aktivierte Skills werden in den System-Prompt des Agenten injiziert.")
                    .font(.caption).foregroundColor(.secondary)

                if skills.isEmpty {
                    Text("Keine Skills gefunden.")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(skills.enumerated()), id: \.element.id) { idx, skill in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.koboldGold)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name).font(.system(size: 13, weight: .medium))
                                Text(skill.filename).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { skills[idx].isEnabled },
                                set: { newVal in
                                    skills[idx].isEnabled = newVal
                                    Task { await SkillLoader.shared.setEnabled(skill.name, enabled: newVal) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        if idx < skills.count - 1 { Divider() }
                    }
                }
            }
            .padding()
        }
        .onAppear { loadSkillsList() }
        settingsSaveButton(section: "Skills")
    }

    private func loadSkillsList() {
        Task {
            let loaded = await SkillLoader.shared.loadSkills()
            skills = loaded.map { SkillDisplay(name: $0.name, filename: $0.filename, isEnabled: $0.isEnabled) }
        }
    }

    private func importSkillFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Markdown-Dateien (.md) als Skills importieren"
        panel.prompt = "Importieren"

        if panel.runModal() == .OK {
            let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("KoboldOS/Skills")
            try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

            for url in panel.urls {
                let dest = skillsDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
            }
            // Reload skills list
            loadSkillsList()
        }
    }

    @State private var backups: [BackupEntry] = []
    @State private var backupStatusMessage: String = ""
    @State private var isCreatingBackup: Bool = false

    // Backup category toggles
    @State private var backupMemories: Bool = true
    @State private var backupSecrets: Bool = true
    @State private var backupChats: Bool = true
    @State private var backupSkills: Bool = true
    @State private var backupSettings: Bool = true
    @State private var backupTasks: Bool = true
    @State private var backupWorkflows: Bool = true

    private func loadBackups() {
        Task {
            backups = await BackupManager.shared.listBackups()
        }
    }

    private func createBackup() {
        isCreatingBackup = true
        backupStatusMessage = ""
        let categories = BackupManager.BackupCategories(
            memories: backupMemories,
            secrets: backupSecrets,
            chats: backupChats,
            skills: backupSkills,
            settings: backupSettings,
            tasks: backupTasks,
            workflows: backupWorkflows
        )
        Task {
            do {
                let url = try await BackupManager.shared.createBackup(categories: categories)
                backupStatusMessage = "Backup erstellt: \(url.lastPathComponent)"
                loadBackups()
            } catch {
                backupStatusMessage = "Fehler: \(error.localizedDescription)"
            }
            isCreatingBackup = false
        }
    }

    private func restoreBackup(_ backup: BackupEntry) {
        Task {
            do {
                try await BackupManager.shared.restoreBackup(backup.url)
                backupStatusMessage = "Backup '\(backup.name)' wiederhergestellt. Bitte App neustarten."
            } catch {
                backupStatusMessage = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    private func deleteBackup(_ backup: BackupEntry) {
        Task {
            try? await BackupManager.shared.deleteBackup(backup.url)
            loadBackups()
        }
    }

    @State private var rawPromptText: String = ""
    @State private var rawResponseText: String = ""

    private func testEndpoint(_ path: String) {
        Task {
            guard let url = URL(string: viewModel.baseURL + path) else { return }
            if let (data, _) = try? await viewModel.authorizedData(from: url) {
                if let json = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: pretty, encoding: .utf8) {
                    rawResponseText = str
                } else {
                    rawResponseText = String(data: data, encoding: .utf8) ?? "Binary data"
                }
            } else {
                rawResponseText = "Error: Could not reach \(path)"
            }
        }
    }

    // advancedSection removed — content merged into generalSection

    // MARK: - Agent-Persönlichkeit

    @AppStorage("kobold.agent.personality") private var agentPersonality: String = ""
    @AppStorage("kobold.agent.soul") private var agentSoul: String = ""
    @AppStorage("kobold.agent.tone") private var agentTone: String = "freundlich"
    @AppStorage("kobold.agent.language") private var agentLanguage: String = "deutsch"
    @AppStorage("kobold.agent.verbosity") private var agentVerbosity: Double = 0.5

    @ViewBuilder
    private func agentPersonalitySection() -> some View {
        sectionTitle("Agent-Persönlichkeit")

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Soul.md — Kernidentität", systemImage: "heart.fill").font(.subheadline.bold())
                Text("Definiert wer der Agent im Kern ist. Grundlegende Werte, Identität und Verhaltensmuster.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $agentSoul)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if agentSoul.isEmpty {
                    Text("Leer = Standard-Persönlichkeit (KoboldOS)")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
            }.padding(6)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Personality.md — Verhaltensstil", systemImage: "theatermasks.fill").font(.subheadline.bold())
                Text("Beschreibt wie der Agent kommuniziert: Tonfall, Humor, Formalität, Eigenheiten.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $agentPersonality)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if agentPersonality.isEmpty {
                    Text("Leer = neutraler, hilfsbereiter Stil")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
            }.padding(6)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Kommunikation", systemImage: "bubble.left.and.bubble.right.fill").font(.subheadline.bold())

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tonfall").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $agentTone) {
                            Text("Freundlich").tag("freundlich")
                            Text("Professionell").tag("professionell")
                            Text("Locker").tag("locker")
                            Text("Direkt").tag("direkt")
                            Text("Humorvoll").tag("humorvoll")
                        }.pickerStyle(.menu).labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sprache").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $agentLanguage) {
                            Text("Deutsch").tag("deutsch")
                            Text("Englisch").tag("englisch")
                            Text("Auto").tag("auto")
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ausführlichkeit: \(String(format: "%.0f%%", agentVerbosity * 100))")
                        .font(.caption.bold()).foregroundColor(.secondary)
                    Slider(value: $agentVerbosity, in: 0...1, step: 0.1)
                        .tint(.koboldEmerald)
                    HStack {
                        Text("Kurz & knapp").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("Ausführlich").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }.padding(6)
        }
    }

    // MARK: - Memory Policy & Verhaltensregeln

    @AppStorage("kobold.agent.memoryPolicy") private var memoryPolicy: String = "auto"
    @AppStorage("kobold.agent.behaviorRules") private var behaviorRules: String = ""

    @ViewBuilder
    private func memoryPolicySection() -> some View {
        sectionTitle("Gedächtnis-Richtlinie")

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Memory Policy", systemImage: "brain.head.profile").font(.subheadline.bold())
                Text("Bestimmt wie der Agent mit Erinnerungen umgeht — automatisch lernen oder nur auf Anweisung.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("Richtlinie", selection: $memoryPolicy) {
                    Text("Automatisch lernen").tag("auto")
                    Text("Auf Nachfrage").tag("ask")
                    Text("Nur manuell").tag("manual")
                    Text("Deaktiviert").tag("disabled")
                }.pickerStyle(.segmented)

                switch memoryPolicy {
                case "auto":
                    Label("Agent speichert automatisch wichtige Fakten über dich und den Kontext.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.koboldEmerald)
                case "ask":
                    Label("Agent fragt dich bevor er etwas ins Gedächtnis schreibt.", systemImage: "questionmark.circle.fill")
                        .font(.caption).foregroundColor(.blue)
                case "manual":
                    Label("Nur du kannst Erinnerungen manuell hinzufügen.", systemImage: "hand.raised.fill")
                        .font(.caption).foregroundColor(.orange)
                case "disabled":
                    Label("Gedächtnis komplett deaktiviert — Agent merkt sich nichts.", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundColor(.red)
                default:
                    EmptyView()
                }
            }.padding(6)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Verhaltensregeln", systemImage: "list.bullet.clipboard.fill").font(.subheadline.bold())
                Text("Feste Regeln, die der Agent immer befolgen muss. Z.B. 'Antworte immer auf Deutsch', 'Frage bei Löschvorgängen immer nach'.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $behaviorRules)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if behaviorRules.isEmpty {
                    Text("Keine besonderen Regeln definiert — Standardverhalten.")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
                Text("Tipp: Jede Zeile = eine Regel. Der Agent sieht diese in jedem Gespräch.")
                    .font(.caption2).foregroundColor(.secondary)
            }.padding(6)
        }
    }

    // MARK: - Proaktive Einstellungen

    @StateObject private var proactiveEngine = ProactiveEngine.shared

    @ViewBuilder
    private func proactiveSettingsSection() -> some View {
        sectionTitle("Proaktive Vorschläge")

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Allgemein", systemImage: "lightbulb.fill").font(.subheadline.bold())

                Toggle("Proaktive Vorschläge aktivieren", isOn: $proactiveEngine.isEnabled)
                    .toggleStyle(.switch)
                    .tint(.koboldEmerald)

                HStack {
                    Text("Prüf-Intervall").font(.caption.bold()).foregroundColor(.secondary)
                    Picker("", selection: $proactiveEngine.checkIntervalMinutes) {
                        Text("5 Min").tag(5)
                        Text("10 Min").tag(10)
                        Text("30 Min").tag(30)
                        Text("60 Min").tag(60)
                    }.pickerStyle(.segmented).frame(maxWidth: 300)
                }
            }.padding(6)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Trigger-Typen", systemImage: "bell.badge.fill").font(.subheadline.bold())

                Toggle("Morgen-Briefing (08:00-09:00)", isOn: $proactiveEngine.morningBriefing)
                    .toggleStyle(.switch).tint(.koboldEmerald)
                Toggle("Tages-Zusammenfassung (17:00-18:00)", isOn: $proactiveEngine.eveningSummary)
                    .toggleStyle(.switch).tint(.koboldEmerald)
                Toggle("Fehler-Diagnose vorschlagen", isOn: $proactiveEngine.errorAlerts)
                    .toggleStyle(.switch).tint(.koboldEmerald)
                Toggle("System-Health-Warnungen", isOn: $proactiveEngine.systemHealth)
                    .toggleStyle(.switch).tint(.koboldEmerald)
            }.padding(6)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Benutzerdefinierte Regeln", systemImage: "list.bullet.rectangle").font(.subheadline.bold())
                    Spacer()
                    Button(action: {
                        let rule = ProactiveRule(id: UUID().uuidString, name: "Neue Regel",
                                                 triggerType: .timeOfDay, triggerValue: "12:00",
                                                 prompt: "Was soll ich tun?", enabled: true)
                        proactiveEngine.addRule(rule)
                    }) {
                        Label("Hinzufügen", systemImage: "plus")
                            .font(.caption)
                    }.buttonStyle(.bordered)
                }

                ForEach($proactiveEngine.rules) { $rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $rule.enabled)
                            .toggleStyle(.switch).labelsHidden().scaleEffect(0.7)
                            .tint(.koboldEmerald)
                            .onChange(of: rule.enabled) { proactiveEngine.saveRules() }

                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: $rule.name)
                                .font(.system(size: 12, weight: .medium))
                                .textFieldStyle(.plain)
                                .onSubmit { proactiveEngine.saveRules() }
                            TextField("Prompt", text: $rule.prompt)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .textFieldStyle(.plain)
                                .onSubmit { proactiveEngine.saveRules() }
                        }

                        Spacer()

                        Picker("", selection: $rule.triggerType) {
                            ForEach(ProactiveRule.TriggerType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }.pickerStyle(.menu).frame(width: 90)
                        .onChange(of: rule.triggerType) { proactiveEngine.saveRules() }

                        if rule.triggerType == .timeOfDay {
                            TextField("HH:MM", text: $rule.triggerValue)
                                .font(.system(size: 11, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .onSubmit { proactiveEngine.saveRules() }
                        }

                        if !ProactiveRule.defaults.contains(where: { $0.id == rule.id }) {
                            Button(action: { proactiveEngine.deleteRule(rule.id) }) {
                                Image(systemName: "trash").font(.caption).foregroundColor(.red.opacity(0.7))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }.padding(6)
        }
    }

    // MARK: - Über

    @ViewBuilder
    private func aboutSection() -> some View {
        sectionTitle("Über KoboldOS")

        // Big logo card
        GroupBox {
            HStack(spacing: 20) {
                Image(systemName: "lizard.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(
                        LinearGradient(colors: [.koboldGold, .koboldEmerald], startPoint: .top, endPoint: .bottom)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("KoboldOS").font(.title.bold())
                    Text("Alpha v0.2.3").font(.title3).foregroundColor(.koboldGold)
                    Text("Dein lokaler KI-Assistent für macOS")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Build-Info", systemImage: "info.circle").font(.subheadline.bold())
                infoRow("Version", "Alpha v0.2.3")
                infoRow("Build", "2026-02-22")
                infoRow("Swift", "6.0")
                infoRow("Plattform", "macOS 14+ (Sonoma)")
                infoRow("Backend", "Ollama \(viewModel.ollamaStatus)")
                infoRow("PID", "\(ProcessInfo.processInfo.processIdentifier)")
            }
            .padding()
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Credits", systemImage: "heart.fill").font(.subheadline.bold())
                Text("Entwickelt von der KoboldOS Community")
                Text("Powered by Ollama · Swift 6 · SwiftUI")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding()
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Links", systemImage: "link").font(.subheadline.bold())
                linkButton("Modellbibliothek (Ollama)", url: "https://ollama.ai/library")
                linkButton("GitHub", url: "https://github.com/FunkJood/KoboldOS")
                linkButton("Problem melden", url: "https://github.com/FunkJood/KoboldOS/issues")
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title2.bold()).padding(.bottom, 4)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 13))
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button(title) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        .buttonStyle(.link)
        .foregroundColor(.koboldEmerald)
    }

    private func cloudModels(for provider: String) -> [String] {
        switch provider {
        case "openai":    return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o1", "o3-mini"]
        case "anthropic": return ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-20250514"]
        case "groq":      return ["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"]
        default:          return []
        }
    }

    private func providerBadgeColor(_ provider: String) -> Color {
        switch provider {
        case "openai":    return .green
        case "anthropic": return .orange
        case "groq":      return .blue
        default:          return .gray
        }
    }

    private func loadModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        Task {
            let models = await viewModel.loadOllamaModels()
            ollamaModels = models
            agentsStore.ollamaModels = models
            if viewModel.activeOllamaModel.isEmpty, let first = models.first {
                viewModel.setActiveModel(first)
            }
            isLoadingModels = false
        }
    }

    private func installCLITools() {
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
                      ?? ProcessInfo.processInfo.arguments.first.map {
                          URL(fileURLWithPath: $0).deletingLastPathComponent().path
                      } ?? ""
        let koboldSrc = execDir + "/kobold"
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp '\(koboldSrc)' /usr/local/bin/kobold && chmod +x /usr/local/bin/kobold" with administrator privileges
        """
        if let scr = NSAppleScript(source: script) {
            var err: NSDictionary?
            scr.executeAndReturnError(&err)
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "koboldos-logs.txt"
        if panel.runModal() == .OK, let url = panel.url {
            let logs = "KoboldOS Alpha v0.2.3 — Logs\nPID: \(ProcessInfo.processInfo.processIdentifier)\nUptime: \(Date())\n"
            try? logs.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - AppStorage Toggle Helper

/// Creates a Binding<Bool> backed by @AppStorage without needing a @State
private func AppStorageToggle(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
    Binding(
        get: { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue },
        set: { UserDefaults.standard.set($0, forKey: key) }
    )
}
