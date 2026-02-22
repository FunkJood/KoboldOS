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

    var apiValue: String {
        switch self {
        case .kurzzeit: return "kurzzeit"
        case .langzeit: return "langzeit"
        case .wissen:   return "wissen"
        }
    }

    var description: String {
        switch self {
        case .kurzzeit:
            return "Aktuelle Sitzung — temporärer Kontext"
        case .langzeit:
            return "Dauerhaft — bleibt über alle Sitzungen"
        case .wissen:
            return "Gelerntes Wissen — Lösungen & Fakten"
        }
    }

    static func from(apiValue: String) -> MemoryType {
        switch apiValue {
        case "langzeit": return .langzeit
        case "wissen": return .wissen
        default: return .kurzzeit
        }
    }

    /// Legacy: Map old block labels to types
    static func from(label: String) -> MemoryType {
        if label.hasPrefix("lz.") { return .langzeit }
        if label.hasPrefix("ws.") { return .wissen }
        if label.hasPrefix("kt.") { return .kurzzeit }
        switch label {
        case "persona", "human", "system": return .langzeit
        case "knowledge", "capabilities": return .wissen
        case "short_term": return .kurzzeit
        default: return .kurzzeit
        }
    }
}

// MARK: - Tagged Memory Entry (for UI)

struct TaggedMemoryEntry: Identifiable {
    let id: String
    var text: String
    var memoryType: MemoryType
    var tags: [String]
    var timestamp: Date
}

// MARK: - Legacy MemoryBlock (for core memory blocks)

struct MemoryBlock: Identifiable {
    let id = UUID()
    var label: String
    var content: String
    var limit: Int
    var memoryType: MemoryType

    var displayLabel: String {
        for type_ in MemoryType.allCases {
            let prefix: String
            switch type_ {
            case .kurzzeit: prefix = "kt."
            case .langzeit: prefix = "lz."
            case .wissen: prefix = "ws."
            }
            if label.hasPrefix(prefix) {
                return String(label.dropFirst(prefix.count))
            }
        }
        return label
    }
}

// MARK: - MemoryView

