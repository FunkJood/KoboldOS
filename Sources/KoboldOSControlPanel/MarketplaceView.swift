import SwiftUI

// MARK: - MarketplaceView (Mock)

struct MarketplaceView: View {
    @ObservedObject var viewModel: RuntimeViewModel

    @State private var selectedCategory: MarketCategory = .widgets
    @State private var searchText: String = ""

    enum MarketCategory: String, CaseIterable, Identifiable {
        case widgets = "Widgets"
        case automations = "Automationen"
        case skills = "Fähigkeiten"
        case themes = "Themes"
        case connectors = "Konnektoren"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .widgets:     return "square.grid.2x2.fill"
            case .automations: return "bolt.circle.fill"
            case .skills:      return "star.circle.fill"
            case .themes:      return "paintpalette.fill"
            case .connectors:  return "link.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "storefront.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.koboldEmerald)
                Text("Marktplatz")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Suchen...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.2))
                .cornerRadius(8)
                .frame(maxWidth: 250)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Category tabs
            HStack(spacing: 4) {
                ForEach(MarketCategory.allCases) { cat in
                    Button(action: { selectedCategory = cat }) {
                        HStack(spacing: 6) {
                            Image(systemName: cat.icon).font(.system(size: 13.5))
                            Text(cat.rawValue).font(.system(size: 14.5, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedCategory == cat ? Color.koboldEmerald.opacity(0.2) : Color.clear)
                        )
                        .foregroundColor(selectedCategory == cat ? .koboldEmerald : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            GlassDivider()

            // Content
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(filteredItems) { item in
                        MarketplaceCard(item: item)
                    }
                }
                .padding(20)
            }
        }
    }

    private var filteredItems: [MarketItem] {
        let items = mockItems.filter { $0.category == selectedCategory }
        if searchText.isEmpty { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.description.localizedCaseInsensitiveContains(searchText) }
    }

    private var mockItems: [MarketItem] {
        [
            // Widgets
            MarketItem(name: "Wetter-Widget", description: "Zeigt aktuelle Wetterdaten auf dem Dashboard.", icon: "cloud.sun.fill", category: .widgets, author: "KoboldOS", downloads: 1240, rating: 4.5),
            MarketItem(name: "Kalender-Widget", description: "Nächste Termine und Events auf einen Blick.", icon: "calendar", category: .widgets, author: "Community", downloads: 890, rating: 4.2),
            MarketItem(name: "Aktien-Ticker", description: "Echtzeit-Aktienkurse und Portfolio-Übersicht.", icon: "chart.line.uptrend.xyaxis", category: .widgets, author: "FinanceKit", downloads: 560, rating: 4.0),
            MarketItem(name: "Notizen-Widget", description: "Schnelle Notizen direkt im Dashboard.", icon: "note.text", category: .widgets, author: "KoboldOS", downloads: 2100, rating: 4.7),
            MarketItem(name: "Pomodoro-Timer", description: "Fokus-Timer mit Pausen und Statistiken.", icon: "timer", category: .widgets, author: "Community", downloads: 780, rating: 4.3),
            // Automations
            MarketItem(name: "Desktop-Aufräumer", description: "Sortiert Dateien automatisch nach Typ in Ordner.", icon: "folder.fill.badge.gearshape", category: .automations, author: "KoboldOS", downloads: 3400, rating: 4.8),
            MarketItem(name: "Screenshot-Sortierung", description: "Archiviert Screenshots nach Datum und Projekt.", icon: "photo.stack.fill", category: .automations, author: "Community", downloads: 1560, rating: 4.4),
            MarketItem(name: "Git Auto-Backup", description: "Automatische Commits und Pushes für Projekte.", icon: "arrow.triangle.branch", category: .automations, author: "DevTools", downloads: 920, rating: 4.1),
            MarketItem(name: "Log-Bereinigung", description: "Räumt alte Logs und Cache-Dateien auf.", icon: "trash.circle.fill", category: .automations, author: "KoboldOS", downloads: 2800, rating: 4.6),
            // Skills
            MarketItem(name: "Code-Review", description: "Analysiert Code auf Bugs, Stil und Performance.", icon: "doc.text.magnifyingglass", category: .skills, author: "DevTools", downloads: 4200, rating: 4.9),
            MarketItem(name: "Zusammenfasser", description: "Fasst lange Texte, PDFs und Webseiten zusammen.", icon: "text.redaction", category: .skills, author: "KoboldOS", downloads: 5100, rating: 4.7),
            MarketItem(name: "Übersetzer Pro", description: "Kontextsensitive Übersetzung in 20+ Sprachen.", icon: "globe", category: .skills, author: "LangKit", downloads: 3600, rating: 4.5),
            MarketItem(name: "Bildanalyse", description: "Beschreibt und analysiert Bildinhalte mit Vision.", icon: "eye.circle.fill", category: .skills, author: "KoboldOS", downloads: 1900, rating: 4.3),
            // Themes
            MarketItem(name: "Midnight Blue", description: "Dunkles Theme mit blauen Akzenten.", icon: "moon.stars.fill", category: .themes, author: "Community", downloads: 1800, rating: 4.6),
            MarketItem(name: "Forest Green", description: "Naturinspiriertes Theme in Grüntönen.", icon: "leaf.fill", category: .themes, author: "Community", downloads: 1200, rating: 4.4),
            MarketItem(name: "Solar Orange", description: "Warmes Theme mit orangenen Highlights.", icon: "sun.max.fill", category: .themes, author: "Community", downloads: 680, rating: 4.1),
            // Connectors
            MarketItem(name: "Slack-Connector", description: "Verbindet KoboldOS mit Slack-Workspaces.", icon: "bubble.left.and.text.bubble.right.fill", category: .connectors, author: "KoboldOS", downloads: 2400, rating: 4.5),
            MarketItem(name: "Notion-Sync", description: "Synchronisiert Gedächtnis mit Notion-Datenbanken.", icon: "doc.on.doc.fill", category: .connectors, author: "Community", downloads: 1100, rating: 4.2),
            MarketItem(name: "HomeKit-Bridge", description: "Steuert Smart-Home-Geräte über KoboldOS.", icon: "house.fill", category: .connectors, author: "SmartKit", downloads: 890, rating: 4.0),
        ]
    }
}

struct MarketItem: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let category: MarketplaceView.MarketCategory
    let author: String
    let downloads: Int
    let rating: Double
}

struct MarketplaceCard: View {
    let item: MarketItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.koboldEmerald.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: item.icon)
                        .font(.system(size: 19))
                        .foregroundColor(.koboldEmerald)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15.5, weight: .semibold))
                        .lineLimit(1)
                    Text(item.author)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(item.description)
                .font(.system(size: 13.5))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundColor(.koboldGold)
                    Text(String(format: "%.1f", item.rating)).font(.system(size: 12.5, weight: .medium))
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundColor(.secondary)
                    Text("\(item.downloads)").font(.system(size: 12.5)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Installieren") {}
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.koboldEmerald.opacity(0.2))
                    .foregroundColor(.koboldEmerald)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(isHovered ? 0.06 : 0.02)))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
