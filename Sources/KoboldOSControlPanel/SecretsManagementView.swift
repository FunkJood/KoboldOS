import SwiftUI
import KoboldCore

// MARK: - SecretsManagementView (Keychain-backed)

struct SecretsManagementView: View {
    @State private var secrets: [SecretEntry] = []
    @State private var newKeyName: String = ""
    @State private var newKeyValue: String = ""
    @State private var selectedCategory: SecretCategory = .apiKey
    @State private var showingAddSheet: Bool = false
    @State private var showValue: Set<String> = []
    @State private var searchText: String = ""
    @State private var statusMessage: String = ""
    @State private var isLoading: Bool = false

    struct SecretEntry: Identifiable {
        let id: String // key name
        let name: String
        let category: SecretCategory
        let maskedValue: String
        var fullValue: String?
    }

    enum SecretCategory: String, CaseIterable {
        case apiKey     = "API-Key"
        case password   = "Passwort"
        case token      = "Token"
        case credential = "Zugangsdaten"
        case other      = "Sonstiges"

        var icon: String {
            switch self {
            case .apiKey:     return "key.fill"
            case .password:   return "lock.fill"
            case .token:      return "lock.shield.fill"
            case .credential: return "person.badge.key.fill"
            case .other:      return "ellipsis.rectangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .apiKey:     return .koboldGold
            case .password:   return .red
            case .token:      return .koboldEmerald
            case .credential: return .koboldGold
            case .other:      return .secondary
            }
        }
    }

