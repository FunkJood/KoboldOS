import SwiftUI
import AppKit
import KoboldCore

// MARK: - Memory Type

enum MemoryType: String, CaseIterable, Identifiable {
    case kurzzeit = "Kurzzeit"
    case langzeit  = "Langzeit"
    case wissen    = "Wissen"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .kurzzeit: return "bolt.circle.fill"
        case .langzeit:  return "archivebox.fill"
        case .wissen:    return "book.closed.fill"
        }
    }

    var color: Color {
        switch self {
        case .kurzzeit: return .koboldEmerald
        case .langzeit:  return .blue
        case .wissen:    return .koboldGold
        }
    }

    var description: String {
        switch self {
        case .kurzzeit:
            return "Aktuelle Sitzung — wird nach Neustart überschrieben"
        case .langzeit:
            return "Dauerhaft gespeichert — bleibt über alle Sitzungen erhalten"
        case .wissen:
            return "Fakten & Fähigkeiten — Referenzwissen für den Agenten"
        }
    }

    /// Label prefix used to encode type in the stored block label
    var prefix: String {
        switch self {
        case .kurzzeit: return "kt."
        case .langzeit:  return "lz."
        case .wissen:    return "ws."
        }
    }

    static func from(label: String) -> MemoryType {
        if label.hasPrefix("lz.") { return .langzeit }
        if label.hasPrefix("ws.") { return .wissen }
        if label.hasPrefix("kt.") { return .kurzzeit }
        // Map well-known CoreMemory block labels to appropriate types
        switch label {
        case "persona", "human", "system":
            return .langzeit
        case "knowledge", "capabilities":
            return .wissen
        case "short_term":
            return .kurzzeit
        default:
            return .kurzzeit
        }
    }
}

// MARK: - MemoryBlock

struct MemoryBlock: Identifiable {
    let id = UUID()
    var label: String          // stored label (may include type prefix)
    var content: String
    var limit: Int
    var memoryType: MemoryType

    /// Display name without the type prefix
    var displayLabel: String {
        for type_ in MemoryType.allCases {
            if label.hasPrefix(type_.prefix) {
                return String(label.dropFirst(type_.prefix.count))
            }
        }
        return label
    }
}

// MARK: - MemoryView

