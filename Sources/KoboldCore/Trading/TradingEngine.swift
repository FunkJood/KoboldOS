#if os(macOS)
import Foundation

// MARK: - Trading Engine Status

public struct TradingStatus: Sendable, Codable {
    public let running: Bool
    public let regime: String
    public let openPositions: Int
    public let totalTrades: Int
    public let dailyPnL: Double
    public let portfolioValue: Double
    public let lastCycleTime: String
    public let activePairs: [String]
    public let activeStrategies: [String]
    public let halted: Bool
    public let haltReason: String
    public let uptime: String

    public init(running: Bool = false, regime: String = "UNKNOWN", openPositions: Int = 0,
                totalTrades: Int = 0, dailyPnL: Double = 0, portfolioValue: Double = 0,
                lastCycleTime: String = "-", activePairs: [String] = [],
                activeStrategies: [String] = [], halted: Bool = false, haltReason: String = "",
                uptime: String = "0m") {
        self.running = running; self.regime = regime; self.openPositions = openPositions
        self.totalTrades = totalTrades; self.dailyPnL = dailyPnL; self.portfolioValue = portfolioValue
        self.lastCycleTime = lastCycleTime; self.activePairs = activePairs
        self.activeStrategies = activeStrategies; self.halted = halted; self.haltReason = haltReason
        self.uptime = uptime
    }
}

// MARK: - Trading Engine (Haupt-Actor)

