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
    @State private var a2aConnectedClients: [A2AConnectedClient] = []

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

    // Google OAuth
    @AppStorage("kobold.google.clientId") private var googleClientId: String = ""
    @AppStorage("kobold.google.connected") private var googleConnected: Bool = false
    @State private var googleEmail: String = ""

    private let sections = ["Konto", "Allgemein", "Agent", "Modelle", "Gedächtnis", "Berechtigungen", "Datenschutz & Sicherheit", "Verbindungen", "Wetter", "Sprache", "Fähigkeiten", "Über"]

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
                    case "Agent":                    memoryPolicySection(); agentPersonalitySection()
                    case "Modelle":                  modelsSection()
                    case "Gedächtnis":               memorySettingsSection()
                    case "Berechtigungen":           permissionsSection()
                    case "Datenschutz & Sicherheit": securitySection()
                    case "Verbindungen":             connectionsSection()
                    case "Wetter":                   weatherSettingsSection()
                    case "Sprache":                  speechSettingsSection()
                    case "Fähigkeiten":              skillsSettingsSection()
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
        case "Berechtigungen":          return "shield.lefthalf.filled"
        case "Datenschutz & Sicherheit": return "lock.shield.fill"
        case "Verbindungen":            return "link.circle.fill"
        case "Wetter":                  return "cloud.sun.fill"
        case "Sprache":                 return "waveform"
        case "Fähigkeiten":            return "sparkles"
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
            .frame(maxHeight: .infinity, alignment: .top)

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
            .frame(maxHeight: .infinity, alignment: .top)
            settingsSaveButton(section: "Konto")
        }
    }

    // MARK: - Allgemein

    @ViewBuilder
    private func generalSection() -> some View {
        sectionTitle("Allgemeine Einstellungen")

        // Sprache + Updates nebeneinander
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Sprache", systemImage: "globe").font(.subheadline.bold())
                    Text("Interface- und Antwortsprache.")
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
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Updates", systemImage: "arrow.down.circle.fill").font(.subheadline.bold())

                    HStack {
                        Text("Version")
                        Spacer()
                        Text("Alpha v\(UpdateManager.currentVersion)")
                            .foregroundColor(.koboldEmerald).fontWeight(.medium)
                    }

                    Toggle("Auto-Check beim Start", isOn: $autoCheckUpdates)
                        .toggleStyle(.switch)

                    switch updateManager.state {
                    case .idle:
                        EmptyView()
                    case .checking:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Suche…").font(.caption).foregroundColor(.secondary)
                        }
                    case .upToDate:
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Aktuell").font(.caption).foregroundColor(.green)
                        }
                    case .available(let version):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill").foregroundColor(.koboldGold)
                                Text("v\(version) verfügbar")
                                    .font(.caption).fontWeight(.medium).foregroundColor(.koboldGold)
                            }
                            if let notes = updateManager.releaseNotes, !notes.isEmpty {
                                Text(notes).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(3)
                            }
                            Button("Installieren") {
                                Task { await updateManager.downloadAndInstall() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.koboldEmerald)
                            .controlSize(.small)
                        }
                    case .downloading(let percent):
                        ProgressView(value: percent).tint(.koboldEmerald)
                    case .installing:
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Installiere…").font(.caption).foregroundColor(.koboldGold)
                        }
                    case .error(let msg):
                        Text(msg).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
                    }

                    Button("Nach Updates suchen") {
                        Task { await updateManager.checkForUpdates() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateManager.state == .checking)
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // Row 1: Verbindung + Darstellung + Sounds
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
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Darstellung", systemImage: "paintbrush.fill").font(.subheadline.bold())
                    Toggle("Erweiterte Statistiken", isOn: $showAdvancedStats)
                        .toggleStyle(.switch)
                    Toggle("Medien automatisch einbetten", isOn: AppStorageToggle("kobold.chat.autoEmbed", default: true))
                        .toggleStyle(.switch)
                    Text("Bilder, Audio und Videos in Agent-Antworten inline anzeigen.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sounds", systemImage: "speaker.wave.2.fill").font(.subheadline.bold())
                    Toggle("Systemsounds", isOn: $soundsEnabled)
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
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // Row 2: Arbeitsverzeichnis
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Standard-Arbeitsverzeichnis", systemImage: "folder.fill").font(.subheadline.bold())
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

        // Row 3: Menüleiste + Autostart + Einrichtungsassistent + Debug (4 columns)
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Menüleiste", systemImage: "menubar.rectangle").font(.subheadline.bold())
                    Toggle("Anzeigen", isOn: Binding(
                        get: { menuBarEnabled },
                        set: { enabled in
                            if enabled { MenuBarController.shared.enable() }
                            else { MenuBarController.shared.disable() }
                            menuBarEnabled = enabled
                        }
                    ))
                    .toggleStyle(.switch)
                    if menuBarEnabled {
                        Toggle("Minimieren", isOn: $menuBarHideOnClose)
                            .toggleStyle(.switch)
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)

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
                        Label("Genehmigung nötig", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Onboarding", systemImage: "wand.and.stars").font(.subheadline.bold())
                    Text("Wizard erneut zeigen")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Zurücksetzen") {
                        UserDefaults.standard.set(false, forKey: "kobold.hasOnboarded")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Debug", systemImage: "ladybug.fill").font(.subheadline.bold())
                    Toggle("Verbose Logging",
                           isOn: AppStorageToggle("kobold.log.verbose", default: false))
                        .toggleStyle(.switch)
                    Toggle("Raw Prompts",
                           isOn: AppStorageToggle("kobold.dev.showRawPrompts", default: false))
                        .toggleStyle(.switch)
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)
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

        // Quick Model Downloads
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Empfohlene Modelle", systemImage: "arrow.down.circle.fill").font(.subheadline.bold())
                Text("Lade die empfohlenen Modelle mit einem Klick herunter.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 12) {
                    // Chat model
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: ModelDownloadManager.shared.chatModelInstalled ? "checkmark.circle.fill" : "cpu.fill")
                                .foregroundColor(ModelDownloadManager.shared.chatModelInstalled ? .koboldEmerald : .koboldGold)
                            Text("Chat: \(ModelDownloadManager.shared.recommendedChatModel)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        if ModelDownloadManager.shared.isDownloadingChat {
                            GlassProgressBar(value: ModelDownloadManager.shared.chatProgress, label: ModelDownloadManager.shared.chatStatus)
                        } else if !ModelDownloadManager.shared.chatModelInstalled {
                            Button("Herunterladen") { ModelDownloadManager.shared.downloadChatModel() }
                                .buttonStyle(.bordered)
                        } else {
                            Text("Installiert").font(.caption).foregroundColor(.koboldEmerald)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(height: 40)

                    // SD model
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: ModelDownloadManager.shared.sdModelInstalled ? "checkmark.circle.fill" : "photo.fill")
                                .foregroundColor(ModelDownloadManager.shared.sdModelInstalled ? .koboldEmerald : .purple)
                            Text("Bild: Stable Diffusion 2.1")
                                .font(.system(size: 12, weight: .medium))
                        }
                        if ModelDownloadManager.shared.isDownloadingSD {
                            GlassProgressBar(value: ModelDownloadManager.shared.sdProgress, label: ModelDownloadManager.shared.sdStatus)
                        } else if !ModelDownloadManager.shared.sdModelInstalled {
                            Button("Herunterladen (~1.5 GB)") { ModelDownloadManager.shared.downloadSDModel() }
                                .buttonStyle(.bordered)
                        } else {
                            Text("Installiert").font(.caption).foregroundColor(.koboldEmerald)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = ModelDownloadManager.shared.lastError {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                Divider()

                HStack(spacing: 12) {
                    Button(action: { ModelDownloadManager.shared.openModelsFolder() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                            Text("Modell-Ordner öffnen")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Öffnet den Ordner mit heruntergeladenen Modellen — hier kannst du Modelle manuell austauschen")

                    Text("Eigene CoreML-Modelle in den Ordner legen, um sie zu verwenden.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
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
        // macOS System-Berechtigungen (zusammengelegt)
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("macOS System-Berechtigungen", systemImage: "apple.logo").font(.subheadline.bold())
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

        // Custom blacklist + whitelist
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Benutzerdefinierte Blacklist", systemImage: "xmark.shield.fill").font(.subheadline.bold())
                    Text("Zusätzlich blockierte Befehle (kommagetrennt).")
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
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Benutzerdefinierte Whitelist", systemImage: "checkmark.shield.fill").font(.subheadline.bold())
                    Text("Zusätzlich erlaubte Befehle (kommagetrennt).")
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
            .frame(maxHeight: .infinity, alignment: .top)
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

    // (A2A section moved into connectionsSection above)

    private func a2aPermToggle(title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isOn.wrappedValue ? color : .secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 11))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(color)
                .controlSize(.small)
        }
    }

    // MARK: - Verbindungen

    @AppStorage("kobold.notificationChannel") private var notificationChannel: String = "gui"
    @State private var iMessageAvailable: Bool = false

    // MARK: - Weather Settings

    @StateObject private var weatherMgr = WeatherManager.shared

    @ViewBuilder
    private func weatherSettingsSection() -> some View {
        sectionTitle("Wetter-Widget")

        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeader(title: "OpenWeatherMap", icon: "cloud.sun.fill")

                VStack(alignment: .leading, spacing: 6) {
                    Text("API-Key").font(.caption).foregroundColor(.secondary)
                    GlassTextField(text: $weatherMgr.apiKey, placeholder: "OpenWeatherMap API-Key eingeben")
                    Text("Kostenlos auf openweathermap.org erhältlich")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Standort (Stadt)").font(.caption).foregroundColor(.secondary)
                    GlassTextField(text: $weatherMgr.manualCity, placeholder: "z.B. Stuttgart (leer = automatisch)")
                    Text("Leer lassen für automatische Standortbestimmung")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    GlassButton(title: "Wetter abrufen", icon: "arrow.clockwise", isPrimary: true) {
                        weatherMgr.fetchWeather()
                    }

                    if let temp = weatherMgr.temperature {
                        HStack(spacing: 6) {
                            Image(systemName: weatherMgr.iconName)
                                .foregroundColor(.koboldGold)
                            Text(String(format: "%.0f°C", temp))
                                .font(.system(size: 14, weight: .semibold))
                            if !weatherMgr.cityName.isEmpty {
                                Text(weatherMgr.cityName)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    if let error = weatherMgr.lastError {
                        Text(error)
                            .font(.caption).foregroundColor(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionsSection() -> some View {
        sectionTitle("Verbindungen")

        // Standardnachrichtenkanal
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Standardnachrichtenkanal", systemImage: "bell.badge.fill").font(.subheadline.bold())
                Text("Wähle wo Updates und Benachrichtigungen ankommen.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("Kanal", selection: $notificationChannel) {
                    Label("GUI (Standard)", systemImage: "desktopcomputer").tag("gui")
                    Label("Telegram", systemImage: "paperplane.fill").tag("telegram")
                    Label("GUI + Telegram", systemImage: "bell.and.waves.left.and.right.fill").tag("both")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)

                if notificationChannel.contains("telegram") || notificationChannel == "both" {
                    if !telegramRunning {
                        Label("Telegram-Bot ist nicht aktiv — konfiguriere ihn weiter unten.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
            }
            .padding()
        }

        // Row 1: Google + SoundCloud
        HStack(alignment: .top, spacing: 12) {
            googleOAuthSection()
            soundCloudOAuthSection()
        }

        // Row 2: iMessage + Telegram
        HStack(alignment: .top, spacing: 12) {
            iMessageSection()
            telegramSection()
        }

        // Row 3: WebApp-Server + Cloudflare Tunnel
        HStack(alignment: .top, spacing: 12) {
            webAppSection()
            cloudflareTunnelSection()
        }

        // Weitere Integrationen
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Weitere Integrationen", systemImage: "puzzlepiece.extension.fill").font(.subheadline.bold())
                Text("Kommende Verbindungen — du kannst bereits jetzt APIs über das Shell- und Web-Tool nutzen.")
                    .font(.caption).foregroundColor(.secondary)
            }.padding()
        }

        let connectionItems: [(String, AnyView, Color, String, Bool)] = [
            ("GitHub",      AnyView(brandLogoGitHub), .purple,   "Repos, Issues, PRs",          true),
            ("Microsoft",   AnyView(brandLogoMicrosoft), .blue,  "OneDrive, Outlook, Teams",     true),
            ("Hugging Face",AnyView(brandLogoHuggingFace), .orange, "AI-Inference, Modelle",     true),
            ("Slack",       AnyView(brandLogoSlack), .green,     "Nachrichten, Kanäle",          true),
            ("Notion",      AnyView(brandLogoNotion), .primary,  "Seiten lesen/bearbeiten",      true),
            ("Discord",     AnyView(brandLogoDiscord), .indigo,  "Server, Nachrichten",          false),
            ("Dropbox",     AnyView(brandLogoDropbox), .cyan,    "Dateien synchronisieren",      false),
            ("Spotify",     AnyView(brandLogoSpotify), .green,   "Playlists, Wiedergabe",        false),
            ("Linear",      AnyView(brandLogoLinear), .purple,   "Issues, Projekte",             false),
            ("Todoist",     AnyView(brandLogoTodoist), .red,     "Tasks, Projekte",              false),
            ("LinkedIn",    AnyView(brandLogoLinkedIn), .blue,   "Profil, Netzwerk",             false),
        ]

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(connectionItems, id: \.0) { item in
                GroupBox {
                    HStack(spacing: 8) {
                        item.1
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0)
                                .font(.system(size: 12, weight: .semibold))
                            Text(item.3)
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(4)
                    .frame(minHeight: 36)
                }
                .overlay(alignment: .topTrailing) {
                    Text(item.4 ? "Phase 1" : "Geplant")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(item.4 ? .koboldEmerald : .secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill((item.4 ? Color.koboldEmerald : Color.secondary).opacity(0.15)))
                        .padding(6)
                }
                .opacity(item.4 ? 0.75 : 0.45)
            }
        }

        // MARK: - A2A (Agent-to-Agent) — unter Verbindungen

        sectionTitle("Agent-to-Agent (A2A)")

        // Row: A2A Server + Berechtigungen
        HStack(alignment: .top, spacing: 12) {
            // A2A Server Card
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(
                                LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A2A Server").font(.system(size: 15, weight: .bold))
                            Text("Agent-zu-Agent Protokoll").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if a2aEnabled {
                            HStack(spacing: 5) {
                                Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                                Text("Aktiv").font(.system(size: 10, weight: .semibold)).foregroundColor(.koboldEmerald)
                            }
                        }
                    }

                    Divider().opacity(0.5)

                    Toggle("A2A aktivieren", isOn: $a2aEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)

                    HStack(spacing: 8) {
                        Text("Port:").font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("8081", value: $a2aPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .font(.system(.caption, design: .monospaced))
                    }

                    if a2aEnabled {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 6, height: 6)
                            Text("http://localhost:\(a2aPort)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.koboldEmerald)
                                .textSelection(.enabled)
                        }

                        // Verbundene Clients
                        if !a2aConnectedClients.isEmpty {
                            Divider().opacity(0.3)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Verbundene Clients (\(a2aConnectedClients.count))")
                                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                ForEach(a2aConnectedClients, id: \.id) { client in
                                    HStack(spacing: 8) {
                                        Circle().fill(Color.koboldEmerald).frame(width: 5, height: 5)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(client.name)
                                                .font(.system(size: 11, weight: .medium))
                                            Text(client.url)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(client.lastSeen)
                                            .font(.system(size: 9)).foregroundColor(.secondary)
                                        Button(action: {
                                            a2aConnectedClients.removeAll { $0.id == client.id }
                                            // Notify daemon to reject this client
                                            NotificationCenter.default.post(
                                                name: Notification.Name("koboldA2AKickClient"),
                                                object: client.id
                                            )
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Client trennen")
                                    }
                                }
                            }
                        } else {
                            Text("Keine Clients verbunden")
                                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("koboldA2AClientConnected"))) { notif in
                if let info = notif.userInfo,
                   let id = info["id"] as? String,
                   let name = info["name"] as? String,
                   let url = info["url"] as? String {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    let client = A2AConnectedClient(id: id, name: name, url: url, lastSeen: formatter.string(from: Date()))
                    if !a2aConnectedClients.contains(where: { $0.id == id }) {
                        a2aConnectedClients.append(client)
                    } else {
                        // Update last seen
                        if let idx = a2aConnectedClients.firstIndex(where: { $0.id == id }) {
                            a2aConnectedClients[idx].lastSeen = formatter.string(from: Date())
                        }
                    }
                }
            }

            // Berechtigungen Card
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(
                                LinearGradient(colors: [Color.orange, Color.red], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A2A Berechtigungen").font(.system(size: 15, weight: .bold))
                            Text("Zugriff externer Agenten").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    Divider().opacity(0.5)

                    VStack(spacing: 6) {
                        a2aPermToggle(title: "Tools nutzen", icon: "wrench.fill", color: .koboldGold, isOn: $a2aAllowTools)
                        a2aPermToggle(title: "Gedächtnis lesen", icon: "brain.fill", color: .cyan, isOn: $a2aAllowMemoryRead)
                        a2aPermToggle(title: "Gedächtnis schreiben", icon: "brain.head.profile", color: .orange, isOn: $a2aAllowMemoryWrite)
                        a2aPermToggle(title: "Dateizugriff", icon: "folder.fill", color: .blue, isOn: $a2aAllowFiles)
                        a2aPermToggle(title: "Shell-Zugriff", icon: "terminal.fill", color: .red, isOn: $a2aAllowShell)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        // Row: Token-Austausch + Vertrauenswürdige Agenten
        HStack(alignment: .top, spacing: 12) {
            // Token Exchange
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Schnellverbindung (Token)", systemImage: "link.badge.plus").font(.subheadline.bold())

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dein Token").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("Token...", text: $a2aToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10, design: .monospaced))
                                .disabled(true)
                            Button("Generieren") {
                                a2aToken = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24).description
                            }
                            .buttonStyle(.borderedProminent).tint(.koboldEmerald).controlSize(.small)
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(a2aToken, forType: .string)
                            }) {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(a2aToken.isEmpty)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remote-Token").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("Token einfügen...", text: $a2aRemoteToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10, design: .monospaced))
                            Button("Verbinden") {
                                if !a2aRemoteToken.isEmpty {
                                    let existing = a2aTrustedAgents.trimmingCharacters(in: .whitespacesAndNewlines)
                                    a2aTrustedAgents = existing.isEmpty ? a2aRemoteToken : existing + "\n" + a2aRemoteToken
                                    a2aRemoteToken = ""
                                }
                            }
                            .buttonStyle(.borderedProminent).tint(.koboldGold).controlSize(.small)
                            .disabled(a2aRemoteToken.isEmpty)
                        }
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)

            // Vertrauenswürdige Agenten
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Vertrauenswürdige Agenten", systemImage: "checkmark.shield.fill").font(.subheadline.bold())
                    Text("URLs/Tokens die sich ohne Bestätigung verbinden dürfen (eine pro Zeile).")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $a2aTrustedAgents)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 60)
                        .padding(4)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                        .scrollContentBackground(.hidden)
                    Text("z.B. http://192.168.1.100:8081")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        settingsSaveButton(section: "A2A")
    }

    // MARK: - Brand Logos (SwiftUI drawn)

    private var brandLogoGoogle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            // Google multi-color "G"
            Text("G")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color(red: 0.918, green: 0.259, blue: 0.208), Color(red: 0.984, green: 0.737, blue: 0.02), Color(red: 0.204, green: 0.659, blue: 0.325), Color(red: 0.259, green: 0.522, blue: 0.957)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var brandLogoSoundCloud: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.333, blue: 0.0)) // SoundCloud orange
            // Cloud + sound waves
            Image(systemName: "cloud.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoTelegram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(colors: [Color(red: 0.165, green: 0.733, blue: 0.914), Color(red: 0.114, green: 0.584, blue: 0.843)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Image(systemName: "paperplane.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .offset(x: -1, y: 1)
        }
    }

    private var brandLogoIMessage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(colors: [Color(red: 0.208, green: 0.824, blue: 0.341), Color(red: 0.118, green: 0.706, blue: 0.267)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Image(systemName: "message.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoGitHub: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.14, green: 0.15, blue: 0.16))
            // Octocat approximation
            Image(systemName: "cat.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoMicrosoft: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            // 4 colored squares
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    Rectangle().fill(Color(red: 0.953, green: 0.318, blue: 0.212)).frame(width: 9, height: 9)
                    Rectangle().fill(Color(red: 0.502, green: 0.725, blue: 0.055)).frame(width: 9, height: 9)
                }
                HStack(spacing: 1) {
                    Rectangle().fill(Color(red: 0.004, green: 0.467, blue: 0.839)).frame(width: 9, height: 9)
                    Rectangle().fill(Color(red: 1.0, green: 0.733, blue: 0.016)).frame(width: 9, height: 9)
                }
            }
        }
    }

    private var brandLogoHuggingFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.827, blue: 0.0))
            Text("🤗")
                .font(.system(size: 18))
        }
    }

    private var brandLogoSlack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.286, green: 0.114, blue: 0.333))
            Image(systemName: "number")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoNotion: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            Text("N")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundColor(.black)
        }
    }

    private var brandLogoDiscord: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.345, green: 0.396, blue: 0.949))
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoDropbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.004, green: 0.388, blue: 1.0))
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoSpotify: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.118, green: 0.843, blue: 0.376))
            // 3 sound waves
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black)
                        .frame(width: CGFloat(18 - i * 3), height: 2.5)
                        .rotationEffect(.degrees(-10))
                }
            }
        }
    }

    private var brandLogoLinear: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(colors: [Color(red: 0.353, green: 0.329, blue: 1.0), Color(red: 0.533, green: 0.314, blue: 0.969)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoTodoist: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.882, green: 0.286, blue: 0.243))
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoLinkedIn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.0, green: 0.467, blue: 0.71))
            Text("in")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundColor(.white)
        }
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
            .frame(maxHeight: .infinity, alignment: .top)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Auto-Speichern", systemImage: "arrow.clockwise").font(.subheadline.bold())
                    Toggle("Automatisch sichern", isOn: AppStorageToggle("kobold.memory.autosave", default: true))
                        .toggleStyle(.switch)
                    Text("Speichert bei jeder Aktualisierung.").font(.caption).foregroundColor(.secondary)
                }
                .padding()
            }
            .frame(maxHeight: .infinity, alignment: .top)
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

        // MARK: Proaktive Vorschläge (ehemals eigener Reiter)
        sectionTitle("Proaktive Vorschläge")

        HStack(alignment: .top, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Allgemein", systemImage: "lightbulb.fill").font(.subheadline.bold())

                    Toggle("Proaktive Vorschläge aktivieren", isOn: $proactiveEngine.isEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)

                    Toggle("Agent darf eigenständig anschreiben", isOn: AppStorageToggle("kobold.proactive.allowInitiate", default: false))
                        .toggleStyle(.switch)
                        .tint(.koboldGold)
                    Text("Agent darf von sich aus Nachrichten senden, z.B. Erinnerungen oder Hinweise.")
                        .font(.caption2).foregroundColor(.secondary)

                    HStack {
                        Text("Prüf-Intervall").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $proactiveEngine.checkIntervalMinutes) {
                            Text("5 Min").tag(5)
                            Text("10 Min").tag(10)
                            Text("30 Min").tag(30)
                            Text("60 Min").tag(60)
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                }.padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)

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
                }.padding()
            }
            .frame(maxWidth: .infinity, alignment: .top)
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
            }.padding()
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
    private func webAppSection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(
                            LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        Image(systemName: "globe")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WebApp-Server").font(.system(size: 15, weight: .bold))
                        Text("Fernsteuerung im Browser").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if webAppRunning {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Aktiv").font(.system(size: 10, weight: .semibold)).foregroundColor(.koboldEmerald)
                        }
                    }
                }

                Divider().opacity(0.5)

                Toggle("WebApp aktivieren", isOn: $webAppEnabled)
                    .toggleStyle(.switch)
                    .tint(.koboldEmerald)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Port").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            TextField("Port", value: $webAppPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Benutzer").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            TextField("Benutzer", text: $webAppUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Passwort").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        SecureField("Passwort", text: $webAppPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if webAppPassword.isEmpty {
                    Label("Passwort setzen", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }

                HStack(spacing: 8) {
                    if webAppEnabled && !webAppPassword.isEmpty {
                        Button(webAppRunning ? "Stoppen" : "Starten") {
                            if webAppRunning {
                                WebAppServer.shared.stop()
                                webAppRunning = false
                                tunnelRunning = false
                                tunnelURL = ""
                            } else {
                                let dPort = UserDefaults.standard.integer(forKey: "kobold.port")
                                let dToken = RuntimeManager.shared.authToken
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
                        .controlSize(.small)
                    }

                    if webAppRunning {
                        Button("Öffnen") {
                            if let url = URL(string: "http://localhost:\(webAppPort)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if webAppRunning {
                    HStack(spacing: 6) {
                        Circle().fill(Color.koboldEmerald).frame(width: 6, height: 6)
                        Text("http://localhost:\(webAppPort)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            webAppRunning = WebAppServer.shared.isRunning
        }
    }

    @ViewBuilder
    private func cloudflareTunnelSection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(
                            LinearGradient(colors: [Color(red: 0.96, green: 0.65, blue: 0.14), Color(red: 0.96, green: 0.45, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        Image(systemName: "network")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloudflare Tunnel").font(.system(size: 15, weight: .bold))
                        Text("Sicherer Internet-Zugang").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if tunnelRunning && !tunnelURL.isEmpty {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Verbunden").font(.system(size: 10, weight: .semibold)).foregroundColor(.koboldEmerald)
                        }
                    }
                }

                Divider().opacity(0.5)

                if !cloudflaredInstalled {
                    VStack(alignment: .leading, spacing: 8) {
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
                    HStack(spacing: 8) {
                        Button(tunnelRunning ? "Stoppen" : "Starten") {
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
                        .controlSize(.small)

                        if tunnelRunning && tunnelURL.isEmpty {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Erstelle...").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    if !tunnelURL.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Circle().fill(Color.blue).frame(width: 6, height: 6)
                                Text(tunnelURL)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 6) {
                                Button("Kopieren") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tunnelURL, forType: .string)
                                }
                                .buttonStyle(.bordered).controlSize(.small)

                                Button("Öffnen") {
                                    if let url = URL(string: tunnelURL) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }

                            // QR Code
                            if let qrImage = generateQRCode(from: tunnelURL) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("QR-Code:").font(.system(size: 10)).foregroundColor(.secondary)
                                    Image(nsImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 120, height: 120)
                                        .background(Color.white)
                                        .cornerRadius(8)
                                }
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
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            cloudflaredInstalled = WebAppServer.isCloudflaredInstalled()
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

    // MARK: - Google OAuth

    @State private var googleSetupExpanded = false

    @ViewBuilder
    private func googleOAuthSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoGoogle),
            name: "Google",
            subtitle: "Drive, Gmail, YouTube, Kalender",
            isConnected: googleConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    if !googleEmail.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 16)).foregroundColor(.secondary)
                            Text(googleEmail)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    let activeScopes = GoogleOAuth.shared.enabledScopes
                    if !activeScopes.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(activeScopes).sorted(by: { $0.label < $1.label }), id: \.self) { scope in
                                Text(scope.label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            }
                        }
                    }
                    Button("Abmelden") {
                        Task {
                            await GoogleOAuth.shared.signOut()
                            googleConnected = false
                            googleEmail = ""
                        }
                    }
                    .buttonStyle(.bordered).foregroundColor(.red).controlSize(.small)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    Button(action: { GoogleOAuth.shared.signIn() }) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color.white).frame(width: 24, height: 24)
                                Text("G").font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(Color(red: 0.259, green: 0.522, blue: 0.957))
                            }
                            Text("Sign in with Google")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        }
                        .padding(.leading, 4).padding(.trailing, 14).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.259, green: 0.522, blue: 0.957)))
                    }
                    .buttonStyle(.plain)
                    scopeSelectionView
                })
            }
        )
        .onAppear {
            googleConnected = GoogleOAuth.shared.isConnected
            googleEmail = GoogleOAuth.shared.userEmail
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            googleConnected = GoogleOAuth.shared.isConnected
            googleEmail = GoogleOAuth.shared.userEmail
        }
    }

    // MARK: - Google Scope Selection

    @ViewBuilder
    private var scopeSelectionView: some View {
        DisclosureGroup("Berechtigungen wählen") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(GoogleScope.allCases, id: \.self) { scope in
                    let isEnabled = GoogleOAuth.shared.enabledScopes.contains(scope)
                    Button(action: {
                        var scopes = GoogleOAuth.shared.enabledScopes
                        if isEnabled { scopes.remove(scope) } else { scopes.insert(scope) }
                        GoogleOAuth.shared.enabledScopes = scopes
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundColor(isEnabled ? .koboldEmerald : .secondary)
                            Text(scope.label)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            Text("Änderungen werden bei der nächsten Anmeldung wirksam.")
                .font(.system(size: 9)).foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - SoundCloud OAuth

    @AppStorage("kobold.soundcloud.connected") private var soundCloudConnected: Bool = false
    @State private var soundCloudUser: String = ""

    @ViewBuilder
    private func soundCloudOAuthSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoSoundCloud),
            name: "SoundCloud",
            subtitle: "Tracks, Playlists, Likes, Suche",
            isConnected: soundCloudConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    if !soundCloudUser.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 16)).foregroundColor(.secondary)
                            Text(soundCloudUser)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Button("Abmelden") {
                        Task {
                            await SoundCloudOAuth.shared.signOut()
                            soundCloudConnected = false
                            soundCloudUser = ""
                        }
                    }
                    .buttonStyle(.bordered).foregroundColor(.red).controlSize(.small)
                })
            },
            signInButton: {
                AnyView(
                    Button(action: { SoundCloudOAuth.shared.signIn() }) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color.white).frame(width: 24, height: 24)
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(red: 1.0, green: 0.333, blue: 0.0))
                            }
                            Text("Sign in with SoundCloud")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        }
                        .padding(.leading, 4).padding(.trailing, 14).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 1.0, green: 0.333, blue: 0.0)))
                    }
                    .buttonStyle(.plain)
                )
            }
        )
        .onAppear {
            soundCloudConnected = SoundCloudOAuth.shared.isConnected
            soundCloudUser = SoundCloudOAuth.shared.userName
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            soundCloudConnected = SoundCloudOAuth.shared.isConnected
            soundCloudUser = SoundCloudOAuth.shared.userName
        }
    }

    // MARK: - iMessage

    @AppStorage("kobold.imessage.enabled") private var iMessageEnabled: Bool = false

    @ViewBuilder
    private func iMessageSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoIMessage),
            name: "iMessage",
            subtitle: "Nachrichten lesen & senden",
            isConnected: iMessageAvailable && iMessageEnabled,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundColor(.koboldEmerald)
                        Text("Automation-Berechtigung erteilt")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Text("Der Agent kann über AppleScript Nachrichten lesen und senden.")
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    Toggle("iMessage aktiviert", isOn: $iMessageEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)
                        .font(.system(size: 12))
                        .onChange(of: iMessageEnabled) {
                            if !iMessageEnabled { iMessageAvailable = false }
                        }
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    Text("Aktiviere iMessage um deinem Agent Zugriff auf Nachrichten zu geben. macOS fragt nach Automation-Berechtigung.")
                        .font(.system(size: 11)).foregroundColor(.secondary)

                    Toggle("iMessage aktivieren", isOn: Binding(
                        get: { iMessageEnabled },
                        set: { newVal in
                            if newVal {
                                // Trigger macOS permission prompt
                                requestIMessageAccess()
                            }
                            iMessageEnabled = newVal
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color(red: 0.208, green: 0.824, blue: 0.341))
                    .font(.system(size: 12))

                    if iMessageEnabled && !iMessageAvailable {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundColor(.orange)
                            Text("Berechtigung noch nicht erteilt")
                                .font(.system(size: 10)).foregroundColor(.orange)
                        }
                        Button("Systemeinstellungen öffnen") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                    }
                })
            }
        )
        .onAppear {
            if iMessageEnabled { checkIMessageAvailability() }
        }
    }

    private func checkIMessageAvailability() {
        let script = NSAppleScript(source: "tell application \"Messages\" to count of every chat")
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        iMessageAvailable = (errorInfo == nil)
    }

    private func requestIMessageAccess() {
        // This triggers the macOS automation permission dialog
        let script = NSAppleScript(source: "tell application \"Messages\" to count of every chat")
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        iMessageAvailable = (errorInfo == nil)
    }

    // MARK: - Telegram Bot

    @AppStorage("kobold.telegram.token") private var telegramToken: String = ""
    @AppStorage("kobold.telegram.chatId") private var telegramChatId: String = ""
    @State private var telegramRunning = false
    @State private var telegramBotName = ""
    @State private var telegramStats: (received: Int, sent: Int) = (0, 0)

    @ViewBuilder
    private func telegramSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoTelegram),
            name: "Telegram",
            subtitle: "Bot-Chat von unterwegs",
            isConnected: telegramRunning,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    if !telegramBotName.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 16)).foregroundColor(.secondary)
                            Text("@\(telegramBotName)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.koboldEmerald)
                        }
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.received)").font(.system(size: 16, weight: .bold)).foregroundColor(.koboldEmerald)
                            Text("Empfangen").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.sent)").font(.system(size: 16, weight: .bold)).foregroundColor(.blue)
                            Text("Gesendet").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                    Button("Bot stoppen") {
                        TelegramBot.shared.stop()
                        telegramRunning = false
                        telegramBotName = ""
                    }
                    .buttonStyle(.bordered).foregroundColor(.red).controlSize(.small)
                    .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                        telegramStats = TelegramBot.shared.stats
                        if telegramBotName.isEmpty {
                            telegramBotName = TelegramBot.shared.botUsername
                        }
                    }
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bot-Token").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        SecureField("123456:ABC-DEF1234...", text: $telegramToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chat-ID (optional)").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        TextField("123456789", text: $telegramChatId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    Button(action: {
                        guard !telegramToken.isEmpty else { return }
                        let chatId = Int64(telegramChatId) ?? 0
                        TelegramBot.shared.start(token: telegramToken, allowedChatId: chatId)
                        telegramRunning = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            telegramBotName = TelegramBot.shared.botUsername
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "paperplane.fill").font(.system(size: 12))
                            Text("Bot starten").font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(
                            LinearGradient(colors: [Color(red: 0.165, green: 0.733, blue: 0.914), Color(red: 0.114, green: 0.584, blue: 0.843)],
                                           startPoint: .leading, endPoint: .trailing)
                        ))
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(telegramToken.isEmpty)
                })
            }
        )
        .onAppear {
            telegramRunning = TelegramBot.shared.isRunning
            telegramBotName = TelegramBot.shared.botUsername
        }
    }

    // MARK: - Connection Card Template

    @ViewBuilder
    private func connectionCard(
        logo: AnyView,
        name: String,
        subtitle: String,
        isConnected: Bool,
        connectedDetail: () -> AnyView,
        signInButton: () -> AnyView
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 10) {
                    logo.frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 15, weight: .bold))
                        Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if isConnected {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Verbunden").font(.system(size: 10, weight: .semibold)).foregroundColor(.koboldEmerald)
                        }
                    }
                }

                Divider().opacity(0.5)

                if isConnected {
                    connectedDetail()
                } else {
                    signInButton()
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Flow Layout (for scope tags)

    private struct FlowLayout: Layout {
        var spacing: CGFloat = 4

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            return CGSize(width: maxWidth, height: currentY + lineHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var currentX: CGFloat = bounds.minX
            var currentY: CGFloat = bounds.minY
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                    currentX = bounds.minX
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
        }
    }

    // MARK: - Sprache (TTS / STT)

    @AppStorage("kobold.tts.voice") private var ttsVoice: String = "de-DE"
    @AppStorage("kobold.tts.rate") private var ttsRate: Double = 0.5
    @AppStorage("kobold.tts.volume") private var ttsVolume: Double = 0.8
    @AppStorage("kobold.tts.autoSpeak") private var ttsAutoSpeak: Bool = false
    @State private var ttsTestText: String = "Hallo! Ich bin dein KoboldOS Assistent."

    @ViewBuilder
    private func speechSettingsSection() -> some View {
        sectionTitle("Sprache")

        // TTS Section
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Text-to-Speech", systemImage: "speaker.wave.3.fill").font(.subheadline.bold())
                Text("Der Agent kann Texte laut vorlesen. Nutze 'lies vor' oder 'sag mir' im Chat.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Agent-Antworten automatisch vorlesen", isOn: $ttsAutoSpeak)
                    .toggleStyle(.switch)
                    .tint(.koboldEmerald)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stimme / Sprache").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $ttsVoice) {
                            ForEach(TTSManager.availableLanguages, id: \.self) { lang in
                                Text(lang).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Geschwindigkeit: \(String(format: "%.1f", ttsRate))").font(.caption.bold()).foregroundColor(.secondary)
                        Slider(value: $ttsRate, in: 0.1...1.0, step: 0.05)
                            .tint(.koboldEmerald)
                            .frame(width: 150)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lautstärke: \(String(format: "%.0f%%", ttsVolume * 100))").font(.caption.bold()).foregroundColor(.secondary)
                        Slider(value: $ttsVolume, in: 0.0...1.0, step: 0.05)
                            .tint(.koboldEmerald)
                            .frame(width: 150)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Testtext...", text: $ttsTestText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Button {
                        TTSManager.shared.speak(ttsTestText, voice: ttsVoice, rate: Float(ttsRate))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("Test").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.koboldEmerald)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    if TTSManager.shared.isSpeaking {
                        Button(action: { TTSManager.shared.stop() }) {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
            }
            .padding()
        }

        // STT Section
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Speech-to-Text (Whisper)", systemImage: "mic.fill").font(.subheadline.bold())
                Text("Sprachnachrichten und Audio-Dateien automatisch transkribieren mit lokalem Whisper-Model.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Sprachnachrichten automatisch transkribieren", isOn: AppStorageToggle("kobold.stt.autoTranscribe", default: true))
                    .toggleStyle(.switch)
                    .tint(.koboldEmerald)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: AppStorageBinding("kobold.stt.model", default: "base")) {
                            Text("tiny (75 MB)").tag("tiny")
                            Text("base (142 MB)").tag("base")
                            Text("small (466 MB)").tag("small")
                            Text("medium (1.5 GB)").tag("medium")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sprache").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: AppStorageBinding("kobold.stt.language", default: "auto")) {
                            Text("Auto-Detect").tag("auto")
                            Text("Deutsch").tag("de")
                            Text("English").tag("en")
                            Text("Français").tag("fr")
                            Text("Español").tag("es")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }

                HStack(spacing: 12) {
                    if STTManager.shared.isModelLoaded {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 8, height: 8)
                            Text("Model '\(STTManager.shared.currentModelName)' geladen")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(.koboldEmerald)
                        }
                    } else if STTManager.shared.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Lade Model...")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    } else {
                        Button("Model herunterladen") {
                            Task { await STTManager.shared.downloadModel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.koboldEmerald)
                        .controlSize(.small)
                    }
                }
            }
            .padding()
        }

        // Stable Diffusion Section
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Bildgenerierung (Stable Diffusion)", systemImage: "photo.artframe").font(.subheadline.bold())
                Text("Generiere Bilder lokal auf deinem Mac mit Stable Diffusion. Sage z.B. 'Erstelle ein Bild von...' im Chat.")
                    .font(.caption).foregroundColor(.secondary)

                // Master Prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("Master-Prompt (wird jedem Prompt vorangestellt)").font(.caption.bold()).foregroundColor(.secondary)
                    TextField("z.B. masterpiece, best quality, highly detailed",
                              text: AppStorageBinding("kobold.sd.masterPrompt", default: "masterpiece, best quality, highly detailed"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                // Negative Prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("Standard Negative Prompt").font(.caption.bold()).foregroundColor(.secondary)
                    TextField("z.B. ugly, blurry, distorted",
                              text: AppStorageBinding("kobold.sd.negativePrompt", default: "ugly, blurry, distorted, low quality, deformed"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Schritte: \(UserDefaults.standard.integer(forKey: "kobold.sd.steps") == 0 ? 30 : UserDefaults.standard.integer(forKey: "kobold.sd.steps"))")
                            .font(.caption.bold()).foregroundColor(.secondary)
                        Slider(value: AppStorageDoubleBinding("kobold.sd.steps", default: 30), in: 10...80, step: 5)
                            .tint(.koboldEmerald)
                            .frame(width: 150)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        let gv = UserDefaults.standard.float(forKey: "kobold.sd.guidanceScale")
                        Text("Guidance: \(String(format: "%.1f", gv > 0 ? gv : 7.5))")
                            .font(.caption.bold()).foregroundColor(.secondary)
                        Slider(value: AppStorageDoubleBinding("kobold.sd.guidanceScale", default: 7.5), in: 1.0...20.0, step: 0.5)
                            .tint(.koboldEmerald)
                            .frame(width: 150)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compute").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: AppStorageBinding("kobold.sd.computeUnits", default: "cpuAndGPU")) {
                            Text("CPU + GPU").tag("cpuAndGPU")
                            Text("Alle (+ ANE)").tag("all")
                            Text("Nur CPU").tag("cpuOnly")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                }

                // Model status
                HStack(spacing: 12) {
                    if ImageGenManager.shared.isModelLoaded {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 8, height: 8)
                            Text("Model '\(ImageGenManager.shared.currentModelName)' geladen")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(.koboldEmerald)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill").font(.caption).foregroundColor(.orange)
                            Text("Lade ein CoreML Stable Diffusion Model herunter und lege es in ~/Library/Application Support/KoboldOS/sd-models/")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button("Models-Ordner öffnen") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("KoboldOS/sd-models")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if ImageGenManager.shared.isGenerating {
                    HStack(spacing: 8) {
                        ProgressView(value: ImageGenManager.shared.generationProgress)
                            .tint(.koboldEmerald)
                        Text("\(Int(ImageGenManager.shared.generationProgress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.koboldEmerald)
                    }
                }
            }
            .padding()
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
    @AppStorage("kobold.agent.memoryRules") private var memoryRules: String = ""

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

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Gedächtnis-Regeln", systemImage: "brain.fill").font(.subheadline.bold())
                Text("Freitext-Anweisungen wie der Agent mit Erinnerungen umgehen soll. Z.B. 'Merke dir meine Lieblingsfarbe', 'Vergiss nie meine Termine'.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $memoryRules)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if memoryRules.isEmpty {
                    Text("Keine besonderen Gedächtnis-Regeln definiert — Agent folgt der gewählten Richtlinie.")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
                Text("Tipp: Hier kannst du dem Agent detailliert sagen, was er sich merken soll und was nicht. Diese Regeln gelten zusätzlich zur gewählten Memory Policy.")
                    .font(.caption2).foregroundColor(.secondary)
            }.padding(6)
        }
    }

    // MARK: - Proaktive Einstellungen

    @StateObject private var proactiveEngine = ProactiveEngine.shared

    // proactiveSettingsSection moved into memorySettingsSection above

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
                    Text("Alpha v0.2.5").font(.title3).foregroundColor(.koboldGold)
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
                infoRow("Version", "Alpha v0.2.5")
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
            let logs = "KoboldOS Alpha v0.2.5 — Logs\nPID: \(ProcessInfo.processInfo.processIdentifier)\nUptime: \(Date())\n"
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

private func AppStorageBinding(_ key: String, default defaultValue: String) -> Binding<String> {
    Binding(
        get: { UserDefaults.standard.string(forKey: key) ?? defaultValue },
        set: { UserDefaults.standard.set($0, forKey: key) }
    )
}

private func AppStorageDoubleBinding(_ key: String, default defaultValue: Double) -> Binding<Double> {
    Binding(
        get: { let v = UserDefaults.standard.double(forKey: key); return v != 0 ? v : defaultValue },
        set: { UserDefaults.standard.set($0, forKey: key) }
    )
}

// MARK: - A2A Connected Client Model

struct A2AConnectedClient: Identifiable {
    let id: String
    let name: String
    let url: String
    var lastSeen: String
}