    var filteredSecrets: [SecretEntry] {
        if searchText.isEmpty { return secrets }
        return secrets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passwort-Manager").font(.title2.bold())
                    Text("Sichere Keychain-Verwaltung").font(.caption).foregroundColor(.secondary)
                }
                Spacer()

                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 14.5))
                    TextField("Suchen...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.koboldSurface))
                .frame(width: 180)

                GlassButton(title: "Hinzufügen", icon: "plus", isPrimary: true) {
                    showingAddSheet = true
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            GlassDivider()

            if isLoading {
                VStack {
                    Spacer()
                    ProgressView().scaleEffect(1.2)
                    Text("Lade Keychain...").font(.caption).foregroundColor(.secondary).padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if secrets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filteredSecrets) { secret in
                            secretRow(secret)
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

            // Security info footer
            HStack(spacing: 16) {
                Label("macOS Keychain", systemImage: "lock.shield.fill")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                Label("Verschlüsselt", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                Label("\(secrets.count) Einträge", systemImage: "key.fill")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            .background(Color.koboldPanel)
        }
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .onAppear { loadSecrets() }
        .sheet(isPresented: $showingAddSheet) {
            addSecretSheet
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 49))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Keine Secrets gespeichert")
                .font(.title3).foregroundColor(.secondary)
            Text("API-Keys, Passwörter und Tokens werden sicher\nim macOS Keychain gespeichert.")
                .font(.caption).foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            GlassButton(title: "Erstes Secret anlegen", icon: "plus") {
                showingAddSheet = true
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Secret Row

    func secretRow(_ secret: SecretEntry) -> some View {
        GlassCard(padding: 12, cornerRadius: 12) {
            HStack(spacing: 12) {
                // Category icon
                Image(systemName: secret.category.icon)
                    .font(.system(size: 18.5))
                    .foregroundColor(secret.category.color)
                    .frame(width: 32, height: 32)
                    .background(secret.category.color.opacity(0.12))
                    .cornerRadius(8)

                // Name + Value
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(secret.name)
                            .font(.system(size: 15.5, weight: .semibold))
                        Text(secret.category.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(secret.category.color)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(secret.category.color.opacity(0.15)))
                    }
                    if showValue.contains(secret.id), let full = secret.fullValue {
                        Text(full)
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else {
                        Text(secret.maskedValue)
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 4) {
                    // Toggle visibility
                    Button(action: { toggleVisibility(secret) }) {
                        Image(systemName: showValue.contains(secret.id) ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14.5))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.koboldSurface)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Anzeigen/Verbergen")

                    // Copy
                    Button(action: { copySecret(secret) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14.5))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.koboldSurface)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("In Zwischenablage kopieren")

                    // Delete
                    Button(action: { deleteSecret(secret) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14.5))
                            .foregroundColor(.red.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Löschen")
                }
            }
        }
    }

    // MARK: - Add Secret Sheet

    var addSecretSheet: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text("Neues Secret").font(.headline)
                Spacer()
                Button(action: { showingAddSheet = false }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Category picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kategorie").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(SecretCategory.allCases, id: \.self) { cat in
                            Button(action: { selectedCategory = cat }) {
                                HStack(spacing: 4) {
                                    Image(systemName: cat.icon).font(.system(size: 13.5))
                                    Text(cat.rawValue).font(.system(size: 13.5, weight: .medium))
                                }
                                .foregroundColor(selectedCategory == cat ? .white : cat.color)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(
                                    selectedCategory == cat
                                    ? Capsule().fill(cat.color)
                                    : Capsule().fill(cat.color.opacity(0.12))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Name field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name / Bezeichnung").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    GlassTextField(text: $newKeyName, placeholder: "z.B. OpenAI API Key")
                }

                // Value field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wert / Schlüssel").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    SecureField("Geheimer Wert eingeben...", text: $newKeyValue)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
                        )
                }

                // Common presets
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schnell-Vorlagen").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        presetButton("OpenAI", name: "openai_api_key", category: .apiKey)
                        presetButton("Anthropic", name: "anthropic_api_key", category: .apiKey)
                        presetButton("GitHub", name: "github_token", category: .token)
                        presetButton("SSH-Key", name: "ssh_passphrase", category: .password)
                    }
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Button("Abbrechen") { showingAddSheet = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                GlassButton(title: "Speichern", icon: "lock.fill", isPrimary: true, isDisabled: newKeyName.isEmpty || newKeyValue.isEmpty) {
                    saveNewSecret()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 440)
        .background(ZStack { Color.koboldBackground; LinearGradient(colors: [Color.koboldEmerald.opacity(0.015), .clear, Color.koboldGold.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing) })
    }

    func presetButton(_ label: String, name: String, category: SecretCategory) -> some View {
        Button(action: {
            newKeyName = name
            selectedCategory = category
        }) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.koboldSurface))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadSecrets() {
        isLoading = true
        Task {
            let keys = await SecretStore.shared.allKeys()
            var entries: [SecretEntry] = []
            for key in keys {
                let cat = guessCategory(key)
                // Don't load values eagerly — avoids Keychain prompts on section open
                entries.append(SecretEntry(
                    id: key,
                    name: key,
                    category: cat,
                    maskedValue: String(repeating: "\u{2022}", count: 12),
                    fullValue: nil
                ))
            }
            await MainActor.run {
                secrets = entries
                isLoading = false
            }
        }
    }

    private func saveNewSecret() {
        guard !newKeyName.isEmpty, !newKeyValue.isEmpty else { return }
        let name = newKeyName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        let value = newKeyValue
        let cat = selectedCategory
        Task {
            await SecretStore.shared.set(value, forKey: name)
            await MainActor.run {
                secrets.append(SecretEntry(
                    id: name,
                    name: name,
                    category: cat,
                    maskedValue: maskValue(value),
                    fullValue: value
                ))
                newKeyName = ""
                newKeyValue = ""
                showingAddSheet = false
                statusMessage = "'\(name)' gespeichert"
                clearStatusAfterDelay()
            }
        }
    }

    private func deleteSecret(_ secret: SecretEntry) {
        Task {
            await SecretStore.shared.delete(secret.id)
            await MainActor.run {
                secrets.removeAll { $0.id == secret.id }
                showValue.remove(secret.id)
                statusMessage = "'\(secret.name)' gelöscht"
                clearStatusAfterDelay()
            }
        }
    }

    private func copySecret(_ secret: SecretEntry) {
        // Read from Keychain on demand (triggers system auth only for copy action)
        Task {
            let value: String
            if let cached = secret.fullValue {
                value = cached
            } else {
                value = await SecretStore.shared.get(secret.id) ?? ""
            }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                statusMessage = "'\(secret.name)' kopiert (wird in 30s gelöscht)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if NSPasteboard.general.string(forType: .string) == value {
                        NSPasteboard.general.clearContents()
                    }
                }
                clearStatusAfterDelay()
            }
        }
    }

    private func toggleVisibility(_ secret: SecretEntry) {
        if showValue.contains(secret.id) {
            showValue.remove(secret.id)
        } else {
            // Lazy-load value from Keychain only when user reveals it
            if secret.fullValue == nil {
                Task {
                    let value = await SecretStore.shared.get(secret.id) ?? ""
                    await MainActor.run {
                        if let idx = secrets.firstIndex(where: { $0.id == secret.id }) {
                            secrets[idx].fullValue = value
                            secrets[idx] = SecretEntry(
                                id: secrets[idx].id,
                                name: secrets[idx].name,
                                category: secrets[idx].category,
                                maskedValue: maskValue(value),
                                fullValue: value
                            )
                        }
                        showValue.insert(secret.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            showValue.remove(secret.id)
                        }
                    }
                }
            } else {
                showValue.insert(secret.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    showValue.remove(secret.id)
                }
            }
        }
    }

    // MARK: - Helpers

    private func maskValue(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 8)) }
        return "\(value.prefix(4))\(String(repeating: "•", count: min(value.count - 8, 16)))\(value.suffix(4))"
    }

    private func guessCategory(_ key: String) -> SecretCategory {
        let k = key.lowercased()
        if k.contains("api") || k.contains("key")      { return .apiKey }
        if k.contains("token") || k.contains("bearer")  { return .token }
        if k.contains("password") || k.contains("pass")
            || k.contains("passphrase")                  { return .password }
        if k.contains("user") || k.contains("login")
            || k.contains("cred")                        { return .credential }
        return .other
    }

    private func clearStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            statusMessage = ""
        }
    }
}