public actor TradingEngine {
    public static let shared = TradingEngine()

    // State
    private var isRunning = false
    private var engineTask: Task<Void, Never>?
    private var selfImprovementTask: Task<Void, Never>?
    private var dailyReportTask: Task<Void, Never>?
    private var autoBacktestTask: Task<Void, Never>?
    private var startTime: Date?

    // Market State (per pair)
    private var currentRegimes: [String: MarketRegime] = [:]
    private var latestForecasts: [String: [ForecastResult]] = [:]
    private var latestIndicators: [String: IndicatorSnapshot] = [:]
    private var portfolioValue: Double = 0

    // DCA-Nachkauf-Counter (verhindert unbegrenztes Nachkaufen)
    private var dcaBuyCount: [String: Int] = [:]  // currency → Anzahl DCA-Käufe

    // Daily Trade Limits + Pair Cooldown
    private var dailyTradeCount: Int = 0
    private var dailyTradeDate: String = ""
    private var pairLastTraded: [String: Date] = [:]
    private var pairLastRejected: [String: Date] = [:]
    private var lastSignalPerPair: [String: (action: String, strategy: String, confidence: Double)] = [:]
    private var cachedFeeRate: Double = 0  // Wird pro Zyklus aus Coinbase aktualisiert (0 = Coinbase One default)
    private var lastLoggedForecast: [String: (String, Double)] = [:]  // "pair-horizon" → (direction, confidence)
    private var forecastValidationTask: Task<Void, Never>?

    // Components
    private let detector = MarketRegimeDetector()
    private let forecaster = ForecastingEngine()
    private let analyzer = TradeAnalyzer()
    private let backtester = Backtester()

    private let hwmFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trading_hwm.json")
    }()

    private init() {}

    // MARK: - HWM Persistence

    private func loadHWM() {
        guard let data = try? Data(contentsOf: hwmFile),
              let combined = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return }
        holdingHighWatermarks = combined["holdings"] ?? [:]
        engineTradeHighWatermarks = combined["trades"] ?? [:]
    }

    private func persistHWM() {
        let combined: [String: [String: Double]] = [
            "holdings": holdingHighWatermarks,
            "trades": engineTradeHighWatermarks
        ]
        if let data = try? JSONEncoder().encode(combined) {
            try? data.write(to: hwmFile, options: .atomic)
        }
    }

    // MARK: - Lifecycle

    /// Startet die Trading Engine als Background Task
    public func start() {
        guard !isRunning else {
            print("[TradingEngine] Already running")
            return
        }

        // Sync settings
        Task { await TradingRiskManager.shared.syncFromDefaults() }
        Task { await StrategyEngine.shared.syncFromDefaults() }
        loadHWM()

        isRunning = true
        startTime = Date()
        print("[TradingEngine] Starting...")

        // Main trading loop
        engineTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runMainLoop()
        }

        // Self-improvement + auto-backtest loop
        selfImprovementTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runSelfImprovementLoop()
        }

        // Auto-Backtest loop (alle 6h)
        autoBacktestTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runAutoBacktestLoop()
        }

        // Daily report loop
        dailyReportTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runDailyReportLoop()
        }

        // Forecast validation loop (alle 30 Min)
        forecastValidationTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runForecastValidationLoop()
        }

        Task { await TradingReporter.shared.sendEngineStatus(status: "Trading Engine gestartet") }
    }

    /// Stoppt die Trading Engine
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engineTask?.cancel()
        selfImprovementTask?.cancel()
        dailyReportTask?.cancel()
        autoBacktestTask?.cancel()
        forecastValidationTask?.cancel()
        engineTask = nil
        selfImprovementTask = nil
        dailyReportTask = nil
        autoBacktestTask = nil
        forecastValidationTask = nil
        print("[TradingEngine] Stopped")
        Task { await TradingReporter.shared.sendEngineStatus(status: "Trading Engine gestoppt") }
    }

    /// Emergency Stop — Schließt alle Positionen und haltet Trading
    public func emergencyStop() async {
        await TradingRiskManager.shared.emergencyStop(reason: "Manueller Emergency Stop")

        // Alle offenen Positionen schließen
        if let openTrades = try? await TradingDatabase.shared.getOpenTrades() {
            for trade in openTrades {
                if let price = await TradeExecutor.shared.getSpotPrice(pair: trade.pair) {
                    await TradeExecutor.shared.closePosition(trade, currentPrice: price)
                }
            }
        }

        await TradingReporter.shared.sendRiskAlert(reason: "Emergency Stop ausgelöst — Alle Positionen geschlossen")
        stop()
    }

    // MARK: - Agent Helpers

    private var lastPortfolioString = ""
    private var liveHoldings: [TradeExecutor.AccountBalance] = []

    private func buildPortfolioString() async -> String {
        let holdings = await TradeExecutor.shared.getAccountBalances()
        let parts = holdings.filter { $0.nativeValue > 0.50 }.map { "\($0.currency): \(String(format: "%.6f", $0.balance)) (\(String(format: "%.2f€", $0.nativeValue)))" }
        let result = parts.joined(separator: ", ")
        lastPortfolioString = result
        return result
    }

    private var agentEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kobold.trading.agentEnabled")
    }

    /// Prüft ob der Agent den Trade abgelehnt hat (anhand der Antwort)
    private func agentRejected(_ response: String) -> Bool {
        let lower = response.lowercased()
        let rejectKeywords = ["abgelehnt", "nicht ausgeführt", "nicht handeln", "kein kauf",
                              "nicht genug", "insufficient", "rejected", "verworfen", "queue"]
        return rejectKeywords.contains(where: { lower.contains($0) })
    }

    // MARK: - Main Trading Loop

    private func runMainLoop() async {
        var cycleCount = 0
        let log = TradingActivityLog.shared

        while isRunning && !Task.isCancelled {
            let cycleStart = Date()
            cycleCount += 1

            // 0. Settings synchronisieren (Threshold, TP/SL etc. live übernehmen)
            await StrategyEngine.shared.syncFromDefaults()
            await TradingRiskManager.shared.syncFromDefaults()

            // 0a. Observed Fee-Rate aus echten Coinbase-Fills (1x pro Zyklus)
            let observedFeeRate = await TradeExecutor.shared.getObservedFeeRate()
            cachedFeeRate = observedFeeRate

            // 0b. Get configured pairs + Holdings-Pairs (alle Coinbase-Positionen)
            let pairsStr = UserDefaults.standard.string(forKey: "kobold.trading.pairs") ?? "BTC-EUR,ETH-EUR"
            var pairs = pairsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            // Alle Coinbase-Holdings als Paare hinzufügen (Engine überwacht ALLES)
            if cycleCount % 10 == 1 || portfolioValue == 0 {
                liveHoldings = await TradeExecutor.shared.getAccountBalances()
                let holdings = liveHoldings
                portfolioValue = holdings.reduce(0) { $0 + $1.nativeValue }
                for h in holdings where h.currency != "EUR" && h.currency != "EURC" && h.nativeValue > 0.50 {
                    let holdingPair = "\(h.currency)-EUR"
                    if !pairs.contains(holdingPair) {
                        pairs.append(holdingPair)
                    }
                }
                if portfolioValue > 0 {
                    await log.add("Portfolio: \(String(format: "%.2f€", portfolioValue)) (\(holdings.filter { $0.nativeValue > 0.50 }.count) Assets)", type: .info)
                }
            }

            var cycleSignals = 0
            var cycleTrades = 0

            // 2. Process each pair
            for pair in pairs {
                guard isRunning else { break }

                // Fetch candles
                let candles = await TradeExecutor.shared.getCandles(pair: pair, granularity: "ONE_HOUR", limit: 300)
                guard candles.count >= 50 else {
                    if cycleCount <= 2 {
                        await log.add("[\(pair)] Nur \(candles.count) Candles — übersprungen", type: .analysis)
                    }
                    continue
                }

                // Compute indicators
                guard let indicators = TechnicalAnalysis.computeSnapshot(candles: candles) else {
                    continue
                }
                latestIndicators[pair] = indicators

                // Detect regime
                let newRegime = detector.detect(candles: candles, indicators: indicators)
                let oldRegime = currentRegimes[pair] ?? .unknown
                if newRegime != oldRegime && oldRegime != .unknown {
                    await TradingReporter.shared.sendRegimeChange(from: oldRegime, to: newRegime, pair: pair)
                    await log.add("[\(pair)] Regime: \(oldRegime.rawValue) → \(newRegime.rawValue)", type: .regime)
                }
                currentRegimes[pair] = newRegime

                // RiskManager über aktuelles Regime informieren (für regime-aware Limits)
                await TradingRiskManager.shared.updateRegime(newRegime)

                let price = candles.last!.close

                // Circuit Breaker: Preis-Drop Check
                let cbResult = await TradingRiskManager.shared.recordPrice(pair: pair, price: price)
                if cbResult.tripped {
                    await log.add("CIRCUIT BREAKER: \(cbResult.reason)", type: .risk)
                    continue
                }

                // Circuit Breaker: Volatilitäts-Check (ATR)
                if indicators.atr > 0 {
                    // Berechne durchschnittlichen ATR der letzten 24h
                    let avgATR = computeAvgATR(candles: candles, period: 24)
                    let volCB = await TradingRiskManager.shared.checkVolatilityBreaker(
                        currentATR: indicators.atr, avgATR: avgATR, pair: pair
                    )
                    if volCB.tripped {
                        await log.add("CIRCUIT BREAKER: \(volCB.reason)", type: .risk)
                    }
                }

                await log.add("[\(pair)] \(newRegime.rawValue) | RSI \(String(format: "%.1f", indicators.rsi)) | MACD \(String(format: "%.2f", indicators.macdHistogram)) | ATR \(String(format: "%.2f", indicators.atr)) | \(String(format: "%.2f€", price))", type: .analysis)

                // Multi-Timeframe: 4h-Trend für Signal-Bestätigung
                let candles4h = await TradeExecutor.shared.getCandles(pair: pair, granularity: "SIX_HOUR", limit: 50)
                let higherTFBias: TradeAction
                if let snap4h = TechnicalAnalysis.computeSnapshot(candles: candles4h) {
                    if snap4h.emaSlope50 > 0.1 && snap4h.ema9 > snap4h.ema21 {
                        higherTFBias = .buy
                    } else if snap4h.emaSlope50 < -0.1 && snap4h.ema9 < snap4h.ema21 {
                        higherTFBias = .sell
                    } else {
                        higherTFBias = .hold  // Kein klarer 4h-Trend
                    }
                } else {
                    higherTFBias = .hold  // Keine 4h-Daten → neutral
                }

                // Generate forecasts
                let forecasts = forecaster.forecast(pair: pair, candles: candles, indicators: indicators, regime: newRegime)
                latestForecasts[pair] = forecasts

                // Forecast-Accuracy-Tracking: nur 1h-Forecast loggen (haeufigste Validierung)
                if let f1h = forecasts.first(where: { $0.horizon == "1h" }) {
                    let lastKey = "\(pair)-1h"
                    let changed = lastLoggedForecast[lastKey] == nil
                        || lastLoggedForecast[lastKey]!.0 != f1h.direction
                        || abs(lastLoggedForecast[lastKey]!.1 - f1h.confidence) > 0.05
                    if changed {
                        let fid = UUID().uuidString
                        // Alle FactorScores als JSON speichern (für per-Faktor-Accuracy)
                        var factorsStr = f1h.factors.prefix(3).joined(separator: "; ")
                        if !f1h.factorScores.isEmpty,
                           let jsonData = try? JSONEncoder().encode(f1h.factorScores),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            factorsStr = jsonStr
                        }
                        try? await TradingDatabase.shared.logForecast(
                            id: fid, pair: pair, horizon: "1h", direction: f1h.direction,
                            confidence: f1h.confidence, currentPrice: f1h.currentPrice,
                            targetPrice: f1h.targetPrice, regime: newRegime.rawValue,
                            factors: factorsStr
                        )
                        lastLoggedForecast[lastKey] = (f1h.direction, f1h.confidence)
                    }
                }

                // Skip trading in CRASH regime
                if newRegime == .crash {
                    await log.add("[\(pair)] CRASH-Regime — kein Kauf", type: .risk)
                    continue
                }

                // Check if halted
                let haltState = await TradingRiskManager.shared.getIsHalted()
                if haltState.halted {
                    await log.add("[\(pair)] Gehaltet: \(haltState.reason)", type: .risk)
                    continue
                }

                // Evaluate strategies
                let signals = await StrategyEngine.shared.evaluateAll(
                    pair: pair, candles: candles, indicators: indicators, regime: newRegime,
                    feeRate: observedFeeRate
                )

                if !signals.isEmpty {
                    cycleSignals += signals.count
                }

                // Execute best signal (HODL-Coin-Schutz + Position-Check + Strategie-Kompatibilität)
                if let bestSignal = signals.first {
                    let currentPrice = candles.last!.close
                    let hodlCoin = UserDefaults.standard.string(forKey: "kobold.trading.hodlCoin")?.uppercased() ?? ""
                    let pairBase = pair.split(separator: "-").first.map(String.init) ?? ""
                    let existingHolding = liveHoldings.first(where: { $0.currency.uppercased() == pairBase.uppercased() && $0.nativeValue > 1.0 })
                    let hasPosition = existingHolding != nil

                    // Position-Size Pre-Filter: Übergewichtete Positionen NICHT nachkaufen
                    // Spart Agent-Calls und verhindert Rejection-Cooldown-Loops
                    // HODL-Coin ist ausgenommen — darf unbegrenzt akkumuliert werden
                    let isHodlCoin = !hodlCoin.isEmpty && pairBase.uppercased() == hodlCoin
                    if bestSignal.action == .buy, let holding = existingHolding, !isHodlCoin {
                        let portfolioValue = liveHoldings.reduce(0.0) { $0 + $1.nativeValue }
                        let maxPosPct = UserDefaults.standard.double(forKey: "kobold.trading.maxPositionPct")
                        let effectiveMaxPos = maxPosPct > 0 ? maxPosPct : 5.0  // Default 5%
                        let currentPct = portfolioValue > 0 ? (holding.nativeValue / portfolioValue) * 100 : 0
                        if currentPct > effectiveMaxPos {
                            await log.add("[\(pair)] BUY-Signal ignoriert — Position bereits \(String(format: "%.1f%%", currentPct)) des Portfolios (Max: \(String(format: "%.0f%%", effectiveMaxPos)))", type: .risk)
                            continue
                        }

                        // DCA-Schutz: Kein Nachkauf am selben Tag wenn Preis nicht deutlich gefallen
                        if let lastTrade = pairLastTraded[pair],
                           Calendar.current.isDateInToday(lastTrade) {
                            let cb = holdingCostBasis[pairBase] ?? currentPrice
                            let priceDrop = ((currentPrice - cb) / cb) * 100
                            if priceDrop > -5.0 {  // Mindestens 5% unter Cost Basis für DCA
                                await log.add("[\(pair)] BUY-Signal ignoriert — heute bereits gekauft, Preis nur \(String(format: "%+.1f%%", priceDrop)) vs. Cost Basis (min -5% für DCA)", type: .risk)
                                continue
                            }
                        }
                    }

                    // Daily Trade Limit + Pair Cooldown (nur für BUY — Sells sind immer erlaubt)
                    if bestSignal.action == .buy {
                        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
                        if String(today) != dailyTradeDate { dailyTradeCount = 0; dailyTradeDate = String(today) }

                        let maxDaily = UserDefaults.standard.integer(forKey: "kobold.trading.maxDailyTrades")
                        let effectiveMaxDaily = maxDaily > 0 ? maxDaily : 6
                        if dailyTradeCount >= effectiveMaxDaily {
                            await log.add("[\(pair)] Daily Trade Limit erreicht (\(dailyTradeCount)/\(effectiveMaxDaily))", type: .risk)
                            continue
                        }

                        let cooldownMin = UserDefaults.standard.double(forKey: "kobold.trading.pairCooldownMinutes")
                        let effectiveCooldown = cooldownMin > 0 ? cooldownMin : 120.0
                        if let lastTrade = pairLastTraded[pair],
                           Date().timeIntervalSince(lastTrade) < effectiveCooldown * 60 {
                            let remaining = Int((effectiveCooldown * 60 - Date().timeIntervalSince(lastTrade)) / 60)
                            await log.add("[\(pair)] Pair-Cooldown aktiv (noch \(remaining) Min.)", type: .risk)
                            continue
                        }

                        // Rejection-Cooldown: 15 Min nach Agent-Ablehnung (reduziert von 30 Min)
                        if let lastReject = pairLastRejected[pair],
                           Date().timeIntervalSince(lastReject) < 900 {
                            let remaining = Int((900 - Date().timeIntervalSince(lastReject)) / 60)
                            await log.add("[\(pair)] Rejection-Cooldown aktiv (noch \(remaining) Min.)", type: .risk)
                            continue
                        }
                    }

                    // Separate Buy/Sell-Signal-Toggles (TP/SL bleibt immer aktiv!)
                    let buySignalsOn = UserDefaults.standard.object(forKey: "kobold.trading.buySignalsEnabled") == nil
                        || UserDefaults.standard.bool(forKey: "kobold.trading.buySignalsEnabled")
                    let sellSignalsOn = UserDefaults.standard.object(forKey: "kobold.trading.sellSignalsEnabled") == nil
                        || UserDefaults.standard.bool(forKey: "kobold.trading.sellSignalsEnabled")

                    if bestSignal.action == .buy && !buySignalsOn {
                        await log.add("[\(pair)] BUY-Signal ignoriert — Buy-Signale deaktiviert", type: .signal)
                        continue
                    }
                    if bestSignal.action == .sell && !sellSignalsOn {
                        await log.add("[\(pair)] SELL-Signal ignoriert — Sell-Signale deaktiviert (TP/SL bleibt aktiv)", type: .signal)
                        continue
                    }

                    // Multi-Timeframe-Bestätigung: BUY nur wenn 4h-Trend nicht dagegen spricht
                    if bestSignal.action == .buy && higherTFBias == .sell {
                        await log.add("[\(pair)] BUY-Signal blockiert — 4h-Trend ist bearish (Multi-TF-Filter)", type: .signal)
                        continue
                    }
                    if bestSignal.action == .sell && higherTFBias == .buy && bestSignal.confidence < 0.8 {
                        await log.add("[\(pair)] SELL-Signal abgeschwächt — 4h-Trend ist bullish (nur starke Sells erlaubt)", type: .signal)
                        continue
                    }

                    // EV-Gate: Nur Trades mit positivem Expected Value ausführen
                    if bestSignal.action == .buy {
                        let tpVal = UserDefaults.standard.double(forKey: "kobold.trading.takeProfit")
                        let slVal = UserDefaults.standard.double(forKey: "kobold.trading.fixedStopLoss")
                        let effTP = (tpVal > 0 ? tpVal : 8.0) / 100.0
                        let effSL = (slVal > 0 ? slVal : 3.0) / 100.0
                        let effFee = observedFeeRate * 2  // Round-trip (0 bei Coinbase One)
                        let netReward = effTP - effFee
                        let netRisk = effSL + effFee
                        let ev = (bestSignal.confidence * netReward) - ((1.0 - bestSignal.confidence) * netRisk)
                        if ev <= 0 {
                            await log.add("[\(pair)] SKIP: Negativer EV (\(String(format: "%.4f", ev))) — Confidence \(String(format: "%.0f%%", bestSignal.confidence * 100)) zu niedrig für TP/SL/Fee-Verhältnis", type: .risk)
                            continue
                        }
                    }

                    // SELL nur wenn Position vorhanden
                    if bestSignal.action == .sell && !hasPosition {
                        await log.add("[\(pair)] SELL-Signal ignoriert — keine Position vorhanden", type: .signal)
                        continue
                    }

                    // EUR-Rücklage-Check vor Sell-Signalen
                    // Wenn EUR-Balance gesund (>120% der Reserve): schwache Sells ignorieren (Positionen halten)
                    // Wenn EUR unter Reserve: Sells priorisieren (Cash-Aufbau)
                    if bestSignal.action == .sell {
                        let eurReserve = UserDefaults.standard.double(forKey: "kobold.trading.eurReserve")
                        if eurReserve > 0 {
                            let eurBalance = liveHoldings
                                .first(where: { $0.currency.uppercased() == "EUR" })?.balance ?? 0
                            if eurBalance > eurReserve * 1.2 && bestSignal.confidence < 0.70 {
                                // Reserve gesund → nur sehr schwache Sells ignorieren
                                await log.add("[\(pair)] SELL-Signal (\(String(format: "%.0f%%", bestSignal.confidence * 100))) ignoriert — EUR-Reserve gesund (\(String(format: "%.0f€", eurBalance))/\(String(format: "%.0f€", eurReserve))). Nur Sells >70% erlaubt.", type: .risk)
                                continue
                            }
                            if eurBalance < eurReserve * 0.8 {
                                // Reserve kritisch niedrig → Sell priorisieren
                                await log.add("[\(pair)] EUR-Reserve niedrig (\(String(format: "%.0f€", eurBalance))/\(String(format: "%.0f€", eurReserve))) — Sell priorisiert", type: .risk)
                            }
                        }
                    }

                    if bestSignal.action == .sell && !hodlCoin.isEmpty && pairBase == hodlCoin {
                        await log.add("[\(pair)] HODL-Schutz: SELL-Signal ignoriert (\(hodlCoin) ist HODL-Coin)", type: .risk)
                    } else if bestSignal.action == .sell && !strategyCompatible(sellStrategy: bestSignal.strategy, holdingStrategy: holdingStrategies[pairBase]) {
                        let owner = holdingStrategies[pairBase] ?? "?"
                        await log.add("[\(pair)] SELL-Signal (\(bestSignal.strategy)) ignoriert — Position gehört \(owner)", type: .signal)
                    } else {
                        // Bestehende Position-Info für Agent-Kontext aufbauen
                        let positionContext: String?
                        if let holding = existingHolding, bestSignal.action == .buy {
                            let cb = holdingCostBasis[pairBase]
                            let pnlStr = cb.map { String(format: "%+.1f%%", ((currentPrice - $0) / $0) * 100) } ?? "?"
                            positionContext = "ACHTUNG NACHKAUF: Du hältst bereits \(String(format: "%.6f", holding.balance)) \(pairBase) (Wert: \(String(format: "%.2f€", holding.nativeValue)), P&L: \(pnlStr), Strategie: \(holdingStrategies[pairBase] ?? "unbekannt")). Prüfe ob ein Nachkauf wirklich sinnvoll ist — berücksichtige max. Positionsgröße, Gesamtrisiko und ob der Preis wirklich attraktiver geworden ist."
                        } else {
                            positionContext = nil
                        }

                        // Signal-Cache: identisches Signal wie letzter Zyklus skippen
                        let sigKey = (action: bestSignal.action.rawValue, strategy: bestSignal.strategy, confidence: (bestSignal.confidence * 10).rounded() / 10)  // 10%-Buckets
                        if let last = lastSignalPerPair[pair],
                           last.action == sigKey.action && last.strategy == sigKey.strategy && last.confidence == sigKey.confidence {
                            await log.add("[\(pair)] Signal-Cache: \(bestSignal.action.rawValue) \(String(format: "%.0f%%", bestSignal.confidence * 100)) [\(bestSignal.strategy)] identisch zum letzten Zyklus — übersprungen", type: .signal)
                            continue
                        }
                        lastSignalPerPair[pair] = sigKey

                        await log.add("[\(pair)] SIGNAL: \(bestSignal.action.rawValue) \(String(format: "%.0f%%", bestSignal.confidence * 100)) [\(bestSignal.strategy)]\(hasPosition && bestSignal.action == .buy ? " (Nachkauf)" : "") — \(bestSignal.reason)", type: .signal)

                        if agentEnabled {
                            let portfolio = lastPortfolioString.isEmpty ? await buildPortfolioString() : lastPortfolioString
                            let ownerStrategy = holdingStrategies[pairBase]
                            let response = await TradingAgent.shared.evaluate(
                                signal: bestSignal, pair: pair, currentPrice: currentPrice,
                                regime: newRegime.rawValue, costBasis: holdingCostBasis[pairBase],
                                portfolio: portfolio, ownerStrategy: ownerStrategy,
                                positionContext: positionContext
                            )
                            // Strategie NUR setzen wenn Agent den Trade NICHT abgelehnt hat
                            if !agentRejected(response) {
                                if bestSignal.action == .buy {
                                    holdingStrategies[pairBase] = bestSignal.strategy
                                }
                                dailyTradeCount += 1
                                pairLastTraded[pair] = Date()
                                pairLastRejected.removeValue(forKey: pair)
                            } else {
                                // Rejection-Cooldown: 30 Min Pause fuer dieses Pair
                                pairLastRejected[pair] = Date()
                                await log.add("[\(pair)] Agent-Rejection — 30 Min Cooldown", type: .risk)
                            }
                            cycleTrades += 1
                        } else {
                            // Ohne Agent: RiskManager prüft max Single Asset Exposure (30%)
                            let result = await TradeExecutor.shared.execute(
                                signal: bestSignal, currentPrice: currentPrice,
                                portfolioValue: portfolioValue, regime: newRegime
                            )

                            if let trade = result {
                                cycleTrades += 1
                                if bestSignal.action == .buy {
                                    holdingStrategies[pairBase] = bestSignal.strategy
                                }
                                dailyTradeCount += 1
                                pairLastTraded[pair] = Date()
                                pairLastRejected.removeValue(forKey: pair)
                                await log.add("[\(pair)] ORDER \(trade.status): \(trade.side) \(String(format: "%.8f", trade.size)) @ \(String(format: "%.2f€", trade.price))\(trade.orderId.map { " (\($0.prefix(12)))" } ?? "")", type: .trade)
                            } else {
                                // Trade fehlgeschlagen → kurzer Cooldown
                                pairLastRejected[pair] = Date()
                                let autoTrade = UserDefaults.standard.bool(forKey: "kobold.trading.autoTrade")
                                if !autoTrade {
                                    await log.add("[\(pair)] Signal geloggt (Auto-Trade AUS)", type: .signal)
                                }
                            }
                        }
                    }
                }
            }

            // 3. Monitor ALL positions (Engine-Trades + Coinbase-Holdings)
            await monitorOpenPositions()
            await monitorExternalHoldings()

            // 4. Health check (every 5 cycles)
            if cycleCount % 5 == 0 {
                await healthCheck()
            }

            // Cycle summary
            let elapsed = Date().timeIntervalSince(cycleStart)
            if cycleSignals > 0 || cycleTrades > 0 {
                await log.add("Cycle #\(cycleCount): \(pairs.count) Paare, \(cycleSignals) Signale, \(cycleTrades) Trades (\(String(format: "%.1fs", elapsed)))", type: .info)
            }

            // Sleep until next cycle
            let interval = UserDefaults.standard.integer(forKey: "kobold.trading.cycleInterval")
            let sleepSec = interval > 0 ? interval : 60
            let remaining = max(Double(sleepSec) - elapsed, 5)

            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                break
            }
        }

        await log.add("Engine gestoppt", type: .info)
        print("[TradingEngine] Main loop exited")
    }

    // MARK: - Position Monitoring (Engine-Trades)

    private func monitorOpenPositions() async {
        guard let openTrades = try? await TradingDatabase.shared.getOpenTrades() else { return }
        let log = TradingActivityLog.shared

        for trade in openTrades {
            guard let currentPrice = await TradeExecutor.shared.getSpotPrice(pair: trade.pair) else { continue }

            let atr = latestIndicators[trade.pair]?.atr ?? 0
            // Persistent High-Watermark-Tracking (Fix: war vorher max(entry, current))
            let prevHigh = engineTradeHighWatermarks[trade.id] ?? trade.price
            let highWatermark = max(prevHigh, currentPrice)
            if highWatermark != prevHigh {
                engineTradeHighWatermarks[trade.id] = highWatermark
                persistHWM()
            }
            let result = await TradingRiskManager.shared.shouldClosePosition(
                entryPrice: trade.price, currentPrice: currentPrice,
                highWatermark: highWatermark, side: trade.side, atr: atr
            )

            // Zombie-Position-Decay: TP schrittweise senken bei zu langer Haltezeit
            let holdingHours = Date().timeIntervalSince(
                ISO8601DateFormatter().date(from: trade.timestamp) ?? Date()
            ) / 3600
            let zombieCheck = await TradingRiskManager.shared.zombieDecayTP(holdingHours: holdingHours, feeRate: cachedFeeRate)

            var shouldClose = result.close
            var closeReason = result.reason

            // Zombie-Decay: Position bei reduziertem TP schließen
            if !shouldClose && zombieCheck.isZombie && trade.side == "BUY" {
                let changePct = ((currentPrice - trade.price) / trade.price) * 100
                if changePct >= zombieCheck.decayedTP {
                    shouldClose = true
                    closeReason = "Zombie-Decay-Exit: +\(String(format: "%.1f%%", changePct)) >= TP \(String(format: "%.1f%%", zombieCheck.decayedTP)) — \(zombieCheck.message)"
                } else if !zombieCheck.message.isEmpty {
                    await log.add("[\(trade.pair)] \(zombieCheck.message) (aktuell: \(String(format: "%+.1f%%", changePct)))", type: .risk)
                }
            }

            if shouldClose {
                await log.add("[\(trade.pair)] Schließen: \(closeReason)", type: .risk)
                await TradingRiskManager.shared.recordStopTrigger()
                await TradeExecutor.shared.closePosition(trade, currentPrice: currentPrice)
                engineTradeHighWatermarks.removeValue(forKey: trade.id)

                // Performance tracking
                let pnl = trade.side == "BUY"
                    ? (currentPrice - trade.price) * trade.size
                    : (trade.price - currentPrice) * trade.size
                let holdingMinutes = holdingHours * 60
                await TradingRiskManager.shared.recordTradeResult(
                    strategy: trade.strategy, pnl: pnl, holdingMinutes: holdingMinutes
                )

                let priceStr = String(format: "%.2f€", currentPrice)
                let pnlStr = String(format: "%+.2f€", pnl)
                await log.add("[\(trade.pair)] Geschlossen @ \(priceStr) — P&L: \(pnlStr)", type: .trade)
            }
        }
    }

    // MARK: - External Holdings Monitoring (Coinbase-Holdings als offene Positionen behandeln)

    private var lastHoldingsCheck: Date? = nil
    private var holdingHighWatermarks: [String: Double] = [:]  // Currency → höchster Preis (External Holdings)
    private var holdingCostBasis: [String: Double] = [:]       // Currency → Durchschnitts-Kaufpreis
    private var holdingSellCooldown: [String: Date] = [:]      // Currency → letzter Sell-Versuch
    private var holdingStrategies: [String: String] = [:]      // Currency → Strategie die Position eröffnet hat
    private var holdingFirstSeen: [String: Date] = [:]         // Currency → wann die Position erstmals erkannt wurde
    private var engineTradeHighWatermarks: [String: Double] = [:] // TradeID → höchster Preis (Engine-Trades)

    // MARK: - Strategy Compatibility (Zeithorizont-Gruppen)

    /// Prüft ob eine Verkaufs-Strategie kompatibel mit der Kauf-Strategie ist.
    /// Nur kompatible Strategien dürfen eine Position schließen.
    /// TP/SL (Risk Management) übersteuert immer — dieses Check gilt nur für Strategie-Signale.
    private func strategyCompatible(sellStrategy: String, holdingStrategy: String?) -> Bool {
        guard let holdingStrategy else { return true } // Unbekannt → erlauben (Legacy)

        // Gleiche Strategie → immer kompatibel
        if sellStrategy == holdingStrategy { return true }

        // Zeithorizont-Gruppen
        let shortTerm: Set<String> = ["scalping", "ultra_scalp"]
        let mediumTerm: Set<String> = ["momentum", "breakout", "mean_reversion", "divergence", "accumulation", "support_resistance"]
        let longTerm: Set<String> = ["trend_following"]

        // Kompatibel nur innerhalb der gleichen Zeithorizont-Gruppe
        if shortTerm.contains(sellStrategy) && shortTerm.contains(holdingStrategy) { return true }
        if mediumTerm.contains(sellStrategy) && mediumTerm.contains(holdingStrategy) { return true }
        if longTerm.contains(sellStrategy) && longTerm.contains(holdingStrategy) { return true }

        // Verschiedene Gruppen → NICHT kompatibel
        return false
    }

    private func monitorExternalHoldings() async {
        // Alle 2 Minuten prüfen
        if let last = lastHoldingsCheck, Date().timeIntervalSince(last) < 120 { return }
        lastHoldingsCheck = Date()

        let autoTrade = UserDefaults.standard.bool(forKey: "kobold.trading.autoTrade")
        let log = TradingActivityLog.shared
        let holdings = await TradeExecutor.shared.getAccountBalances()
        let hodlCoin = UserDefaults.standard.string(forKey: "kobold.trading.hodlCoin")?.uppercased() ?? ""

        for holding in holdings {
            guard holding.currency != "EUR" && holding.currency != "EURC" else { continue }
            guard holding.nativeValue > 1.0 else { continue }

            // HODL-Coin Schutz
            if !hodlCoin.isEmpty && holding.currency.uppercased() == hodlCoin { continue }

            // Sell-Cooldown (15 Min nach letztem Versuch)
            if let lastSell = holdingSellCooldown[holding.currency],
               Date().timeIntervalSince(lastSell) < 900 { continue }

            let pair = "\(holding.currency)-EUR"

            // Spot-Preis holen
            guard let currentPrice = await TradeExecutor.shared.getSpotPrice(pair: pair) else { continue }

            // High Watermark tracken
            let prevHigh = holdingHighWatermarks[holding.currency] ?? currentPrice
            let highWatermark = max(prevHigh, currentPrice)
            if highWatermark != prevHigh {
                holdingHighWatermarks[holding.currency] = highWatermark
                persistHWM()
            }

            // Cost Basis laden (einmalig pro Coin)
            if holdingCostBasis[holding.currency] == nil {
                if let cb = await TradeExecutor.shared.getCostBasis(currency: holding.currency) {
                    holdingCostBasis[holding.currency] = cb.avgPrice
                }
            }

            guard let entryPrice = holdingCostBasis[holding.currency], entryPrice > 0 else { continue }

            // ATR für volatilitätsbasierte TP/SL
            let atr = latestIndicators[pair]?.atr ?? 0

            // TP/SL Check — gleiche Logik wie Engine-Trades
            let result = await TradingRiskManager.shared.shouldClosePosition(
                entryPrice: entryPrice, currentPrice: currentPrice,
                highWatermark: highWatermark, side: "BUY", atr: atr
            )

            // Zombie-Position-Decay für External Holdings
            if holdingFirstSeen[holding.currency] == nil {
                holdingFirstSeen[holding.currency] = Date()
            }
            let holdingHoursExt = Date().timeIntervalSince(holdingFirstSeen[holding.currency] ?? Date()) / 3600
            let zombieExt = await TradingRiskManager.shared.zombieDecayTP(holdingHours: holdingHoursExt, feeRate: cachedFeeRate)

            var extShouldClose = result.close
            var extCloseReason = result.reason

            if !extShouldClose && zombieExt.isZombie {
                let changePct = ((currentPrice - entryPrice) / entryPrice) * 100
                if changePct >= zombieExt.decayedTP {
                    extShouldClose = true
                    extCloseReason = "Zombie-Decay-Exit: +\(String(format: "%.1f%%", changePct)) >= TP \(String(format: "%.1f%%", zombieExt.decayedTP)) — \(zombieExt.message)"
                } else if !zombieExt.message.isEmpty {
                    await log.add("[\(pair)] \(zombieExt.message) (aktuell: \(String(format: "%+.1f%%", changePct)))", type: .risk)
                }
            }

            if extShouldClose {
                let pnlPct = ((currentPrice - entryPrice) / entryPrice) * 100
                await log.add("[\(pair)] POSITION-CHECK: \(extCloseReason) (P&L: \(String(format: "%+.1f%%", pnlPct)))", type: .risk)

                guard autoTrade else {
                    await log.add("[\(pair)] Auto-Trade AUS — würde \(holding.currency) verkaufen", type: .signal)
                    continue
                }

                if agentEnabled {
                    // KI-Agent verkauft (TP/SL = Risk Management, übersteuert Strategie)
                    // Holding-Info mitgeben damit Agent die Coinbase-Position sieht (nicht nur Engine-DB)
                    let response = await TradingAgent.shared.executeSell(
                        currency: holding.currency,
                        reason: "\(result.reason) (P&L: \(String(format: "%+.1f%%", pnlPct)), Strategie: \(holdingStrategies[holding.currency] ?? "unbekannt"))",
                        holdingInfo: (balance: holding.balance, nativeValue: holding.nativeValue, entryPrice: entryPrice)
                    )
                    // Tracking NUR löschen wenn Agent den Sell NICHT abgelehnt hat
                    if !agentRejected(response) {
                        holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                        holdingHighWatermarks.removeValue(forKey: holding.currency)
                        holdingStrategies.removeValue(forKey: holding.currency)
                        dcaBuyCount.removeValue(forKey: holding.currency)
                    }
                } else {
                    // Direkter Sell (v3-Balance)
                    let sellResult = await TradeExecutor.shared.sellAll(currency: holding.currency)

                    if let orderId = sellResult.orderId {
                        let pnl = (currentPrice - entryPrice) * holding.balance
                        // Trade in DB loggen (Fix: fehlte vorher → Trades nicht in Historie sichtbar)
                        let effFee = cachedFeeRate
                        let sellRecord = TradeRecord(
                            id: UUID().uuidString, timestamp: ISO8601DateFormatter().string(from: Date()),
                            pair: pair, side: "SELL", type: "MARKET",
                            size: holding.balance, price: currentPrice, fee: holding.nativeValue * effFee,
                            strategy: holdingStrategies[holding.currency] ?? "external", regime: (currentRegimes[pair] ?? .unknown).rawValue,
                            confidence: 0, exitPrice: currentPrice, pnl: pnl, holdingTime: nil,
                            status: "CLOSED", orderId: orderId, notes: result.reason
                        )
                        try? await TradingDatabase.shared.logTrade(sellRecord)
                        await log.add("[\(pair)] VERKAUFT: \(String(format: "%.4f", holding.balance)) @ \(String(format: "%.2f€", currentPrice)) — P&L: \(String(format: "%+.2f€", pnl)) (\(result.reason)) Order: \(orderId.prefix(12))", type: .trade)
                        holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                        holdingHighWatermarks.removeValue(forKey: holding.currency)
                        holdingStrategies.removeValue(forKey: holding.currency)
                        dcaBuyCount.removeValue(forKey: holding.currency)
                    } else {
                        await log.add("[\(pair)] Sell fehlgeschlagen: \(sellResult.error ?? "?")", type: .error)
                        holdingSellCooldown[holding.currency] = Date()
                    }
                }
            } else {
                // Strategie-Signale auswerten (zusätzlich zu TP/SL)
                let candles = await TradeExecutor.shared.getCandles(pair: pair, granularity: "ONE_HOUR", limit: 50)
                guard candles.count >= 26 else { continue }

                let indicators: IndicatorSnapshot
                if let cached = latestIndicators[pair] {
                    indicators = cached
                } else if let computed = TechnicalAnalysis.computeSnapshot(candles: candles) {
                    indicators = computed
                    latestIndicators[pair] = computed
                } else { continue }

                let regime = currentRegimes[pair] ?? .unknown
                let signals = await StrategyEngine.shared.evaluateAll(
                    pair: pair, candles: candles, indicators: indicators, regime: regime,
                    feeRate: cachedFeeRate
                )

                // Starkes SELL-Signal (>75% Konfidenz) → verkaufen NUR wenn Strategie kompatibel + Sell-Signale aktiviert
                let sellSignalsOn = UserDefaults.standard.object(forKey: "kobold.trading.sellSignalsEnabled") == nil
                    || UserDefaults.standard.bool(forKey: "kobold.trading.sellSignalsEnabled")
                if sellSignalsOn, let sellSignal = signals.first(where: { $0.action == .sell && $0.confidence > 0.75 }) {
                    let ownerStrat = holdingStrategies[holding.currency]

                    // Strategie-Kompatibilitäts-Check: Scalping-SELL darf kein TrendFollowing-BUY killen
                    guard strategyCompatible(sellStrategy: sellSignal.strategy, holdingStrategy: ownerStrat) else {
                        await log.add("[\(pair)] SELL (\(sellSignal.strategy)) blockiert — Position gehört \(ownerStrat ?? "?") (anderer Zeithorizont)", type: .signal)
                        continue
                    }

                    await log.add("[\(pair)] SELL-Signal [\(sellSignal.strategy)] \(String(format: "%.0f%%", sellSignal.confidence * 100)): \(sellSignal.reason)", type: .signal)

                    guard autoTrade else { continue }

                    if agentEnabled {
                        let portfolio = lastPortfolioString.isEmpty ? await buildPortfolioString() : lastPortfolioString
                        let response = await TradingAgent.shared.evaluate(
                            signal: sellSignal, pair: pair, currentPrice: currentPrice,
                            regime: (currentRegimes[pair] ?? .unknown).rawValue,
                            costBasis: entryPrice, portfolio: portfolio,
                            ownerStrategy: ownerStrat
                        )
                        // Tracking NUR löschen wenn Agent den Sell tatsächlich ausgeführt hat
                        if !agentRejected(response) {
                            holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                            holdingHighWatermarks.removeValue(forKey: holding.currency)
                            holdingStrategies.removeValue(forKey: holding.currency)
                            dcaBuyCount.removeValue(forKey: holding.currency)
                        }
                    } else {
                        let sellResult = await TradeExecutor.shared.sellAll(currency: holding.currency)
                        if let orderId = sellResult.orderId {
                            let pnl = (currentPrice - entryPrice) * holding.balance
                            // Trade in DB loggen (Fix: Signal-Sells fehlten in Historie)
                            let feeRateVal = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
                            let effFee = feeRateVal > 0 ? feeRateVal : 0.012
                            let sellRecord = TradeRecord(
                                id: UUID().uuidString, timestamp: ISO8601DateFormatter().string(from: Date()),
                                pair: pair, side: "SELL", type: "MARKET",
                                size: holding.balance, price: currentPrice, fee: holding.nativeValue * effFee,
                                strategy: sellSignal.strategy, regime: (currentRegimes[pair] ?? .unknown).rawValue,
                                confidence: sellSignal.confidence, exitPrice: currentPrice, pnl: pnl, holdingTime: nil,
                                status: "CLOSED", orderId: orderId, notes: "Signal-Sell: \(sellSignal.reason)"
                            )
                            try? await TradingDatabase.shared.logTrade(sellRecord)
                            await log.add("[\(pair)] VERKAUFT (Signal): \(String(format: "%.4f", holding.balance)) @ \(String(format: "%.2f€", currentPrice)) — P&L: \(String(format: "%+.2f€", pnl)) Order: \(orderId.prefix(12))", type: .trade)
                            holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                            holdingHighWatermarks.removeValue(forKey: holding.currency)
                            holdingStrategies.removeValue(forKey: holding.currency)
                            dcaBuyCount.removeValue(forKey: holding.currency)
                        } else {
                            holdingSellCooldown[holding.currency] = Date()
                        }
                    }
                }
            }

            // DCA: Progressives Nachkaufen (1€ → 2€ → 4€ → ... bis Max) — NICHT im Crash-Regime
            let dcaEnabled = UserDefaults.standard.bool(forKey: "kobold.trading.dcaEnabled")
            let dcaRegime = currentRegimes[pair] ?? .unknown
            if dcaEnabled && autoTrade && dcaRegime != .crash {
                let dcaDropPct = UserDefaults.standard.double(forKey: "kobold.trading.dcaDropPct")
                let dcaMaxAmount = UserDefaults.standard.double(forKey: "kobold.trading.dcaBuyAmount")
                let dcaMaxCount = UserDefaults.standard.integer(forKey: "kobold.trading.dcaMaxCount")
                let effectiveDrop = dcaDropPct > 0 ? dcaDropPct : 5.0
                let effectiveMaxAmount = dcaMaxAmount > 0 ? dcaMaxAmount : 50.0
                let effectiveMaxCount = dcaMaxCount > 0 ? dcaMaxCount : 5

                // Progressives DCA: Basis aus User-Konfiguration, Faktor 1.5x pro Stufe
                let currentCount = dcaBuyCount[holding.currency] ?? 0
                let threshold = entryPrice * (1 - effectiveDrop * Double(currentCount + 1) / 100)

                if currentPrice < threshold && currentCount < effectiveMaxCount {
                    let dcaBaseAmount = effectiveMaxAmount / max(Double(effectiveMaxCount), 1)
                    let dcaAmount = min(dcaBaseAmount * pow(1.5, Double(currentCount)), effectiveMaxAmount)

                    await log.add("[\(pair)] DCA #\(currentCount + 1)/\(effectiveMaxCount): \(String(format: "%.2f€", dcaAmount)) — Preis \(String(format: "%.2f€", currentPrice)) < Threshold \(String(format: "%.2f€", threshold))", type: .signal)

                    if agentEnabled {
                        let response = await TradingAgent.shared.executeBuy(
                            pair: pair, amount: dcaAmount,
                            reason: "DCA #\(currentCount + 1): Preis -\(String(format: "%.0f%%", effectiveDrop * Double(currentCount + 1))) unter Cost Basis (\(String(format: "%.2f€", dcaAmount)))"
                        )
                        if !agentRejected(response) {
                            dcaBuyCount[holding.currency] = currentCount + 1
                            holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                        }
                        holdingSellCooldown[holding.currency] = Date()
                    } else {
                        let orderId = await TradeExecutor.shared.placeMarketBuy(productId: pair, quoteSize: String(format: "%.2f", dcaAmount))
                        if let orderId = orderId {
                            dcaBuyCount[holding.currency] = currentCount + 1
                            // Trade in DB loggen (Fix: DCA-Käufe fehlten in Historie)
                            let feeRateVal = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
                            let effFee = feeRateVal > 0 ? feeRateVal : 0.012
                            let dcaRecord = TradeRecord(
                                id: UUID().uuidString, timestamp: ISO8601DateFormatter().string(from: Date()),
                                pair: pair, side: "BUY", type: "MARKET",
                                size: dcaAmount / currentPrice, price: currentPrice, fee: dcaAmount * effFee,
                                strategy: "dca", regime: (currentRegimes[pair] ?? .unknown).rawValue,
                                confidence: 0, exitPrice: nil, pnl: nil, holdingTime: nil,
                                status: "OPEN", orderId: orderId, notes: "DCA-Kauf #\(currentCount + 1)"
                            )
                            try? await TradingDatabase.shared.logTrade(dcaRecord)
                            await log.add("[\(pair)] DCA-KAUF #\(currentCount + 1): \(String(format: "%.2f€", dcaAmount)) nachgekauft (Order: \(orderId.prefix(12)))", type: .trade)
                            holdingCostBasis.removeValue(forKey: holding.currency)
                        holdingFirstSeen.removeValue(forKey: holding.currency)
                        }
                        holdingSellCooldown[holding.currency] = Date()
                    }
                }
            }
        }
    }

    // MARK: - ATR Helpers

    private func computeAvgATR(candles: [Candle], period: Int) -> Double {
        guard candles.count >= period + 14 else { return 0 }
        // Berechne ATR für jede der letzten `period` Stunden und mittele
        var atrs: [Double] = []
        let startIdx = max(candles.count - period, 14)
        for i in startIdx..<candles.count {
            let window = Array(candles[max(0, i-14)...i])
            if window.count >= 14 {
                let tr = zip(window.dropFirst(), window).map { curr, prev in
                    max(curr.high - curr.low, abs(curr.high - prev.close), abs(curr.low - prev.close))
                }
                atrs.append(tr.reduce(0, +) / Double(tr.count))
            }
        }
        return atrs.isEmpty ? 0 : atrs.reduce(0, +) / Double(atrs.count)
    }

    // MARK: - Self-Improvement Loop

    private func runSelfImprovementLoop() async {
        while isRunning && !Task.isCancelled {
            let hours = UserDefaults.standard.integer(forKey: "kobold.trading.selfImproveHours")
            let intervalHours = hours > 0 ? hours : 6

            do {
                try await Task.sleep(nanoseconds: UInt64(intervalHours) * 3_600_000_000_000)
            } catch { break }

            guard isRunning, UserDefaults.standard.bool(forKey: "kobold.trading.selfImprove") else { continue }

            let log = TradingActivityLog.shared
            await log.add("[Engine] Self-Improvement-Zyklus gestartet...", type: .info)

            // 1. Trade-Analyse
            let trades = (try? await TradingDatabase.shared.getClosedTrades()) ?? []
            let analytics = analyzer.analyze(trades: trades, period: "self-improvement")

            // 2. Backtest-Ergebnisse sammeln
            let btResults = latestBacktests
            var btSummary = ""
            for (key, r) in btResults.prefix(20) {
                btSummary += "  \(key): Return \(String(format: "%+.1f%%", r.totalReturn)), WinRate \(String(format: "%.0f%%", r.winRate)), Sharpe \(String(format: "%.1f", r.sharpeRatio))\n"
            }

            // 3. Regime-Analyse
            var regimeSummary = ""
            for (pair, regime) in currentRegimes {
                regimeSummary += "  \(pair): \(regime.rawValue)\n"
            }

            // 4. Strategy-Performance
            let stratPerfs = await TradingRiskManager.shared.getStrategyPerformance()
            var perfSummary = ""
            for p in stratPerfs {
                perfSummary += "  \(p.name): \(p.totalTrades) Trades, WinRate \(String(format: "%.0f%%", p.winRate)), P&L \(String(format: "%+.2f€", p.totalPnL))\n"
            }

            // 5. Aktuelle Settings
            let d = UserDefaults.standard
            let settingsSummary = """
            TP: \(d.double(forKey: "kobold.trading.takeProfit"))%, SL: \(d.double(forKey: "kobold.trading.trailingStop"))%
            Mode: \(d.string(forKey: "kobold.trading.tpSlMode") ?? "trailing")
            Max Trade: \(d.double(forKey: "kobold.trading.maxTradeSize"))%, Max Daily Loss: \(d.double(forKey: "kobold.trading.maxDailyLoss"))%
            """

            // 6. Forecast-Accuracy + Hot/Cold
            let acc1h = (try? await TradingDatabase.shared.getForecastAccuracy(horizon: "1h", days: 7)) ?? (0, 0, 0.0)
            let acc4h = (try? await TradingDatabase.shared.getForecastAccuracy(horizon: "4h", days: 7)) ?? (0, 0, 0.0)
            var forecastAccuracySummary = ""
            if acc1h.0 > 0 { forecastAccuracySummary += "1h: \(String(format: "%.0f%%", acc1h.2 * 100)) (\(acc1h.0) Forecasts)\n" }
            if acc4h.0 > 0 { forecastAccuracySummary += "4h: \(String(format: "%.0f%%", acc4h.2 * 100)) (\(acc4h.0) Forecasts)\n" }
            if forecastAccuracySummary.isEmpty { forecastAccuracySummary = "Noch keine Daten (Tracking läuft)" }

            let multipliers = await StrategyEngine.shared.getMultipliers()
            var hotColdSummary = ""
            for p in stratPerfs {
                let mul = multipliers[p.name] ?? 1.0
                let status = p.winRate >= 60 ? "HOT" : (p.winRate <= 40 ? "COLD" : "NEUTRAL")
                hotColdSummary += "\(p.name): \(status) (WR: \(String(format: "%.0f%%", p.winRate)), Multiplier: \(String(format: "%.2f", mul)))\n"
            }
            if hotColdSummary.isEmpty { hotColdSummary = "Noch keine Strategie-Daten" }

            // 7. Strategie-Multipliers aus Win-Rate aktualisieren
            let mulPerfs = stratPerfs.map { (name: $0.name, winRate: $0.winRate / 100.0, trades: $0.totalTrades) }
            await StrategyEngine.shared.updateMultipliers(performances: mulPerfs)

            // 7b. Forecast-Gewichte adaptiv anpassen (per-Faktor-Accuracy)
            if let factorAcc = try? await TradingDatabase.shared.getForecastAccuracyByFactor(days: 14) {
                if !factorAcc.isEmpty {
                    forecaster.updateAdaptiveWeights(forecastAccuracyByFactor: factorAcc)
                    let adjusted = factorAcc.filter { $0.value.total >= 50 }.count
                    await log.add("[Engine] Forecast-Gewichte aktualisiert: \(factorAcc.count) Faktoren, \(adjusted) adaptiv angepasst", type: .info)
                }
            }

            // 8. Wenn Agent aktiv → Agent analysieren lassen (umfassend)
            if d.bool(forKey: "kobold.trading.agentEnabled") {
                let prompt = """
                Du bist im Self-Improvement-Modus. Analysiere die Daten und gib konkrete Verbesserungsvorschläge.

                ## Trade-Performance (\(analytics.totalTrades) Trades)
                Win Rate: \(String(format: "%.1f%%", analytics.winRate))
                Total P&L: \(String(format: "%+.2f€", analytics.totalPnL))
                Sharpe Ratio: \(String(format: "%.2f", analytics.sharpeRatio))
                Max Drawdown: \(String(format: "%.1f%%", analytics.maxDrawdownPct))
                Avg Hold: \(String(format: "%.0f min", analytics.avgHoldingTimeMinutes))

                ## Backtest-Ergebnisse
                \(btSummary.isEmpty ? "Keine Backtests vorhanden" : btSummary)

                ## Aktuelle Regimes
                \(regimeSummary.isEmpty ? "Keine Regime-Daten" : regimeSummary)

                ## Strategie-Performance
                \(perfSummary.isEmpty ? "Keine Strategie-Daten" : perfSummary)

                ## Aktuelle Settings
                \(settingsSummary)

                ## Forecast-Accuracy (7 Tage)
                \(forecastAccuracySummary)

                ## Strategie Hot/Cold Status
                \(hotColdSummary)

                ## Aufgaben
                1. Recherchiere aktuelle Krypto-News und Markttrends (nutze web_search)
                2. Bewerte welche Strategien gut/schlecht performen und warum
                3. Schlage konkrete Settings-Änderungen vor (z.B. TP/SL anpassen, Strategien an/aus)
                4. Nutze trading_tool mit action "regime" für aktuelle Marktlage
                5. Wenn du Settings ändern willst, nutze settings_read Tool
                6. Bewerte ob Forecast-Accuracy ausreicht (Ziel: >60%) — wenn nicht, erkläre mögliche Ursachen
                7. Prüfe COLD-Strategien: Sollten sie deaktiviert werden?

                Fasse deine Analyse in 3-5 Sätzen zusammen. Wichtig: Begründe WARUM.
                """

                let response = await TradingAgent.shared.evaluate(
                    signal: "SELF_IMPROVE", context: prompt
                )
                await log.add("[Engine] KI-Lernzyklus: \(response)", type: .agent)

                // Lernnotiz persistent speichern
                saveLearningNote(response)
            } else {
                // Ohne Agent: Nur Performance loggen
                if analytics.totalTrades >= 10 {
                    for strategy in await StrategyEngine.shared.getActiveStrategies() {
                        if strategy.enabled {
                            let perfJson = "{\"winRate\":\(analytics.winRate),\"sharpe\":\(analytics.sharpeRatio),\"maxDD\":\(analytics.maxDrawdownPct)}"
                            try? await TradingDatabase.shared.saveStrategyVersion(
                                name: strategy.name, version: strategy.version, params: perfJson
                            )
                        }
                    }
                }
                await log.add("[Engine] Self-Improvement: \(analytics.totalTrades) Trades, WinRate \(String(format: "%.0f%%", analytics.winRate)), P&L \(String(format: "%+.2f€", analytics.totalPnL))", type: .info)
            }
        }
    }

    /// Speichert Lernnotizen des Agents persistent
    private func saveLearningNote(_ note: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS")
        let file = dir.appendingPathComponent("trading_learning.json")
        var notes: [[String: String]] = []
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            notes = existing
        }
        let fmt = ISO8601DateFormatter()
        notes.append(["date": fmt.string(from: Date()), "note": String(note.prefix(500))])
        // Max 50 Einträge behalten
        if notes.count > 50 { notes = Array(notes.suffix(50)) }
        if let data = try? JSONSerialization.data(withJSONObject: notes) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Lernnotizen lesen (für UI)
    public func getLearningNotes() -> [(date: String, note: String)] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/trading_learning.json")
        guard let data = try? Data(contentsOf: file),
              let notes = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return notes.compactMap { dict in
            guard let date = dict["date"], let note = dict["note"] else { return nil }
            return (date: date, note: note)
        }
    }

    // MARK: - Daily Report Loop

    private func runDailyReportLoop() async {
        while isRunning && !Task.isCancelled {
            // Sleep until next report time
            let reportTime = UserDefaults.standard.string(forKey: "kobold.trading.dailyReportTime") ?? "22:00"
            let sleepInterval = secondsUntilTime(reportTime)

            do {
                try await Task.sleep(nanoseconds: UInt64(sleepInterval) * 1_000_000_000)
            } catch { break }

            guard isRunning, UserDefaults.standard.bool(forKey: "kobold.trading.telegramDaily") else { continue }

            // Generate daily report
            let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            let trades = (try? await TradingDatabase.shared.getClosedTrades(since: today)) ?? []
            let analytics = analyzer.analyze(trades: trades, period: "heute")
            let regime = currentRegimes.values.first ?? .unknown
            let openCount = (try? await TradingDatabase.shared.getOpenTrades().count) ?? 0

            await TradingReporter.shared.sendDailySummary(
                analytics: analytics, regime: regime, openPositions: openCount
            )

            // Save report to file
            let report = analyzer.generateReport(analytics: analytics)
            saveReport(report, filename: "trade_analysis.md")

            // Also save forecast report
            if let firstPair = latestForecasts.keys.first,
               let forecasts = latestForecasts[firstPair],
               let indicators = latestIndicators[firstPair] {
                let forecastReport = forecaster.generateReport(
                    pair: firstPair, forecasts: forecasts, indicators: indicators, regime: regime
                )
                saveReport(forecastReport, filename: "market_forecast.md")
            }
        }
    }

    // MARK: - Forecast Validation Loop

    private func runForecastValidationLoop() async {
        let log = TradingActivityLog.shared
        // Erster Durchlauf erst nach 10 Minuten (Engine muss erst Forecasts generieren)
        do { try await Task.sleep(nanoseconds: 600_000_000_000) } catch { return }

        while isRunning && !Task.isCancelled {
            // 1h-Forecasts validieren (mindestens 70 Min alt — 1h Horizont + 10 Min Puffer)
            let pending = (try? await TradingDatabase.shared.getPendingForecasts(maxAge: 4200)) ?? []

            var validated = 0
            for forecast in pending {
                guard isRunning, !Task.isCancelled else { break }

                // Aktuellen Preis von Coinbase holen
                guard let actualPrice = await TradeExecutor.shared.getSpotPrice(pair: forecast.pair) else {
                    continue
                }

                try? await TradingDatabase.shared.validateForecast(
                    id: forecast.id,
                    actualPrice: actualPrice,
                    forecastPrice: forecast.currentPrice
                )
                validated += 1
            }

            if validated > 0 {
                // Accuracy-Stats loggen
                let accuracy = (try? await TradingDatabase.shared.getForecastAccuracy(horizon: "1h", pair: nil, days: 7)) ?? (0, 0, 0.0)
                let accTotal = accuracy.0
                let accCorrect = accuracy.1
                let accPct = accuracy.2
                if accTotal > 0 {
                    let pct = Int(accPct * 100)
                    let msg = "[Forecast] \(validated) validiert — 7d Accuracy: \(pct)% (\(accCorrect)/\(accTotal))"
                    await log.add(msg, type: .info)
                }
            }

            // Alte Forecasts purgen (>30 Tage)
            try? await TradingDatabase.shared.purgeForecastLog(olderThanDays: 30)

            // Alle 30 Minuten wiederholen
            do { try await Task.sleep(nanoseconds: 1_800_000_000_000) } catch { break }
        }
    }

    // MARK: - Health Check

    private func healthCheck() async {
        // 1. Verify API connectivity
        let price = await TradeExecutor.shared.getSpotPrice(pair: "BTC-EUR")
        if price == nil {
            print("[TradingEngine] WARNING: Coinbase API not reachable")
        }

        // 2. Verify database integrity
        let dbOk = await TradingDatabase.shared.verifyIntegrity()
        if !dbOk {
            print("[TradingEngine] WARNING: Database integrity check failed")
            await TradingReporter.shared.sendRiskAlert(reason: "Datenbank-Integritätsprüfung fehlgeschlagen")
        }

        // 3. Check risk limits
        let haltState = await TradingRiskManager.shared.getIsHalted()
        if haltState.halted {
            print("[TradingEngine] Trading halted: \(haltState.reason)")
        }
    }

    // MARK: - Public Queries

    public func getStatus() async -> TradingStatus {
        let openTrades = (try? await TradingDatabase.shared.getOpenTrades()) ?? []
        let totalTrades = (try? await TradingDatabase.shared.getTradeCount()) ?? 0
        let dailyPnL = await TradingRiskManager.shared.getDailyPnL()
        let haltState = await TradingRiskManager.shared.getIsHalted()
        let strategies = await StrategyEngine.shared.getActiveStrategies()
        let pairsStr = UserDefaults.standard.string(forKey: "kobold.trading.pairs") ?? "BTC-EUR,ETH-EUR"
        let pairs = pairsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let regime = currentRegimes.values.first ?? .unknown

        let uptimeStr: String
        if let start = startTime {
            let mins = Int(Date().timeIntervalSince(start) / 60)
            uptimeStr = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
        } else { uptimeStr = "0m" }

        let now = ISO8601DateFormatter().string(from: Date())

        return TradingStatus(
            running: isRunning, regime: regime.rawValue,
            openPositions: openTrades.count, totalTrades: totalTrades,
            dailyPnL: dailyPnL, portfolioValue: portfolioValue,
            lastCycleTime: now, activePairs: pairs,
            activeStrategies: strategies.filter(\.enabled).map(\.name),
            halted: haltState.halted, haltReason: haltState.reason,
            uptime: uptimeStr
        )
    }

    public func getForecasts(pair: String) -> [ForecastResult] {
        latestForecasts[pair] ?? []
    }

    /// On-Demand-Forecast für ein beliebiges Pair (auch wenn Engine nicht läuft)
    public func forecastOnDemand(pair: String) async -> [ForecastResult] {
        // Erst Cache prüfen
        if let cached = latestForecasts[pair], !cached.isEmpty { return cached }

        let candles = await TradeExecutor.shared.getCandles(pair: pair, granularity: "ONE_HOUR", limit: 300)
        guard candles.count >= 100,
              let indicators = TechnicalAnalysis.computeSnapshot(candles: candles) else { return [] }
        let regime = detector.detect(candles: candles, indicators: indicators)
        let result = forecaster.forecast(pair: pair, candles: candles, indicators: indicators, regime: regime)
        latestForecasts[pair] = result
        currentRegimes[pair] = regime
        return result
    }

    public func getRegime(pair: String) -> MarketRegime {
        currentRegimes[pair] ?? .unknown
    }

    public func getAnalytics(period: String) async -> TradingAnalytics {
        let trades = (try? await TradingDatabase.shared.getClosedTrades()) ?? []
        return analyzer.analyze(trades: trades, period: period)
    }

    public func runBacktest(strategyName: String, pair: String, days: Int) async -> BacktestResult? {
        let candles = await TradeExecutor.shared.getCandles(
            pair: pair, granularity: "ONE_HOUR", limit: days * 24
        )
        guard candles.count >= 200 else { return nil }

        // Get the strategy instance (built-in or custom)
        guard let strategy = await StrategyEngine.shared.getStrategy(name: strategyName) else {
            return nil
        }

        // Echte Fee-Rate nutzen (nicht hardcoded 1.2%)
        let feeRate = await TradeExecutor.shared.getObservedFeeRate()
        let result = backtester.run(strategy: strategy, candles: candles, pair: pair, feeRate: feeRate)

        // Save report
        let report = backtester.generateReport(result)
        saveReport(report, filename: "backtests/\(strategyName)_\(pair)_\(days)d.md")

        return result
    }

    public func getIsRunning() -> Bool { isRunning }

    /// Engine-Monitoring-Info pro Coin (für UI: Entry-Preis, High Watermark, Regime, Strategie)
    public struct HoldingMonitorInfo: Sendable {
        public let currency: String
        public let entryPrice: Double      // Cost Basis / Durchschnittskaufpreis
        public let highWatermark: Double   // Höchster Preis seit Tracking
        public let regime: String          // Aktuelles Marktregime
        public let isMonitored: Bool       // Engine überwacht aktiv
        public let strategy: String?       // Strategie die Position eröffnet hat
    }

    public func getHoldingMonitorInfo() -> [String: HoldingMonitorInfo] {
        var result: [String: HoldingMonitorInfo] = [:]
        for (currency, entryPrice) in holdingCostBasis {
            let hwm = holdingHighWatermarks[currency] ?? entryPrice
            let pair = "\(currency)-EUR"
            let regime = currentRegimes[pair]?.rawValue ?? "UNKNOWN"
            result[currency] = HoldingMonitorInfo(
                currency: currency, entryPrice: entryPrice,
                highWatermark: hwm, regime: regime, isMonitored: isRunning,
                strategy: holdingStrategies[currency]
            )
        }
        return result
    }

    /// Gibt die neuesten Auto-Backtest-Ergebnisse zurück (Key = "strategy:pair")
    public func getLatestBacktests() -> [String: BacktestResult] {
        latestBacktests
    }

    /// Backtest-Ergebnisse nur für ein bestimmtes Pair
    public func getBacktestsForPair(_ pair: String) -> [String: BacktestResult] {
        latestBacktests.filter { $0.value.pair == pair }
    }

    // MARK: - Auto-Backtest Loop

    private var latestBacktests: [String: BacktestResult] = [:]  // Key: "strategy:pair"

    private func runAutoBacktestLoop() async {
        // Erste Backtests nach 5 Minuten
        do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }

        while isRunning && !Task.isCancelled {
            let log = TradingActivityLog.shared
            await log.add("Auto-Backtest gestartet...", type: .info)

            let strategies = await StrategyEngine.shared.getActiveStrategies()

            // ALLE konfigurierten Paare + Holdings backtesten (nicht nur BTC!)
            let pairsStr = UserDefaults.standard.string(forKey: "kobold.trading.pairs") ?? "BTC-EUR"
            var allPairs = Set(pairsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

            // Holdings-Paare hinzufügen
            for h in liveHoldings where h.currency != "EUR" && h.currency != "EURC" && h.nativeValue > 0.50 {
                allPairs.insert("\(h.currency)-EUR")
            }

            var backtestCount = 0
            let btFeeRate = await TradeExecutor.shared.getObservedFeeRate()

            for pair in allPairs.sorted() {
                // Candles einmal pro Pair holen
                let candles = await TradeExecutor.shared.getCandles(pair: pair, granularity: "ONE_HOUR", limit: 14 * 24)
                guard candles.count >= 200 else { continue }

                for strat in strategies where strat.enabled {
                    guard isRunning && !Task.isCancelled else { break }
                    guard let strategy = await StrategyEngine.shared.getStrategy(name: strat.name) else { continue }

                    let result = backtester.run(strategy: strategy, candles: candles, pair: pair, feeRate: btFeeRate)
                    let key = "\(strat.name):\(pair)"
                    latestBacktests[key] = result
                    backtestCount += 1

                    // Nur auffällige Ergebnisse loggen (um Log nicht zu fluten)
                    if result.totalTrades >= 3 {
                        await log.add("BT \(strat.name)/\(pair): \(String(format: "%+.1f%%", result.totalReturn)) WR\(String(format: "%.0f%%", result.winRate)) Sharpe \(String(format: "%.2f", result.sharpeRatio))", type: .analysis)
                    }
                }
            }

            await log.add("Auto-Backtest abgeschlossen: \(backtestCount) Tests über \(allPairs.count) Paare", type: .info)

            // Alle 6 Stunden wiederholen
            do { try await Task.sleep(nanoseconds: 6 * 3_600_000_000_000) } catch { break }
        }
    }

    // MARK: - Helpers

    private func secondsUntilTime(_ timeStr: String) -> UInt64 {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return 3600 }
        let targetHour = parts[0]
        let targetMinute = parts[1]

        let cal = Calendar.current
        let now = Date()
        var target = cal.date(bySettingHour: targetHour, minute: targetMinute, second: 0, of: now)!
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target)! }
        return UInt64(max(target.timeIntervalSince(now), 60))
    }

    private func saveReport(_ content: String, filename: String) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/trading/reports")
        let dir = base.appendingPathComponent(filename).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.write(to: base.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }
}
#endif