struct MemoryView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    @State private var blocks: [MemoryBlock] = []
    @State private var isLoading = false
    @State private var showAddBlock = false
    @State private var saveStatus = ""
    @State private var searchText = ""
    @State private var filterType: MemoryType? = nil
    @State private var errorMsg = ""

    // Add block form
    @State private var newLabel = ""
    @State private var newContent = ""
    @State private var newType: MemoryType = .kurzzeit

    var filteredBlocks: [MemoryBlock] {
        var result = blocks
        if let type_ = filterType {
            result = result.filter { $0.memoryType == type_ }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayLabel.localizedCaseInsensitiveContains(searchText) ||
                $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    // Archival & versioning state
    @State private var archivalEntries: [(label: String, content: String, date: String)] = []
    @State private var archivalCount = 0
    @State private var archivalSize = 0
    @State private var memoryVersions: [(id: String, date: String, message: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                memoryHeader
                searchAndFilterBar
                memoryTypeInfo
                if !errorMsg.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(errorMsg).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Erneut versuchen") { Task { await loadMemory() } }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                memoryList
                archivalSection
                versioningSection
                snapshotsSection
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
        .task {
            await loadMemory()
            await loadArchival()
            await loadVersions()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadMemory() }
        }
        .sheet(isPresented: $showAddBlock) { addBlockSheet }
    }

    // MARK: - Header

    var memoryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gedächtnis").font(.title2.bold())
                Text("Erinnerungen, Wissen und Lernfortschritt des Agenten")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !saveStatus.isEmpty {
                Text(saveStatus)
                    .font(.caption).foregroundColor(.koboldEmerald)
                    .transition(.opacity)
                    .animation(.easeInOut, value: saveStatus)
            }
            GlassButton(title: "Neu", icon: "plus", isPrimary: true) {
                showAddBlock = true
            }
            .help("Neuen Gedächtnisblock hinzufügen")
            GlassButton(title: "Exportieren", icon: "square.and.arrow.up", isPrimary: false) {
                exportMemory()
            }
            .help("Alle Erinnerungen als JSON-Datei speichern")
            GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                Task { await loadMemory() }
            }
        }
    }

    // MARK: - Search & Filter

    var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Gedächtnis durchsuchen...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1)))

            // Type filter chips
            HStack(spacing: 6) {
                filterChip(nil, label: "Alle")
                ForEach(MemoryType.allCases) { type_ in
                    filterChip(type_, label: type_.rawValue)
                }
            }
        }
    }

    func filterChip(_ type_: MemoryType?, label: String) -> some View {
        let isSelected = filterType == type_
        let color: Color = type_.map { $0.color } ?? .secondary
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                filterType = isSelected ? nil : type_
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? color : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? color.opacity(0.2) : Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(isSelected ? color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Memory Type Info

    var memoryTypeInfo: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(MemoryType.allCases) { type_ in
                let count = blocks.filter { $0.memoryType == type_ }.count
                GlassCard(padding: 10, cornerRadius: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: type_.icon)
                            .font(.system(size: 16))
                            .foregroundColor(type_.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type_.rawValue).font(.system(size: 12, weight: .semibold))
                            Text(type_.description)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(type_.color)
                    }
                }
            }
        }
    }

    // MARK: - Memory List

    var memoryList: some View {
        Group {
            if isLoading {
                GlassProgressBar(value: 0.5, label: "Lade Gedächtnis...")
                    .padding(.horizontal, 4)
            } else if filteredBlocks.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredBlocks) { block in
                        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
                            MemoryBlockCard(block: $blocks[idx], onSave: {
                                Task { await saveBlock(blocks[idx]) }
                            }, onDelete: {
                                Task { await deleteBlock(label: blocks[idx].label) }
                            })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "brain.filled.head.profile")
                    .font(.system(size: 36)).foregroundColor(.secondary)
                Text(searchText.isEmpty && filterType == nil ? "Keine Erinnerungen" : "Keine Treffer")
                    .font(.headline)
                Text(searchText.isEmpty && filterType == nil
                     ? "Der Agent hat noch keine Erinnerungen. Füge welche hinzu oder lass den Agenten selbst lernen."
                     : "Keine Erinnerungen passen zur Suche oder zum Filter.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                if searchText.isEmpty && filterType == nil {
                    GlassButton(title: "Erste Erinnerung hinzufügen", icon: "plus", isPrimary: true) {
                        showAddBlock = true
                    }
                }
            }
            .frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: - Archival Memory Section

    var archivalSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Archiv", icon: "tray.full.fill")
                Text("Automatisch archivierte Erinnerungen wenn Core Memory >80% voll ist.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("\(archivalCount)").font(.title3.bold()).foregroundColor(.koboldEmerald)
                        Text("Einträge").font(.caption2).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(formatBytes(archivalSize)).font(.title3.bold()).foregroundColor(.blue)
                        Text("Gesamtgröße").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                        Task { await loadArchival() }
                    }
                }

                if !archivalEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(archivalEntries.prefix(5), id: \.content) { entry in
                            HStack(spacing: 8) {
                                Text("[\(entry.label)]")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.koboldGold)
                                Text(entry.content.prefix(60) + (entry.content.count > 60 ? "..." : ""))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.date)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if archivalEntries.count > 5 {
                            Text("... und \(archivalEntries.count - 5) weitere")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Memory Versioning Section

    var versioningSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Versionen", icon: "clock.arrow.circlepath")
                Text("Git-ähnliche Versionierung — jede Session erstellt einen Commit.")
                    .font(.caption).foregroundColor(.secondary)

                if memoryVersions.isEmpty {
                    Text("Keine Versionen vorhanden")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memoryVersions.prefix(10), id: \.id) { v in
                            HStack(spacing: 8) {
                                Text(String(v.id.prefix(8)))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.koboldEmerald)
                                Text(v.message.prefix(40) + (v.message.count > 40 ? "..." : ""))
                                    .font(.system(size: 10))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(v.date)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Button(action: { Task { await rollbackTo(v.id) } }) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                .help("Auf diese Version zurücksetzen")
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                        Task { await loadVersions() }
                    }
                }
            }
        }
    }

    // MARK: - Snapshots Section

    var snapshotsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Gedächtnis-Backup", icon: "externaldrive.fill")
                Text("Erstelle einen Snapshot aller Erinnerungen oder exportiere sie zur Sicherung.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    GlassButton(title: "Snapshot erstellen", icon: "camera", isPrimary: false) {
                        Task { await createSnapshot() }
                    }
                    .help("Speichert einen Zeitstempel-Snapshot auf dem Daemon-Server")
                    GlassButton(title: "Als JSON exportieren", icon: "square.and.arrow.up", isPrimary: false) {
                        exportMemory()
                    }
                    .help("Exportiert alle Erinnerungen als JSON-Datei auf deinem Mac")
                    Spacer()
                    Text("\(blocks.count) Block(s) gesamt")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Add Block Sheet

    var addBlockSheet: some View {
        VStack(spacing: 20) {
            Text("Neue Erinnerung").font(.title3.bold()).padding(.top, 20)

            // Memory Type Picker
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Gedächtnistyp").font(.caption.bold()).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("Wähle den passenden Typ für diese Erinnerung")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(MemoryType.allCases) { type_ in
                        Button(action: { newType = type_ }) {
                            HStack(spacing: 5) {
                                Image(systemName: type_.icon).font(.system(size: 11))
                                Text(type_.rawValue).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(newType == type_ ? type_.color : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(newType == type_ ? type_.color.opacity(0.2) : Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(newType == type_ ? type_.color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(newType.description).font(.caption2).foregroundColor(.secondary).padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Label").font(.caption.bold()).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("Eindeutiger Name für diesen Block (z.B. user_name, project_goal)")
                        .font(.caption).foregroundColor(.secondary)
                }
                GlassTextField(text: $newLabel, placeholder: "z.B. user_name, aktuelle_aufgabe...")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Inhalt").font(.caption.bold()).foregroundColor(.secondary)
                TextEditor(text: $newContent)
                    .font(.system(size: 13))
                    .frame(minHeight: 100, maxHeight: 200)
                    .padding(8)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
            }

            HStack(spacing: 12) {
                GlassButton(title: "Abbrechen", isPrimary: false) {
                    showAddBlock = false; newLabel = ""; newContent = ""
                }
                GlassButton(title: "Hinzufügen", icon: "plus", isPrimary: true,
                            isDisabled: newLabel.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await addBlock() }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 420)
        .background(Color.koboldBackground)
    }

    // MARK: - Networking

    func loadMemory() async {
        isLoading = true
        errorMsg = ""
        defer { isLoading = false }

        guard viewModel.isConnected else {
            errorMsg = "Daemon nicht verbunden"
            return
        }

        guard let url = URL(string: viewModel.baseURL + "/memory") else {
            errorMsg = "Ungültige URL"
            return
        }

        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                errorMsg = "HTTP-Fehler \(http.statusCode)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blockList = json["blocks"] as? [[String: Any]] else {
                errorMsg = "Ungültige Antwort vom Daemon"
                return
            }

            blocks = blockList.compactMap { item in
                guard let label = item["label"] as? String,
                      let value = item["content"] as? String ?? item["value"] as? String else { return nil }
                let limit = item["limit"] as? Int ?? 2000
                let type_ = MemoryType.from(label: label)
                return MemoryBlock(label: label, content: value, limit: limit, memoryType: type_)
            }
        } catch {
            errorMsg = "Verbindungsfehler: \(error.localizedDescription)"
        }
    }

    func saveBlock(_ block: MemoryBlock) async {
        guard let url = URL(string: viewModel.baseURL + "/memory/update") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "label": block.label,
            "content": block.content
        ])
        _ = try? await URLSession.shared.data(for: req)
        withAnimation { saveStatus = "Gespeichert ✓" }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func deleteBlock(label: String) async {
        guard let url = URL(string: viewModel.baseURL + "/memory/update") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["label": label, "content": "", "delete": true])
        _ = try? await URLSession.shared.data(for: req)
        blocks.removeAll { $0.label == label }
    }

    func addBlock() async {
        let rawLabel = newLabel.trimmingCharacters(in: .whitespaces)
        let content  = newContent.trimmingCharacters(in: .whitespaces)
        guard !rawLabel.isEmpty else { return }
        // Encode memory type as prefix
        let fullLabel = newType.prefix + rawLabel
        let block = MemoryBlock(label: fullLabel, content: content, limit: 500, memoryType: newType)
        blocks.append(block)
        await saveBlock(block)
        showAddBlock = false; newLabel = ""; newContent = ""
    }

    func createSnapshot() async {
        guard let url = URL(string: viewModel.baseURL + "/memory/snapshot") else { return }
        let req = viewModel.authorizedRequest(url: url, method: "POST")
        _ = try? await URLSession.shared.data(for: req)
        withAnimation { saveStatus = "Snapshot erstellt ✓" }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func exportMemory() {
        let exportData: [[String: Any]] = blocks.map {
            ["label": $0.label, "display_label": $0.displayLabel,
             "content": $0.content, "type": $0.memoryType.rawValue, "limit": $0.limit]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KoboldOS_Gedaechtnis_\(formattedDate()).json"
        panel.allowedContentTypes = [.json]
        panel.message = "Exportiere alle Gedächtnisblöcke als JSON"
        if panel.runModal() == .OK, let url = panel.url {
            try? json.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { saveStatus = "Exportiert ✓" }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { self.saveStatus = "" }
            }
        }
    }

    // MARK: - Archival & Versioning Data

    func loadArchival() async {
        // Load from KoboldCore directly since ArchivalMemoryStore is in-process
        let store = KoboldCore.ArchivalMemoryStore.shared
        let entries = await store.allEntries()
        archivalCount = entries.count
        archivalSize = await store.totalSize()
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM HH:mm"
        archivalEntries = entries.prefix(20).map { e in
            (label: e.label, content: e.content, date: fmt.string(from: e.timestamp))
        }
    }

    func loadVersions() async {
        let versions = await KoboldCore.MemoryVersionStore.shared.log(limit: 10)
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM HH:mm"
        memoryVersions = versions.map { v in
            (id: v.id, date: fmt.string(from: v.timestamp), message: v.message)
        }
    }

    func rollbackTo(_ versionId: String) async {
        guard let url = URL(string: viewModel.baseURL + "/memory/rollback") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": versionId])
        _ = try? await URLSession.shared.data(for: req)
        withAnimation { saveStatus = "Rollback ✓" }
        await loadMemory()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func formattedDate() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmm"
        return fmt.string(from: Date())
    }
}

