import SwiftUI
import KoboldCore
import AppKit
import Charts

// MARK: - Price Change Direction (for flash animation)

enum PriceDirection {
    case up, down, unchanged
}

// MARK: - Trading View (Professional Dashboard)

struct TradingView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager

    enum SubTab: String, CaseIterable {
        case dashboard = "Dashboard"
        case positions = "Positionen"
        case history = "Historie"
        case analytics = "Analytics"
        case learning = "Lernen"
        case strategies = "Strategien"
        case backtest = "Backtest"
    }

    @State private var subTab: SubTab = .dashboard
    @State private var status: TradingStatus = TradingStatus()
    @State private var analytics: TradingAnalytics = TradingAnalytics()
    @State private var openPositions: [TradeRecord] = []
    @State private var tradeHistory: [TradeRecord] = []
    @State private var forecasts: [String: [ForecastResult]] = [:]
    @State private var isLoading = true
    @State private var refreshTimer: Timer?

    // Live Portfolio (direkt von Coinbase, unabhängig von Engine)
    @State private var livePortfolioValue: Double = 0
    @State private var liveHoldings: [TradeExecutor.AccountBalance] = []
    @State private var spotPrices: [String: Double] = [:]
    @State private var previousPrices: [String: Double] = [:]  // For flash animation
    @State private var priceDirections: [String: PriceDirection] = [:]

    // Regime (eigenständig erkannt, unabhängig von Engine)
    @State private var detectedRegime: String = "UNKNOWN"
    @State private var priceChanges24h: [String: Double] = [:]  // Pair → 24h % Change

    // Activity Log
    @State private var tradingLog: [TradingLogEntry] = []
    @State private var showLog = true
    @State private var logInput = ""
    @State private var tradingSessionId = UUID()

    // Diagnostics
    @State private var diagnosticResult: String?
    @State private var showDiagnostics = false
    @State private var expandedLogIds: Set<UUID> = []

    // Custom Strategies
    @State private var customStrategies: [CustomStrategyInfo] = []

    // Refresh Cycle Counter (schwere Daten nur alle 6 Zyklen = 60s)
    @State private var refreshCycle = 0

    // Sell Confirmation + Feedback
    @State private var sellConfirmTarget: TradeExecutor.AccountBalance?
    @State private var showSellConfirm = false
    @State private var showAutoTradeConfirm = false
    @State private var sellResultMessage: String?
    @State private var showSellResult = false
    @State private var sellResultSuccess = false

    // Gesamt-P&L (eingezahlte Summe)
    @AppStorage("kobold.trading.totalInvested") private var totalInvestedStored: Double = 0
    @State private var showInvestedEditor = false
    @State private var investedInput: String = ""

    // Valid Product IDs (für Sell-Button Validierung)
    @State private var validProducts: Set<String> = []

    // Backtest State
    @State private var btStrategy = "momentum"
    @State private var btPair = "BTC-EUR"
    @State private var btDays = 30
    @State private var btResult: BacktestResult?
    @State private var btRunning = false

    // Learning / Strategy Performance
    @State private var strategyPerfs: [TradingRiskManager.StrategyPerf] = []
    @State private var autoBacktestResults: [String: BacktestResult] = [:]
    @State private var learningNotes: [(date: String, note: String)] = []

    // Cost Basis pro Coin (für echtes P&L)
    @State private var costBasis: [String: (avgPrice: Double, totalInvested: Double)] = [:]

    // Engine-Monitoring-Info pro Coin
    @State private var holdingMonitorInfo: [String: TradingEngine.HoldingMonitorInfo] = [:]

    // KI-Agent Toggle
    @AppStorage("kobold.trading.agentEnabled") private var agentEnabled = false
    @State private var showAgentConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            tradingHeader
            GlassDivider()
            subTabBar
            GlassDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch subTab {
                    case .dashboard:   dashboardContent
                    case .positions:   positionsContent
                    case .history:     historyContent
                    case .analytics:   analyticsContent
                    case .learning:    learningContent
                    case .strategies:  strategiesContent
                    case .backtest:    backtestContent
                    }
                }
                .padding(24)
            }

            // Activity-Log Panel (fixiert am unteren Rand)
            activityLogPanel
        }
        .background(Color.koboldBackground)
        .task { await loadAll() }
        .onAppear { startAutoRefresh() }
        .alert("Position verkaufen?", isPresented: $showSellConfirm) {
            Button("Abbrechen", role: .cancel) { sellConfirmTarget = nil }
            Button("Verkaufen", role: .destructive) {
                guard let target = sellConfirmTarget else { return }
                let currency = target.currency
                let useAgent = agentEnabled
                sellConfirmTarget = nil
                Task {
                    if useAgent {
                        addLog("Verkaufe \(currency)... (KI-Agent)", type: .trade)
                        let response = await TradingAgent.shared.executeSell(
                            currency: currency, reason: "Manuell vom User angefordert"
                        )
                        sellResultMessage = "KI-Agent: \(response)"
                        sellResultSuccess = !response.contains("Fehler") && !response.contains("fehlgeschlagen")
                    } else {
                        addLog("Verkaufe \(currency)... (v3 Balance-Check)", type: .trade)
                        let result = await TradeExecutor.shared.sellAll(currency: currency)
                        if let orderId = result.orderId {
                            addLog("Verkauft: \(currency) (Order: \(orderId.prefix(8))...)", type: .trade)
                            sellResultMessage = "\(currency) erfolgreich verkauft!\nOrder: \(orderId.prefix(12))..."
                            sellResultSuccess = true
                        } else {
                            addLog("Verkauf fehlgeschlagen: \(result.error ?? "Unbekannter Fehler")", type: .risk)
                            sellResultMessage = "Verkauf fehlgeschlagen:\n\(result.error ?? "Unbekannter Fehler")"
                            sellResultSuccess = false
                        }
                    }
                    showSellResult = true
                    await loadAll()
                }
            }
        } message: {
            if let target = sellConfirmTarget {
                Text("Wirklich \(String(format: "%.8f", target.availableBalance)) \(target.currency) (\(String(format: "%.2f€", target.nativeValue))) verkaufen?")
            }
        }
        .alert(sellResultSuccess ? "Verkauf erfolgreich" : "Verkauf fehlgeschlagen", isPresented: $showSellResult) {
            Button("OK") { sellResultMessage = nil }
        } message: {
            Text(sellResultMessage ?? "")
        }
        .alert("Auto-Trade aktivieren?", isPresented: $showAutoTradeConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren", role: .destructive) {
                UserDefaults.standard.set(true, forKey: "kobold.trading.autoTrade")
                addLog("Auto-Trade AKTIVIERT — echte Orders werden ausgeführt!", type: .trade)
            }
        } message: {
            Text("Auto-Trade führt echte Käufe und Verkäufe mit realem Geld aus. Die Engine handelt basierend auf konfigurierten Strategien. Fortfahren?")
        }
        .alert("KI-Agent aktivieren?", isPresented: $showAgentConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Aktivieren") {
                agentEnabled = true
                addLog("KI-Agent AKTIVIERT — Agent bewertet Signale und handelt autonom", type: .trade)
            }
        } message: {
            Text("Der KI-Agent bewertet Trading-Signale autonom und führt Käufe/Verkäufe über die Coinbase API aus. Er nutzt das lokale LLM zur Entscheidungsfindung.")
        }
    }

    // MARK: - Header

    private var tradingHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2).foregroundColor(.koboldGold)
            Text("Trading").font(.title2.bold())

            // Live Price Ticker (Top 3 beliebteste Coins)
            if !spotPrices.isEmpty {
                HStack(spacing: 10) {
                    let top3: [String] = ["BTC-EUR", "ETH-EUR", "SOL-EUR"]
                    let displayPairs = top3
                    ForEach(displayPairs, id: \.self) { pair in
                        if let price = spotPrices[pair] {
                            let dir = priceDirections[pair] ?? .unchanged
                            HStack(spacing: 3) {
                                Text(pair.replacingOccurrences(of: "-EUR", with: ""))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text(formatPrice(price))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(dir == .up ? .koboldEmerald : dir == .down ? .red : .primary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(
                                (dir == .up ? Color.koboldEmerald : dir == .down ? Color.red : Color.clear)
                                    .opacity(dir == .unchanged ? 0 : 0.15)
                            )
                            .cornerRadius(4)
                            .animation(.easeOut(duration: 0.5), value: dir == .up)
                        }
                    }
                }
            }

            Spacer()

            // Status Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(status.running ? Color.koboldEmerald : Color.red)
                    .frame(width: 8, height: 8)
                Text(status.running ? "Engine Aktiv" : "Engine Aus")
                    .font(.caption.weight(.medium))
                    .foregroundColor(status.running ? .koboldEmerald : .red)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.koboldSurface.opacity(0.5))
            .cornerRadius(12)

            Button(action: {
                Task {
                    if status.running { await TradingEngine.shared.stop() }
                    else { await TradingEngine.shared.start() }
                    await loadAll()
                }
            }) {
                Label(status.running ? "Stop" : "Start",
                      systemImage: status.running ? "stop.fill" : "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(status.running ? .red : .koboldEmerald)

            // Auto-Trade Toggle (prominent im Header)
            let autoTradeOn = UserDefaults.standard.bool(forKey: "kobold.trading.autoTrade")
            Button(action: {
                if autoTradeOn {
                    UserDefaults.standard.set(false, forKey: "kobold.trading.autoTrade")
                    addLog("Auto-Trade DEAKTIVIERT", type: .info)
                } else {
                    showAutoTradeConfirm = true
                }
            }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(autoTradeOn ? Color.koboldEmerald : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(autoTradeOn ? "Auto-Trade AN" : "Auto-Trade AUS")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(autoTradeOn ? Color.koboldEmerald.opacity(0.15) : Color.gray.opacity(0.15))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .help(autoTradeOn ? "Auto-Trade AUS schalten — Engine analysiert weiter, führt aber keine echten Orders aus" : "Auto-Trade AN — Engine kauft/verkauft automatisch mit echtem Geld")

            // KI-Agent Toggle
            Button(action: {
                if agentEnabled {
                    agentEnabled = false
                    addLog("KI-Agent DEAKTIVIERT — Engine nutzt direkten API-Zugang", type: .info)
                } else {
                    showAgentConfirm = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: agentEnabled ? "brain.fill" : "brain")
                        .font(.system(size: 10))
                    Text(agentEnabled ? "KI AN" : "KI AUS")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(agentEnabled ? Color.purple.opacity(0.2) : Color.gray.opacity(0.15))
                .foregroundColor(agentEnabled ? .purple : .secondary)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .help(agentEnabled ? "KI-Agent AUS — Engine handelt direkt über Coinbase API" : "KI-Agent AN — Engine sendet Signale an den KI-Agent der autonom entscheidet")

            // Buy/Sell Signal Toggles (kompakt)
            let buyOn = UserDefaults.standard.object(forKey: "kobold.trading.buySignalsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "kobold.trading.buySignalsEnabled")
            let sellOn = UserDefaults.standard.object(forKey: "kobold.trading.sellSignalsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "kobold.trading.sellSignalsEnabled")

            Button(action: {
                UserDefaults.standard.set(!buyOn, forKey: "kobold.trading.buySignalsEnabled")
                addLog("Buy-Signale \(!buyOn ? "AKTIVIERT" : "DEAKTIVIERT")", type: .info)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle\(buyOn ? ".fill" : "")").font(.system(size: 9))
                    Text("Buy").font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(buyOn ? Color.koboldEmerald.opacity(0.15) : Color.red.opacity(0.15))
                .foregroundColor(buyOn ? .koboldEmerald : .red)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .help(buyOn ? "Buy-Signale deaktivieren — keine neuen Käufe" : "Buy-Signale aktivieren")

            Button(action: {
                UserDefaults.standard.set(!sellOn, forKey: "kobold.trading.sellSignalsEnabled")
                addLog("Sell-Signale \(!sellOn ? "AKTIVIERT" : "DEAKTIVIERT") (TP/SL bleibt aktiv!)", type: .info)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.circle\(sellOn ? ".fill" : "")").font(.system(size: 9))
                    Text("Sell").font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(sellOn ? Color.orange.opacity(0.15) : Color.red.opacity(0.15))
                .foregroundColor(sellOn ? .orange : .red)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .help(sellOn ? "Sell-Signale deaktivieren — TP/SL bleibt aktiv!" : "Sell-Signale aktivieren")

            if status.running {
                Button(action: {
                    Task { await TradingEngine.shared.emergencyStop(); await loadAll() }
                }) {
                    Label("Emergency", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .help("Stoppt die Engine sofort und schließt alle offenen Engine-Positionen")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: - Sub-Tab Bar

    private var subTabBar: some View {
        HStack(spacing: 4) {
            ForEach(SubTab.allCases, id: \.self) { tab in
                Button(action: { subTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: subTab == tab ? .semibold : .regular))
                        .foregroundColor(subTab == tab ? .koboldEmerald : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(subTab == tab ? Color.koboldSurface : Color.clear)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 6)
    }

    // MARK: - Dashboard

    private var dashboardContent: some View {
        let displayPortfolio = livePortfolioValue > 0 ? livePortfolioValue : status.portfolioValue

        return VStack(alignment: .leading, spacing: 16) {
            // Portfolio Value + Key Metrics
            HStack(spacing: 12) {
                // Big Portfolio Card
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "wallet.pass.fill").font(.caption2).foregroundColor(.koboldGold)
                        Text("Portfolio").font(.caption).foregroundColor(.secondary)
                    }
                    Text(String(format: "%.2f€", displayPortfolio))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                    if status.dailyPnL != 0 {
                        Text(String(format: "%+.2f€ heute", status.dailyPnL))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(status.dailyPnL >= 0 ? .koboldEmerald : .red)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.koboldSurface.opacity(0.3))
                .cornerRadius(8)

                // Gesamt-P&L (automatisch aus Cost Basis ODER manueller Einlage)
                let autoCostBasis = costBasis.values.reduce(0.0) { $0 + $1.totalInvested }
                let effectiveInvested = totalInvestedStored > 0 ? totalInvestedStored : autoCostBasis
                // Bei Cost Basis: nur Crypto-Wert vergleichen (EUR-Saldo ist kein Investment)
                let cryptoOnlyValue = liveHoldings.filter { $0.currency != "EUR" && $0.currency != "EURC" }.reduce(0.0) { $0 + $1.nativeValue }
                let compareValue = totalInvestedStored > 0 ? displayPortfolio : cryptoOnlyValue
                let totalPnL = effectiveInvested > 0 ? compareValue - effectiveInvested : 0
                let totalPnLPctAll = effectiveInvested > 0 ? (totalPnL / effectiveInvested) * 100 : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.caption2).foregroundColor(totalPnL >= 0 ? .koboldEmerald : .red)
                        Text("Gesamt-P&L").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(action: { investedInput = totalInvestedStored > 0 ? String(format: "%.2f", totalInvestedStored) : ""; showInvestedEditor.toggle() }) {
                            Image(systemName: "pencil.circle").font(.caption).foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                    if effectiveInvested > 0 {
                        Text(String(format: "%+.2f€", totalPnL))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(totalPnL >= 0 ? .koboldEmerald : .red)
                        let source = totalInvestedStored > 0 ? "Einlage" : "Cost Basis"
                        Text(String(format: "%+.1f%% (\(source): %.0f€)", totalPnLPctAll, effectiveInvested))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    } else {
                        Text("—").font(.system(size: 18, weight: .bold, design: .monospaced))
                        Text("Wird berechnet…").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if showInvestedEditor {
                        HStack(spacing: 4) {
                            TextField("€ eingezahlt", text: $investedInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 80)
                            Button("OK") {
                                if let val = Double(investedInput.replacingOccurrences(of: ",", with: ".")) {
                                    totalInvestedStored = val
                                }
                                showInvestedEditor = false
                            }.font(.system(size: 10)).buttonStyle(.bordered)
                            Button("Reset") {
                                totalInvestedStored = 0
                                showInvestedEditor = false
                            }.font(.system(size: 10)).buttonStyle(.bordered).tint(.red)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.koboldSurface.opacity(0.3))
                .cornerRadius(8)

                // 24h P&L
                let totalPnL24h = computePortfolioPnL24h()
                let totalPnLPct24 = computePortfolioPnLPct24h()
                metricCard("24h P&L",
                           String(format: "%+.2f€ (%+.1f%%)", totalPnL24h, totalPnLPct24),
                           icon: "arrow.up.arrow.down.circle.fill",
                           color: totalPnL24h >= 0 ? .koboldEmerald : .red)
                metricCard("Regime", displayRegime, icon: "globe", color: regimeColor)
            }

            // Holdings (Live from Coinbase — ALL positions, not just our module)
            if !liveHoldings.isEmpty {
                holdingsSection(displayPortfolio: displayPortfolio)
            } else if isLoading {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Lade Portfolio von Coinbase...").font(.caption).foregroundColor(.secondary)
                }
                .padding(20)
            } else if !hasCoinbaseKeys {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text("Coinbase API-Key fehlt. Einstellungen → Integrationen → Coinbase.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(12).background(Color.orange.opacity(0.1)).cornerRadius(8)
            }

            // Diagnose-Button (zeigt sich wenn Portfolio 0 ist und Keys vorhanden)
            if livePortfolioValue == 0 && hasCoinbaseKeys {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "stethoscope").foregroundColor(.orange)
                        Text("Portfolio zeigt 0€ — API-Verbindung prüfen?")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Diagnose starten") {
                            showDiagnostics = true
                            Task {
                                diagnosticResult = await TradeExecutor.shared.diagnoseConnection()
                            }
                        }
                        .font(.caption).buttonStyle(.bordered).tint(.orange)
                    }
                    if showDiagnostics {
                        if let diag = diagnosticResult {
                            Text(diag)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(6)
                        } else {
                            HStack {
                                ProgressView().scaleEffect(0.6)
                                Text("Prüfe Verbindung...").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(12).background(Color.orange.opacity(0.08)).cornerRadius(8)
            }

            // Halted Warning
            if status.halted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text("GEHALTET: \(status.haltReason)")
                        .font(.caption.weight(.bold)).foregroundColor(.red)
                    Spacer()
                    Button("Fortsetzen") {
                        Task { await TradingRiskManager.shared.resumeTrading(); await loadAll() }
                    }
                    .font(.caption).buttonStyle(.borderedProminent).tint(.koboldEmerald)
                }
                .padding(12).background(Color.red.opacity(0.1)).cornerRadius(8)
            }

            // Prognosen — Top-16 nach Beliebtheit (Market Cap)
            let top16order = ["BTC-EUR","ETH-EUR","SOL-EUR","XRP-EUR","ADA-EUR","DOGE-EUR",
                              "AVAX-EUR","DOT-EUR","LINK-EUR","MATIC-EUR","SHIB-EUR","UNI-EUR",
                              "LTC-EUR","NEAR-EUR","ATOM-EUR","FIL-EUR"]
            let sortedForecastPairs = top16order.filter { forecasts[$0] != nil } +
                forecasts.keys.filter { !top16order.contains($0) }.sorted()
            if !sortedForecastPairs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Prognosen (\(sortedForecastPairs.count) Coins)").font(.headline)
                        Spacer()
                        Text("% = Konfidenz der Richtungsprognose")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    let forecastCols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    LazyVGrid(columns: forecastCols, spacing: 6) {
                        ForEach(sortedForecastPairs, id: \.self) { pair in
                            if let pf = forecasts[pair] {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Circle().fill(barColorForCurrency(String(pair.split(separator: "-").first ?? ""))).frame(width: 6, height: 6)
                                        Text(pair.replacingOccurrences(of: "-EUR", with: ""))
                                            .font(.system(size: 12, weight: .semibold))
                                        if let price = spotPrices[pair] {
                                            Spacer()
                                            Text(formatPrice(price))
                                                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        }
                                    }
                                    let pillCols = Array(repeating: GridItem(.flexible(), spacing: 3), count: min(pf.count, 5))
                                    LazyVGrid(columns: pillCols, alignment: .leading, spacing: 3) {
                                        ForEach(pf, id: \.horizon) { f in forecastPill(f) }
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.15))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
            }

            // (Trade-Historie → eigener Tab)
        }
    }

    // MARK: - Holdings Section (All Coinbase positions)

    private func holdingsSection(displayPortfolio: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bestände").font(.headline)
                Text("(Coinbase)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f€", displayPortfolio))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.koboldGold)
            }

            // Table Header
            HStack(spacing: 0) {
                Text("Coin").frame(width: 55, alignment: .leading)
                Text("Menge").frame(width: 90, alignment: .trailing)
                Text("Wert").frame(width: 65, alignment: .trailing)
                Text("P&L €").frame(width: 60, alignment: .trailing)
                Text("P&L %").frame(width: 50, alignment: .trailing)
                Text("24h €").frame(width: 55, alignment: .trailing)
                Text("24h %").frame(width: 50, alignment: .trailing)
                Text("").frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)

            ForEach(liveHoldings.filter { $0.currency != "EURC" && $0.nativeValue > 0.01 }, id: \.currency) { h in
                holdingRow(h, displayPortfolio: displayPortfolio)
            }
        }
        .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
    }

    @ViewBuilder
    private func holdingRow(_ h: TradeExecutor.AccountBalance, displayPortfolio: Double) -> some View {
        let dir = priceDirections["\(h.currency)-EUR"] ?? .unchanged
        let change24h = priceChanges24h[h.currency] ?? 0
        let cb = costBasis[h.currency]
        let dashPnL: Double? = cb.map { h.nativeValue - $0.totalInvested }
        let dashPnLPct: Double? = cb.flatMap { $0.totalInvested > 0 ? (h.nativeValue - $0.totalInvested) / $0.totalInvested * 100 : nil }
        let pnlColor: Color = (dashPnL ?? 0) > 0 ? .koboldEmerald : (dashPnL ?? 0) < 0 ? .red : .secondary
        // 24h Wertänderung in EUR berechnen
        let change24hEur = h.currency != "EUR" ? h.nativeValue * (change24h / (100 + change24h)) : 0

        HStack(spacing: 0) {
            Text(h.currency).font(.system(size: 12, weight: .semibold)).frame(width: 55, alignment: .leading)
            Text(formatCryptoAmount(h.balance, currency: h.currency))
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 90, alignment: .trailing)
            Text(String(format: "%.2f", h.nativeValue))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(dir == .up ? .koboldEmerald : dir == .down ? .red : .primary).frame(width: 65, alignment: .trailing)
            // P&L €
            Text(h.currency == "EUR" ? "—" : (dashPnL.map { String(format: "%+.2f", $0) } ?? "—"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(pnlColor).frame(width: 60, alignment: .trailing)
            // P&L %
            Text(h.currency == "EUR" ? "—" : (dashPnLPct.map { String(format: "%+.1f%%", $0) } ?? "—"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(pnlColor).frame(width: 50, alignment: .trailing)
            // 24h €
            Text(h.currency == "EUR" ? "—" : String(format: "%+.2f", change24hEur))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(change24h > 0 ? .koboldEmerald : change24h < 0 ? .red : .secondary).frame(width: 55, alignment: .trailing)
            // 24h %
            Text(h.currency == "EUR" ? "—" : String(format: "%+.1f%%", change24h))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(change24h > 0 ? .koboldEmerald : change24h < 0 ? .red : .secondary).frame(width: 50, alignment: .trailing)
            // Progress bar
            GeometryReader { geo in
                let pct = displayPortfolio > 0 ? h.nativeValue / displayPortfolio : 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColorForCurrency(h.currency).opacity(0.5))
                    .frame(width: max(CGFloat(min(pct, 1.0)) * geo.size.width, 0), height: 6)
                    .frame(height: geo.size.height, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 18).padding(.leading, 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((dir == .up ? Color.koboldEmerald : dir == .down ? Color.red : Color.clear).opacity(dir == .unchanged ? 0 : 0.08))
        .background(Color.koboldSurface.opacity(0.12)).cornerRadius(4)
        .animation(.easeOut(duration: 0.6), value: h.nativeValue)
    }

    // MARK: - Positions (All Holdings as Engine-Monitored Positions)

    private var positionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            let cryptoHoldings = liveHoldings.filter { $0.currency != "EUR" && $0.currency != "EURC" && $0.nativeValue > 0.01 }
            let hodlCoin = UserDefaults.standard.string(forKey: "kobold.trading.hodlCoin")?.uppercased() ?? ""
            let tpSlMode = UserDefaults.standard.string(forKey: "kobold.trading.tpSlMode") ?? "trailing"
            let tpPct = UserDefaults.standard.double(forKey: "kobold.trading.takeProfit")
            let slPct = UserDefaults.standard.double(forKey: "kobold.trading.trailingStop")
            let effectiveTP = tpPct > 0 ? tpPct : 5.0
            let effectiveSL = slPct > 0 ? slPct : 3.0

            // Engine-Analyse Info-Box
            engineAnalysisBox

            // Positions Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu").foregroundColor(.koboldEmerald)
                    Text("Engine-Positionen (\(cryptoHoldings.count))").font(.headline)
                    if status.running {
                        Text("LIVE").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.koboldEmerald.opacity(0.3)).cornerRadius(4)
                            .foregroundColor(.koboldEmerald)
                    }
                    Spacer()
                    Text(String(format: "%.2f€", livePortfolioValue))
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.koboldGold)
                }

                if cryptoHoldings.isEmpty {
                    HStack {
                        Image(systemName: "wallet.pass").foregroundColor(.secondary)
                        Text("Keine Coin-Bestände auf Coinbase").font(.caption).foregroundColor(.secondary)
                    }.padding(20)
                } else {
                    // Header
                    HStack {
                        Text("Coin").frame(width: 80, alignment: .leading)
                        Text("Wert").frame(width: 65, alignment: .trailing)
                        Text("Entry").frame(width: 70, alignment: .trailing)
                        Text("Kurs").frame(width: 70, alignment: .trailing)
                        Text("P&L €").frame(width: 65, alignment: .trailing)
                        Text("P&L %").frame(width: 50, alignment: .trailing)
                        Text("TP/SL").frame(width: 75, alignment: .trailing)
                        Spacer()
                        Text("").frame(width: 70)
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 8)

                    ForEach(cryptoHoldings, id: \.currency) { h in
                        positionRow(h, hodlCoin: hodlCoin, tpSlMode: tpSlMode, effectiveTP: effectiveTP, effectiveSL: effectiveSL)
                    }
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

            // Engine-Trades aus DB (nur wenn vorhanden — meistens leer)
            if !openPositions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aktive Engine-Orders (\(openPositions.count))").font(.headline)
                    ForEach(openPositions) { trade in
                        engineTradeRow(trade)
                    }
                }
                .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private func positionRow(_ h: TradeExecutor.AccountBalance, hodlCoin: String, tpSlMode: String, effectiveTP: Double, effectiveSL: Double) -> some View {
        let pair = "\(h.currency)-EUR"
        let price = spotPrices[pair]
        let cb = costBasis[h.currency]
        let monitor = holdingMonitorInfo[h.currency]
        let entryPrice = cb?.avgPrice ?? monitor?.entryPrice
        let realPnL: Double? = cb.map { h.nativeValue - $0.totalInvested }
        let realPnLPct: Double? = cb.flatMap { $0.totalInvested > 0 ? (h.nativeValue - $0.totalInvested) / $0.totalInvested * 100 : nil }
        let isHodl = !hodlCoin.isEmpty && h.currency.uppercased() == hodlCoin
        let isMonitored = monitor?.isMonitored == true && !isHodl
        let pnlColor: Color = (realPnL ?? 0) > 0 ? .koboldEmerald : (realPnL ?? 0) < 0 ? .red : .secondary

        VStack(spacing: 0) {
            HStack {
                // Coin + Badges
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Circle().fill(barColorForCurrency(h.currency)).frame(width: 8, height: 8)
                        Text(h.currency).font(.system(size: 12, weight: .semibold))
                    }
                    HStack(spacing: 2) {
                        if isHodl {
                            Text("HODL").font(.system(size: 7, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.koboldGold.opacity(0.3)).cornerRadius(3)
                                .foregroundColor(.koboldGold)
                        } else if isMonitored {
                            Text("ENGINE").font(.system(size: 7, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.koboldEmerald.opacity(0.3)).cornerRadius(3)
                                .foregroundColor(.koboldEmerald)
                        }
                        if let strat = monitor?.strategy {
                            Text(strat.prefix(8).uppercased()).font(.system(size: 6, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2)).cornerRadius(3)
                                .foregroundColor(.blue)
                        }
                    }
                }.frame(width: 80, alignment: .leading)

                // Wert in €
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.2f€", h.nativeValue))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(formatCryptoAmount(h.balance, currency: h.currency))
                        .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                }.frame(width: 65, alignment: .trailing)

                // Entry-Preis
                Text(entryPrice.map { formatPrice($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)

                // Aktueller Kurs
                Text(price.map { formatPrice($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)

                // P&L €
                Text(realPnL.map { String(format: "%+.2f€", $0) } ?? "—")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(pnlColor)
                    .frame(width: 65, alignment: .trailing)

                // P&L %
                Text(realPnLPct.map { String(format: "%+.1f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(pnlColor)
                    .frame(width: 50, alignment: .trailing)

                // TP/SL Distanz
                tpSlIndicator(entryPrice: entryPrice, currentPrice: price, tpPct: effectiveTP, slPct: effectiveSL, mode: tpSlMode)
                    .frame(width: 75, alignment: .trailing)

                Spacer()

                // Aktion
                if isHodl {
                    // HODL: Investiert-Wert + Lock
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 2) {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundColor(.koboldGold)
                            if let invested = cb?.totalInvested, invested > 0 {
                                Text("Inv: \(String(format: "%.0f€", invested))")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundColor(.koboldGold)
                            }
                        }
                    }
                    .frame(width: 70)
                } else {
                    Button("Verkaufen") {
                        sellConfirmTarget = h
                        showSellConfirm = true
                    }
                    .font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered).tint(.red)
                    .frame(width: 70)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(isMonitored ? Color.koboldEmerald.opacity(0.04) : Color.koboldSurface.opacity(0.12))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func tpSlIndicator(entryPrice: Double?, currentPrice: Double?, tpPct: Double, slPct: Double, mode: String) -> some View {
        if let entry = entryPrice, let current = currentPrice, entry > 0 {
            let pct = ((current - entry) / entry) * 100
            let distToTP = tpPct - pct
            let distToSL = pct + slPct

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 2) {
                    Text("TP").font(.system(size: 7, weight: .bold)).foregroundColor(.koboldEmerald)
                    Text(String(format: "%.1f%%", distToTP))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(distToTP <= 1 ? .koboldEmerald : .secondary)
                }
                HStack(spacing: 2) {
                    Text("SL").font(.system(size: 7, weight: .bold)).foregroundColor(.red)
                    Text(String(format: "%.1f%%", distToSL))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(distToSL <= 1 ? .red : .secondary)
                }
            }
        } else {
            Text("—").font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func engineTradeRow(_ trade: TradeRecord) -> some View {
        let currentPrice = spotPrices[trade.pair]
        let unrealizedPnL: Double? = currentPrice.map { cp in
            trade.side == "BUY" ? (cp - trade.price) * trade.size : (trade.price - cp) * trade.size
        }
        let unrealizedPct: Double? = currentPrice.map { cp in
            trade.side == "BUY" ? ((cp - trade.price) / trade.price) * 100 : ((trade.price - cp) / trade.price) * 100
        }
        let entryValue = trade.price * trade.size
        let currentValue: Double? = currentPrice.map { $0 * trade.size }
        HStack {
            HStack(spacing: 4) {
                Circle().fill(trade.side == "BUY" ? Color.koboldEmerald : Color.red).frame(width: 6, height: 6)
                Text(trade.pair).font(.system(size: 12, weight: .semibold))
            }.frame(width: 80, alignment: .leading)
            Text(trade.side).font(.system(size: 11, weight: .bold))
                .foregroundColor(trade.side == "BUY" ? .koboldEmerald : .red).frame(width: 35)
            // Entry-Preis + EUR-Wert
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatPrice(trade.price)).font(.system(size: 11, design: .monospaced))
                Text(String(format: "%.2f€", entryValue))
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
            }.frame(width: 80, alignment: .trailing)
            // Aktueller Preis + Wert
            VStack(alignment: .trailing, spacing: 0) {
                Text(currentPrice.map { formatPrice($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                Text(currentValue.map { String(format: "%.2f€", $0) } ?? "")
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
            }.frame(width: 80, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 0) {
                Text(unrealizedPnL.map { String(format: "%+.2f€", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor((unrealizedPnL ?? 0) >= 0 ? .koboldEmerald : .red)
                Text(unrealizedPct.map { String(format: "%+.1f%%", $0) } ?? "")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }.frame(width: 75, alignment: .trailing)
            Text(trade.strategy).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
            Spacer()
            Button("Close") {
                Task {
                    if let p = await TradeExecutor.shared.getSpotPrice(pair: trade.pair) {
                        await TradeExecutor.shared.closePosition(trade, currentPrice: p)
                        await loadAll()
                    }
                }
            }
            .font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered).tint(.red)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.koboldSurface.opacity(0.15)).cornerRadius(4)
    }

    // MARK: - Engine Analysis Info Box

    private var engineAnalysisBox: some View {
        let strategies = UserDefaults.standard.bool(forKey: "kobold.trading.strategies.momentum") != false ? "Momentum" : ""
        let activeStrats = [
            UserDefaults.standard.object(forKey: "kobold.trading.strategies.momentum") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.strategies.momentum") ? "Momentum" : nil,
            UserDefaults.standard.object(forKey: "kobold.trading.strategies.breakout") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.strategies.breakout") ? "Breakout" : nil,
            UserDefaults.standard.object(forKey: "kobold.trading.strategies.mean_reversion") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.strategies.mean_reversion") ? "MeanRev" : nil,
            UserDefaults.standard.object(forKey: "kobold.trading.strategies.trend_following") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.strategies.trend_following") ? "Trend" : nil,
            UserDefaults.standard.object(forKey: "kobold.trading.strategies.scalping") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.strategies.scalping") ? "Scalp" : nil,
        ].compactMap { $0 }
        let _ = strategies // suppress unused warning

        return HStack(spacing: 12) {
            Image(systemName: "cpu").font(.system(size: 14)).foregroundColor(.koboldEmerald)
            VStack(alignment: .leading, spacing: 2) {
                Text("Engine-Analyse: Technische Indikatoren").font(.system(size: 11, weight: .semibold))
                HStack(spacing: 4) {
                    ForEach(["RSI", "MACD", "EMA", "BB", "ATR", "Vol"], id: \.self) { ind in
                        Text(ind).font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15)).cornerRadius(3)
                            .foregroundColor(.blue)
                    }
                }
                Text("Strategien: \(activeStrats.joined(separator: ", "))").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Circle().fill(status.running ? Color.koboldEmerald : Color.red).frame(width: 6, height: 6)
                    Text(status.running ? "Aktiv" : "Gestoppt").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(status.running ? .koboldEmerald : .red)
                }
                Text("Zyklus: \(status.lastCycleTime.suffix(8))").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(10).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
    }

    // MARK: - History

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trade-Historie (\(tradeHistory.count))").font(.headline)
                Spacer()
                Button("CSV Export") { exportCSV() }.font(.caption).buttonStyle(.bordered)
            }
            if tradeHistory.isEmpty {
                Text("Keine Trades vorhanden.").foregroundColor(.secondary).padding(40)
            } else {
                HStack {
                    Text("Zeit").frame(width: 120, alignment: .leading)
                    Text("Paar").frame(width: 70, alignment: .leading)
                    Text("Seite").frame(width: 40)
                    Text("Preis").frame(width: 80, alignment: .trailing)
                    Text("Menge").frame(width: 90, alignment: .trailing)
                    Text("P&L €").frame(width: 70, alignment: .trailing)
                    Text("P&L %").frame(width: 55, alignment: .trailing)
                    Text("Dauer").frame(width: 55, alignment: .trailing)
                    Text("Strategie").frame(width: 75, alignment: .leading)
                    Text("Bemerkung").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.horizontal, 8)

                ForEach(tradeHistory) { trade in tradeRow(trade) }
            }
        }
    }

    // MARK: - Analytics (Professional Metrics)

    private var analyticsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // SECTION 1: Portfolio-Analyse (immer sichtbar wenn Holdings vorhanden)
            let cryptoHoldings = liveHoldings.filter { $0.currency != "EUR" && $0.currency != "EURC" && $0.nativeValue > 0.01 }
            if !cryptoHoldings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Portfolio-Analyse").font(.headline)

                    let totalCrypto = cryptoHoldings.reduce(0.0) { $0 + $1.nativeValue }
                    let totalPnL24h = computePortfolioPnL24h()
                    let totalPnLPct = computePortfolioPnLPct24h()
                    let largest = cryptoHoldings.max(by: { $0.nativeValue < $1.nativeValue })
                    let largestPct = (largest.map { $0.nativeValue / max(totalCrypto, 0.01) * 100 }) ?? 0

                    HStack(spacing: 12) {
                        metricCard("Crypto-Wert", String(format: "%.2f€", totalCrypto), icon: "bitcoinsign.circle.fill", color: .orange)
                        metricCard("24h P&L", String(format: "%+.2f€ (%+.1f%%)", totalPnL24h, totalPnLPct),
                                   icon: totalPnL24h >= 0 ? "arrow.up.right" : "arrow.down.right",
                                   color: totalPnL24h >= 0 ? .koboldEmerald : .red)
                        metricCard("Assets", "\(cryptoHoldings.count) Coins", icon: "square.stack.3d.up.fill", color: .blue)
                        metricCard("Größte Pos.", "\(largest?.currency ?? "—") (\(String(format: "%.0f%%", largestPct)))",
                                   icon: "chart.pie.fill", color: .purple)
                    }

                    // Asset-Verteilung als horizontale Bars
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Asset-Verteilung").font(.subheadline.weight(.semibold))
                        ForEach(cryptoHoldings.prefix(8), id: \.currency) { h in
                            let pct = totalCrypto > 0 ? (h.nativeValue / totalCrypto) * 100 : 0
                            let change = priceChanges24h[h.currency] ?? 0
                            HStack(spacing: 8) {
                                HStack(spacing: 4) {
                                    Circle().fill(barColorForCurrency(h.currency)).frame(width: 8, height: 8)
                                    Text(h.currency).font(.system(size: 12, weight: .semibold)).frame(width: 45, alignment: .leading)
                                }
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(barColorForCurrency(h.currency).opacity(0.6))
                                        .frame(width: max(CGFloat(pct / 100) * geo.size.width, 2), height: 14)
                                }
                                .frame(height: 14)
                                Text(String(format: "%.1f%%", pct))
                                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                    .frame(width: 45, alignment: .trailing)
                                Text(String(format: "%.2f€", h.nativeValue))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 65, alignment: .trailing)
                                Text(String(format: "%+.1f%%", change))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(change > 0 ? .koboldEmerald : change < 0 ? .red : .secondary)
                                    .frame(width: 55, alignment: .trailing)
                            }
                        }
                    }
                    .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

                    // Top/Bottom Performer
                    let sorted24h = cryptoHoldings.sorted { (priceChanges24h[$0.currency] ?? 0) > (priceChanges24h[$1.currency] ?? 0) }
                    if sorted24h.count >= 2 {
                        HStack(spacing: 12) {
                            let best = sorted24h.first!
                            let worst = sorted24h.last!
                            let bestChange = priceChanges24h[best.currency] ?? 0
                            let worstChange = priceChanges24h[worst.currency] ?? 0
                            metricCard("Top Performer", "\(best.currency) \(String(format: "%+.1f%%", bestChange))",
                                       icon: "crown.fill", color: .koboldEmerald)
                            metricCard("Schwächster", "\(worst.currency) \(String(format: "%+.1f%%", worstChange))",
                                       icon: "arrow.down.circle.fill", color: .red)
                        }
                    }
                }
                .padding(12).background(Color.koboldSurface.opacity(0.15)).cornerRadius(8)
            }

            // SECTION 2: Trading-Performance (nur bei abgeschlossenen Trades)
            Text("Trading-Performance").font(.headline)

            if analytics.totalTrades == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title).foregroundColor(.secondary)
                    Text("Noch keine abgeschlossenen Trades. Starte die Engine für automatisches Trading.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(40).frame(maxWidth: .infinity)
            } else {
                // Risk-Adjusted Returns
                HStack(spacing: 12) {
                    metricCard("Sharpe", String(format: "%.2f", analytics.sharpeRatio), icon: "chart.bar.fill",
                               color: analytics.sharpeRatio >= 1 ? .koboldEmerald : analytics.sharpeRatio >= 0 ? .orange : .red)
                    metricCard("Sortino", String(format: "%.2f", analytics.sortinoRatio), icon: "chart.bar.fill",
                               color: analytics.sortinoRatio >= 2 ? .koboldEmerald : analytics.sortinoRatio >= 0 ? .orange : .red)
                    metricCard("Calmar", String(format: "%.2f", analytics.calmarRatio), icon: "chart.bar.fill",
                               color: analytics.calmarRatio >= 1 ? .koboldEmerald : analytics.calmarRatio >= 0 ? .orange : .red)
                    metricCard("Max DD", String(format: "%.1f%%", analytics.maxDrawdownPct), icon: "arrow.down", color: .red)
                }

                HStack(spacing: 12) {
                    metricCard("Win Rate", String(format: "%.1f%%", analytics.winRate), icon: "target", color: .blue)
                    metricCard("Profit Factor", String(format: "%.2f", analytics.profitFactor), icon: "scalemass.fill", color: .koboldGold)
                    metricCard("Total P&L", String(format: "%+.2f€", analytics.totalPnL), icon: "eurosign.circle.fill",
                               color: analytics.totalPnL >= 0 ? .koboldEmerald : .red)
                    metricCard("Trades", "\(analytics.totalTrades) (\(analytics.wins)W/\(analytics.losses)L)", icon: "arrow.left.arrow.right", color: .cyan)
                }

                HStack(spacing: 12) {
                    metricCard("Avg Profit", String(format: "%.2f€", analytics.avgProfit), icon: "plus.circle", color: .koboldEmerald)
                    metricCard("Avg Loss", String(format: "%.2f€", analytics.avgLoss), icon: "minus.circle", color: .red)
                    metricCard("Bester Trade", String(format: "%+.2f€", analytics.bestTrade), icon: "star.fill", color: .koboldGold)
                    metricCard("Schlechtester", String(format: "%+.2f€", analytics.worstTrade), icon: "xmark.circle", color: .red)
                }

                // Equity Curve Chart
                if analytics.equityCurve.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Equity Curve").font(.subheadline.weight(.semibold))
                        Chart {
                            ForEach(Array(analytics.equityCurve.enumerated()), id: \.offset) { idx, value in
                                LineMark(x: .value("Trade", idx), y: .value("P&L", value))
                                    .foregroundStyle(Color.koboldEmerald)
                                AreaMark(x: .value("Trade", idx), y: .value("P&L", value))
                                    .foregroundStyle(
                                        LinearGradient(colors: [.koboldEmerald.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                                    )
                            }
                        }
                        .chartYAxisLabel("€")
                        .frame(height: 180)
                    }
                    .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
                }

                // Drawdown Chart
                if analytics.drawdownCurve.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drawdown").font(.subheadline.weight(.semibold))
                        Chart {
                            ForEach(Array(analytics.drawdownCurve.enumerated()), id: \.offset) { idx, value in
                                BarMark(x: .value("Trade", idx), y: .value("DD%", -value))
                                    .foregroundStyle(Color.red.opacity(0.6))
                            }
                        }
                        .chartYAxisLabel("%")
                        .frame(height: 100)
                    }
                    .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
                }

                // Benchmark info
                HStack {
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                    Text("Sharpe >1.0, Sortino >2.0, Calmar >1.0 gelten als gut. Profit Factor >1.5 ist solide.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Learning (Strategy Performance + Improvement Tracking)

    private var learningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Engine-Lernfortschritt").font(.headline)
                Spacer()
                Button(action: {
                    Task {
                        strategyPerfs = await TradingRiskManager.shared.getStrategyPerformance()
                        autoBacktestResults = await TradingEngine.shared.getLatestBacktests()
                        learningNotes = await TradingEngine.shared.getLearningNotes()
                    }
                }) {
                    Label("Aktualisieren", systemImage: "arrow.clockwise").font(.caption)
                }.buttonStyle(.bordered)
            }

            // Aktive Strategien-Übersicht (immer sichtbar)
            let activeStrategies = status.activeStrategies
            VStack(alignment: .leading, spacing: 8) {
                Text("Aktive Strategien (\(activeStrategies.count))").font(.subheadline.weight(.semibold))
                let stratColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: stratColumns, spacing: 8) {
                    strategyInfoCard("Momentum", "RSI + MACD + EMA200", "chart.line.uptrend.xyaxis", activeStrategies.contains("momentum"))
                    strategyInfoCard("Breakout", "Perioden-Hoch/Tief + Volumen", "arrow.up.right.circle", activeStrategies.contains("breakout"))
                    strategyInfoCard("Mean Reversion", "Bollinger Bands + BB%B", "arrow.left.arrow.right.circle", activeStrategies.contains("mean_reversion"))
                    strategyInfoCard("Trend Following", "EMA-Crossover + EMA200 + MACD", "arrow.right.circle", activeStrategies.contains("trend_following"))
                    strategyInfoCard("Scalping", "BB-Squeeze + EMA9 + Momentum", "bolt.circle", activeStrategies.contains("scalping"))
                    strategyInfoCard("Ultra Scalp", "6-Check Leverage-Ready (1-3h)", "bolt.trianglebadge.exclamationmark", activeStrategies.contains("ultra_scalp"))
                    strategyInfoCard("Divergence", "RSI-Preis-Divergenz (bullish/bearish)", "arrow.triangle.swap", activeStrategies.contains("divergence"))
                    strategyInfoCard("Akkumulation", "OBV + Smart-Money-Detection", "chart.bar.fill", activeStrategies.contains("accumulation"))
                    strategyInfoCard("Support/Resist.", "Key-Level-Bounce + Break", "rectangle.split.3x1", activeStrategies.contains("support_resistance"))
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

            // Strategy Performance (wenn Daten vorhanden)
            if !strategyPerfs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Strategie-Performance").font(.subheadline.weight(.semibold))
                    ForEach(strategyPerfs, id: \.name) { perf in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                    .foregroundColor(perf.totalPnL >= 0 ? .koboldEmerald : .red)
                                Text(perf.name).font(.system(size: 14, weight: .bold))
                                Spacer()
                                Text(String(format: "%+.2f€", perf.totalPnL))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(perf.totalPnL >= 0 ? .koboldEmerald : .red)
                            }
                            HStack(spacing: 12) {
                                perfPill("Trades", "\(perf.totalTrades)", color: .blue)
                                perfPill("Win Rate", String(format: "%.0f%%", perf.winRate),
                                         color: perf.winRate >= 50 ? .koboldEmerald : .red)
                                perfPill("W/L", "\(perf.wins)/\(perf.losses)",
                                         color: perf.wins >= perf.losses ? .koboldEmerald : .red)
                                perfPill("Bester", String(format: "%+.2f€", perf.bestTrade), color: .koboldEmerald)
                                perfPill("Worst", String(format: "%+.2f€", perf.worstTrade), color: .red)
                                perfPill("Avg Hold", String(format: "%.0fmin", perf.avgHoldingMinutes), color: .secondary)
                            }
                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.koboldEmerald.opacity(0.7))
                                        .frame(width: max(CGFloat(perf.winRate / 100) * geo.size.width, 2))
                                    Rectangle().fill(Color.red.opacity(0.5))
                                }
                                .cornerRadius(3)
                            }
                            .frame(height: 8)
                        }
                        .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
                    }

                    let totalTrades = strategyPerfs.reduce(0) { $0 + $1.totalTrades }
                    let totalPnL = strategyPerfs.reduce(0.0) { $0 + $1.totalPnL }
                    let totalWins = strategyPerfs.reduce(0) { $0 + $1.wins }
                    let overallWinRate = totalTrades > 0 ? Double(totalWins) / Double(totalTrades) * 100 : 0
                    HStack(spacing: 12) {
                        metricCard("Gesamt-Trades", "\(totalTrades)", icon: "arrow.left.arrow.right", color: .blue)
                        metricCard("Gesamt-P&L", String(format: "%+.2f€", totalPnL), icon: "eurosign.circle.fill",
                                   color: totalPnL >= 0 ? .koboldEmerald : .red)
                        metricCard("Win Rate", String(format: "%.1f%%", overallWinRate), icon: "target",
                                   color: overallWinRate >= 50 ? .koboldEmerald : .red)
                        metricCard("Beste Strategie", strategyPerfs.first?.name ?? "—", icon: "crown.fill", color: .koboldGold)
                    }
                }
            } else {
                // Erklärung wenn noch keine Performance-Daten
                VStack(alignment: .leading, spacing: 8) {
                    Text("Strategie-Performance").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        Image(systemName: "brain.head.profile").font(.title2).foregroundColor(.koboldGold)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Noch keine Trade-Daten vorhanden")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Die Engine trackt automatisch jeden Trade und zeigt hier Win-Rate, P&L und Haltezeit pro Strategie. Starte die Engine mit Auto-Trade AN um Daten zu sammeln.")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
            }

            // Auto-Backtest Ergebnisse (einklappbar nach Coin)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Auto-Backtests (\(autoBacktestResults.count))").font(.subheadline.weight(.semibold))
                    Spacer()
                    if !autoBacktestResults.isEmpty {
                        let avgReturn = autoBacktestResults.values.map(\.totalReturn).reduce(0, +) / max(Double(autoBacktestResults.count), 1)
                        Text(String(format: "Ø %+.1f%%", avgReturn))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(avgReturn >= 0 ? .koboldEmerald : .red)
                    }
                }
                if autoBacktestResults.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backtests laufen automatisch").font(.system(size: 13, weight: .semibold))
                            Text("Alle 6 Stunden testet die Engine jede Strategie gegen historische Daten.")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                } else {
                    // Gruppiert nach Coin
                    let grouped = Dictionary(grouping: autoBacktestResults.values.map { $0 }) {
                        $0.pair.replacingOccurrences(of: "-EUR", with: "")
                    }
                    ForEach(Array(grouped.keys.sorted()), id: \.self) { coin in
                        if let results = grouped[coin] {
                            let bestReturn = results.max(by: { $0.totalReturn < $1.totalReturn })
                            let avgWinRate = results.map(\.winRate).reduce(0, +) / max(Double(results.count), 1)
                            let summaryColor: Color = (bestReturn?.totalReturn ?? 0) >= 0 ? .koboldEmerald : .red

                            DisclosureGroup {
                                // Header
                                HStack(spacing: 0) {
                                    Text("Strategie").frame(width: 100, alignment: .leading)
                                    Text("Return").frame(width: 65, alignment: .trailing)
                                    Text("Sharpe").frame(width: 55, alignment: .trailing)
                                    Text("Win%").frame(width: 50, alignment: .trailing)
                                    Text("DD").frame(width: 50, alignment: .trailing)
                                    Text("Trades").frame(width: 45, alignment: .trailing)
                                    Text("PF").frame(width: 40, alignment: .trailing)
                                    Spacer()
                                }
                                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 6)

                                ForEach(results.sorted(by: { $0.totalReturn > $1.totalReturn }), id: \.strategy) { r in
                                    HStack(spacing: 0) {
                                        Text(r.strategy).font(.system(size: 11, weight: .semibold))
                                            .frame(width: 100, alignment: .leading).lineLimit(1)
                                        Text(String(format: "%+.1f%%", r.totalReturn))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(r.totalReturn >= 0 ? .koboldEmerald : .red)
                                            .frame(width: 65, alignment: .trailing)
                                        Text(String(format: "%.1f", r.sharpeRatio))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(r.sharpeRatio >= 1 ? .koboldEmerald : .secondary)
                                            .frame(width: 55, alignment: .trailing)
                                        Text(String(format: "%.0f%%", r.winRate))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(r.winRate >= 50 ? .koboldEmerald : .red)
                                            .frame(width: 50, alignment: .trailing)
                                        Text(String(format: "%.1f%%", r.maxDrawdown))
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.red)
                                            .frame(width: 50, alignment: .trailing)
                                        Text("\(r.totalTrades)").font(.system(size: 10, design: .monospaced))
                                            .frame(width: 45, alignment: .trailing)
                                        Text(String(format: "%.1f", r.profitFactor))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(r.profitFactor >= 1.5 ? .koboldEmerald : .secondary)
                                            .frame(width: 40, alignment: .trailing)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.koboldSurface.opacity(0.1)).cornerRadius(3)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(barColorForCurrency(coin)).frame(width: 8, height: 8)
                                    Text(coin).font(.system(size: 13, weight: .bold))
                                    Text("\(results.count) Strategien").font(.system(size: 10)).foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "Best: %+.1f%%", bestReturn?.totalReturn ?? 0))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(summaryColor)
                                    Text(String(format: "Ø Win: %.0f%%", avgWinRate))
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                            }
                            .padding(6).background(Color.koboldSurface.opacity(0.15)).cornerRadius(6)
                        }
                    }
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

            // KI-Agent Lernnotizen
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "brain.head.profile").foregroundColor(.purple)
                    Text("KI-Agent Erkenntnisse (\(learningNotes.count))").font(.subheadline.weight(.semibold))
                    Spacer()
                    if !learningNotes.isEmpty {
                        Button(action: {
                            Task {
                                // Datei löschen
                                let file = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent("Library/Application Support/KoboldOS/trading_learning.json")
                                try? FileManager.default.removeItem(at: file)
                                learningNotes = []
                            }
                        }) {
                            Label("Löschen", systemImage: "trash").font(.caption)
                        }.buttonStyle(.bordered).tint(.red)
                    }
                }

                if learningNotes.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.title2).foregroundColor(.purple.opacity(0.5))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Noch keine KI-Erkenntnisse").font(.system(size: 13, weight: .semibold))
                            Text("Wenn der KI-Agent aktiv ist, analysiert er alle 6h die Performance, Backtests und Marktlage. Seine Erkenntnisse und Empfehlungen erscheinen hier.")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                } else {
                    ForEach(Array(learningNotes.reversed().enumerated()), id: \.offset) { idx, note in
                        DisclosureGroup {
                            Text(note.note)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.9))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.05))
                                .cornerRadius(6)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(.purple)
                                Text(note.date).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                Text(String(note.note.prefix(80)).replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 11)).foregroundColor(.primary).lineLimit(1)
                            }
                        }
                        .padding(6).background(Color.purple.opacity(0.05)).cornerRadius(6)
                    }
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

            // Engine-Konfiguration Schnellübersicht
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine-Konfiguration").font(.subheadline.weight(.semibold))
                let engineCols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: engineCols, spacing: 8) {
                    let cyc = UserDefaults.standard.integer(forKey: "kobold.trading.cycleInterval")
                    configCard("Zyklus", "\(cyc > 0 ? cyc : 60)s")
                    let mts = UserDefaults.standard.double(forKey: "kobold.trading.maxTradeSize")
                    configCard("Max Position", "\(String(format: "%.1f", mts > 0 ? mts : 2.0))%")
                    let mop = UserDefaults.standard.integer(forKey: "kobold.trading.maxOpenPositions")
                    configCard("Max Positionen", "\(mop > 0 ? mop : 5)")
                    let ct = UserDefaults.standard.double(forKey: "kobold.trading.confidenceThreshold")
                    configCard("Confidence", "\(String(format: "%.0f", (ct > 0 ? ct : 0.7) * 100))%")
                    configCard("TP/SL Modus", UserDefaults.standard.string(forKey: "kobold.trading.tpSlMode") ?? "trailing")
                    let fr = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
                    configCard("Fee Rate", "\(String(format: "%.1f", (fr > 0 ? fr : 0.005) * 100))%")
                    let hc = UserDefaults.standard.string(forKey: "kobold.trading.hodlCoin") ?? ""
                    configCard("HODL-Coin", hc.isEmpty ? "—" : hc)
                    configCard("Circuit Break", UserDefaults.standard.bool(forKey: "kobold.trading.circuitBreakers") ? "AN" : "AUS")
                    let bsOn = UserDefaults.standard.object(forKey: "kobold.trading.buySignalsEnabled") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.buySignalsEnabled")
                    let ssOn = UserDefaults.standard.object(forKey: "kobold.trading.sellSignalsEnabled") == nil || UserDefaults.standard.bool(forKey: "kobold.trading.sellSignalsEnabled")
                    configCard("Buy-Signale", bsOn ? "AN" : "AUS")
                    configCard("Sell-Signale", ssOn ? "AN" : "AUS")
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

            // Benchmarks
            VStack(alignment: .leading, spacing: 8) {
                Text("Bewertungskriterien").font(.subheadline.weight(.semibold))
                let bmCols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: bmCols, spacing: 6) {
                    benchmarkCard("Win Rate", [">60% Gut", "40-60% OK", "<40% Schlecht"], [.koboldEmerald, .orange, .red])
                    benchmarkCard("Sharpe Ratio", [">1.0 Gut", "0.5-1.0 OK", "<0.5 Schlecht"], [.koboldEmerald, .orange, .red])
                    benchmarkCard("Max Drawdown", ["<15% Gut", "15-25% OK", ">25% Schlecht"], [.koboldEmerald, .orange, .red])
                    benchmarkCard("Profit Factor", [">1.5 Solide", "1.0-1.5 OK", "<1.0 Verlust"], [.koboldEmerald, .orange, .red])
                }
            }
            .padding(12).background(Color.koboldSurface.opacity(0.2)).cornerRadius(8)
        }
    }

    private func strategyInfoCard(_ name: String, _ desc: String, _ icon: String, _ active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(active ? .koboldEmerald : .secondary)
                Text(name).font(.system(size: 12, weight: .bold))
                Spacer()
                Circle().fill(active ? Color.koboldEmerald : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
            }
            Text(desc).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(10).background(active ? Color.koboldEmerald.opacity(0.08) : Color.koboldSurface.opacity(0.3)).cornerRadius(8)
    }

    private func configCard(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(8).frame(maxWidth: .infinity).background(Color.black.opacity(0.15)).cornerRadius(6)
    }

    private func benchmarkCard(_ title: String, _ items: [String], _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .bold))
            ForEach(Array(zip(items, colors)), id: \.0) { item, color in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(item).font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.1)).cornerRadius(6)
    }

    private func perfPill(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.1)).cornerRadius(4)
    }

    private func benchmarkRow(_ metric: String, _ threshold: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(metric).font(.system(size: 10, weight: .medium)).frame(width: 55, alignment: .leading)
            Text(threshold).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 50)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(color)
        }
    }

    // MARK: - Strategies

    private var strategiesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Built-in Strategien
            Text("Built-in Strategien").font(.headline)
            strategyCard("Momentum", description: "RSI + MACD Crossover + EMA Alignment. Folgt dem Trend bei starkem Momentum.", key: "kobold.trading.strategies.momentum", icon: "bolt.fill")
            strategyCard("Breakout", description: "N-Perioden High/Low Breakout + Volumenbestätigung. Erfasst Ausbrüche aus Ranges.", key: "kobold.trading.strategies.breakout", icon: "arrow.up.right.circle.fill")
            strategyCard("Mean Reversion", description: "Bollinger Band Reversion in Sideways-Märkten. Kauft bei Überverkauf, verkauft bei Überkauf.", key: "kobold.trading.strategies.mean_reversion", icon: "arrow.left.and.right")
            strategyCard("Trend Following", description: "EMA Crossover System (Golden/Death Cross) + MACD Richtungswechsel. Folgt etablierten Trends.", key: "kobold.trading.strategies.trend_following", icon: "arrow.up.forward.circle.fill")
            strategyCard("Scalping", description: "Kurzfristige Gewinnmitnahmen: BB-Squeeze, RSI-Dips, Pullback-Erkennung. Für schnelle Trades.", key: "kobold.trading.strategies.scalping", icon: "hare.fill")

            // Custom-Strategien
            HStack {
                Text("Custom-Strategien (\(customStrategies.count))").font(.headline)
                Spacer()
                Text("Erstelle neue Strategien über den Chat oder Activity-Log")
                    .font(.caption).foregroundColor(.secondary)
            }

            if customStrategies.isEmpty {
                HStack {
                    Image(systemName: "wand.and.stars").foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keine Custom-Strategien").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Text("Der Agent kann Strategien erstellen: \"Erstelle eine Strategie die bei RSI unter 30 kauft\"")
                            .font(.caption).foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding(16).background(Color.koboldSurface.opacity(0.2)).cornerRadius(8)
            } else {
                ForEach(customStrategies, id: \.name) { cs in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "wand.and.stars").font(.title3).foregroundColor(.purple).frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(cs.name).font(.system(size: 14, weight: .semibold))
                                    Text("v\(cs.version)").font(.caption).foregroundColor(.secondary)
                                    if !cs.regimeFilter.isEmpty {
                                        Text(cs.regimeFilter)
                                            .font(.system(size: 10)).foregroundColor(.orange)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.15)).cornerRadius(4)
                                    }
                                }
                                Text(cs.rules)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                Task {
                                    _ = await StrategyEngine.shared.removeCustomStrategy(name: cs.name)
                                    await loadCustomStrategies()
                                }
                            }) {
                                Image(systemName: "trash").font(.caption).foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            Toggle("", isOn: Binding(
                                get: {
                                    let key = "kobold.trading.strategies.\(cs.name)"
                                    return UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.bool(forKey: key) : true
                                },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.trading.strategies.\(cs.name)") }
                            )).toggleStyle(.switch)
                        }
                        // Regeln anzeigen
                        ForEach(Array(cs.ruleDetails.enumerated()), id: \.offset) { idx, rule in
                            HStack(spacing: 6) {
                                Text("→").foregroundColor(.secondary)
                                Text(rule.indicator).font(.system(size: 11, weight: .medium, design: .monospaced))
                                Text(rule.condition).font(.system(size: 11)).foregroundColor(.secondary)
                                Text(String(format: "%.1f", rule.value))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text("(\(String(format: "%.0f%%", rule.weight * 100)))")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                Text(rule.action.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(rule.action == "buy" ? .koboldEmerald : .red)
                            }
                            .padding(.leading, 40)
                        }
                    }
                    .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Backtest (with Charts)

    private var backtestContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Backtest").font(.headline)
            Text("Historische Simulation einer Strategie mit echten Coinbase-Kursdaten.")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Strategie").font(.caption.weight(.semibold))
                    Picker("", selection: $btStrategy) {
                        Text("Momentum").tag("momentum")
                        Text("Breakout").tag("breakout")
                        Text("Mean Reversion").tag("mean_reversion")
                        Text("Trend Following").tag("trend_following")
                        Text("Scalping").tag("scalping")
                    }.frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paar").font(.caption.weight(.semibold))
                    TextField("z.B. BTC-EUR", text: $btPair).frame(width: 120).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zeitraum").font(.caption.weight(.semibold))
                    Picker("", selection: $btDays) {
                        Text("7 Tage").tag(7)
                        Text("14 Tage").tag(14)
                        Text("30 Tage").tag(30)
                    }.frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(" ").font(.caption)
                    Button(action: runBacktest) {
                        if btRunning {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.6)
                                Text("Läuft...").font(.caption)
                            }
                        } else {
                            Label("Backtest starten", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.koboldEmerald).disabled(btRunning)
                }
            }

            if let r = btResult {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Ergebnis: \(r.strategy)").font(.subheadline.weight(.semibold))
                        Text("\(r.pair) • \(r.periodDays) Tage • \(r.totalTrades) Trades")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    // Key Metrics
                    HStack(spacing: 12) {
                        metricCard("Return", String(format: "%.2f%%", r.totalReturn), icon: "percent",
                                   color: r.totalReturn >= 0 ? .koboldEmerald : .red)
                        metricCard("Sharpe", String(format: "%.2f", r.sharpeRatio), icon: "chart.bar.fill", color: .purple)
                        metricCard("Max DD", String(format: "%.2f%%", r.maxDrawdown), icon: "arrow.down", color: .red)
                        metricCard("Win Rate", String(format: "%.1f%%", r.winRate), icon: "target", color: .blue)
                    }
                    HStack(spacing: 12) {
                        metricCard("Trades", "\(r.totalTrades)", icon: "arrow.left.arrow.right", color: .cyan)
                        metricCard("Profit Factor", String(format: "%.2f", r.profitFactor), icon: "scalemass.fill", color: .koboldGold)
                        metricCard("Avg Return", String(format: "%.2f%%", r.avgTradeReturn), icon: "equal", color: .orange)
                        metricCard("Zeitraum", "\(r.startDate.prefix(10)) — \(r.endDate.prefix(10))", icon: "calendar", color: .secondary)
                    }

                    // Equity Curve Chart
                    if r.equityCurve.count > 2 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Equity Curve (Kapitalverlauf)").font(.subheadline.weight(.semibold))
                            Chart {
                                ForEach(Array(r.equityCurve.enumerated()), id: \.offset) { idx, value in
                                    let normalized = (value / r.equityCurve[0] - 1) * 100
                                    LineMark(x: .value("Step", idx), y: .value("Return %", normalized))
                                        .foregroundStyle(normalized >= 0 ? Color.koboldEmerald : Color.red)
                                    AreaMark(x: .value("Step", idx), y: .value("Return %", normalized))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [
                                                    (normalized >= 0 ? Color.koboldEmerald : Color.red).opacity(0.2),
                                                    .clear
                                                ],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        )
                                }
                                // Zero line
                                RuleMark(y: .value("Zero", 0))
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .lineStyle(StrokeStyle(dash: [4, 4]))
                            }
                            .chartYAxisLabel("Return %")
                            .frame(height: 200)
                        }
                        .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)

                        // Drawdown visualization
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Drawdown").font(.subheadline.weight(.semibold))
                            let drawdowns = computeDrawdownFromEquity(r.equityCurve)
                            Chart {
                                ForEach(Array(drawdowns.enumerated()), id: \.offset) { idx, dd in
                                    BarMark(x: .value("Step", idx), y: .value("DD%", -dd))
                                        .foregroundStyle(Color.red.opacity(0.5))
                                }
                            }
                            .chartYAxisLabel("Drawdown %")
                            .frame(height: 100)
                        }
                        .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
                    }
                }
                .padding(12).background(Color.koboldSurface.opacity(0.15)).cornerRadius(8)
            } else if !btRunning {
                HStack {
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                    Text("Wähle eine Strategie und ein Paar, dann klicke 'Backtest starten'. Die Engine holt historische Kursdaten von Coinbase und simuliert die Strategie.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(12).background(Color.koboldSurface.opacity(0.2)).cornerRadius(8)
            }
        }
    }

    // MARK: - Components

    private func metricCard(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundColor(color)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Text(value).font(.system(size: 15, weight: .bold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.koboldSurface.opacity(0.3))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func logEntryView(_ entry: TradingLogEntry) -> some View {
        let isAgent = entry.type == .agent
        let isLong = entry.message.count > 120
        let isExpanded = expandedLogIds.contains(entry.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                Image(systemName: entry.icon)
                    .font(.system(size: 9)).foregroundColor(entry.color)
                if isAgent && isLong && !isExpanded {
                    Text(String(entry.message.prefix(120)) + " ▸")
                        .font(.system(size: 11)).foregroundColor(.primary)
                } else {
                    Text(entry.message)
                        .font(.system(size: 11)).foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, isAgent ? 3 : 1)
        }
        .background(isAgent ? Color.purple.opacity(0.06) : Color.clear)
        .onTapGesture {
            if isAgent && isLong {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedLogIds.remove(entry.id) }
                    else { expandedLogIds.insert(entry.id) }
                }
            }
        }
    }

    private func forecastPill(_ f: ForecastResult) -> some View {
        let arrow = f.direction == "UP" ? "↑" : f.direction == "DOWN" ? "↓" : "→"
        let color: Color = f.direction == "UP" ? .koboldEmerald : f.direction == "DOWN" ? .red : .secondary
        return HStack(spacing: 4) {
            Text(f.horizon).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            Text(arrow).foregroundColor(color)
            Text(String(format: "%.0f%%", f.confidence * 100))
                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.1)).cornerRadius(6)
    }

    private func tradeRow(_ trade: TradeRecord) -> some View {
        let isAgentTrade = trade.strategy.hasPrefix("KI:")
        let displayStrategy = isAgentTrade ? String(trade.strategy.dropFirst(3)) : trade.strategy
        let invested = trade.price * trade.size
        let pnlPct: Double? = (trade.pnl != nil && invested > 0) ? (trade.pnl! / invested * 100) : nil

        return HStack {
            Text(String(trade.timestamp.prefix(16))).font(.system(size: 10, design: .monospaced)).frame(width: 110, alignment: .leading)
            Text(trade.pair).font(.system(size: 11, weight: .medium)).frame(width: 65, alignment: .leading)
            Text(trade.side).font(.system(size: 11, weight: .bold))
                .foregroundColor(trade.side == "BUY" ? .koboldEmerald : .red).frame(width: 35)
            // Preis + EUR-Wert
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.2f€", trade.price)).font(.system(size: 11, design: .monospaced))
                Text(String(format: "%.2f€ Wert", invested))
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
            }.frame(width: 80, alignment: .trailing)
            // P&L € + %
            if let pnl = trade.pnl {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%+.2f€", pnl)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(pnl >= 0 ? .koboldEmerald : .red)
                    if let pct = pnlPct {
                        Text(String(format: "%+.1f%%", pct)).font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(pct >= 0 ? .koboldEmerald : .red)
                    }
                }.frame(width: 70, alignment: .trailing)
            } else {
                Text("offen").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 70, alignment: .trailing)
            }
            // Haltezeit
            Text(trade.holdingTime ?? "—").font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
            HStack(spacing: 3) {
                if isAgentTrade {
                    Image(systemName: "brain.fill").font(.system(size: 9)).foregroundColor(.purple)
                }
                Text(displayStrategy).font(.system(size: 10)).foregroundColor(isAgentTrade ? .purple : .secondary)
                    .lineLimit(1)
            }.frame(width: 70, alignment: .leading)
            // Bemerkung
            Text(trade.notes ?? "—")
                .font(.system(size: 9)).foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(trade.notes ?? "")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isAgentTrade ? Color.purple.opacity(0.05) : Color.koboldSurface.opacity(0.15)).cornerRadius(4)
    }

    private func strategyCard(_ name: String, description: String, key: String, icon: String) -> some View {
        let isEnabled = UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.bool(forKey: key) : true
        return HStack {
            Image(systemName: icon).font(.title3).foregroundColor(isEnabled ? .koboldEmerald : .secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.bool(forKey: key) : true },
                set: { UserDefaults.standard.set($0, forKey: key) }
            )).toggleStyle(.switch)
        }
        .padding(12).background(Color.koboldSurface.opacity(0.3)).cornerRadius(8)
    }

    // MARK: - Activity Log Panel

    private var activityLogPanel: some View {
        VStack(spacing: 0) {
            GlassDivider()
            // Toggle header
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showLog ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                    Text("Trading-Log").font(.system(size: 12, weight: .semibold))
                    if !tradingLog.isEmpty {
                        Text("(\(tradingLog.count))")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if showLog {
                        Button("Clear") {
                            tradingLog.removeAll()
                        }
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.koboldSurface.opacity(0.5))
            }
            .buttonStyle(.plain)

            if showLog {
                // Log entries — Agent-Nachrichten expandierbar
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(tradingLog) { entry in
                                logEntryView(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 180)
                    .background(Color.black.opacity(0.2))
                    .onChange(of: tradingLog.count) { _ in
                        if let last = tradingLog.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // Chat input
                HStack(spacing: 8) {
                    TextField("Frage zum Trading...", text: $logInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { sendLogMessage() }
                    Button(action: sendLogMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent).tint(.koboldEmerald)
                    .disabled(logInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.koboldSurface.opacity(0.3))
            }
        }
    }

    private func sendLogMessage() {
        let text = logInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        addLog("Du: \(text)", type: .info)
        logInput = ""

        // Enriched context for trading-aware agent response
        let context = buildTradingContext()
        Task {
            await viewModel.sendMessage(
                text,
                targetSessionId: tradingSessionId,
                agentText: context,
                source: "trading"
            )
            // Show agent response in log
            if let lastMsg = viewModel.messages.last,
               case .assistant(let text) = lastMsg.kind {
                addLog("Agent: \(text.prefix(300))", type: .agent)
            }
        }
    }

    private func buildTradingContext() -> String {
        var ctx = "Trading-Kontext:\n"
        ctx += "Portfolio: \(String(format: "%.2f€", livePortfolioValue))\n"
        ctx += "Regime: \(displayRegime)\n"
        ctx += "24h P&L: \(String(format: "%+.2f€ (%+.1f%%)", computePortfolioPnL24h(), computePortfolioPnLPct24h()))\n"
        ctx += "Holdings: "
        for h in liveHoldings where h.currency != "EUR" && h.nativeValue > 0.01 {
            let ch = priceChanges24h[h.currency] ?? 0
            ctx += "\(h.currency): \(String(format: "%.2f€", h.nativeValue)) (\(String(format: "%+.1f%%", ch))) | "
        }
        ctx += "\nEngine: \(status.running ? "Läuft" : "Aus")"
        if status.running {
            ctx += " | Strategien: \(status.activeStrategies.joined(separator: ", "))"
        }
        return ctx
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true

        // 1. Fetch holdings + valid products from Coinbase
        async let holdingsTask = TradeExecutor.shared.getAccountBalances()
        async let statusTask = TradingEngine.shared.getStatus()
        async let analyticsTask = TradingEngine.shared.getAnalytics(period: "all")

        // Load valid products once
        if validProducts.isEmpty {
            await TradeExecutor.shared.loadValidProducts()
            let products = await TradeExecutor.shared.getAllProducts()
            validProducts = Set(products.filter { $0.status == "online" && $0.quoteCurrency == "EUR" }.map { $0.id })
        }

        liveHoldings = await holdingsTask
        livePortfolioValue = liveHoldings.reduce(0) { $0 + $1.nativeValue }
        status = await statusTask
        analytics = await analyticsTask
        openPositions = (try? await TradingDatabase.shared.getOpenTrades()) ?? []
        tradeHistory = (try? await TradingDatabase.shared.getTradeHistory(limit: 50)) ?? []

        // 2. Fetch spot prices for live ticker (configured pairs + holdings)
        var allPairs = Set(status.activePairs)
        for h in liveHoldings where h.currency != "EUR" && h.currency != "EURC" && h.balance > 0.000001 {
            allPairs.insert("\(h.currency)-EUR")
        }

        previousPrices = spotPrices

        await withTaskGroup(of: (String, Double?).self) { group in
            for pair in allPairs {
                group.addTask {
                    let price = await TradeExecutor.shared.getSpotPrice(pair: pair)
                    return (pair, price)
                }
            }
            for await (pair, price) in group {
                if let p = price { spotPrices[pair] = p }
            }
        }

        // Compute price directions for flash animation
        for (pair, newPrice) in spotPrices {
            if let oldPrice = previousPrices[pair] {
                if newPrice > oldPrice * 1.0001 { priceDirections[pair] = .up }
                else if newPrice < oldPrice * 0.9999 { priceDirections[pair] = .down }
                else { priceDirections[pair] = .unchanged }
            } else {
                priceDirections[pair] = .unchanged
            }
        }

        // Clear flash after 1.5s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for key in priceDirections.keys { priceDirections[key] = .unchanged }
        }

        // === Schwere Daten nur alle 6 Zyklen (= ~60s) laden ===
        let fullRefresh = refreshCycle % 6 == 0
        refreshCycle += 1

        if fullRefresh {
            // 3. Regime eigenständig erkennen (auch ohne Engine)
            if !status.running || status.regime == "UNKNOWN" {
                let mainPair = status.activePairs.first ?? "BTC-EUR"
                let candles = await TradeExecutor.shared.getCandles(pair: mainPair, granularity: "ONE_HOUR", limit: 100)
                if candles.count >= 50, let indicators = TechnicalAnalysis.computeSnapshot(candles: candles) {
                    let detector = MarketRegimeDetector()
                    detectedRegime = detector.detect(candles: candles, indicators: indicators).rawValue
                }
            }

            // 4. 24h-Preisänderung für jede Holding berechnen
            await withTaskGroup(of: (String, Double).self) { group in
                for h in liveHoldings where h.currency != "EUR" && h.currency != "EURC" && h.balance > 0.000001 {
                    let pair = "\(h.currency)-EUR"
                    group.addTask {
                        let candles = await TradeExecutor.shared.getCandles(pair: pair, granularity: "ONE_DAY", limit: 2)
                        if candles.count >= 2 {
                            let open24h = candles[candles.count - 2].close
                            let current = candles.last!.close
                            let change = (current - open24h) / open24h * 100
                            return (h.currency, change)
                        }
                        return (h.currency, 0)
                    }
                }
                for await (currency, change) in group {
                    priceChanges24h[currency] = change
                }
            }

            // 5. Load custom strategies
            await loadCustomStrategies()

            // 6. Load forecasts — Top-16 Coins immer, auch wenn Engine nicht läuft
            let top16 = ["BTC-EUR","ETH-EUR","SOL-EUR","XRP-EUR","ADA-EUR","DOGE-EUR",
                          "AVAX-EUR","DOT-EUR","LINK-EUR","MATIC-EUR","SHIB-EUR","UNI-EUR",
                          "LTC-EUR","NEAR-EUR","ATOM-EUR","FIL-EUR"]
            let forecastPairs = Array(Set(top16 + status.activePairs))
            await withTaskGroup(of: (String, [ForecastResult]).self) { group in
                for pair in forecastPairs {
                    group.addTask {
                        let f = await TradingEngine.shared.forecastOnDemand(pair: pair)
                        return (pair, f)
                    }
                }
                for await (pair, f) in group {
                    if !f.isEmpty { forecasts[pair] = f }
                }
            }

            // 7. Load strategy performance + auto-backtest results for Learning tab
            strategyPerfs = await TradingRiskManager.shared.getStrategyPerformance()
            autoBacktestResults = await TradingEngine.shared.getLatestBacktests()
            learningNotes = await TradingEngine.shared.getLearningNotes()

            // 7c. Load cost basis for real P&L
            await withTaskGroup(of: (String, (Double, Double)?).self) { group in
                for h in liveHoldings where h.currency != "EUR" && h.currency != "EURC" && h.nativeValue > 0.50 {
                    group.addTask {
                        let cb = await TradeExecutor.shared.getCostBasis(currency: h.currency)
                        return (h.currency, cb)
                    }
                }
                for await (currency, cb) in group {
                    if let cb = cb { costBasis[currency] = cb }
                }
            }
        }

        // 7b. Engine monitoring info (jeder Zyklus — leicht)
        holdingMonitorInfo = await TradingEngine.shared.getHoldingMonitorInfo()

        // 8. Load engine activity log + merge with local log
        let engineEntries = await TradingActivityLog.shared.getRecent(limit: 100)
        for entry in engineEntries {
            let logType: TradingLogEntry.LogType
            switch entry.type {
            case .analysis: logType = .info
            case .signal: logType = .signal
            case .trade: logType = .trade
            case .risk: logType = .risk
            case .regime: logType = .regime
            case .info: logType = .info
            case .error: logType = .risk
            case .agent: logType = .agent
            }
            // Avoid duplicate entries (check by timestamp + message)
            if !tradingLog.contains(where: { $0.message == entry.message && abs($0.timestamp.timeIntervalSince(entry.timestamp)) < 1 }) {
                tradingLog.append(TradingLogEntry(timestamp: entry.timestamp, message: entry.message, type: logType))
            }
        }
        // Cap log size
        if tradingLog.count > 200 { tradingLog = Array(tradingLog.suffix(200)) }

        isLoading = false
    }

    private func loadCustomStrategies() async {
        let cs = await StrategyEngine.shared.getCustomStrategies()
        customStrategies = cs.map { s in
            CustomStrategyInfo(name: s.name, rules: "\(s.rules.count) Regeln",
                               regimeFilter: s.regimeFilter.joined(separator: ", "),
                               enabled: true, version: s.version, ruleDetails: s.rules)
        }
    }

    private func addLog(_ message: String, type: TradingLogEntry.LogType) {
        let entry = TradingLogEntry(timestamp: Date(), message: message, type: type)
        if tradingLog.count > 100 { tradingLog.removeFirst() }
        tradingLog.append(entry)
    }

    private func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { await loadAll() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func runBacktest() {
        btRunning = true
        btResult = nil
        Task {
            btResult = await TradingEngine.shared.runBacktest(
                strategyName: btStrategy, pair: btPair, days: btDays
            )
            btRunning = false
        }
    }

    private func exportCSV() {
        var csv = "Timestamp,Pair,Side,Price,Size,Fee,PnL,Strategy,Regime,Confidence,Status\n"
        for t in tradeHistory {
            csv += "\(t.timestamp),\(t.pair),\(t.side),\(t.price),\(t.size),\(t.fee),\(t.pnl ?? 0),\(t.strategy),\(t.regime),\(t.confidence),\(t.status)\n"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "trades_export.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private func computeDrawdownFromEquity(_ equity: [Double]) -> [Double] {
        guard !equity.isEmpty else { return [] }
        var peak = equity[0]
        return equity.map { val in
            if val > peak { peak = val }
            return peak > 0 ? (peak - val) / peak * 100 : 0
        }
    }

    private func formatPrice(_ price: Double) -> String {
        if price >= 1000 { return String(format: "%.2f€", price) }
        else if price >= 1 { return String(format: "%.4f€", price) }
        else { return String(format: "%.6f€", price) }
    }

    private func formatCryptoAmount(_ amount: Double, currency: String) -> String {
        if currency == "EUR" || currency == "USD" || currency == "GBP" { return String(format: "%.2f", amount) }
        else if amount >= 1 { return String(format: "%.6f", amount) }
        else { return String(format: "%.8f", amount) }
    }

    private func barColorForCurrency(_ currency: String) -> Color {
        switch currency {
        case "BTC": return .orange
        case "ETH": return .blue
        case "SOL": return .purple
        case "EUR", "USD": return .koboldGold
        default: return .koboldEmerald
        }
    }

    private var hasCoinbaseKeys: Bool {
        let k = UserDefaults.standard.string(forKey: "kobold.coinbase.keyName") ?? ""
        let s = UserDefaults.standard.string(forKey: "kobold.coinbase.keySecret") ?? ""
        return !k.isEmpty && !s.isEmpty
    }

    /// 24h Gesamt-PnL in EUR (gewichtet nach Portfolio-Anteil)
    private func computePortfolioPnL24h() -> Double {
        var totalChange = 0.0
        for h in liveHoldings where h.currency != "EUR" && h.currency != "EURC" && h.nativeValue > 0.01 {
            let changePct = priceChanges24h[h.currency] ?? 0
            totalChange += h.nativeValue * (changePct / 100.0)
        }
        return totalChange
    }

    /// 24h Gesamt-PnL in % (gewichtet)
    private func computePortfolioPnLPct24h() -> Double {
        let cryptoValue = liveHoldings.filter { $0.currency != "EUR" && $0.currency != "EURC" }.reduce(0.0) { $0 + $1.nativeValue }
        guard cryptoValue > 0 else { return 0 }
        let pnl = computePortfolioPnL24h()
        return (pnl / (cryptoValue - pnl)) * 100 // Bezogen auf den Wert vor 24h
    }

    private var displayRegime: String {
        if status.running && status.regime != "UNKNOWN" { return status.regime }
        return detectedRegime
    }

    private var regimeColor: Color {
        switch displayRegime {
        case "BULL": return .koboldEmerald
        case "BEAR": return .red
        case "CRASH": return .purple
        case "SIDEWAYS": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Supporting Types

struct TradingLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let type: LogType

    enum LogType { case info, trade, risk, regime, agent, price, signal }

    var icon: String {
        switch type {
        case .info: return "info.circle"
        case .trade: return "arrow.left.arrow.right"
        case .signal: return "bolt.fill"
        case .risk: return "exclamationmark.triangle"
        case .regime: return "globe"
        case .agent: return "brain"
        case .price: return "chart.line.uptrend.xyaxis"
        }
    }

    var color: Color {
        switch type {
        case .info: return .secondary
        case .trade: return .blue
        case .signal: return .yellow
        case .risk: return .red
        case .regime: return .orange
        case .agent: return .purple
        case .price: return .koboldEmerald
        }
    }
}

struct CustomStrategyInfo: Identifiable {
    let id = UUID()
    let name: String
    let rules: String
    let regimeFilter: String
    var enabled: Bool
    var version: Int = 1
    var ruleDetails: [StrategyRule] = []
}
