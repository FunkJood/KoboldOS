import SwiftUI
import AppKit
import KoboldCore

// MARK: - Memory Type

enum MemoryType: String, CaseIterable, Identifiable {
    case kurzzeit  = "Kurzzeit"
    case langzeit  = "Langzeit"
    case wissen    = "Wissen"
    case lösungen  = "Lösungen"
    case fehler    = "Fehler"
    case regeln    = "Regeln"
    case verhalten = "Verhalten"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .kurzzeit:  return "bolt.circle.fill"
        case .langzeit:  return "archivebox.fill"
        case .wissen:    return "book.closed.fill"
        case .lösungen:  return "lightbulb.fill"
        case .fehler:    return "exclamationmark.triangle.fill"
        case .regeln:    return "shield.checkered"
        case .verhalten: return "figure.walk"
        }
    }

    var color: Color {
        switch self {
        case .kurzzeit:  return .koboldEmerald
        case .langzeit:  return .koboldEmerald
        case .wissen:    return .koboldGold
        case .lösungen:  return .blue
        case .fehler:    return .red
        case .regeln:    return .orange
        case .verhalten: return .purple
        }
    }

    var apiValue: String {
        switch self {
        case .kurzzeit:  return "kurzzeit"
        case .langzeit:  return "langzeit"
        case .wissen:    return "wissen"
        case .lösungen:  return "lösungen"
        case .fehler:    return "fehler"
        case .regeln:    return "regeln"
        case .verhalten: return "verhalten"
        }
    }

    var description: String {
        switch self {
        case .kurzzeit:
            return "Aktuelle Sitzung — temporärer Kontext"
        case .langzeit:
            return "Dauerhaft — bleibt über alle Sitzungen"
        case .wissen:
            return "Gelerntes Wissen — Fakten & Referenzen"
        case .lösungen:
            return "Bewährte Lösungen — was funktioniert hat"
        case .fehler:
            return "Bekannte Fehler — was schiefgegangen ist"
        case .regeln:
            return "Feste Regeln — Anweisungen die IMMER gelten"
        case .verhalten:
            return "Prozedurales Gedächtnis — Abläufe & Reaktionen"
        }
    }

    func localizedName(_ lang: AppLanguage) -> String {
        switch self {
        case .kurzzeit:  return lang.memShortTerm
        case .langzeit:  return lang.memLongTerm
        case .wissen:    return lang.memKnowledge
        case .lösungen:  return lang.memSolutions
        case .fehler:    return lang.memErrors
        case .regeln:    return lang.memRules
        case .verhalten: return lang.memBehavior
        }
    }

    func localizedDesc(_ lang: AppLanguage) -> String {
        switch self {
        case .kurzzeit:  return lang.memShortTermDesc
        case .langzeit:  return lang.memLongTermDesc
        case .wissen:    return lang.memKnowledgeDesc
        case .lösungen:  return lang.memSolutionsDesc
        case .fehler:    return lang.memErrorsDesc
        case .regeln:    return lang.memRulesDesc
        case .verhalten: return lang.memBehaviorDesc
        }
    }

    static func from(apiValue: String) -> MemoryType {
        switch apiValue {
        case "langzeit":  return .langzeit
        case "wissen":    return .wissen
        case "lösungen":  return .lösungen
        case "fehler":    return .fehler
        case "regeln":    return .regeln
        case "verhalten": return .verhalten
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
    var memoryTypes: [MemoryType]
    var tags: [String]
    var timestamp: Date
    var valence: Float = 0.0
    var arousal: Float = 0.5
    var linkedEntryId: String? = nil
    var source: String? = nil

    /// Backward-compat: primary type (first in array)
    var memoryType: MemoryType { memoryTypes.first ?? .kurzzeit }
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
            case .kurzzeit:  prefix = "kt."
            case .langzeit:  prefix = "lz."
            case .wissen:    prefix = "ws."
            case .lösungen:  prefix = "ls."
            case .fehler:    prefix = "fe."
            case .regeln:    prefix = "rg."
            case .verhalten: prefix = "vh."
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
    private var lang: AppLanguage { l10n.language }

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
    @State private var newTypes: Set<MemoryType> = [.langzeit]
    @State private var newTags = ""

    // Edit entry form
    @State private var editingEntry: TaggedMemoryEntry? = nil
    @State private var editText = ""
    @State private var editTypes: Set<MemoryType> = [.langzeit]
    @State private var editTags = ""

    // Archival & versioning state
    @State private var archivalEntries: [(label: String, content: String, date: String)] = []
    @State private var archivalCount = 0
    @State private var archivalSize = 0

    var filteredEntries: [TaggedMemoryEntry] {
        var result = entries
        if let type_ = filterType {
            result = result.filter { $0.memoryTypes.contains(type_) }
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
                            Button(lang.retry) { Task { await loadAll() } }
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
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .task { await loadAll() }
        .task {
            // P9: Replaces Timer.publish(every:15, on:.main) — auto-cancelled when view disappears
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, !isLoading else { continue }
                await loadEntries()
            }
        }
        .sheet(isPresented: $showAddEntry) { addEntrySheet }
        .sheet(item: $editingEntry) { entry in editEntrySheet(for: entry) }
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
                Text(lang.memTitle).font(.title2.bold())
                Text(lang.memSubtitle)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !saveStatus.isEmpty {
                Text(saveStatus)
                    .font(.caption).foregroundColor(.koboldEmerald)
                    .transition(.opacity)
                    .animation(.easeInOut, value: saveStatus)
            }
            GlassButton(title: lang.newLabel, icon: "plus", isPrimary: true) {
                showAddEntry = true
            }
            .help(lang.addMemoryHint)
            GlassButton(title: lang.exportLabel, icon: "square.and.arrow.up", isPrimary: false) {
                exportMemory()
            }
            GlassButton(title: lang.refreshLabel, icon: "arrow.clockwise", isPrimary: false) {
                Task { await loadAll() }
            }
        }
    }

    // MARK: - Search & Filter

    var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14.5))
                    .foregroundColor(.secondary)
                TextField(lang.memSearchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15.5))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1)))

            // Type filter chips
            HStack(spacing: 6) {
                typeFilterChip(nil, label: lang.allLabel)
                ForEach(MemoryType.allCases) { type_ in
                    typeFilterChip(type_, label: type_.localizedName(lang))
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
                        Text(lang.tagsLabel).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.secondary)

                        if filterTag != nil {
                            Button(action: { withAnimation { filterTag = nil } }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark").font(.system(size: 9))
                                    Text(lang.allLabel).font(.system(size: 12.5))
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
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
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
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? color : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? color.opacity(0.2) : Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(isSelected ? color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Memory Type Info

    var memoryTypeInfo: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            // Gesamt-Box
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { filterType = nil } }) {
                GlassCard(padding: 10, cornerRadius: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 18.5))
                            .foregroundColor(.koboldGold)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.totalLabel).font(.system(size: 14.5, weight: .semibold))
                            Text(lang.allMemories)
                                .font(.system(size: 11.5)).foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text("\(entries.count)")
                            .font(.system(size: 16.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.koboldGold)
                    }
                }
            }.buttonStyle(.plain)

            // Kategorie-Boxen
            ForEach(MemoryType.allCases) { type_ in
                let count = entries.filter { $0.memoryTypes.contains(type_) }.count
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { filterType = filterType == type_ ? nil : type_ } }) {
                    GlassCard(padding: 10, cornerRadius: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: type_.icon)
                                .font(.system(size: 18.5))
                                .foregroundColor(type_.color)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type_.localizedName(lang)).font(.system(size: 14.5, weight: .semibold))
                                Text(type_.localizedDesc(lang))
                                    .font(.system(size: 11.5)).foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text("\(count)")
                                .font(.system(size: 16.5, weight: .bold, design: .monospaced))
                                .foregroundColor(type_.color)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(filterType == type_ ? type_.color.opacity(0.5) : Color.clear, lineWidth: 2)
                    )
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tagged Memory List

    var taggedMemoryList: some View {
        Group {
            if isLoading && entries.isEmpty {
                GlassProgressBar(value: 0.5, label: lang.loadingMemories)
                    .padding(.horizontal, 4)
            } else if filteredEntries.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        TaggedMemoryCard(entry: entry, onDelete: {
                            Task { await deleteEntry(id: entry.id) }
                        }, onEdit: {
                            editText = entry.text
                            editTypes = Set(entry.memoryTypes)
                            editTags = entry.tags.joined(separator: ", ")
                            editingEntry = entry
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
                Text(searchText.isEmpty && filterType == nil && filterTag == nil ? lang.noMemoriesTitle : lang.noMatchesTitle)
                    .font(.headline)
                Text(searchText.isEmpty && filterType == nil && filterTag == nil
                     ? lang.noMemories
                     : lang.noMatchesDesc)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                if searchText.isEmpty && filterType == nil && filterTag == nil {
                    GlassButton(title: lang.addFirstMemory, icon: "plus", isPrimary: true) {
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
                        .font(.system(size: 12.5))
                    Text(lang.coreBlocks).font(.system(size: 14.5, weight: .semibold))
                    Text("(\(blocks.count))").font(.system(size: 13.5)).foregroundColor(.secondary)
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
                GlassSectionHeader(title: lang.archiveLabel, icon: "tray.full.fill")
                Text(lang.archiveAutoDesc)
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("\(archivalCount)").font(.title3.bold()).foregroundColor(.koboldEmerald)
                        Text(lang.entriesLabel).font(.caption2).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(formatBytes(archivalSize)).font(.title3.bold()).foregroundColor(.koboldGold)
                        Text(lang.totalSize).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    GlassButton(title: lang.refreshLabel, icon: "arrow.clockwise", isPrimary: false) {
                        Task { await loadArchival() }
                    }
                }
                if !archivalEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(archivalEntries.prefix(5), id: \.content) { entry in
                            HStack(spacing: 8) {
                                Text("[\(entry.label)]")
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.koboldGold)
                                Text(entry.content.prefix(60) + (entry.content.count > 60 ? "..." : ""))
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.date)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if archivalEntries.count > 5 {
                            Text(lang.andMore(archivalEntries.count - 5))
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
                GlassSectionHeader(title: lang.memBackup, icon: "externaldrive.fill")
                Text(lang.createSnapshot)
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    GlassButton(title: lang.createSnapshotBtn, icon: "camera", isPrimary: false) {
                        Task { await createSnapshot() }
                    }
                    GlassButton(title: lang.exportAsJson, icon: "square.and.arrow.up", isPrimary: false) {
                        exportMemory()
                    }
                    Spacer()
                    Text("\(lang.memoriesCount(entries.count)) · \(lang.blocksCount(blocks.count))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Add Entry Sheet

    var addEntrySheet: some View {
        VStack(spacing: 20) {
            Text(lang.newMemoryTitle).font(.title3.bold()).padding(.top, 20)

            // Memory Type Multi-Select
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(lang.categoriesLabel).font(.caption.bold()).foregroundColor(.secondary)
                    Text(lang.multipleAllowed).font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(MemoryType.allCases) { type_ in
                        let isOn = newTypes.contains(type_)
                        Button(action: {
                            if isOn && newTypes.count > 1 { newTypes.remove(type_) }
                            else if !isOn { newTypes.insert(type_) }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: type_.icon).font(.system(size: 13.5))
                                Text(type_.localizedName(lang)).font(.system(size: 14.5, weight: .medium))
                            }
                            .foregroundColor(isOn ? type_.color : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(isOn ? type_.color.opacity(0.2) : Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(isOn ? type_.color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let first = newTypes.first {
                    Text(first.localizedDesc(lang)).font(.caption2).foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.contentLabel).font(.caption.bold()).foregroundColor(.secondary)
                TextEditor(text: $newText)
                    .font(.system(size: 15.5))
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(8)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(lang.tagsNoColon).font(.caption.bold()).foregroundColor(.secondary)
                    Text(lang.commaSeparated).font(.caption2).foregroundColor(.secondary)
                }
                GlassTextField(text: $newTags, placeholder: lang.tagExample)
            }

            HStack(spacing: 12) {
                GlassButton(title: lang.cancel, isPrimary: false) {
                    showAddEntry = false; newText = ""; newTags = ""; newTypes = [.langzeit]
                }
                GlassButton(title: lang.save, icon: "checkmark", isPrimary: true,
                            isDisabled: newText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await addEntry() }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    // MARK: - Edit Entry Sheet

    func editEntrySheet(for entry: TaggedMemoryEntry) -> some View {
        VStack(spacing: 20) {
            Text(lang.editMemoryTitle).font(.title3.bold()).padding(.top, 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(lang.categoriesLabel).font(.caption.bold()).foregroundColor(.secondary)
                    Text(lang.multipleAllowed).font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(MemoryType.allCases) { type_ in
                        let isOn = editTypes.contains(type_)
                        Button(action: {
                            if isOn && editTypes.count > 1 { editTypes.remove(type_) }
                            else if !isOn { editTypes.insert(type_) }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: type_.icon).font(.system(size: 13.5))
                                Text(type_.localizedName(lang)).font(.system(size: 14.5, weight: .medium))
                            }
                            .foregroundColor(isOn ? type_.color : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(isOn ? type_.color.opacity(0.2) : Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(isOn ? type_.color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let first = editTypes.first {
                    Text(first.localizedDesc(lang)).font(.caption2).foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.contentLabel).font(.caption.bold()).foregroundColor(.secondary)
                TextEditor(text: $editText)
                    .font(.system(size: 15.5))
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(8)
                    .background(Color.black.opacity(0.2)).cornerRadius(8)
                    .scrollContentBackground(.hidden)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(lang.tagsNoColon).font(.caption.bold()).foregroundColor(.secondary)
                    Text(lang.commaSeparated).font(.caption2).foregroundColor(.secondary)
                }
                GlassTextField(text: $editTags, placeholder: lang.tagExample)
            }

            HStack(spacing: 12) {
                GlassButton(title: lang.cancel, isPrimary: false) {
                    editingEntry = nil
                }
                GlassButton(title: lang.save, icon: "checkmark", isPrimary: true,
                            isDisabled: editText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await updateEntry(id: entry.id) }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
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
                // Multi-category: parse "types" array, fallback to single "type"
                let memTypes: [MemoryType]
                if let typesArr = item["types"] as? [String], !typesArr.isEmpty {
                    memTypes = typesArr.map { MemoryType.from(apiValue: $0) }
                } else {
                    let type = item["type"] as? String ?? "kurzzeit"
                    memTypes = [MemoryType.from(apiValue: type)]
                }
                let tags = item["tags"] as? [String] ?? []
                let ts = (item["timestamp"] as? String).flatMap { fmt.date(from: $0) } ?? Date()
                let valence = (item["valence"] as? Double).map { Float($0) } ?? 0.0
                let arousal = (item["arousal"] as? Double).map { Float($0) } ?? 0.5
                let linkedId = item["linked_id"] as? String
                let source = item["source"] as? String
                return TaggedMemoryEntry(id: id, text: text, memoryTypes: memTypes, tags: tags, timestamp: ts, valence: valence, arousal: arousal, linkedEntryId: linkedId, source: source)
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
        let typesArr = newTypes.map { $0.apiValue }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "type": typesArr.first ?? "langzeit",
            "types": typesArr,
            "tags": tags
        ] as [String : Any])
        _ = try? await URLSession.shared.data(for: req)

        showAddEntry = false; newText = ""; newTags = ""; newTypes = [.langzeit]
        withAnimation { saveStatus = lang.savedStatus }
        await loadEntries()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func updateEntry(id: String) async {
        let text = editText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let tags = editTags.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let url = URL(string: viewModel.baseURL + "/memory/entries") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let typesArr = editTypes.map { $0.apiValue }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "text": text,
            "type": typesArr.first ?? "langzeit",
            "types": typesArr,
            "tags": tags
        ] as [String: Any])
        _ = try? await URLSession.shared.data(for: req)

        editingEntry = nil
        withAnimation { saveStatus = lang.updatedStatus }
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
            errorMsg = lang.daemonDisconnected
            return
        }
        guard let url = URL(string: viewModel.baseURL + "/memory") else { return }

        do {
            let (data, resp) = try await viewModel.authorizedData(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                errorMsg = "\(lang.httpError) \(http.statusCode)"
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
            errorMsg = "\(lang.connectionErrorPrefix): \(error.localizedDescription)"
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
        withAnimation { saveStatus = lang.savedStatus }
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
        withAnimation { saveStatus = lang.snapshotCreatedStatus }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { saveStatus = "" }
    }

    func exportMemory() {
        var exportData: [[String: Any]] = entries.map {
            ["id": $0.id, "text": $0.text,
             "type": $0.memoryType.apiValue,
             "types": $0.memoryTypes.map { $0.apiValue },
             "tags": $0.tags,
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
            withAnimation { saveStatus = lang.exportedStatus }
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
    let onEdit: () -> Void
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard(padding: 12, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: type badges + tags + date + delete
                HStack(spacing: 6) {
                    // Type badges (multi-category)
                    ForEach(entry.memoryTypes) { type_ in
                        HStack(spacing: 3) {
                            Image(systemName: type_.icon)
                                .font(.system(size: 12.5))
                            Text(type_.localizedName(lang))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(type_.color)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(type_.color.opacity(0.15)))
                    }

                    // Tags
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.koboldEmerald.opacity(0.8))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.koboldEmerald.opacity(0.1)))
                    }

                    // Valence indicator
                    if entry.valence != 0 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(entry.valence > 0 ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(String(format: "%.1f", entry.valence))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(entry.valence > 0 ? .green : .red)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill((entry.valence > 0 ? Color.green : Color.red).opacity(0.1)))
                    }

                    // Linked entry indicator
                    if let linkedId = entry.linkedEntryId {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text(String(linkedId.prefix(8)))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }

                    Spacer()

                    // Date
                    Text(formatDate(entry.timestamp))
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)

                    // Edit
                    Button(action: { onEdit() }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12.5))
                            .foregroundColor(.koboldGold.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    // Delete
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12.5))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(lang.deleteMemoryConfirm, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button(lang.delete, role: .destructive) { onDelete() }
                        Button(lang.cancel, role: .cancel) {}
                    }
                }

                // Content
                Text(entry.text)
                    .font(.system(size: 14.5))
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
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }
    @State private var isEditing = false
    @State private var showDeleteConfirm = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: block.memoryType.icon)
                        .font(.system(size: 14.5))
                        .foregroundColor(block.memoryType.color)
                    GlassStatusBadge(label: block.displayLabel, color: block.memoryType.color, icon: "tag.fill")
                    Text(block.memoryType.localizedName(lang))
                        .font(.system(size: 12.5))
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
                    .confirmationDialog(lang.deleteBlockConfirm(block.displayLabel), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button(lang.delete, role: .destructive) { onDelete() }
                        Button(lang.cancel, role: .cancel) {}
                    }
                }
                if isEditing {
                    TextEditor(text: $block.content)
                        .font(.system(size: 14.5, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 160)
                        .padding(6)
                        .background(Color.black.opacity(0.2)).cornerRadius(6)
                        .scrollContentBackground(.hidden)
                    HStack {
                        Spacer()
                        GlassButton(title: lang.save, icon: "checkmark", isPrimary: true) {
                            onSave()
                            withAnimation { isEditing = false }
                        }
                    }
                } else {
                    Text(block.content.isEmpty ? lang.emptyBlock : block.content)
                        .font(.system(size: 14.5, design: .monospaced))
                        .foregroundColor(block.content.isEmpty ? .secondary : .primary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
