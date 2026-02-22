import SwiftUI

struct ModelsView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @State private var selectedBackend: String = "Ollama"
    @State private var backendHealth: [String: Bool] = [:]
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Models & Backends")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                // Backend Selection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active Backend")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Picker("Backend", selection: $selectedBackend) {
                        ForEach(getAvailableBackends(), id: \.self) { backend in
                            Text(backend).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedBackend) { _, _ in }

                    // Backend Health Status
                    if !backendHealth.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Backend Health")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            ForEach(Array(backendHealth.keys).sorted(), id: \.self) { backend in
                                HStack {
                                    Circle()
                                        .fill(backendHealth[backend] == true ? Color.green : Color.red)
                                        .frame(width: 12, height: 12)
                                    Text(backend)
                                    Spacer()
                                    Text(backendHealth[backend] == true ? "Healthy" : "Unhealthy")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.koboldSurface)
                        .cornerRadius(12)
                    }
                }

                // Loaded Models Section
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Loaded Models")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            isLoading = true
                            Task {
                                await viewModel.loadModels()
                                isLoading = false
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.koboldEmerald)
                    }

                    if viewModel.loadedModels.isEmpty {
                        Text("No models loaded")
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.koboldSurface)
                            .cornerRadius(8)
                    } else {
                        ForEach(viewModel.loadedModels) { model in
                            ModelCardView(model: model)
                        }
                    }
                }

                // Model Roles Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Model Roles")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Different roles for specialized tasks:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    let roles = [
                        ("Instructor", "High-quality reasoning", "🧠"),
                        ("Utility", "Fast lightweight tasks", "⚡"),
                        ("Coder", "Coding and development", "💻"),
                        ("Reviewer", "Analysis and review", "🔍"),
                        ("Web", "Web search and browsing", "🌐"),
                        ("Embedding", "Vector embeddings", "🔗")
                    ]

                    ForEach(roles, id: \.0) { role, description, icon in
                        HStack {
                            Text(icon)
                                .font(.title3)
                            VStack(alignment: .leading) {
                                Text(role)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            // Backend indicator for each role
                            Text(selectedBackend)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.koboldSurface)
                                .cornerRadius(6)
                        }
                        .padding()
                        .background(Color.koboldPanel)
                        .cornerRadius(12)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            Task {
                await loadBackendHealth()
            }
        }
    }

    private func getAvailableBackends() -> [String] {
        return ["Local", "Ollama", "Claude Code"]
    }

    private func loadBackendHealth() async {
        // Mock health data for now
        backendHealth = [
            "Local": true,
            "Ollama": true,
            "Claude Code": false // Will be checked dynamically
        ]
    }
}

struct ModelCardView: View {
    let model: ModelInfo

    var body: some View {
        HStack {
            Image(systemName: "cpu.fill")
                .foregroundColor(.koboldEmerald)
            VStack(alignment: .leading) {
                Text(model.name)
                    .foregroundColor(.primary)
                if model.usageCount > 0 {
                    Text("\(model.usageCount) uses")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(timeAgo(model.lastUsed))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.koboldSurface)
        .cornerRadius(12)
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}