struct MemoryView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager

    // Tagged entries (new system)
    @State private var entries: [TaggedMemoryEntry] = []
    @State private var allTags: [String: Int] = [:]

    // Legacy blocks
    @State private var blocks: [MemoryBlock] = []

    // UI State
    @State private var isLoading = false
    @State private var showAddEntry = false
    @State private var saveStatus = ""
    @State private var searchText = ""
    @State private var filterType: MemoryType? = nil
    @State private var filterTag: String? = nil
    @State private var errorMsg = ""
    @State private var showLegacyBlocks = false

    // Add entry form
    @State private var newText = ""
    @State private var newType: MemoryType = .langzeit
    @State private var newTags = ""

    // Archival & versioning state
    @State private var archivalEntries: [(label: String, content: String, date: String)] = []
    @State private var archivalCount = 0
    @State private var archivalSize = 0

    var filteredEntries: [TaggedMemoryEntry] {
        var result = entries
        if let type_ = filterType {
            result = result.filter { $0.memoryType == type_ }
        }
        if let tag = filterTag {
            result = result.filter { $0.tags.map { $0.lowercased() }.contains(tag.lowercased()) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.text.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                memoryHeader
                HStack(alignment: .top, spacing: 12) {
                    archivalSection
                    snapshotsSection
                }

                Divider().padding(.horizontal, 4)

                searchAndFilterBar
                tagFilterBar
                memoryTypeInfo

                if !errorMsg.isEmpty {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(errorMsg).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Erneut versuchen") { Task { await loadAll() } }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }

                taggedMemoryList

                // Legacy blocks toggle
                if !blocks.isEmpty {
                    legacyBlocksSection
                }
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
        .task { await loadAll() }
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadEntries() }
        }
        .sheet(isPresented: $showAddEntry) { addEntrySheet }
    }

    private func loadAll() async {
        await loadEntries()
        await loadMemory()
        await loadArchival()
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
                showAddEntry = true
            }
            .help("Neue Erinnerung hinzufügen")
            GlassButton(title: "Exportieren", icon: "square.and.arrow.up", isPrimary: false) {
                exportMemory()
            }
            GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                Task { await loadAll() }
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
                TextField("Erinnerungen durchsuchen...", text: $searchText)
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
                typeFilterChip(nil, label: "Alle")
                ForEach(MemoryType.allCases) { type_ in
                    typeFilterChip(type_, label: type_.rawValue)
                }
            }
        }
    }

    // MARK: - Tag Filter Bar

    var tagFilterBar: some View {
        Group {
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Tags:").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)

                        if filterTag != nil {
                            Button(action: { withAnimation { filterTag = nil } }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                    Text("Alle").font(.system(size: 10))
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(sortedTags, id: \.key) { tag, count in
                            tagChip(tag: tag, count: count)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    var sortedTags: [(key: String, value: Int)] {
        allTags.sorted { $0.value > $1.value }
    }

    func tagChip(tag: String, count: Int) -> some View {
        let isSelected = filterTag?.lowercased() == tag.lowercased()
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                filterTag = isSelected ? nil : tag
            }
        }) {
            HStack(spacing: 3) {
                Text("#\(tag)")
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(isSelected ? .koboldEmerald : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(isSelected ? Color.koboldEmerald.opacity(0.2) : Color.white.opacity(0.06))
                .overlay(Capsule().stroke(isSelected ? Color.koboldEmerald.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }

    func typeFilterChip(_ type_: MemoryType?, label: String) -> some View {
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
                let count = entries.filter { $0.memoryType == type_ }.count
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

    // MARK: - Tagged Memory List

    var taggedMemoryList: some View {
        Group {
            if isLoading && entries.isEmpty {
                GlassProgressBar(value: 0.5, label: "Lade Erinnerungen...")
                    .padding(.horizontal, 4)
            } else if filteredEntries.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        TaggedMemoryCard(entry: entry, onDelete: {
                            Task { await deleteEntry(id: entry.id) }
                        })
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
                Text(searchText.isEmpty && filterType == nil && filterTag == nil ? "Keine Erinnerungen" : "Keine Treffer")
                    .font(.headline)
                Text(searchText.isEmpty && filterType == nil && filterTag == nil
                     ? "Der Agent hat noch keine Erinnerungen gespeichert. Sprich mit ihm — er lernt automatisch."
                     : "Keine Erinnerungen passen zu deiner Suche.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                if searchText.isEmpty && filterType == nil && filterTag == nil {
                    GlassButton(title: "Erste Erinnerung hinzufügen", icon: "plus", isPrimary: true) {
                        showAddEntry = true
                    }
                }
            }
            .frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: - Legacy Blocks Section

    var legacyBlocksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation { showLegacyBlocks.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showLegacyBlocks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Text("Core Memory Blöcke").font(.system(size: 12, weight: .semibold))
                    Text("(\(blocks.count))").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if showLegacyBlocks {
                LazyVStack(spacing: 10) {
                    ForEach(blocks) { block in
                        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
                            LegacyMemoryBlockCard(block: $blocks[idx], onSave: {
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

    // MARK: - Snapshots Section

    var snapshotsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(title: "Gedächtnis-Backup", icon: "externaldrive.fill")
                Text("Erstelle einen Snapshot aller Erinnerungen.")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    GlassButton(title: "Snapshot erstellen", icon: "camera", isPrimary: false) {
                        Task { await createSnapshot() }
                    }
                    GlassButton(title: "Als JSON exportieren", icon: "square.and.arrow.up", isPrimary: false) {
                        exportMemory()
                    }
                    Spacer()
                    Text("\(entries.count) Erinnerungen · \(blocks.count) Blöcke")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Add Entry Sheet

    var addEntrySheet: some View {
        VStack(spacing: 20) {
            Text("Neue Erinnerung").font(.title3.bold()).padding(.top, 20)

            // Memory Type Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Typ").font(.caption.bold()).foregroundColor(.secondary)
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
                Text(newType.description).font(.caption2).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Inhalt").font(.caption.bold()).foregroundColor(.secondary)
                TextEditor(text: $newText)
                    .font(.system(size: 13))
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(8)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tags").font(.caption.bold()).foregroundColor(.secondary)
                    Text("(kommagetrennt)").font(.caption2).foregroundColor(.secondary)
                }
                GlassTextField(text: $newTags, placeholder: "z.B. coding, python, projekt...")
            }

            HStack(spacing: 12) {
                GlassButton(title: "Abbrechen", isPrimary: false) {
                    showAddEntry = false; newText = ""; newTags = ""
                }
                GlassButton(title: "Speichern", icon: "checkmark", isPrimary: true,
                            isDisabled: newText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await addEntry() }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
        .background(Color.koboldBackground)
    }

    // MARK: - Networking: Tagged Entries

    func loadEntries() async {
        guard viewModel.isConnected else { return }
        guard let url = URL(string: viewModel.baseURL + "/memory/entries") else { return }

        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entryList = json["entries"] as? [[String: Any]] else { return }

            let fmt = ISO8601DateFormatter()
            entries = entryList.compactMap { item in
                guard let id = item["id"] as? String,
                      let text = item["text"] as? String else { return nil }
                let type = item["type"] as? String ?? "kurzzeit"
                let tags = item["tags"] as? [String] ?? []
                let ts = (item["timestamp"] as? String).flatMap { fmt.date(from: $0) } ?? Date()
                return TaggedMemoryEntry(id: id, text: text, memoryType: MemoryType.from(apiValue: type), tags: tags, timestamp: ts)
            }

            // Load tags
            if let tagsJson = json["tags"] as? [String: Int] {
                allTags = tagsJson
            } else {
                // Compute locally
                var tc: [String: Int] = [:]
                for e in entries {
                    for t in e.tags { tc[t.lowercased(), default: 0] += 1 }
                }
                allTags = tc
            }
        } catch {}
    }

    func addEntry() async {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let tags = newTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        guard let url = URL(string: viewModel.baseURL + "/memory/entries") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "type": newType.apiValue,
            "tags": tags
        ] as [String : Any])
        _ = try? await URLSession.shared.data(for: req)

        showAddEntry = false; newText = ""; newTags = ""
        withAnimation { saveStatus = "Gespeichert" }
        await loadEntries()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func deleteEntry(id: String) async {
        guard let url = URL(string: viewModel.baseURL + "/memory/entries") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "DELETE")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        _ = try? await URLSession.shared.data(for: req)
        entries.removeAll { $0.id == id }
    }

    // MARK: - Networking: Legacy Blocks

    func loadMemory() async {
        isLoading = true
        errorMsg = ""
        defer { isLoading = false }

        guard viewModel.isConnected else {
            errorMsg = "Daemon nicht verbunden"
            return
        }
        guard let url = URL(string: viewModel.baseURL + "/memory") else { return }

        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                errorMsg = "HTTP-Fehler \(http.statusCode)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blockList = json["blocks"] as? [[String: Any]] else { return }

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
        withAnimation { saveStatus = "Gespeichert" }
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

    // MARK: - Archival & Versioning

    func loadArchival() async {
        let store = ArchivalMemoryStore.shared
        let entries = await store.allEntries()
        archivalCount = entries.count
        archivalSize = await store.totalSize()
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM HH:mm"
        archivalEntries = entries.prefix(20).map { e in
            (label: e.label, content: e.content, date: fmt.string(from: e.timestamp))
        }
    }

    func createSnapshot() async {
        guard let url = URL(string: viewModel.baseURL + "/memory/snapshot") else { return }
        let req = viewModel.authorizedRequest(url: url, method: "POST")
        _ = try? await URLSession.shared.data(for: req)
        withAnimation { saveStatus = "Snapshot erstellt" }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func exportMemory() {
        var exportData: [[String: Any]] = entries.map {
            ["id": $0.id, "text": $0.text, "type": $0.memoryType.apiValue, "tags": $0.tags,
             "timestamp": ISO8601DateFormatter().string(from: $0.timestamp)]
        }
        // Also include legacy blocks
        exportData += blocks.map {
            ["label": $0.label, "content": $0.content, "type": $0.memoryType.apiValue, "limit": $0.limit, "legacy": true] as [String : Any]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KoboldOS_Gedaechtnis_\(formattedDate()).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? json.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { saveStatus = "Exportiert" }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { self.saveStatus = "" }
            }
        }
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

// MARK: - TaggedMemoryCard

struct TaggedMemoryCard: View {
    let entry: TaggedMemoryEntry
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard(padding: 12, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: type badge + tags + date + delete
                HStack(spacing: 6) {
                    // Type badge
                    HStack(spacing: 3) {
                        Image(systemName: entry.memoryType.icon)
                            .font(.system(size: 10))
                        Text(entry.memoryType.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(entry.memoryType.color)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(entry.memoryType.color.opacity(0.15)))

                    // Tags
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.koboldEmerald.opacity(0.8))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.koboldEmerald.opacity(0.1)))
                    }

                    Spacer()

                    // Date
                    Text(formatDate(entry.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    // Delete
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Erinnerung löschen?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Löschen", role: .destructive) { onDelete() }
                        Button("Abbrechen", role: .cancel) {}
                    }
                }

                // Content
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM.yy HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - LegacyMemoryBlockCard

struct LegacyMemoryBlockCard: View {
    @Binding var block: MemoryBlock
    let onSave: () -> Void
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
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
                    Text("\(block.content.count)/\(block.limit)")
                        .font(.caption2)
                        .foregroundColor(block.content.count > block.limit ? .red : .secondary)
                    Button(action: {
                        if isEditing { onSave() }
                        withAnimation { isEditing.toggle() }
                    }) {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                            .foregroundColor(isEditing ? .koboldEmerald : .secondary)
                    }
                    .buttonStyle(.plain)
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Block '\(block.displayLabel)' löschen?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Löschen", role: .destructive) { onDelete() }
                        Button("Abbrechen", role: .cancel) {}
                    }
                }
                if isEditing {
                    TextEditor(text: $block.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 160)
                        .padding(6)
                        .background(Color.black.opacity(0.2)).cornerRadius(6)
                        .scrollContentBackground(.hidden)
                    HStack {
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
