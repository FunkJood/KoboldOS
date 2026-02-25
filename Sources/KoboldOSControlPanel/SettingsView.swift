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
    @ObservedObject private var launchAgent = LaunchAgentManager.shared
    @ObservedObject private var agentsStore = AgentsStore.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var toolEnv = ToolEnvironment.shared

    @State private var selectedSection: String = "Allgemein"
    @State private var ollamaModels: [String] = []
    @State private var isLoadingModels = false
    @AppStorage("kobold.workerPool.size") private var workerPoolSize: Int = 3

    // General
    @AppStorage("kobold.showAdvancedStats") private var showAdvancedStats: Bool = false
    @AppStorage("kobold.port") private var daemonPort: Int = 8080

    // Permissions
    @AppStorage("kobold.autonomyLevel") private var autonomyLevel: Int = 2
    @AppStorage("kobold.perm.shell")        private var permShell: Bool = true
    @AppStorage("kobold.perm.fileWrite")    private var permFileWrite: Bool = true
    @AppStorage("kobold.perm.network")      private var permNetwork: Bool = true
    @AppStorage("kobold.perm.confirmAdmin") private var permConfirmAdmin: Bool = true
    @AppStorage("kobold.perm.playwright") private var permPlaywright: Bool = false
    @AppStorage("kobold.perm.screenControl") private var permScreenControl: Bool = false

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

    // Context Management
    @AppStorage("kobold.context.windowSize") private var contextWindowSize: Int = 32768
    @AppStorage("kobold.context.autoCompress") private var contextAutoCompress: Bool = true
    @AppStorage("kobold.context.threshold") private var contextThreshold: Double = 0.8

    // RAG / Embedding
    @AppStorage("kobold.embedding.model") private var embeddingModel: String = "nomic-embed-text"
    @State private var ragStatus: String = "Ungeprüft"
    @State private var ragAvailable: Bool? = nil
    @State private var isCheckingRAG: Bool = false
    @State private var isPullingEmbeddingModel: Bool = false
    @State private var pullOutput: String = ""

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
    @State private var showSecretsManager: Bool = false

    private let sections = ["Allgemein", "Persönlichkeit", "Agenten", "Modelle", "Gedächtnis", "Berechtigungen", "Datenschutz & Sicherheit", "Benachrichtigungen", "Debugging & Sicherheit", "Verbindungen", "Sprache & Audio", "Fähigkeiten", "Über"]

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
                    case "Allgemein":                generalSection()
                    case "Persönlichkeit":           agentPersonalitySection()
                    case "Agenten":                  agentsSettingsSection()
                    case "Modelle":                  modelsSection()
                    case "Gedächtnis":               memoryPolicySection(); memorySettingsSection()
                    case "Berechtigungen":           permissionsSection()
                    case "Datenschutz & Sicherheit": securitySection()
                    case "Benachrichtigungen":       notificationsSettingsSection()
                    case "Debugging & Sicherheit":   debugSecuritySection()
                    case "Verbindungen":             connectionsSection()
                    case "Sprache & Audio":          speechAndAudioSection()
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
        case "Allgemein":               return "gear"
        case "Persönlichkeit":          return "person.fill.viewfinder"
        case "Agenten":                 return "person.3.fill"
        case "Modelle":                 return "cpu.fill"
        case "Gedächtnis":              return "brain.head.profile"
        case "Berechtigungen":          return "shield.lefthalf.filled"
        case "Datenschutz & Sicherheit": return "lock.shield.fill"
        case "Benachrichtigungen":      return "bell.badge.fill"
        case "Debugging & Sicherheit":  return "ant.fill"
        case "Verbindungen":            return "link.circle.fill"
        case "Sprache & Audio":         return "waveform"
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
                        .font(.system(size: 14.5))
                    Text(saveConfirmed == section ? "Gespeichert" : "Speichern")
                        .font(.system(size: 15.5, weight: .medium))
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
                    .font(.system(size: 49))
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

        // MARK: Heartbeat (ganz oben)
        sectionTitle("Heartbeat")

        HStack(alignment: .top, spacing: 12) {
            FuturisticBox(icon: "heart.fill", title: "Heartbeat-System", accent: .red) {
                Text("Der Heartbeat ist der Puls des Agenten — ein regelmäßiger Timer der prüft, ob der Agent bereit ist und ob es proaktive Arbeit gibt. Ohne Heartbeat bleibt der Agent passiv und wartet nur auf deine Eingaben.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Heartbeat aktivieren", isOn: $proactiveEngine.heartbeatEnabled)
                    .toggleStyle(.switch).tint(.red)

                HStack {
                    Text("Intervall").font(.caption.bold()).foregroundColor(.secondary)
                    Picker("", selection: $proactiveEngine.heartbeatIntervalSec) {
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("60s").tag(60)
                        Text("120s").tag(120)
                        Text("300s").tag(300)
                    }.pickerStyle(.segmented).frame(maxWidth: 350)
                }
                Text("Wie oft der Agent seinen Status prüft. Kürzere Intervalle = reaktiver, aber mehr CPU.")
                    .font(.caption2).foregroundColor(.secondary)

                Toggle("Im Dashboard anzeigen", isOn: $proactiveEngine.heartbeatShowInDashboard)
                    .toggleStyle(.switch).tint(.koboldEmerald)

                Divider()

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proactiveEngine.heartbeatEnabled ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(proactiveEngine.heartbeatStatus)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    Spacer()
                    if let last = proactiveEngine.lastHeartbeat {
                        Text("Letzter: \(last, style: .relative) her")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            FuturisticBox(icon: "list.clipboard.fill", title: "Heartbeat-Log", accent: .secondary) {
                Text("Protokoll der letzten Heartbeat-Zyklen. Zeigt was der Agent bei jedem Takt geprüft und entschieden hat.")
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Text("Aufbewahrung").font(.caption.bold()).foregroundColor(.secondary)
                    Picker("", selection: $proactiveEngine.heartbeatLogRetention) {
                        Text("20").tag(20)
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                    }.pickerStyle(.segmented).frame(maxWidth: 250)
                    Text("Einträge").font(.caption).foregroundColor(.secondary)
                }

                if proactiveEngine.heartbeatLog.isEmpty {
                    Text("Noch keine Heartbeat-Einträge. Starte den Heartbeat, um das Protokoll zu füllen.")
                        .font(.caption2).foregroundColor(.secondary).italic()
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(proactiveEngine.heartbeatLog.prefix(30)) { entry in
                                HStack(spacing: 6) {
                                    Text(entry.timestamp, style: .time)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 65, alignment: .leading)
                                    Text(entry.status)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(entry.action != nil ? .koboldEmerald : .secondary)
                                    if let action = entry.action {
                                        Text("→ \(action)")
                                            .font(.system(size: 12))
                                            .foregroundColor(.koboldGold)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)

                    HStack {
                        Spacer()
                        Button("Log löschen") { proactiveEngine.clearHeartbeatLog() }
                            .font(.caption).buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        // Idle Aufgaben
        IdleTasksSettingsView()

        // Row 0: Updates + Darstellung
        HStack(alignment: .top, spacing: 12) {
            FuturisticBox(icon: "arrow.down.circle.fill", title: "Updates", accent: .koboldEmerald) {
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
                            Text(notes).font(.system(size: 12.5)).foregroundColor(.secondary).lineLimit(3)
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
                    Text(msg).font(.system(size: 12.5)).foregroundColor(.red).lineLimit(2)
                }

                Button("Nach Updates suchen") {
                    Task { await updateManager.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updateManager.state == .checking)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "paintbrush.fill", title: "Darstellung", accent: .koboldGold) {
                Toggle("Erweiterte Statistiken", isOn: $showAdvancedStats)
                    .toggleStyle(.switch)
                Toggle("Medien einbetten", isOn: AppStorageToggle("kobold.chat.autoEmbed", default: true))
                    .toggleStyle(.switch)
                Text("Bilder, Audio und Videos inline anzeigen.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // Row 2: Arbeitsverzeichnis
        FuturisticBox(icon: "folder.fill", title: "Arbeitsverzeichnis", accent: .koboldGold) {
            HStack {
                Text(defaultWorkDir)
                    .font(.system(.caption, design: .monospaced))
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
                .controlSize(.small)
                Button("Öffnen") {
                    let expanded = NSString(string: defaultWorkDir).expandingTildeInPath
                    let url = URL(fileURLWithPath: expanded)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        // Row 3: Autostart + Einrichtungsassistent (2 columns)
        HStack(alignment: .top, spacing: 12) {
            FuturisticBox(icon: "power", title: "Autostart", accent: .koboldEmerald) {
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
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "wand.and.stars", title: "Onboarding", accent: .koboldGold) {
                Text("Wizard erneut zeigen")
                    .font(.caption).foregroundColor(.secondary)
                Button("Zurücksetzen") {
                    UserDefaults.standard.set(false, forKey: "kobold.hasOnboarded")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            // Debug box removed — use "Debugging & Sicherheit" section instead
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
                                        Text(ver).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                                    } else if !tool.isAvailable {
                                        Text("Nicht installiert").font(.system(size: 11.5)).foregroundColor(.secondary)
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
                            Text("Standalone Python (~17 MB) in App Support installieren").font(.system(size: 11.5)).foregroundColor(.secondary)
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
        FuturisticBox(icon: "server.rack", title: "Ollama Backend", accent: .koboldGold) {
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

        // Parallel Multi-Chat
        FuturisticBox(icon: "cpu.fill", title: "Parallele Chats (Worker-Pool)", accent: .koboldCyan) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mehrere Chats laufen gleichzeitig in isolierten Workers. Jeder Worker hat seinen eigenen LLM-Kontext.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Worker-Anzahl").font(.system(size: 13, weight: .medium))
                        Text("1 = sequenziell, 3 = empfohlen, max 8")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Stepper("\(workerPoolSize)", value: $workerPoolSize, in: 1...16)
                        .onChange(of: workerPoolSize) { newVal in
                            Task { await AgentWorkerPool.shared.resize(to: newVal) }
                        }
                }

                Divider()

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ollama-Parallelität aktivieren")
                            .font(.system(size: 13, weight: .medium))
                        Text("Startet Ollama neu mit OLLAMA_NUM_PARALLEL=\(workerPoolSize)")
                            .font(.caption2).foregroundColor(.secondary)
                        Text("Benötigt: Ollama via brew install ollama")
                            .font(.caption2).foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                    Button("Ollama neu starten (×\(workerPoolSize))") {
                        viewModel.restartOllamaWithParallelism(workers: workerPoolSize)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldCyan)
                }

                if viewModel.ollamaStatus.contains("Restarting") || viewModel.ollamaStatus.contains("×") {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.ollamaStatus.contains("Running") ? "checkmark.circle.fill" : "arrow.clockwise")
                            .foregroundColor(viewModel.ollamaStatus.contains("Running") ? .koboldEmerald : .koboldGold)
                        Text(viewModel.ollamaStatus)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }

        // Per-agent model pickers
        FuturisticBox(icon: "person.3.fill", title: "Modell pro Agent", accent: .koboldEmerald) {
                Text("Jeder Agent kann ein eigenes Modell nutzen. Leer = primäres Modell.")
                    .font(.caption).foregroundColor(.secondary)

                ForEach($agentsStore.configs) { $config in
                    HStack(spacing: 10) {
                        Text(config.emoji).font(.title3)
                        Text(config.displayName)
                            .font(.system(size: 14.5, weight: .medium))
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
                                .font(.system(size: 9, weight: .bold))
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
        FuturisticBox(icon: icon, title: name, accent: color) {
                HStack {
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
                            .font(.system(size: 11.5, design: .monospaced))
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
        FuturisticBox(icon: "dial.high.fill", title: "Autonomie-Level", accent: .koboldGold) {
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

        // Individual permissions
        FuturisticBox(icon: "checklist", title: "Einzelne Berechtigungen", accent: .koboldGold) {
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
                Divider()
                permToggle("Playwright (Chrome-Automatisierung)",
                           detail: "Erlaubt Browser-Automatisierung mit Chrome via Playwright (Node.js)",
                           icon: "globe", color: .purple,
                           binding: $permPlaywright)
                Divider()
                permToggle("Bildschirmsteuerung (Maus/Tastatur/OCR)",
                           detail: "Erlaubt den PC zu steuern: Maus, Tastatur, Screenshots, Text-Erkennung",
                           icon: "display", color: .orange,
                           binding: $permScreenControl)
        }

        // Apple System Permissions — Request macOS access
        // macOS System-Berechtigungen (zusammengelegt)
        FuturisticBox(icon: "apple.logo", title: "macOS System-Berechtigungen", accent: .red) {
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

        // Shell Permissions — 3 Tier Toggles (Blacklist-System)
        FuturisticBox(icon: "terminal.fill", title: "Shell-Berechtigungen (Blacklist)", accent: .red) {
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

        // Custom blacklist + whitelist
        HStack(alignment: .top, spacing: 16) {
            FuturisticBox(icon: "xmark.shield.fill", title: "Benutzerdefinierte Blacklist", accent: .red) {
                    Text("Zusätzlich blockierte Befehle (kommagetrennt).")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("z.B. docker, terraform, ansible", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.shell.customBlacklist") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.shell.customBlacklist") }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
            }
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "checkmark.shield.fill", title: "Benutzerdefinierte Whitelist", accent: .koboldEmerald) {
                    Text("Zusätzlich erlaubte Befehle (kommagetrennt).")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("z.B. python3, node, cargo, docker", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.shell.customAllowlist") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.shell.customAllowlist") }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
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
                    .font(.system(size: 15.5, weight: .semibold))
                Text(description)
                    .font(.caption).foregroundColor(.secondary)
                Text(commands)
                    .font(.system(size: 11.5, design: .monospaced))
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
                Text(title).font(.system(size: 14.5, weight: .semibold))
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
                Text(title).font(.system(size: 15.5))
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
                Text(title).font(.system(size: 15.5))
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
                .font(.system(size: 18.5))
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15.5, weight: .medium))
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
        // Trigger AppleScript permission on background thread to avoid Main Thread freeze
        Task.detached(priority: .utility) {
            let script = NSAppleScript(source: "tell application \"System Events\" to return name of first process")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
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
        FuturisticBox(icon: "externaldrive.fill", title: "Datenpersistenz", accent: .koboldGold) {
                Text("Steuere ob Daten (Gedächtnis, Chat-Verlauf, Skills) auch nach dem Löschen der App erhalten bleiben.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Daten über App-Löschung hinaus speichern", isOn: $persistDataAfterDelete)
                    .toggleStyle(.switch)
                Text(persistDataAfterDelete
                     ? "Daten bleiben in ~/Library/Application Support/KoboldOS/ erhalten."
                     : "Alle Daten werden beim Deinstallieren der App entfernt.")
                    .font(.caption2).foregroundColor(.secondary)
        }

        // Safe Mode
        FuturisticBox(icon: "lock.shield.fill", title: "Safe Mode", accent: .red) {
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

        // Daemon Auth
        FuturisticBox(icon: "key.fill", title: "Daemon-Authentifizierung", accent: .red) {
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

        // Cloud API Provider & Keys
        Text("Cloud API-Provider").font(.headline).padding(.top, 8)

        // OpenAI
        providerCard(
            name: "OpenAI", icon: "brain.head.profile", color: .koboldEmerald,
            keyBinding: $openaiKey, baseURLBinding: $openaiBaseURL,
            defaultURL: "https://api.openai.com",
            models: ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o1"],
            provider: "openai"
        )
        // Anthropic
        providerCard(
            name: "Anthropic", icon: "sparkles", color: .koboldGold,
            keyBinding: $anthropicKey, baseURLBinding: $anthropicBaseURL,
            defaultURL: "https://api.anthropic.com",
            models: ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-20250514"],
            provider: "anthropic"
        )
        // Groq
        providerCard(
            name: "Groq", icon: "bolt.fill", color: .koboldEmerald,
            keyBinding: $groqKey, baseURLBinding: $groqBaseURL,
            defaultURL: "https://api.groq.com",
            models: ["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"],
            provider: "groq"
        )

        FuturisticBox(icon: "cloud.fill", title: "Cloud API-Keys (Schnellzugriff)", accent: .red) {
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

        // Secrets (lazy loaded — avoids Keychain prompts when section appears)
        FuturisticBox(icon: "lock.rectangle.stack.fill", title: "Secrets & API-Keys", accent: .red) {
                if showSecretsManager {
                    SecretsManagementView()
                } else {
                    VStack(spacing: 8) {
                        Text("Keychain-basierter Passwort-Manager für API-Keys, Tokens und Zugangsdaten.")
                            .font(.caption).foregroundColor(.secondary)
                        Button(action: { showSecretsManager = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.open.fill")
                                Text("Secrets-Manager öffnen")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
        }

        // Datensicherung (merged from former standalone tab)
        Text("Datensicherung").font(.headline).padding(.top, 8)
        backupContent()
        settingsSaveButton(section: "Sicherheit")
    }

    @ViewBuilder
    private func backupContent() -> some View {
        // Create backup
        FuturisticBox(icon: "arrow.down.doc.fill", title: "Backup erstellen", accent: .koboldEmerald) {
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
                .font(.system(size: 14.5))

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

        // Existing backups
        FuturisticBox(icon: "clock.arrow.circlepath", title: "Vorhandene Backups", accent: .koboldGold) {

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
                                    .font(.system(size: 15.5, weight: .medium))
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
        .onAppear { loadBackups() }
    }

    // (A2A section moved into connectionsSection above)

    private func a2aPermToggle(title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14.5))
                .foregroundColor(isOn.wrappedValue ? color : .secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13.5))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(color)
                .controlSize(.small)
        }
    }

    // MARK: - Verbindungen

    @State private var iMessageAvailable: Bool = false

    // MARK: - Weather Settings

    // MARK: - Benachrichtigungen

    @AppStorage("kobold.notify.chatStepThreshold") private var chatStepThreshold: Int = 3
    @AppStorage("kobold.notify.taskAlways") private var notifyTaskAlways: Bool = true
    @AppStorage("kobold.notify.workflowAlways") private var notifyWorkflowAlways: Bool = true
    @AppStorage("kobold.notify.sound") private var notifySound: Bool = true
    @AppStorage("kobold.notify.systemNotifications") private var systemNotifications: Bool = true
    @AppStorage("kobold.notify.channel") private var notifyChannel: String = "system"

    @ViewBuilder
    private func notificationsSettingsSection() -> some View {
        sectionTitle("Benachrichtigungen")

        FuturisticBox(icon: "bell.badge.fill", title: "Benachrichtigungsregeln", accent: .koboldGold) {
            Text("Lege fest wann und wie du benachrichtigt wirst.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("System-Benachrichtigungen (macOS)", isOn: $systemNotifications)
                .toggleStyle(.switch)
            Toggle("Benachrichtigungssound", isOn: $notifySound)
                .toggleStyle(.switch)

            GlassDivider()

            Toggle("Tasks: Immer bei Abschluss/Fehler", isOn: $notifyTaskAlways)
                .toggleStyle(.switch)
            Toggle("Workflows: Immer bei Abschluss/Fehler", isOn: $notifyWorkflowAlways)
                .toggleStyle(.switch)

            HStack {
                Text("Normale Chats: Ab")
                Stepper("\(chatStepThreshold) Schritten", value: $chatStepThreshold, in: 1...20)
                    .frame(width: 160)
            }
            Text("Normale Chat-Benachrichtigungen erst wenn der Agent mindestens \(chatStepThreshold) Tool-Schritte ausführt.")
                .font(.caption2).foregroundColor(.secondary)
        }

        FuturisticBox(icon: "paperplane.fill", title: "Benachrichtigungskanal", accent: .koboldEmerald) {
            Text("Wohin sollen Benachrichtigungen geschickt werden?")
                .font(.caption).foregroundColor(.secondary)

            Picker("Kanal", selection: $notifyChannel) {
                Text("Nur System (macOS)").tag("system")
                Text("System + Telegram").tag("telegram")
                Text("System + iMessage").tag("imessage")
            }
            .pickerStyle(.radioGroup)

            if notifyChannel == "telegram" {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").foregroundColor(.blue)
                    Text("Telegram muss unter Verbindungen konfiguriert sein.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if notifyChannel == "imessage" {
                HStack(spacing: 6) {
                    Image(systemName: "message.fill").foregroundColor(.green)
                    Text("iMessage sendet an deine Apple-ID.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Debugging & Sicherheit

    @AppStorage("kobold.log.level") private var logLevel: Int = 2
    @AppStorage("kobold.recovery.autoRestart") private var autoRestartDaemon: Bool = true
    @AppStorage("kobold.recovery.sessionRecovery") private var sessionRecovery: Bool = true
    @AppStorage("kobold.recovery.maxRetries") private var maxRetries: Int = 3
    @AppStorage("kobold.security.sandboxTools") private var sandboxTools: Bool = true
    @AppStorage("kobold.security.networkRestrict") private var networkRestrict: Bool = false
    @AppStorage("kobold.security.confirmDangerous") private var confirmDangerous: Bool = true
    @AppStorage("kobold.recovery.healthInterval") private var healthCheckInterval: Int = 60

    @ViewBuilder
    private func debugSecuritySection() -> some View {
        sectionTitle("Debugging & Sicherheit")

        HStack(alignment: .top, spacing: 16) {
            // Logging
            FuturisticBox(icon: "doc.text.magnifyingglass", title: "Logging", accent: .koboldEmerald) {
                HStack {
                    Text("Log-Level").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $logLevel) {
                        Text("Verbose").tag(0)
                        Text("Debug").tag(1)
                        Text("Info").tag(2)
                        Text("Warnung").tag(3)
                        Text("Fehler").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 350)
                }

                Toggle("Verbose Logging", isOn: AppStorageToggle("kobold.log.verbose", default: false))
                    .toggleStyle(.switch)
                Toggle("Raw Prompts anzeigen", isOn: AppStorageToggle("kobold.dev.showRawPrompts", default: false))
                    .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button("Logs exportieren") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "kobold-logs.txt"
                        panel.allowedContentTypes = [.plainText]
                        if panel.runModal() == .OK, let url = panel.url {
                            let logs = "[KoboldOS Log Export — \(Date())]\n\nLog-Level: \(logLevel)\nExport complete."
                            try? logs.write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Logs löschen") {
                        print("[KoboldOS] Logs cleared")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            // Recovery
            FuturisticBox(icon: "arrow.counterclockwise.circle.fill", title: "Wiederherstellung", accent: .koboldGold) {
                Toggle("Daemon automatisch neu starten", isOn: $autoRestartDaemon)
                    .toggleStyle(.switch)
                Text("Startet den Daemon automatisch bei unerwartetem Abbruch.")
                    .font(.caption2).foregroundColor(.secondary)

                Toggle("Session-Wiederherstellung", isOn: $sessionRecovery)
                    .toggleStyle(.switch)
                Text("Stellt unterbrochene Sitzungen nach Neustart wieder her.")
                    .font(.caption2).foregroundColor(.secondary)

                HStack {
                    Text("Max. Wiederholungsversuche").font(.caption)
                    Spacer()
                    Stepper("\(maxRetries)", value: $maxRetries, in: 1...10)
                        .frame(width: 120)
                }

                HStack {
                    Text("Gesundheitscheck-Intervall").font(.caption)
                    Spacer()
                    Stepper("\(healthCheckInterval)s", value: $healthCheckInterval, in: 10...300, step: 10)
                        .frame(width: 120)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        FuturisticBox(icon: "shield.checkered", title: "Sicherheitsautomatisierungen", accent: .red) {
            Text("Kontrolliere wie der Agent mit kritischen Operationen umgeht.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Tool-Sandboxing (beschränkt Shell-Befehle)", isOn: $sandboxTools)
                .toggleStyle(.switch)
            Toggle("Netzwerk-Einschränkungen (blockt localhost-Zugriffe)", isOn: $networkRestrict)
                .toggleStyle(.switch)
            Toggle("Bestätigung bei gefährlichen Aktionen (rm, sudo, etc.)", isOn: $confirmDangerous)
                .toggleStyle(.switch)

            GlassDivider()

            HStack(spacing: 12) {
                Button("Alle Sessions zurücksetzen") {
                    // Only with confirmation
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Daemon-Cache leeren") {
                    Task { if let url = URL(string: viewModel.baseURL + "/history/clear") {
                        var req = viewModel.authorizedRequest(url: url, method: "POST")
                        _ = try? await URLSession.shared.data(for: req)
                    }}
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // weatherMgr removed — weather uses auto-location now

    @ViewBuilder
    private func connectionsSection() -> some View {
        sectionTitle("Verbindungen")

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

        // Row 4: GitHub + Microsoft
        HStack(alignment: .top, spacing: 12) {
            githubConnectionSection()
            microsoftConnectionSection()
        }

        // Row 5: HuggingFace + Slack
        HStack(alignment: .top, spacing: 12) {
            huggingFaceConnectionSection()
            slackConnectionSection()
        }

        // Row 6: Notion + WhatsApp
        HStack(alignment: .top, spacing: 12) {
            notionConnectionSection()
            whatsappConnectionSection()
        }

        // Row 7: E-Mail + Twilio
        HStack(alignment: .top, spacing: 12) {
            emailConnectionSection()
            twilioConnectionSection()
        }

        // Row 8: Webhook + CalDAV
        HStack(alignment: .top, spacing: 12) {
            webhookConnectionSection()
            caldavConnectionSection()
        }

        // Row 9: MQTT + RSS
        HStack(alignment: .top, spacing: 12) {
            mqttConnectionSection()
            rssConnectionSection()
        }

        // Row 10: Lieferando + Uber
        HStack(alignment: .top, spacing: 12) {
            lieferandoConnectionSection()
            uberConnectionSection()
        }

        // Weitere Integrationen (Phase 2+)
        FuturisticBox(icon: "puzzlepiece.extension.fill", title: "Weitere Integrationen", accent: .koboldGold) {
                Text("Kommende Verbindungen — du kannst bereits jetzt APIs über das Shell- und Web-Tool nutzen.")
                    .font(.caption).foregroundColor(.secondary)
        }

        let futureItems: [(String, AnyView, Color, String)] = [
            ("Discord",      AnyView(brandLogoDiscord), .indigo,   "Server, Nachrichten"),
            ("Dropbox",      AnyView(brandLogoDropbox), .cyan,     "Dateien synchronisieren"),
            ("Spotify",      AnyView(brandLogoSpotify), .green,    "Playlists, Wiedergabe"),
            ("Linear",       AnyView(brandLogoLinear), .purple,    "Issues, Projekte"),
            ("Todoist",      AnyView(brandLogoTodoist), .red,      "Tasks, Projekte"),
            ("LinkedIn",     AnyView(brandLogoLinkedIn), .blue,    "Profil, Netzwerk"),
        ]

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(futureItems, id: \.0) { item in
                GroupBox {
                    HStack(spacing: 8) {
                        item.1
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0)
                                .font(.system(size: 14.5, weight: .semibold))
                            Text(item.3)
                                .font(.system(size: 12.5)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(4)
                    .frame(minHeight: 36)
                }
                .overlay(alignment: .topTrailing) {
                    Text("Geplant")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .padding(6)
                }
                .opacity(0.45)
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
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A2A Server").font(.system(size: 17.5, weight: .bold))
                            Text("Agent-zu-Agent Protokoll").font(.system(size: 13.5)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if a2aEnabled {
                            HStack(spacing: 5) {
                                Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                                Text("Aktiv").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldEmerald)
                            }
                        }
                    }

                    Divider().opacity(0.5)

                    Toggle("A2A aktivieren", isOn: $a2aEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)

                    HStack(spacing: 8) {
                        Text("Port:").font(.system(size: 13.5)).foregroundColor(.secondary)
                        TextField("8081", value: $a2aPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .font(.system(.caption, design: .monospaced))
                    }

                    if a2aEnabled {
                        HStack(spacing: 6) {
                            Circle().fill(Color.koboldEmerald).frame(width: 6, height: 6)
                            Text("http://localhost:\(a2aPort)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(.koboldEmerald)
                                .textSelection(.enabled)
                        }

                        // Verbundene Clients
                        if !a2aConnectedClients.isEmpty {
                            Divider().opacity(0.3)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Verbundene Clients (\(a2aConnectedClients.count))")
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
                                ForEach(a2aConnectedClients, id: \.id) { client in
                                    HStack(spacing: 8) {
                                        Circle().fill(Color.koboldEmerald).frame(width: 5, height: 5)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(client.name)
                                                .font(.system(size: 13.5, weight: .medium))
                                            Text(client.url)
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(client.lastSeen)
                                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                                        Button(action: {
                                            a2aConnectedClients.removeAll { $0.id == client.id }
                                            // Notify daemon to reject this client
                                            NotificationCenter.default.post(
                                                name: Notification.Name("koboldA2AKickClient"),
                                                object: client.id
                                            )
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 14.5))
                                                .foregroundColor(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Client trennen")
                                    }
                                }
                            }
                        } else {
                            Text("Keine Clients verbunden")
                                .font(.system(size: 12.5)).foregroundColor(.secondary.opacity(0.6))
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
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A2A Berechtigungen").font(.system(size: 17.5, weight: .bold))
                            Text("Zugriff externer Agenten").font(.system(size: 13.5)).foregroundColor(.secondary)
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
            FuturisticBox(icon: "link.badge.plus", title: "Schnellverbindung (Token)", accent: .koboldGold) {

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dein Token").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("Token...", text: $a2aToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
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
                        Text("Remote-Token").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("Token einfügen...", text: $a2aRemoteToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
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
            .frame(maxWidth: .infinity, alignment: .top)

            // Vertrauenswürdige Agenten
            FuturisticBox(icon: "checkmark.shield.fill", title: "Vertrauenswürdige Agenten", accent: .koboldEmerald) {
                    Text("URLs/Tokens die sich ohne Bestätigung verbinden dürfen (eine pro Zeile).")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $a2aTrustedAgents)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(height: 60)
                        .padding(4)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                        .scrollContentBackground(.hidden)
                    Text("z.B. http://192.168.1.100:8081")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        settingsSaveButton(section: "A2A")

        // MCP Server (Model Context Protocol)
        mcpServersSection()
            .onAppear { Task { await loadMCPServers() } }
    }

    // MARK: - Brand Logos (SwiftUI drawn)

    private var brandLogoGoogle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            // Google multi-color "G"
            Text("G")
                .font(.system(size: 21, weight: .bold, design: .rounded))
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
                .font(.system(size: 18.5, weight: .bold))
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
                .font(.system(size: 17.5, weight: .semibold))
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
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    var brandLogoGitHub: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.14, green: 0.15, blue: 0.16))
            // Octocat approximation
            Image(systemName: "cat.fill")
                .font(.system(size: 17.5, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    var brandLogoMicrosoft: some View {
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

    var brandLogoHuggingFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.827, blue: 0.0))
            Text("🤗")
                .font(.system(size: 19))
        }
    }

    var brandLogoSlack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.286, green: 0.114, blue: 0.333))
            Image(systemName: "number")
                .font(.system(size: 18.5, weight: .bold))
                .foregroundColor(.white)
        }
    }

    var brandLogoNotion: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            Text("N")
                .font(.system(size: 19, weight: .bold, design: .serif))
                .foregroundColor(.black)
        }
    }

    private var brandLogoDiscord: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.345, green: 0.396, blue: 0.949))
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoDropbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.004, green: 0.388, blue: 1.0))
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 16.5, weight: .semibold))
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
                .font(.system(size: 18.5, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoTodoist: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.882, green: 0.286, blue: 0.243))
            Image(systemName: "checkmark")
                .font(.system(size: 18.5, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var brandLogoLinkedIn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.0, green: 0.467, blue: 0.71))
            Text("in")
                .font(.system(size: 19.5, weight: .bold, design: .serif))
                .foregroundColor(.white)
        }
    }

    // MARK: - Gedächtnis

    @ViewBuilder
    private func memorySettingsSection() -> some View {
        // MARK: Context Management
        sectionTitle("Kontext-Management")

        HStack(alignment: .top, spacing: 16) {
            FuturisticBox(icon: "text.line.last.and.arrowtriangle.forward", title: "Kontextfenster", accent: .koboldEmerald) {
                Text("Definiert wie viel Text der Agent gleichzeitig im Gedächtnis halten kann.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("Kontextgröße", selection: $contextWindowSize) {
                    Text("4K").tag(4096)
                    Text("8K").tag(8192)
                    Text("16K").tag(16384)
                    Text("32K").tag(32768)
                    Text("64K").tag(65536)
                    Text("128K").tag(131072)
                    Text("256K").tag(262144)
                }
                .pickerStyle(.menu)

                Toggle("Auto-Komprimierung", isOn: $contextAutoCompress)
                    .toggleStyle(.switch).tint(.koboldEmerald)
                Text("Komprimiert automatisch ältere Nachrichten wenn der Kontext voll wird.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "gauge.with.dots.needle.bottom.50percent", title: "Kompressions-Schwelle", accent: .koboldGold) {
                Text("Ab welcher Auslastung wird komprimiert: \(Int(contextThreshold * 100))%")
                    .font(.caption).foregroundColor(.secondary)

                Slider(value: $contextThreshold, in: 0.5...0.95, step: 0.05)
                    .tint(.koboldGold)

                HStack {
                    Text("50%").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text("95%").font(.caption2).foregroundColor(.secondary)
                }

                Text("Niedrigere Werte = früher komprimieren (sparsamer). Höhere Werte = mehr Kontext behalten (akkurater).")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // RAG / Semantic Memory
        FuturisticBox(icon: "brain.filled.head.profile", title: "Embedding-Modell (Semantisches RAG)", accent: .koboldCyan) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nur die 5 relevantesten Erinnerungen werden per Vektorsuche geladen (~150 statt ~3000 Tokens). Erfordert 'nomic-embed-text' (274 MB).")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 12) {
                    TextField("Modell-Name", text: $embeddingModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)

                    // Status badge
                    if let available = ragAvailable {
                        Label(available ? "Verfügbar" : "Nicht geladen",
                              systemImage: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(available ? .koboldEmerald : .koboldGold)
                            .font(.caption)
                    } else if isCheckingRAG {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text(ragStatus)
                            .font(.caption).foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Status prüfen") {
                        isCheckingRAG = true
                        Task {
                            let ok = await EmbeddingRunner.shared.isAvailable()
                            await MainActor.run {
                                ragAvailable = ok
                                ragStatus = ok ? "Verfügbar" : "Nicht geladen"
                                isCheckingRAG = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modell installieren").font(.system(size: 13, weight: .medium))
                        Text("Führt 'ollama pull \(embeddingModel)' aus (274 MB).")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isPullingEmbeddingModel ? "Installiere…" : "Modell installieren") {
                        isPullingEmbeddingModel = true
                        pullOutput = ""
                        let modelToPull = embeddingModel
                        Task.detached {
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
                            if !FileManager.default.fileExists(atPath: "/usr/local/bin/ollama") {
                                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
                            }
                            process.arguments = ["pull", modelToPull]
                            let pipe = Pipe()
                            process.standardOutput = pipe
                            process.standardError = pipe
                            try? process.run()
                            process.waitUntilExit()
                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                            let out = String(data: data, encoding: .utf8) ?? ""
                            await MainActor.run {
                                pullOutput = out
                                isPullingEmbeddingModel = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.koboldCyan)
                    .disabled(isPullingEmbeddingModel)
                }

                if !pullOutput.isEmpty {
                    ScrollView {
                        Text(pullOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                    .padding(6)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(6)
                }
            }
        }

        sectionTitle("Agent-Leistung")

        HStack(alignment: .top, spacing: 16) {
            FuturisticBox(icon: "bolt.fill", title: "Schritte & Limits", accent: .orange) {
                Text("Max. Schritte die der Agent pro Anfrage ausführen darf.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("Web", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.agent.webSteps").nonZero ?? 50 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.agent.webSteps") }
                )) {
                    Text("20 Schritte").tag(20)
                    Text("50 (Standard)").tag(50)
                    Text("80 Schritte").tag(80)
                    Text("100 Schritte").tag(100)
                }.pickerStyle(.menu)

                Picker("Coder", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.agent.coderSteps").nonZero ?? 40 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.agent.coderSteps") }
                )) {
                    Text("15 Schritte").tag(15)
                    Text("40 (Standard)").tag(40)
                    Text("60 Schritte").tag(60)
                    Text("80 Schritte").tag(80)
                }.pickerStyle(.menu)

                Picker("Allgemein", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.agent.generalSteps").nonZero ?? 25 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.agent.generalSteps") }
                )) {
                    Text("10 Schritte").tag(10)
                    Text("25 (Standard)").tag(25)
                    Text("40 Schritte").tag(40)
                    Text("60 Schritte").tag(60)
                }.pickerStyle(.menu)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "timer", title: "Timeouts", accent: .orange) {
                Text("Max. Laufzeit für Shell-Befehle und Sub-Agenten.")
                    .font(.caption).foregroundColor(.secondary)

                Picker("Shell-Timeout", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.shell.timeout").nonZero ?? 300 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.shell.timeout") }
                )) {
                    Text("60 Sek.").tag(60)
                    Text("2 Min.").tag(120)
                    Text("5 Min. (Standard)").tag(300)
                    Text("10 Min.").tag(600)
                }.pickerStyle(.menu)

                Picker("Sub-Agent-Timeout", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.subagent.timeout").nonZero ?? 300 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.subagent.timeout") }
                )) {
                    Text("2 Min.").tag(120)
                    Text("5 Min. (Standard)").tag(300)
                    Text("10 Min.").tag(600)
                    Text("15 Min.").tag(900)
                }.pickerStyle(.menu)

                Picker("Max. Sub-Agenten", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "kobold.subagent.maxConcurrent").nonZero ?? 10 },
                    set: { UserDefaults.standard.set($0, forKey: "kobold.subagent.maxConcurrent") }
                )) {
                    Text("3 gleichzeitig").tag(3)
                    Text("5 gleichzeitig").tag(5)
                    Text("10 (Standard)").tag(10)
                    Text("20 gleichzeitig").tag(20)
                    Text("Unbegrenzt (50)").tag(50)
                }.pickerStyle(.menu)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        sectionTitle("Gedächtnis-Einstellungen")

        // Core Memory blocks
        HStack(alignment: .top, spacing: 16) {
            FuturisticBox(icon: "ruler.fill", title: "Speicherlimits", accent: .koboldGold) {
                    HStack {
                        Text("Persona-Block").font(.system(size: 15.5))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.integer(forKey: "kobold.memory.personaLimit").nonZero ?? 2000 },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.memory.personaLimit") }
                        )) {
                            Text("1000").tag(1000); Text("2000").tag(2000); Text("4000").tag(4000); Text("8000").tag(8000)
                        }.pickerStyle(.menu).frame(width: 90)
                    }
                    HStack {
                        Text("Human-Block").font(.system(size: 15.5))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.integer(forKey: "kobold.memory.humanLimit").nonZero ?? 2000 },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.memory.humanLimit") }
                        )) {
                            Text("1000").tag(1000); Text("2000").tag(2000); Text("4000").tag(4000); Text("8000").tag(8000)
                        }.pickerStyle(.menu).frame(width: 90)
                    }
                    HStack {
                        Text("Knowledge-Block").font(.system(size: 15.5))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.integer(forKey: "kobold.memory.knowledgeLimit").nonZero ?? 3000 },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.memory.knowledgeLimit") }
                        )) {
                            Text("2000").tag(2000); Text("3000").tag(3000); Text("5000").tag(5000); Text("10000").tag(10000)
                        }.pickerStyle(.menu).frame(width: 90)
                    }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            FuturisticBox(icon: "arrow.clockwise", title: "Auto-Speichern", accent: .koboldEmerald) {
                    Toggle("Automatisch sichern", isOn: AppStorageToggle("kobold.memory.autosave", default: true))
                        .toggleStyle(.switch)
                    Text("Speichert bei jeder Aktualisierung.").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // Recall settings (AgentZero-style)
        FuturisticBox(icon: "magnifyingglass", title: "Memory Recall", accent: .koboldEmerald) {
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

        // Memorization settings
        FuturisticBox(icon: "brain.fill", title: "Automatisches Merken", accent: .koboldEmerald) {
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

        // Export / Import
        FuturisticBox(icon: "square.and.arrow.up", title: "Export / Import", accent: .koboldGold) {
                HStack(spacing: 8) {
                    Button("Exportieren") { exportMemory() }.buttonStyle(.bordered)
                    Button("Importieren") { importMemory() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Zurücksetzen") { resetMemory() }.buttonStyle(.bordered).foregroundColor(.red)
                }
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
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WebApp-Server").font(.system(size: 17.5, weight: .bold))
                        Text("Fernsteuerung im Browser").font(.system(size: 13.5)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if webAppRunning {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Aktiv").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldEmerald)
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
                            Text("Port").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                            TextField("Port", value: $webAppPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Benutzer").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
                            TextField("Benutzer", text: $webAppUsername)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Passwort").font(.system(size: 12.5, weight: .medium)).foregroundColor(.secondary)
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
                            .font(.system(size: 12.5, design: .monospaced))
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
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloudflare Tunnel").font(.system(size: 17.5, weight: .bold))
                        Text("Sicherer Internet-Zugang").font(.system(size: 13.5)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if tunnelRunning && !tunnelURL.isEmpty {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Verbunden").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldEmerald)
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
                                    .font(.system(size: 12.5, design: .monospaced))
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
                                    Text("QR-Code:").font(.system(size: 12.5)).foregroundColor(.secondary)
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
                                .font(.system(size: 18.5)).foregroundColor(.secondary)
                            Text(googleEmail)
                                .font(.system(size: 14.5, weight: .medium))
                        }
                    }
                    let activeScopes = GoogleOAuth.shared.enabledScopes
                    if !activeScopes.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(activeScopes).sorted(by: { $0.label < $1.label }), id: \.self) { scope in
                                Text(scope.label)
                                    .font(.system(size: 11.5, weight: .medium))
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
                                Text("G").font(.system(size: 16.5, weight: .bold, design: .rounded))
                                    .foregroundColor(Color(red: 0.259, green: 0.522, blue: 0.957))
                            }
                            Text("Sign in with Google")
                                .font(.system(size: 15.5, weight: .medium)).foregroundColor(.white)
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
                                .font(.system(size: 13.5))
                                .foregroundColor(isEnabled ? .koboldEmerald : .secondary)
                            Text(scope.label)
                                .font(.system(size: 13.5))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            Text("Änderungen werden bei der nächsten Anmeldung wirksam.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
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
                                .font(.system(size: 18.5)).foregroundColor(.secondary)
                            Text(soundCloudUser)
                                .font(.system(size: 14.5, weight: .medium))
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
                                    .font(.system(size: 14.5, weight: .bold))
                                    .foregroundColor(Color(red: 1.0, green: 0.333, blue: 0.0))
                            }
                            Text("Sign in with SoundCloud")
                                .font(.system(size: 15.5, weight: .medium)).foregroundColor(.white)
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
                            .font(.system(size: 14.5)).foregroundColor(.koboldEmerald)
                        Text("Automation-Berechtigung erteilt")
                            .font(.system(size: 13.5)).foregroundColor(.secondary)
                    }
                    Text("Der Agent kann über AppleScript Nachrichten lesen und senden.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)

                    Toggle("iMessage aktiviert", isOn: $iMessageEnabled)
                        .toggleStyle(.switch)
                        .tint(.koboldEmerald)
                        .font(.system(size: 14.5))
                        .onChange(of: iMessageEnabled) {
                            if !iMessageEnabled { iMessageAvailable = false }
                        }
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    Text("Aktiviere iMessage um deinem Agent Zugriff auf Nachrichten zu geben. macOS fragt nach Automation-Berechtigung.")
                        .font(.system(size: 13.5)).foregroundColor(.secondary)

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
                    .font(.system(size: 14.5))

                    if iMessageEnabled && !iMessageAvailable {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12.5)).foregroundColor(.orange)
                            Text("Berechtigung noch nicht erteilt")
                                .font(.system(size: 12.5)).foregroundColor(.orange)
                        }
                        Button("Systemeinstellungen öffnen") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                        .font(.system(size: 13.5))
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
        // Run on background thread to avoid Main Thread freeze
        Task.detached(priority: .utility) {
            let script = NSAppleScript(source: "tell application \"Messages\" to count of every chat")
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
            let available = (errorInfo == nil)
            await MainActor.run { iMessageAvailable = available }
        }
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
                                .font(.system(size: 18.5)).foregroundColor(.secondary)
                            Text("@\(telegramBotName)")
                                .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.koboldEmerald)
                        }
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.received)").font(.system(size: 18.5, weight: .bold)).foregroundColor(.koboldEmerald)
                            Text("Empfangen").font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("\(telegramStats.sent)").font(.system(size: 18.5, weight: .bold)).foregroundColor(.blue)
                            Text("Gesendet").font(.system(size: 11.5)).foregroundColor(.secondary)
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
                        Text("Bot-Token").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
                        SecureField("123456:ABC-DEF1234...", text: $telegramToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14.5))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chat-ID (optional)").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
                        TextField("123456789", text: $telegramChatId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14.5))
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
                            Image(systemName: "paperplane.fill").font(.system(size: 14.5))
                            Text("Bot starten").font(.system(size: 15.5, weight: .medium))
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
    func connectionCard(
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
                        Text(name).font(.system(size: 17.5, weight: .bold))
                        Text(subtitle).font(.system(size: 13.5)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if isConnected {
                        HStack(spacing: 5) {
                            Circle().fill(Color.koboldEmerald).frame(width: 7, height: 7)
                            Text("Verbunden").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.koboldEmerald)
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

    // MARK: - MCP Server Settings (inside Verbindungen)

    @State private var mcpServers: [(name: String, command: String, status: String)] = []
    @State private var mcpNewName: String = ""
    @State private var mcpNewCommand: String = ""
    @State private var mcpNewArgs: String = ""

    @ViewBuilder
    private func mcpServersSection() -> some View {
        sectionTitle("MCP Server (Model Context Protocol)")

        FuturisticBox(icon: "server.rack", title: "MCP Server", accent: .koboldCyan) {
            Text("Verbinde externe Tool-Server via MCP. Tools werden automatisch dem Agent zur Verfügung gestellt.")
                .font(.caption).foregroundColor(.secondary)

            if mcpServers.isEmpty {
                Text("Keine MCP-Server konfiguriert")
                    .font(.system(size: 13.5)).foregroundColor(.secondary.opacity(0.6))
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(mcpServers.enumerated()), id: \.offset) { _, server in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(server.status == "connected" ? Color.koboldEmerald : Color.orange)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 13.5, weight: .medium))
                            Text(server.command).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(server.status).font(.system(size: 11.5)).foregroundColor(.secondary)
                        Button(action: {
                            let name = server.name
                            Task {
                                try? await MCPConfigManager.shared.removeConfig(name)
                                await loadMCPServers()
                            }
                        }) {
                            Image(systemName: "trash").font(.system(size: 12.5)).foregroundColor(.red.opacity(0.7))
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.3)
                }
            }

            // Add new server
            Divider().opacity(0.3)
            Text("Server hinzufügen").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("Name", text: $mcpNewName)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                TextField("Befehl (z.B. npx)", text: $mcpNewCommand)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                TextField("Argumente (kommagetrennt)", text: $mcpNewArgs)
                    .textFieldStyle(.roundedBorder)
                Button("Hinzufügen") {
                    guard !mcpNewName.isEmpty, !mcpNewCommand.isEmpty else { return }
                    let args = mcpNewArgs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let name = mcpNewName
                    let cmd = mcpNewCommand
                    Task {
                        let config = MCPClient.ServerConfig(name: name, command: cmd, args: args, env: [:])
                        try? await MCPConfigManager.shared.saveConfig(config)
                        // Connect server immediately (tools register on next agent call)
                        try? await MCPConfigManager.shared.mcpClient.connectServer(config)
                        await MainActor.run {
                            mcpNewName = ""
                            mcpNewCommand = ""
                            mcpNewArgs = ""
                        }
                        await loadMCPServers()
                    }
                }
                .disabled(mcpNewName.isEmpty || mcpNewCommand.isEmpty)
            }
            .font(.system(size: 12.5))
        }
    }

    private func loadMCPServers() async {
        let mgr = MCPConfigManager.shared
        let configs = await mgr.loadConfigs()
        let status = await mgr.getStatus()
        mcpServers = configs.map { config in
            let connected = status.first(where: { $0.name == config.name })?.connected ?? false
            return (name: config.name, command: config.command, status: connected ? "connected" : "disconnected")
        }
    }

    // MARK: - Sprache & Audio (TTS / STT / Sounds)

    @AppStorage("kobold.tts.voice") private var ttsVoice: String = "de-DE"
    @AppStorage("kobold.tts.rate") private var ttsRate: Double = 0.5
    @AppStorage("kobold.tts.volume") private var ttsVolume: Double = 0.8
    @AppStorage("kobold.tts.autoSpeak") private var ttsAutoSpeak: Bool = false
    @State private var ttsTestText: String = "Hallo! Ich bin dein KoboldOS Assistent."

    @ViewBuilder
    private func speechAndAudioSection() -> some View {
        sectionTitle("Sprache & Audio")

        // Systemsounds
        HStack(alignment: .top, spacing: 16) {
            FuturisticBox(icon: "speaker.wave.2.fill", title: "Systemsounds", accent: .koboldGold) {
                    Toggle("Sounds aktivieren", isOn: $soundsEnabled)
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
            .frame(maxHeight: .infinity, alignment: .top)

            FuturisticBox(icon: "globe", title: "Sprache", accent: .koboldGold) {
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
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // TTS Section
        FuturisticBox(icon: "speaker.wave.3.fill", title: "Text-to-Speech", accent: .koboldEmerald) {
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
                        .font(.system(size: 14.5))

                    Button {
                        TTSManager.shared.speak(ttsTestText, voice: ttsVoice, rate: Float(ttsRate))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 12.5))
                            Text("Test").font(.system(size: 14.5, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.koboldEmerald)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    if TTSManager.shared.isSpeaking {
                        Button(action: { TTSManager.shared.stop() }) {
                            Image(systemName: "stop.fill").font(.system(size: 12.5))
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
        }

        // STT Section
        FuturisticBox(icon: "mic.fill", title: "Speech-to-Text (Whisper)", accent: .koboldEmerald) {
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
                                .font(.system(size: 13.5, weight: .medium)).foregroundColor(.koboldEmerald)
                        }
                    } else if STTManager.shared.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Lade Model...")
                                .font(.system(size: 13.5)).foregroundColor(.secondary)
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

        settingsSaveButton(section: "Sprache & Audio")
    }

    @ViewBuilder
    private func skillsSettingsSection() -> some View {
        sectionTitle("Skills")

        // Verwalten box FIRST (above active skills)
        FuturisticBox(icon: "folder.fill", title: "Skills verwalten", accent: .koboldGold) {
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
                        Image(systemName: "arrow.clockwise").font(.system(size: 14.5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.koboldEmerald)
                    .help("Skills neu laden")
                }
        }

        // Active Skills list
        FuturisticBox(icon: "sparkles", title: "Aktive Skills", accent: .koboldGold) {
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
                                Text(skill.name).font(.system(size: 15.5, weight: .medium))
                                Text(skill.filename).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { skills[idx].isEnabled },
                                set: { newVal in
                                    skills[idx].isEnabled = newVal
                                    // Synchronous UserDefaults save — no fire-and-forget Task
                                    var names = UserDefaults.standard.stringArray(forKey: "kobold.skills.enabled") ?? []
                                    if newVal {
                                        if !names.contains(skill.name) { names.append(skill.name) }
                                    } else {
                                        names.removeAll { $0 == skill.name }
                                    }
                                    UserDefaults.standard.set(names, forKey: "kobold.skills.enabled")
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        if idx < skills.count - 1 { Divider() }
                    }
                }
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
    private func agentsSettingsSection() -> some View {
        sectionTitle("Agenten")
        AgentsView(viewModel: viewModel)
            .frame(minHeight: 600)
    }

    @ViewBuilder
    private func agentPersonalitySection() -> some View {
        sectionTitle("Agent-Persönlichkeit")

        FuturisticBox(icon: "bubble.left.and.bubble.right.fill", title: "Kommunikation", accent: .koboldGold) {

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
        }

        FuturisticBox(icon: "heart.fill", title: "Soul.md — Kernidentität", accent: .koboldEmerald) {
                Text("Definiert wer der Agent im Kern ist. Grundlegende Werte, Identität und Verhaltensmuster.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $agentSoul)
                    .font(.system(size: 14.5, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if agentSoul.isEmpty {
                    Text("Leer = Standard-Persönlichkeit (KoboldOS)")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
        }

        FuturisticBox(icon: "theatermasks.fill", title: "Personality.md — Verhaltensstil", accent: .koboldGold) {
                Text("Beschreibt wie der Agent kommuniziert: Tonfall, Humor, Formalität, Eigenheiten.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $agentPersonality)
                    .font(.system(size: 14.5, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
                if agentPersonality.isEmpty {
                    Text("Leer = neutraler, hilfsbereiter Stil")
                        .font(.caption2).foregroundColor(.secondary).italic()
                }
        }

        // Verhaltensregeln (gelb)
        FuturisticBox(icon: "list.bullet.clipboard.fill", title: "Verhaltensregeln", accent: .koboldGold) {
                Text("Feste Regeln, die der Agent immer befolgen muss. Z.B. 'Antworte immer auf Deutsch', 'Frage bei Löschvorgängen immer nach'.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $behaviorRules)
                    .font(.system(size: 14.5, design: .monospaced))
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
        }

        // Goals
        FuturisticBox(icon: "target", title: "Ziele", accent: .koboldEmerald) {
            Text("Langfristige Ziele die das autonome Verhalten deines Agenten stark beeinflussen. Ziele fließen in den System-Prompt und die proaktiven Vorschläge ein.")
                .font(.caption).foregroundColor(.secondary)

            ForEach(Array(ProactiveEngine.shared.goals.enumerated()), id: \.element.id) { idx, goal in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { ProactiveEngine.shared.goals[idx].isActive },
                        set: { ProactiveEngine.shared.goals[idx].isActive = $0; ProactiveEngine.shared.saveGoals() }
                    ))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)

                    Picker("", selection: Binding(
                        get: { ProactiveEngine.shared.goals[idx].priority },
                        set: { ProactiveEngine.shared.goals[idx].priority = $0; ProactiveEngine.shared.saveGoals() }
                    )) {
                        ForEach(GoalEntry.GoalPriority.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu).frame(width: 80)

                    Text(goal.text).font(.system(size: 14.5)).lineLimit(2)
                    Spacer()
                    Button(action: { ProactiveEngine.shared.deleteGoal(goal.id) }) {
                        Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.red.opacity(0.7))
                    }.buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("Neues Ziel, z.B. 'Desktop aufgeräumt halten'", text: $newGoalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14.5))
                    .onSubmit { addNewGoal() }
                Button("Hinzufügen") { addNewGoal() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newGoalText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if ProactiveEngine.shared.goals.isEmpty {
                Text("Beispiele: 'Systemgesundheit überwachen', 'Code vor dem Commit reviewen', 'Meine Termine im Blick behalten'")
                    .font(.caption2).foregroundColor(.secondary).italic()
            }
        }

        // MARK: Autonomie & Proaktivität
        Group {
        sectionTitle("Autonomie & Proaktivität")

        FuturisticBox(icon: "lightbulb.fill", title: "Proaktive Vorschläge", accent: .koboldGold) {
            Text("Der Agent analysiert regelmäßig den Kontext und schlägt passende Aktionen vor — Morgen-Briefings, Fehlerdiagnosen, Systemchecks.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Proaktive Vorschläge aktivieren", isOn: $proactiveEngine.isEnabled)
                .toggleStyle(.switch).tint(.koboldEmerald)

            Toggle("Agent darf eigenständig anschreiben", isOn: AppStorageToggle("kobold.proactive.allowInitiate", default: false))
                .toggleStyle(.switch).tint(.koboldGold)
            Text("Erlaubt dem Agent, von sich aus Nachrichten zu senden — z.B. Erinnerungen, Warnungen oder Hinweise.")
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
        }

        settingsSaveButton(section: "Persönlichkeit")
        } // end Group
    }

    @State private var newGoalText: String = ""
    private func addNewGoal() {
        let text = newGoalText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        ProactiveEngine.shared.addGoal(GoalEntry(text: text))
        newGoalText = ""
    }

    // MARK: - Memory Policy & Verhaltensregeln

    @AppStorage("kobold.agent.memoryPolicy") private var memoryPolicy: String = "auto"
    @AppStorage("kobold.agent.behaviorRules") private var behaviorRules: String = ""
    @AppStorage("kobold.agent.memoryRules") private var memoryRules: String = ""

    @ViewBuilder
    private func memoryPolicySection() -> some View {
        sectionTitle("Gedächtnis-Richtlinie")

        FuturisticBox(icon: "brain.head.profile", title: "Memory Policy", accent: .koboldEmerald) {
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
        }

        FuturisticBox(icon: "brain.fill", title: "Gedächtnis-Regeln", accent: .koboldEmerald) {
                Text("Freitext-Anweisungen wie der Agent mit Erinnerungen umgehen soll. Z.B. 'Merke dir meine Lieblingsfarbe', 'Vergiss nie meine Termine'.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $memoryRules)
                    .font(.system(size: 14.5, design: .monospaced))
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
        }
    }

    // MARK: - Proaktive Einstellungen

    @ObservedObject private var proactiveEngine = ProactiveEngine.shared

    // proactiveSettingsSection moved into memorySettingsSection above

    // MARK: - Über

    @ViewBuilder
    private func aboutSection() -> some View {
        sectionTitle("Über KoboldOS")

        // Big logo card
        GroupBox {
            HStack(spacing: 20) {
                Image(systemName: "lizard.fill")
                    .font(.system(size: 53))
                    .foregroundStyle(
                        LinearGradient(colors: [.koboldGold, .koboldEmerald], startPoint: .top, endPoint: .bottom)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("KoboldOS").font(.title.bold())
                    Text("Alpha v0.3.1").font(.title3).foregroundColor(.koboldGold)
                    Text("Dein lokaler KI-Assistent für macOS")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
        }

        FuturisticBox(icon: "info.circle", title: "Build-Info", accent: .koboldGold) {
                infoRow("Version", "Alpha v0.3.1")
                infoRow("Build", "2026-02-23")
                infoRow("Swift", "6.0")
                infoRow("Plattform", "macOS 14+ (Sonoma)")
                infoRow("Backend", "Ollama \(viewModel.ollamaStatus)")
                infoRow("PID", "\(ProcessInfo.processInfo.processIdentifier)")
        }

        FuturisticBox(icon: "heart.fill", title: "Credits", accent: .koboldGold) {
                Text("Entwickelt von der KoboldOS Community")
                Text("Powered by Ollama · Swift 6 · SwiftUI")
                    .font(.caption).foregroundColor(.secondary)
        }

        FuturisticBox(icon: "link", title: "Links", accent: .koboldEmerald) {
                linkButton("Modellbibliothek (Ollama)", url: "https://ollama.ai/library")
                linkButton("GitHub", url: "https://github.com/FunkJood/KoboldOS")
                linkButton("Problem melden", url: "https://github.com/FunkJood/KoboldOS/issues")
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
        .font(.system(size: 15.5))
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

// MARK: - Helpers

private extension Int {
    /// Returns nil if zero, otherwise self. Used for UserDefaults with default fallback.
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Idle Tasks Settings (eingebettet in Allgemein)

struct IdleTasksSettingsView: View {
    @ObservedObject private var proactiveEngine = ProactiveEngine.shared
    @State private var showAddForm = false
    @State private var newIdleName = ""
    @State private var newIdlePrompt = ""
    @State private var newIdlePriority: GoalEntry.GoalPriority = .medium
    @State private var newIdleCooldown: Int = 60

    var body: some View {
        FuturisticBox(icon: "moon.zzz.fill", title: "Idle Aufgaben", accent: .indigo) {
            Text("Aufgaben die der Agent automatisch erledigt, wenn du den Computer nicht benutzt.")
                .font(.caption).foregroundColor(.secondary)

            // Hauptschalter
            HStack {
                Toggle("Idle Aufgaben aktivieren", isOn: $proactiveEngine.idleTasksEnabled)
                    .toggleStyle(.switch).tint(.indigo)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(proactiveEngine.idleTasksEnabled ? Color.indigo : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(proactiveEngine.idleTasksEnabled ? "Aktiv" : "Aus")
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Statistik
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erledigt").font(.caption2).foregroundColor(.secondary)
                    Text("\(proactiveEngine.idleTasksCompleted)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aktive Tasks").font(.caption2).foregroundColor(.secondary)
                    Text("\(proactiveEngine.idleTasks.filter(\.enabled).count)/\(proactiveEngine.idleTasks.count)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }
                Spacer()
            }

            Divider()

            // Aufgabenliste
            HStack {
                Text("Aufgaben").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(action: { withAnimation { showAddForm.toggle() } }) {
                    Label(showAddForm ? "Abbrechen" : "Hinzufügen", systemImage: showAddForm ? "xmark" : "plus")
                        .font(.caption)
                }.buttonStyle(.bordered).controlSize(.small)
            }

            if showAddForm {
                VStack(spacing: 8) {
                    TextField("Name (z.B. 'Downloads aufräumen')", text: $newIdleName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Prompt (Anweisung an den Agent)", text: $newIdlePrompt)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Priorität", selection: $newIdlePriority) {
                            ForEach(GoalEntry.GoalPriority.allCases, id: \.self) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }.pickerStyle(.segmented).frame(maxWidth: 200)
                        Picker("Cooldown", selection: $newIdleCooldown) {
                            Text("15m").tag(15); Text("30m").tag(30); Text("1h").tag(60)
                            Text("6h").tag(360); Text("12h").tag(720); Text("24h").tag(1440)
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                    HStack {
                        Spacer()
                        Button("Hinzufügen") {
                            let task = IdleTask(name: newIdleName.trimmingCharacters(in: .whitespaces),
                                                prompt: newIdlePrompt.trimmingCharacters(in: .whitespaces),
                                                priority: newIdlePriority,
                                                cooldownMinutes: newIdleCooldown)
                            proactiveEngine.addIdleTask(task)
                            newIdleName = ""; newIdlePrompt = ""; newIdlePriority = .medium; newIdleCooldown = 60
                            showAddForm = false
                        }
                        .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
                        .disabled(newIdleName.trimmingCharacters(in: .whitespaces).isEmpty || newIdlePrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(8)
                .background(Color.indigo.opacity(0.05))
                .cornerRadius(8)
            }

            if proactiveEngine.idleTasks.isEmpty {
                VStack(spacing: 6) {
                    Text("Definiere was der Agent tun soll wenn er nichts zu tun hat.")
                        .font(.caption).foregroundColor(.secondary).italic()
                    Text("Schnell hinzufügen:").font(.caption2.bold()).foregroundColor(.secondary)
                    ForEach(IdleTask.examples, id: \.id) { example in
                        Button(action: { proactiveEngine.addIdleTask(example) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 12)).foregroundColor(.indigo)
                                Text(example.name).font(.system(size: 13)).foregroundColor(.primary)
                                Spacer()
                                Text("Cooldown: \(example.cooldownMinutes / 60)h")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.indigo.opacity(0.06)).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                ForEach(Array(proactiveEngine.idleTasks.enumerated()), id: \.element.id) { idx, task in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { guard idx < proactiveEngine.idleTasks.count else { return false }; return proactiveEngine.idleTasks[idx].enabled },
                            set: { newVal in guard idx < proactiveEngine.idleTasks.count else { return }; proactiveEngine.idleTasks[idx].enabled = newVal; proactiveEngine.saveIdleTasks() }
                        ))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(.indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.name).font(.system(size: 13.5, weight: .medium))
                            Text(task.prompt).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(task.priority.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(task.priority == .high ? .orange : .secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill((task.priority == .high ? Color.orange : Color.secondary).opacity(0.15)))
                            HStack(spacing: 4) {
                                Image(systemName: "clock").font(.system(size: 10))
                                Text("\(task.cooldownMinutes)m").font(.system(size: 11, design: .monospaced))
                            }.foregroundColor(.secondary)
                        }
                        if task.runCount > 0 {
                            Text("x\(task.runCount)")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.indigo)
                        }
                        Button(action: { proactiveEngine.deleteIdleTask(task.id) }) {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundColor(.red.opacity(0.6))
                        }.buttonStyle(.plain)
                    }
                }
            }

            // Einstellungen (nur wenn aktiviert)
            if proactiveEngine.idleTasksEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timing").font(.system(size: 13, weight: .semibold))
                    HStack {
                        Text("Min. Leerlaufzeit").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $proactiveEngine.idleMinIdleMinutes) {
                            Text("2m").tag(2); Text("5m").tag(5); Text("10m").tag(10); Text("15m").tag(15); Text("30m").tag(30)
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                    HStack {
                        Text("Max. pro Stunde").font(.caption.bold()).foregroundColor(.secondary)
                        Picker("", selection: $proactiveEngine.idleMaxPerHour) {
                            Text("1").tag(1); Text("3").tag(3); Text("5").tag(5); Text("10").tag(10)
                        }.pickerStyle(.segmented).frame(maxWidth: 240)
                    }
                    Toggle("Bei User-Aktivität pausieren", isOn: $proactiveEngine.idlePauseOnUserActivity)
                        .toggleStyle(.switch).tint(.indigo)
                    Toggle("Bei Ausführung benachrichtigen", isOn: $proactiveEngine.idleNotifyOnExecution)
                        .toggleStyle(.switch).tint(.koboldEmerald)
                    Toggle("Nur Hochprioritäts-Tasks", isOn: $proactiveEngine.idleOnlyHighPriority)
                        .toggleStyle(.switch).tint(.indigo)
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Ruhezeiten", isOn: $proactiveEngine.idleQuietHoursEnabled)
                        .toggleStyle(.switch).tint(.indigo)
                    if proactiveEngine.idleQuietHoursEnabled {
                        HStack(spacing: 8) {
                            Text("Von").font(.caption.bold()).foregroundColor(.secondary)
                            Picker("", selection: $proactiveEngine.idleQuietHoursStart) {
                                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                            }.pickerStyle(.menu).frame(width: 80)
                            Text("Bis").font(.caption.bold()).foregroundColor(.secondary)
                            Picker("", selection: $proactiveEngine.idleQuietHoursEnd) {
                                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                            }.pickerStyle(.menu).frame(width: 80)
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Berechtigungen im Idle-Modus").font(.caption.bold()).foregroundColor(.secondary)
                    Toggle("Shell-Befehle", isOn: $proactiveEngine.idleAllowShell)
                        .toggleStyle(.switch).tint(.orange)
                    Toggle("Netzwerk-Zugriff", isOn: $proactiveEngine.idleAllowNetwork)
                        .toggleStyle(.switch).tint(.orange)
                    Toggle("Dateien schreiben", isOn: $proactiveEngine.idleAllowFileWrite)
                        .toggleStyle(.switch).tint(.orange)
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erlaubte Kategorien").font(.caption.bold()).foregroundColor(.secondary)
                    let categories = [("system", "System-Health"), ("error", "Fehler-Recovery"), ("time", "Tageszeit"), ("idle", "Leerlauf"), ("custom", "Benutzerdefiniert")]
                    let activeCategories = Set(proactiveEngine.idleCategoriesRaw.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
                    ForEach(categories, id: \.0) { key, label in
                        Toggle(label, isOn: Binding(
                            get: { activeCategories.contains(key) },
                            set: { enabled in
                                var cats = activeCategories
                                if enabled { cats.insert(key) } else { cats.remove(key) }
                                proactiveEngine.idleCategoriesRaw = cats.sorted().joined(separator: ",")
                            }
                        )).toggleStyle(.switch).tint(.indigo)
                    }
                }
            }
        }
    }
}
