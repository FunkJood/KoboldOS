import SwiftUI
import KoboldCore

// MARK: - SkillsView

struct SkillsView: View {
    @State private var skills: [Skill] = []
    @State private var isLoading = true
    @State private var selectedSkill: Skill? = nil
    @State private var showImportPanel = false
    @State private var searchText = ""

    private var filteredSkills: [Skill] {
        if searchText.isEmpty { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                searchBar
                if isLoading {
                    ProgressView("Skills werden geladen...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(40)
                } else if filteredSkills.isEmpty {
                    emptyState
                } else {
                    skillsGrid
                }
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
        .onAppear { loadSkills() }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailSheet(skill: skill)
        }
    }

    // MARK: - Header

    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills").font(.title2.bold())
                Text("Markdown-Dateien, die in den System-Prompt des Agenten injiziert werden.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            GlassButton(title: "Skill importieren", icon: "plus.circle.fill", isPrimary: true) {
                importSkill()
            }
            GlassButton(title: "Aktualisieren", icon: "arrow.clockwise", isPrimary: false) {
                loadSkills()
            }
        }
    }

    // MARK: - Search

    var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Skills durchsuchen...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.koboldSurface)
        .cornerRadius(10)
    }

    // MARK: - Skills Grid

    var skillsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(filteredSkills) { skill in
                SkillCard(skill: skill, onToggle: { toggleSkill(skill) }, onTap: { selectedSkill = skill })
            }
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Keine Skills gefunden")
                .font(.title3.bold())
            Text("Skills sind Markdown-Dateien im Ordner:\n~/Library/Application Support/KoboldOS/Skills/")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            GlassButton(title: "Skills-Ordner öffnen", icon: "folder.fill", isPrimary: false) {
                openSkillsFolder()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    func loadSkills() {
        isLoading = true
        Task {
            let loaded = await SkillLoader.shared.loadSkills()
            skills = loaded
            isLoading = false
        }
    }

    func toggleSkill(_ skill: Skill) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[idx].isEnabled.toggle()
        Task {
            await SkillLoader.shared.setEnabled(skill.name, enabled: skills[idx].isEnabled)
        }
    }

    func importSkill() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsMultipleSelection = true
        panel.message = "Wähle Markdown-Dateien als Skills"
        guard panel.runModal() == .OK else { return }

        let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        for url in panel.urls {
            let dest = skillsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        loadSkills()
    }

    func openSkillsFolder() {
        let skillsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS/Skills")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skillsDir)
    }
}

// MARK: - SkillCard

struct SkillCard: View {
    let skill: Skill
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundColor(skill.isEnabled ? .orange : .secondary)
                    Text(skill.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { skill.isEnabled },
                        set: { _ in onToggle() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                Text(skillPreview)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)

                HStack {
                    GlassStatusBadge(
                        label: skill.isEnabled ? "Aktiv" : "Inaktiv",
                        color: skill.isEnabled ? .koboldEmerald : .secondary
                    )
                    Spacer()
                    Button("Details") { onTap() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    var skillPreview: String {
        let lines = skill.content.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.prefix(3).joined(separator: " ").prefix(200).description
    }
}

// MARK: - SkillDetailSheet

struct SkillDetailSheet: View {
    let skill: Skill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text(skill.name)
                    .font(.title2.bold())
                Spacer()
                GlassStatusBadge(
                    label: skill.isEnabled ? "Aktiv" : "Inaktiv",
                    color: skill.isEnabled ? .koboldEmerald : .secondary
                )
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                Text(skill.content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("Datei: \(skill.filename)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(skill.content.count) Zeichen")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 400)
        .background(Color.koboldBackground)
    }
}
