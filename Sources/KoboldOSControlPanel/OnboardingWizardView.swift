import SwiftUI

struct OnboardingWizardView: View {
    @Binding var isVisible: Bool
    @Binding var completed: Bool
    @State private var currentPage = 0
    @State private var claudeCodeInstalled = false
    @State private var ollamaInstalled = false
    @State private var apiKey: String = ""
    @State private var modelSelection: String = "qwen2.5:1.5b"
    @State private var isCheckingDependencies = false
    @State private var dependencyCheckResults: [String: Bool] = [:]

    private let totalPages = 5

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Welcome to KoboldOS")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal)

            // Progress indicator
            ProgressView(value: Double(currentPage + 1), total: Double(totalPages))
                .padding(.horizontal)

            Text("Step \(currentPage + 1) of \(totalPages)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom)

            // Content based on current page
            VStack(spacing: 20) {
                switch currentPage {
                case 0:
                    welcomePage()
                case 1:
                    dependencyCheckPage()
                case 2:
                    claudeCodeSetupPage()
                case 3:
                    ollamaSetupPage()
                case 4:
                    configurationPage()
                default:
                    completionPage()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation buttons
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        currentPage -= 1
                    }
                    .buttonStyle(.bordered)
                } else {
                    Spacer()
                }

                if currentPage < totalPages - 1 {
                    Button("Next") {
                        handleNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isNextEnabled())
                } else {
                    Button("Finish Setup") {
                        finishSetup()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
        }
        .frame(width: 600, height: 500)
        .onAppear {
            checkDependencies()
        }
    }

    @ViewBuilder
    private func welcomePage() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 60))
                .foregroundColor(.koboldEmerald)

            Text("Welcome to KoboldOS")
                .font(.title)
                .fontWeight(.bold)

            Text("Your personal AI operating system that grows and learns with you.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("This quick setup will help you configure KoboldOS for optimal performance.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func dependencyCheckPage() -> some View {
        VStack(spacing: 20) {
            Text("System Check")
                .font(.title2)
                .fontWeight(.bold)

            if isCheckingDependencies {
                ProgressView("Checking dependencies...")
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: 100)
            } else {
                VStack(spacing: 15) {
                    dependencyRow(
                        name: "Claude Code CLI",
                        installed: dependencyCheckResults["claude"] ?? false,
                        description: "Required for coding tasks"
                    )

                    dependencyRow(
                        name: "Ollama",
                        installed: dependencyCheckResults["ollama"] ?? false,
                        description: "Required for local model inference"
                    )

                    dependencyRow(
                        name: "Xcode Command Line Tools",
                        installed: dependencyCheckResults["xcode"] ?? false,
                        description: "Required for compilation"
                    )

                    if !(dependencyCheckResults["claude"] ?? false) ||
                        !(dependencyCheckResults["ollama"] ?? false) {
                        Text("Some dependencies are missing. Please install them before continuing.")
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            Button("Recheck Dependencies") {
                checkDependencies()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func claudeCodeSetupPage() -> some View {
        VStack(spacing: 20) {
            Text("Claude Code Setup")
                .font(.title2)
                .fontWeight(.bold)

            Text("Claude Code provides specialized coding capabilities for KoboldOS.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if dependencyCheckResults["claude"] ?? false {
                VStack(alignment: .leading, spacing: 10) {
                    Text("✓ Claude Code CLI is installed")
                        .foregroundColor(.green)

                    Text("Claude Code will be used automatically for coding tasks.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Install Claude Code")
                        .font(.headline)

                    Text("To install Claude Code:")
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("1. Visit claude.ai")
                        Text("2. Download Claude Code CLI")
                        Text("3. Install it in your PATH")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                    Button("Open Installation Guide") {
                        NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code")!)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("Note: Claude Code will be used as the backend for the 'Coder' role.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func ollamaSetupPage() -> some View {
        VStack(spacing: 20) {
            Text("Ollama Setup")
                .font(.title2)
                .fontWeight(.bold)

            Text("Ollama provides local model inference for KoboldOS.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if dependencyCheckResults["ollama"] ?? false {
                VStack(alignment: .leading, spacing: 10) {
                    Text("✓ Ollama is installed and running")
                        .foregroundColor(.green)

                    Text("Ollama will be used as the default backend for most tasks.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Install Ollama")
                        .font(.headline)

                    Text("To install Ollama:")
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("1. Visit ollama.ai")
                        Text("2. Download and install Ollama")
                        Text("3. Start the Ollama service")
                        Text("4. Pull a model: ollama pull qwen2.5:1.5b")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                    Button("Open Ollama Website") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("You can configure which models to use in the settings after setup.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func configurationPage() -> some View {
        VStack(spacing: 20) {
            Text("Initial Configuration")
                .font(.title2)
                .fontWeight(.bold)

            Text("Configure your KoboldOS experience.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            GroupBox("API Keys (Optional)") {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Add API keys for additional capabilities:")
                        .font(.subheadline)

                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            HStack {
                                Spacer()
                                Button("Save") {
                                    saveApiKey()
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.koboldEmerald)
                            }
                        )

                    Text("Supported services: OpenAI, Anthropic, etc.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            GroupBox("Default Model") {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Select your preferred default model:")
                        .font(.subheadline)

                    Picker("Model", selection: $modelSelection) {
                        Text("qwen2.5:1.5b").tag("qwen2.5:1.5b")
                        Text("llama3.1:8b").tag("llama3.1:8b")
                        Text("mistral:7b").tag("mistral:7b")
                    }
                    .pickerStyle(.menu)

                    Text("You can change this later in the settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            Text("KoboldOS will use Claude Code for coding tasks and Ollama for other tasks.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func completionPage() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Setup Complete!")
                .font(.title)
                .fontWeight(.bold)

            Text("KoboldOS is ready to use.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("What's next:")
                    .font(.headline)

                Text("• Start chatting in the Chat tab")
                    .font(.caption)
                Text("• Explore models in the Models tab")
                    .font(.caption)
                Text("• Configure settings in the Settings tab")
                    .font(.caption)
                Text("• Check metrics in the Metrics tab")
                    .font(.caption)
            }
            .padding()
            .background(Color.koboldPanel)
            .cornerRadius(12)

            Text("Remember to keep your dependencies updated for the best experience.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func dependencyRow(name: String, installed: Bool, description: String) -> some View {
        HStack {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(installed ? .green : .red)
                .font(.title2)

            VStack(alignment: .leading) {
                Text(name)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.koboldSurface)
        .cornerRadius(12)
    }

    private func checkDependencies() {
        isCheckingDependencies = true

        // Simulate dependency checking
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            // In a real implementation, this would actually check for installations
            await MainActor.run {
                isCheckingDependencies = false
                dependencyCheckResults = [
                    "claude": true,  // Simulate Claude Code installed
                    "ollama": true,  // Simulate Ollama installed
                    "xcode": true    // Simulate Xcode tools installed
                ]
            }
        }
    }

    private func handleNext() {
        // Validate current page before proceeding
        switch currentPage {
        case 1: // Dependency check page
            if !(dependencyCheckResults["claude"] ?? false) ||
                !(dependencyCheckResults["ollama"] ?? false) {
                // Some dependencies missing — allow proceeding anyway
            }
        default:
            break
        }

        currentPage += 1
    }

    private func isNextEnabled() -> Bool {
        switch currentPage {
        case 1: // Dependency check - always allow proceeding
            return true
        default:
            return true
        }
    }

    private func saveApiKey() {
        if !apiKey.isEmpty {
            UserDefaults.standard.set(apiKey, forKey: "kobold.apiKey")
            apiKey = ""
        }
    }

    private func finishSetup() {
        completed = true
        isVisible = false
    }
}