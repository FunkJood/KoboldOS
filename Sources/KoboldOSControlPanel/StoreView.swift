import SwiftUI

// MARK: - StoreView (Placeholder for future marketplace)

struct StoreView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Store").font(.title2.bold())
                        Text("Tools, Skills und Automationen entdecken und installieren")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Coming Soon
                GlassCard {
                    VStack(spacing: 20) {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 49))
                            .foregroundColor(.koboldGold)

                        Text("Bald verfügbar")
                            .font(.title3.bold())

                        Text("Der KoboldOS Store wird es dir ermöglichen, neue Tools, Skills und Automationen zu entdecken, zu installieren und zu teilen.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)

                        // Feature preview cards
                        HStack(spacing: 16) {
                            storeFeatureCard(
                                icon: "wrench.and.screwdriver.fill",
                                title: "Tools",
                                description: "Neue Werkzeuge für deinen Agenten"
                            )
                            storeFeatureCard(
                                icon: "sparkles",
                                title: "Skills",
                                description: "Vorgefertigte Fähigkeiten"
                            )
                            storeFeatureCard(
                                icon: "arrow.triangle.2.circlepath",
                                title: "Automationen",
                                description: "Workflow-Vorlagen"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .padding(24)
        }
        .background(Color.koboldBackground)
    }

    private func storeFeatureCard(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 25))
                .foregroundColor(.koboldEmerald)
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.koboldSurface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}
