import SwiftUI
import KoboldCore

// MARK: - SecretsManagementView (UserDefaults-backed, synced with WebGUI)

struct SecretsManagementView: View {
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }

    // Matches WebGUI kobold.vault.entries JSON format exactly
    struct VaultEntry: Identifiable, Codable {
        var id: Int
        var name: String
        var value: String
        var tags: [String]
    }

    @State private var entries: [VaultEntry] = []
    @State private var newName = ""
    @State private var newValue = ""
    @State private var newTags: Set<String> = []
    @State private var showingAddSheet = false
    @State private var showValue: Set<Int> = []
    @State private var searchText = ""
    @State private var filterTag: String? = nil
    @State private var statusMessage = ""
    @State private var isLoading = false

    static let allTags = ["passwort", "api-key", "token", "zugangsdaten", "mail", "sonstiges"]
    static let tagColors: [String: Color] = [
        "passwort": .red, "api-key": .koboldGold, "token": .koboldEmerald,
        "zugangsdaten": .koboldGold, "mail": .blue, "sonstiges": .secondary
    ]
    static let tagIcons: [String: String] = [
        "passwort": "lock.fill", "api-key": "key.fill", "token": "lock.shield.fill",
        "zugangsdaten": "person.badge.key.fill", "mail": "envelope.fill", "sonstiges": "ellipsis.rectangle.fill"
    ]

    private static let udKey = "kobold.vault.entries"

    var filteredEntries: [VaultEntry] {
        var f = entries
        if let tag = filterTag { f = f.filter { $0.tags.contains(tag) } }
        if !searchText.isEmpty {
            let s = searchText.lowercased()
            f = f.filter { $0.name.lowercased().contains(s) || $0.tags.joined(separator: " ").lowercased().contains(s) }
        }
        return f
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.passwordManager).font(.title2.bold())
                    Text("Synchronisiert mit WebGUI").font(.caption).foregroundColor(.secondary)
                }
                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 14.5))
                    TextField(lang.searchDots, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.koboldSurface))
                .frame(width: 180)

                GlassButton(title: lang.addItem, icon: "plus", isPrimary: true) {
                    showingAddSheet = true
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            GlassDivider()

            // Tag filter row
            HStack(spacing: 6) {
                tagPill(nil, label: "Alle")
                ForEach(Self.allTags, id: \.self) { tag in
                    tagPill(tag, label: tag.capitalized)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)

            if isLoading {
                VStack {
                    Spacer()
                    ProgressView().scaleEffect(1.2)
                    Text(lang.loadingKeychain).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36)).foregroundColor(.secondary.opacity(0.4))
                    Text("Keine Treffer").font(.callout).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(20)
                }
            }

            // Status bar
            if !statusMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald).font(.caption)
                    Text(statusMessage).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
                .background(Color.koboldPanel)
            }

            // Footer
            HStack(spacing: 16) {
                Label("UserDefaults Synced", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                Label("\(entries.count) \(l10n.language.entries)", systemImage: "key.fill")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            .background(Color.koboldPanel)
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .onAppear { loadEntries() }
        .sheet(isPresented: $showingAddSheet) { addSheet }
    }

    // MARK: - Tag Pill

    func tagPill(_ tag: String?, label: String) -> some View {
        let active = filterTag == tag
        return Button(action: { filterTag = filterTag == tag ? nil : tag }) {
            Text(label)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .white : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(active ? Color.koboldEmerald : Color.koboldSurface))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 49))
                .foregroundColor(.secondary.opacity(0.4))
            Text(lang.noSecretsStored)
                .font(.title3).foregroundColor(.secondary)
            Text(lang.secretsEmptyDesc)
                .font(.caption).foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            GlassButton(title: lang.createFirstSecret, icon: "plus") {
                showingAddSheet = true
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entry Row

    func entryRow(_ entry: VaultEntry) -> some View {
        let primaryTag = entry.tags.first ?? "sonstiges"
        let color = Self.tagColors[primaryTag] ?? .secondary
        let icon = Self.tagIcons[primaryTag] ?? "ellipsis.rectangle.fill"

        return GlassCard(padding: 12, cornerRadius: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18.5))
                    .foregroundColor(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 15.5, weight: .semibold))
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(Self.tagColors[tag] ?? .secondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill((Self.tagColors[tag] ?? .secondary).opacity(0.15)))
                        }
                    }
                    if showValue.contains(entry.id) {
                        Text(entry.value)
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else {
                        Text(maskValue(entry.value))
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Button(action: { toggleVisibility(entry) }) {
                        Image(systemName: showValue.contains(entry.id) ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14.5))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.koboldSurface)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(lang.showHide)

                    Button(action: { copyEntry(entry) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14.5))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.koboldSurface)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(lang.copyToClipboard)

                    Button(action: { deleteEntry(entry) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14.5))
                            .foregroundColor(.red.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(lang.delete)
                }
            }
        }
    }

    // MARK: - Add Sheet

    var addSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(lang.newSecret).font(.headline)
                Spacer()
                Button(action: { showingAddSheet = false }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Tags (multi-select)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(Self.allTags, id: \.self) { tag in
                            Button(action: {
                                if newTags.contains(tag) { newTags.remove(tag) }
                                else { newTags.insert(tag) }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: Self.tagIcons[tag] ?? "tag").font(.system(size: 13.5))
                                    Text(tag.capitalized).font(.system(size: 13.5, weight: .medium))
                                }
                                .foregroundColor(newTags.contains(tag) ? .white : (Self.tagColors[tag] ?? .secondary))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(
                                    Capsule().fill(newTags.contains(tag)
                                        ? (Self.tagColors[tag] ?? .secondary)
                                        : (Self.tagColors[tag] ?? .secondary).opacity(0.12))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Name field
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.nameDesignation).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    GlassTextField(text: $newName, placeholder: "z.B. OpenAI API Key")
                }

                // Value field
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.valueKey).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    SecureField(lang.enterSecretValue, text: $newValue)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
                        )
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button(lang.cancel) { showingAddSheet = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                GlassButton(title: l10n.language.save, icon: "lock.fill", isPrimary: true, isDisabled: newName.isEmpty || newValue.isEmpty) {
                    saveNewEntry()
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 400)
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    // MARK: - Storage (UserDefaults — synced with WebGUI)

    private func loadEntries() {
        isLoading = true
        if let raw = UserDefaults.standard.string(forKey: Self.udKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) {
            entries = decoded
        } else if let data = UserDefaults.standard.data(forKey: Self.udKey),
                  let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) {
            // Fallback: stored as Data (e.g. from JSONEncoder)
            entries = decoded
        }

        // Migration: Keychain → UserDefaults (einmalig)
        Task {
            let keychainKeys = await SecretStore.shared.allKeys()
            var migrated = 0
            for key in keychainKeys {
                if !entries.contains(where: { $0.name.lowercased() == key.lowercased() }) {
                    if let val = await SecretStore.shared.get(key), !val.isEmpty {
                        let tag = guessTag(key)
                        entries.append(VaultEntry(
                            id: Int(Date().timeIntervalSince1970 * 1000) + Int.random(in: 0...999),
                            name: key,
                            value: val,
                            tags: [tag]
                        ))
                        migrated += 1
                    }
                }
            }
            if migrated > 0 {
                persistEntries()
                await MainActor.run {
                    statusMessage = "\(migrated) Einträge aus Keychain migriert"
                    clearStatusAfterDelay()
                }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func persistEntries() {
        if let data = try? JSONEncoder().encode(entries),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.udKey)
        }
    }

    private func saveNewEntry() {
        guard !newName.isEmpty, !newValue.isEmpty else { return }
        let tags = newTags.isEmpty ? ["sonstiges"] : Array(newTags)
        let entry = VaultEntry(
            id: Int(Date().timeIntervalSince1970 * 1000) + Int.random(in: 0...999),
            name: newName.trimmingCharacters(in: .whitespaces),
            value: newValue,
            tags: tags
        )
        entries.append(entry)
        persistEntries()
        newName = ""
        newValue = ""
        newTags = []
        showingAddSheet = false
        statusMessage = "'\(entry.name)' gespeichert"
        clearStatusAfterDelay()
    }

    private func deleteEntry(_ entry: VaultEntry) {
        entries.removeAll { $0.id == entry.id }
        showValue.remove(entry.id)
        persistEntries()
        statusMessage = "'\(entry.name)' gelöscht"
        clearStatusAfterDelay()
    }

    private func copyEntry(_ entry: VaultEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.value, forType: .string)
        statusMessage = "'\(entry.name)' kopiert (30s)"
        let val = entry.value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if NSPasteboard.general.string(forType: .string) == val {
                NSPasteboard.general.clearContents()
            }
        }
        clearStatusAfterDelay()
    }

    private func toggleVisibility(_ entry: VaultEntry) {
        if showValue.contains(entry.id) {
            showValue.remove(entry.id)
        } else {
            showValue.insert(entry.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                showValue.remove(entry.id)
            }
        }
    }

    // MARK: - Helpers

    private func maskValue(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 8)) }
        return "\(value.prefix(4))\(String(repeating: "•", count: min(value.count - 8, 16)))\(value.suffix(4))"
    }

    private func guessTag(_ key: String) -> String {
        let k = key.lowercased()
        if k.contains("api") || k.contains("key") { return "api-key" }
        if k.contains("token") || k.contains("bearer") { return "token" }
        if k.contains("password") || k.contains("pass") { return "passwort" }
        if k.contains("user") || k.contains("login") || k.contains("cred") { return "zugangsdaten" }
        if k.contains("mail") || k.contains("email") { return "mail" }
        return "sonstiges"
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            statusMessage = ""
        }
    }
}