// MARK: - MemoryBlockCard

struct MemoryBlockCard: View {
    @Binding var block: MemoryBlock
    let onSave: () -> Void
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                // Header row
                HStack(spacing: 8) {
                    // Memory type icon + color
                    Image(systemName: block.memoryType.icon)
                        .font(.system(size: 12))
                        .foregroundColor(block.memoryType.color)

                    GlassStatusBadge(label: block.displayLabel, color: block.memoryType.color, icon: "tag.fill")

                    Text(block.memoryType.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(block.memoryType.color.opacity(0.8))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(block.memoryType.color.opacity(0.1)))

                    Spacer()

                    // Character counter
                    Text("\(block.content.count)/\(block.limit)")
                        .font(.caption2)
                        .foregroundColor(block.content.count > block.limit ? .red : .secondary)

                    // Edit button
                    Button(action: {
                        if isEditing { onSave() }
                        withAnimation { isEditing.toggle() }
                    }) {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                            .foregroundColor(isEditing ? .koboldEmerald : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? "Speichern" : "Bearbeiten")

                    // Delete button
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Erinnerung löschen")
                    .confirmationDialog(
                        "Erinnerung '\(block.displayLabel)' löschen?",
                        isPresented: $showDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Löschen", role: .destructive) { onDelete() }
                        Button("Abbrechen", role: .cancel) {}
                    }
                }

                // Content editor / viewer
                if isEditing {
                    TextEditor(text: $block.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 160)
                        .padding(6)
                        .background(Color.black.opacity(0.2)).cornerRadius(6)
                        .scrollContentBackground(.hidden)

                    HStack {
                        Text(block.memoryType.description)
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        GlassButton(title: "Speichern", icon: "checkmark", isPrimary: true) {
                            onSave()
                            withAnimation { isEditing = false }
                        }
                    }
                } else {
                    Text(block.content.isEmpty ? "(leer)" : block.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(block.content.isEmpty ? .secondary : .primary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
