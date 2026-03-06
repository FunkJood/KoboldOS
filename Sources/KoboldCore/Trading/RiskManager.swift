#if os(macOS)
import Foundation

// MARK: - Risk Manager
// Professionelles Risk-Management: Circuit Breakers, ATR-Stops, Volatility Scaling
// Priorität: stability > safety > performance > profitability

public actor TradingRiskManager {
    public static let shared = TradingRiskManager()

    // Konfigurierbare Limits (werden aus UserDefaults gelesen)
    public var maxTradeSizePct: Double = 2.0        // Max 2% Portfolio pro Trade
    public var maxDailyLossPct: Double = 5.0        // Max 5% Tagesverlust
    public var maxOpenPositions: Int = 5            // Max 5 offene Positionen
    public var trailingStopPct: Double = 3.0        // 3% Trailing Stop
    public var maxSingleAssetPct: Double = 30.0     // Max 30% in einem Asset
    public var maxWeeklyLossPct: Double = 10.0       // Max 10% Wochenverlust

    // TP/SL Settings
    public var takeProfitPct: Double = 5.0          // Take-Profit bei +5%
    public var fixedStopLossPct: Double = 3.0       // Fixed Stop-Loss bei -3%
    public var tpSlMode: String = "trailing"        // "trailing" | "fixed" | "both" | "atr"
    public var noLossSell: Bool = false             // Nie im Minus verkaufen

    // Circuit Breaker Settings
    public var circuitBreakersEnabled: Bool = true
    public var cbPriceDropPct: Double = 5.0         // Preis-Drop % in 5min → Pause
    public var cbVolatilityMultiplier: Double = 3.0 // ATR > 3x Avg → Halt
    public var cbMaxConcurrentStops: Int = 3        // Max gleichzeitige Stops → Halt

    // ATR-based TP/SL (für Mode "atr")
    public var atrStopMultiplier: Double = 1.5      // SL = Entry ± ATR × Multiplier
    public var atrTakeProfitMultiplier: Double = 3.0 // TP = Entry ± ATR × Multiplier

    // Regime-aware Defaults (werden dynamisch angepasst)
    public var currentRegime: MarketRegime = .unknown

    // Runtime State
    private var dailyPnL: Double = 0
    private var dailyDate: String = ""
    private var isHalted: Bool = false
    private var haltReason: String = ""
    private var weeklyPnL: Double = 0
    private var weeklyDate: String = ""

    // Circuit Breaker State
    private var recentPrices: [String: [(time: Date, price: Double)]] = [:]
    private var circuitBreakerPausedUntil: Date? = nil
    private var circuitBreakerReason: String = ""
    private var consecutiveStops: Int = 0
    private var lastStopTime: Date? = nil

    // Strategy Performance Tracking
    public struct StrategyPerf: Sendable, Codable {
        public var name: String
        public var totalTrades: Int = 0
        public var wins: Int = 0
        public var losses: Int = 0
        public var totalPnL: Double = 0
        public var bestTrade: Double = 0
        public var worstTrade: Double = 0
        public var avgHoldingMinutes: Double = 0
        public var grossProfit: Double = 0
        public var grossLoss: Double = 0

        public var winRate: Double { totalTrades > 0 ? Double(wins) / Double(totalTrades) * 100 : 0 }
        public var profitFactor: Double {
            grossLoss > 0 ? grossProfit / grossLoss : (grossProfit > 0 ? 99.0 : 0)
        }
    }

    private var strategyPerformance: [String: StrategyPerf] = [:]

    private init() {}

    // MARK: - Config Sync

    public func syncFromDefaults() {
        let d = UserDefaults.standard
        maxTradeSizePct = d.double(forKey: "kobold.trading.maxTradeSize")
        if maxTradeSizePct <= 0 { maxTradeSizePct = 2.0 }
        maxDailyLossPct = d.double(forKey: "kobold.trading.maxDailyLoss")
        if maxDailyLossPct <= 0 { maxDailyLossPct = 3.0 }
        maxOpenPositions = d.integer(forKey: "kobold.trading.maxOpenPositions")
        if maxOpenPositions <= 0 { maxOpenPositions = 3 }
        trailingStopPct = d.double(forKey: "kobold.trading.trailingStop")
        if trailingStopPct <= 0 { trailingStopPct = 4.0 }
        takeProfitPct = d.double(forKey: "kobold.trading.takeProfit")
        if takeProfitPct <= 0 { takeProfitPct = 8.0 }
        fixedStopLossPct = d.double(forKey: "kobold.trading.fixedStopLoss")
        if fixedStopLossPct <= 0 { fixedStopLossPct = 3.0 }
        let mode = d.string(forKey: "kobold.trading.tpSlMode") ?? "trailing"
        tpSlMode = ["trailing", "fixed", "both", "atr"].contains(mode) ? mode : "trailing"
        noLossSell = d.bool(forKey: "kobold.trading.noLossSell")
        maxWeeklyLossPct = d.double(forKey: "kobold.trading.maxWeeklyLoss")
        if maxWeeklyLossPct <= 0 { maxWeeklyLossPct = 6.0 }

        // Circuit Breaker Settings
        circuitBreakersEnabled = d.object(forKey: "kobold.trading.circuitBreakers") != nil
            ? d.bool(forKey: "kobold.trading.circuitBreakers") : true
        let cbDrop = d.double(forKey: "kobold.trading.cbPriceDrop")
        if cbDrop > 0 { cbPriceDropPct = cbDrop }
        let cbVol = d.double(forKey: "kobold.trading.cbVolatility")
        if cbVol > 0 { cbVolatilityMultiplier = cbVol }

        // ATR TP/SL
        let atrSL = d.double(forKey: "kobold.trading.atrStopMultiplier")
        if atrSL > 0 { atrStopMultiplier = atrSL }
        let atrTP = d.double(forKey: "kobold.trading.atrTakeProfitMultiplier")
        if atrTP > 0 { atrTakeProfitMultiplier = atrTP }

        // Load saved strategy performance
        if let data = d.data(forKey: "kobold.trading.strategyPerf"),
           let perfs = try? JSONDecoder().decode([String: StrategyPerf].self, from: data) {
            strategyPerformance = perfs
        }
    }

    // MARK: - Trade Validation

    public struct RiskCheck: Sendable {
        public let allowed: Bool
        public let reason: String
        public let adjustedSize: Double? // Kann Position verkleinern bei hoher Volatilität

        public static func ok(adjustedSize: Double? = nil) -> RiskCheck {
            RiskCheck(allowed: true, reason: "OK", adjustedSize: adjustedSize)
        }
        public static func denied(_ reason: String) -> RiskCheck {
            RiskCheck(allowed: false, reason: reason, adjustedSize: nil)
        }
    }

    /// Prüft ob ein Trade erlaubt ist (mit Circuit Breaker + Volatility Scaling)
    public func checkTradeAllowed(
        pair: String,
        side: String,
        size: Double,
        price: Double,
        portfolioValue: Double,
        openPositions: [TradeRecord],
        currentATR: Double = 0,
        avgATR: Double = 0
    ) -> RiskCheck {

        // Emergency Halt?
        if isHalted {
            return .denied("Trading gehaltet: \(haltReason)")
        }

        // Circuit Breaker aktiv?
        if let pauseEnd = circuitBreakerPausedUntil, Date() < pauseEnd {
            let remaining = Int(pauseEnd.timeIntervalSinceNow / 60)
            return .denied("Circuit Breaker aktiv: \(circuitBreakerReason) (noch \(remaining)min)")
        }

        // Täglichen PnL zurücksetzen wenn neuer Tag
        let today = dateString()
        if today != dailyDate {
            dailyPnL = 0
            dailyDate = today
            consecutiveStops = 0
        }

        // Wöchentlichen PnL zurücksetzen wenn neue Kalenderwoche
        let cal = Calendar.current
        let weekId = "\(cal.component(.yearForWeekOfYear, from: Date()))-W\(cal.component(.weekOfYear, from: Date()))"
        if weekId != weeklyDate {
            weeklyPnL = 0
            weeklyDate = weekId
        }

        // 1. Max Trade Size (regime-aware)
        let tradeValue = size * price
        let effectiveMaxTradePct = regimeMaxTradeSizePct()
        let maxTradeValue = portfolioValue * (effectiveMaxTradePct / 100.0)
        if tradeValue > maxTradeValue {
            return .denied("Trade-Größe \(formatEUR(tradeValue)) überschreitet \(String(format: "%.1f", effectiveMaxTradePct))% Limit (\(formatEUR(maxTradeValue))) [\(currentRegime.rawValue)]")
        }

        // 2. Max Open Positions (regime-aware: Bull = mehr, Bear = weniger)
        let effectiveMaxPositions = regimeMaxOpenPositions()
        if openPositions.count >= effectiveMaxPositions && side == "BUY" {
            return .denied("Max. offene Positionen erreicht (\(openPositions.count)/\(effectiveMaxPositions)) [\(currentRegime.rawValue)]")
        }

        // 3. Daily Loss Limit
        let maxDailyLoss = portfolioValue * (maxDailyLossPct / 100.0)
        if dailyPnL < 0 && abs(dailyPnL) >= maxDailyLoss {
            return .denied("Tagesverlust-Limit erreicht: \(formatEUR(abs(dailyPnL))) / \(formatEUR(maxDailyLoss))")
        }

        // 3b. Weekly Loss Limit
        let maxWeeklyLoss = portfolioValue * (maxWeeklyLossPct / 100.0)
        if weeklyPnL < 0 && abs(weeklyPnL) >= maxWeeklyLoss {
            return .denied("Wochenverlust-Limit erreicht: \(formatEUR(abs(weeklyPnL))) / \(formatEUR(maxWeeklyLoss))")
        }

        // 4. Single Asset Exposure (regime-aware: Bull = 50%, Bear = 15%)
        let assetBase = pair.split(separator: "-").first.map(String.init) ?? pair
        let existingExposure = openPositions
            .filter { $0.pair.hasPrefix(assetBase) && $0.side == "BUY" }
            .reduce(0.0) { $0 + $1.size * $1.price }
        let newExposure = existingExposure + tradeValue
        let effectiveAssetPct = regimeMaxSingleAssetPct()
        let maxAssetValue = portfolioValue * (effectiveAssetPct / 100.0)
        if newExposure > maxAssetValue && side == "BUY" {
            return .denied("Asset-Exposure für \(assetBase) (\(formatEUR(newExposure))) überschreitet \(String(format: "%.0f", effectiveAssetPct))% Limit [\(currentRegime.rawValue)]")
        }

        // 5. Volatility Scaling — reduziert Positionsgröße bei hoher Volatilität
        if currentATR > 0 && avgATR > 0 {
            let volatilityRatio = currentATR / avgATR
            if volatilityRatio > 2.0 {
                // Extreme Vola: 75% Reduktion
                let adjustedSize = size * 0.25
                return .ok(adjustedSize: adjustedSize)
            } else if volatilityRatio > 1.5 {
                // Hohe Vola: 50% Reduktion
                let adjustedSize = size * 0.50
                return .ok(adjustedSize: adjustedSize)
            }
        }

        return .ok()
    }

    // MARK: - Circuit Breakers

    /// Zeichnet Preise auf und prüft Circuit Breaker Bedingungen
    public func recordPrice(pair: String, price: Double) -> (tripped: Bool, reason: String) {
        guard circuitBreakersEnabled else { return (false, "") }

        let now = Date()

        // Preis aufzeichnen
        if recentPrices[pair] == nil { recentPrices[pair] = [] }
        recentPrices[pair]?.append((now, price))

        // Nur letzte 30 Minuten behalten
        recentPrices[pair] = recentPrices[pair]?.filter { now.timeIntervalSince($0.time) < 1800 }

        guard let prices = recentPrices[pair], prices.count >= 2 else { return (false, "") }

        // Price Circuit Breaker: Drop > X% in 5 Minuten
        let fiveMinAgo = now.addingTimeInterval(-300)
        if let recentHigh = prices.filter({ $0.time > fiveMinAgo }).map(\.price).max() {
            let dropPct = (recentHigh - price) / recentHigh * 100
            if dropPct >= cbPriceDropPct {
                let reason = "Preis-Drop \(String(format: "%.1f%%", dropPct)) in 5min (\(pair))"
                triggerCircuitBreaker(reason: reason, pauseMinutes: 15)
                return (true, reason)
            }
        }

        return (false, "")
    }

    /// Prüft ATR-basierte Volatilitäts-Circuit-Breaker
    public func checkVolatilityBreaker(currentATR: Double, avgATR: Double, pair: String) -> (tripped: Bool, reason: String) {
        guard circuitBreakersEnabled, avgATR > 0 else { return (false, "") }

        let ratio = currentATR / avgATR
        if ratio >= cbVolatilityMultiplier {
            let reason = "Volatilitäts-Spike: ATR \(String(format: "%.1fx", ratio)) des Durchschnitts (\(pair))"
            triggerCircuitBreaker(reason: reason, pauseMinutes: 30)
            return (true, reason)
        }
        return (false, "")
    }

    /// Registriert einen Stop-Loss-Trigger (für Kaskaden-Detection)
    public func recordStopTrigger() {
        let now = Date()
        if let last = lastStopTime, now.timeIntervalSince(last) < 1800 {
            consecutiveStops += 1
        } else {
            consecutiveStops = 1
        }
        lastStopTime = now

        if consecutiveStops >= cbMaxConcurrentStops {
            triggerCircuitBreaker(
                reason: "\(consecutiveStops) Stops in Folge — Kaskaden-Risiko",
                pauseMinutes: 30
            )
        }
    }

    private func triggerCircuitBreaker(reason: String, pauseMinutes: Int) {
        circuitBreakerPausedUntil = Date().addingTimeInterval(Double(pauseMinutes) * 60)
        circuitBreakerReason = reason
        print("[RiskManager] CIRCUIT BREAKER: \(reason) — Pause für \(pauseMinutes)min")
    }

    /// Manuelles Zurücksetzen des Circuit Breakers
    public func resetCircuitBreaker() {
        circuitBreakerPausedUntil = nil
        circuitBreakerReason = ""
        consecutiveStops = 0
    }

    // MARK: - Position Management

    /// Berechnet Trailing-Stop-Preis für eine Position (regime-aware)
    public func trailingStopPrice(entryPrice: Double, currentPrice: Double, side: String) -> Double {
        let effectiveStop = regimeTrailingStopPct()
        if side == "BUY" {
            let highWatermark = max(entryPrice, currentPrice)
            return highWatermark * (1 - effectiveStop / 100.0)
        } else {
            let lowWatermark = min(entryPrice, currentPrice)
            return lowWatermark * (1 + effectiveStop / 100.0)
        }
    }

    /// Prüft ob ein Trailing Stop ausgelöst wurde (regime-aware)
    public func isStopTriggered(entryPrice: Double, currentPrice: Double, highWatermark: Double, side: String) -> Bool {
        let effectiveStop = regimeTrailingStopPct()
        if side == "BUY" {
            let stopPrice = highWatermark * (1 - effectiveStop / 100.0)
            return currentPrice <= stopPrice
        } else {
            let stopPrice = highWatermark * (1 + effectiveStop / 100.0)
            return currentPrice >= stopPrice
        }
    }

    /// Prüft ob eine Position geschlossen werden soll (TP/SL/Trailing/ATR)
    public func shouldClosePosition(entryPrice: Double, currentPrice: Double,
                                     highWatermark: Double, side: String,
                                     atr: Double = 0) -> (close: Bool, reason: String) {
        let changePct: Double
        if side == "BUY" {
            changePct = ((currentPrice - entryPrice) / entryPrice) * 100.0
        } else {
            changePct = ((entryPrice - currentPrice) / entryPrice) * 100.0
        }

        // Nie im Minus verkaufen (wenn aktiviert) — ABER absolutes Maximum-Loss-Override bei -15%
        if noLossSell && changePct < 0 {
            if changePct <= -15.0 {
                return (true, "NOTVERKAUF: -\(String(format: "%.1f%%", abs(changePct))) überschreitet absolutes Maximum (-15%)")
            }
            return (false, "Kein Verkauf im Minus (\(String(format: "%+.1f%%", changePct))) — Einstellung aktiv")
        }

        let mode = tpSlMode

        // ATR-basiertes TP/SL (professionelles System)
        if mode == "atr" && atr > 0 {
            let atrStop = atr * atrStopMultiplier
            let atrTP = atr * atrTakeProfitMultiplier

            if side == "BUY" {
                if currentPrice >= entryPrice + atrTP {
                    return (true, "ATR-TP erreicht: +\(String(format: "%.2f€", currentPrice - entryPrice)) (ATR×\(String(format: "%.1f", atrTakeProfitMultiplier))=\(String(format: "%.2f€", atrTP)))")
                }
                if currentPrice <= entryPrice - atrStop {
                    return (true, "ATR-SL ausgelöst: \(String(format: "%.2f€", currentPrice - entryPrice)) (ATR×\(String(format: "%.1f", atrStopMultiplier))=\(String(format: "%.2f€", atrStop)))")
                }
            } else {
                if currentPrice <= entryPrice - atrTP {
                    return (true, "ATR-TP erreicht (Short)")
                }
                if currentPrice >= entryPrice + atrStop {
                    return (true, "ATR-SL ausgelöst (Short)")
                }
            }

            // ATR-Modus hat auch Trailing nach TP1-Bereich (50% des TP)
            if changePct > 0 {
                let trailingStart = atrTP * 0.5 / entryPrice * 100
                if changePct >= trailingStart {
                    let triggered = isStopTriggered(entryPrice: entryPrice, currentPrice: currentPrice,
                                                     highWatermark: highWatermark, side: side)
                    if triggered {
                        return (true, "ATR-Trailing Stop nach +\(String(format: "%.1f%%", changePct))")
                    }
                }
            }

            return (false, "ATR OK (\(String(format: "%+.1f%%", changePct)))")
        }

        // Take-Profit Check (nur bei "fixed" oder "both")
        if mode == "fixed" || mode == "both" {
            if changePct >= takeProfitPct {
                return (true, "TP \(String(format: "%+.1f%%", changePct)) erreicht (Limit: \(String(format: "%.1f%%", takeProfitPct)))")
            }
        }

        // Fixed Stop-Loss Check (nur bei "fixed" oder "both")
        if mode == "fixed" || mode == "both" {
            if changePct <= -fixedStopLossPct {
                return (true, "SL \(String(format: "%+.1f%%", changePct)) ausgelöst (Limit: -\(String(format: "%.1f%%", fixedStopLossPct)))")
            }
        }

        // Trailing Stop Check (nur bei "trailing" oder "both") — regime-aware
        if mode == "trailing" || mode == "both" {
            let triggered = isStopTriggered(entryPrice: entryPrice, currentPrice: currentPrice,
                                             highWatermark: highWatermark, side: side)
            if triggered {
                let effectiveStop = regimeTrailingStopPct()
                let dropFromHigh: Double
                if side == "BUY" {
                    dropFromHigh = ((highWatermark - currentPrice) / highWatermark) * 100.0
                } else {
                    dropFromHigh = ((currentPrice - highWatermark) / highWatermark) * 100.0
                }
                return (true, "Trailing Stop \(String(format: "-%.1f%%", dropFromHigh)) vom Hoch (Limit: \(String(format: "%.1f%%", effectiveStop)) [\(currentRegime.rawValue)])")
            }
        }

        return (false, "OK (\(String(format: "%+.1f%%", changePct)))")
    }

    // MARK: - Strategy Performance Tracking

    /// Zeichnet das Ergebnis eines geschlossenen Trades auf
    public func recordTradeResult(strategy: String, pnl: Double, holdingMinutes: Double) {
        if strategyPerformance[strategy] == nil {
            strategyPerformance[strategy] = StrategyPerf(name: strategy)
        }
        strategyPerformance[strategy]?.totalTrades += 1
        strategyPerformance[strategy]?.totalPnL += pnl
        if pnl > 0 {
            strategyPerformance[strategy]?.wins += 1
            strategyPerformance[strategy]?.grossProfit += pnl
            if pnl > (strategyPerformance[strategy]?.bestTrade ?? 0) {
                strategyPerformance[strategy]?.bestTrade = pnl
            }
        } else {
            strategyPerformance[strategy]?.losses += 1
            strategyPerformance[strategy]?.grossLoss += abs(pnl)
            if pnl < (strategyPerformance[strategy]?.worstTrade ?? 0) {
                strategyPerformance[strategy]?.worstTrade = pnl
            }
        }
        // Running average
        let n = Double(strategyPerformance[strategy]?.totalTrades ?? 1)
        let prevAvg = strategyPerformance[strategy]?.avgHoldingMinutes ?? 0
        strategyPerformance[strategy]?.avgHoldingMinutes = prevAvg + (holdingMinutes - prevAvg) / n

        // Persist
        saveStrategyPerformance()
    }

    /// Gibt die Performance aller Strategien zurück
    public func getStrategyPerformance() -> [StrategyPerf] {
        Array(strategyPerformance.values).sorted { $0.totalPnL > $1.totalPnL }
    }

    private func saveStrategyPerformance() {
        if let data = try? JSONEncoder().encode(strategyPerformance) {
            UserDefaults.standard.set(data, forKey: "kobold.trading.strategyPerf")
        }
    }

    // MARK: - Daily PnL Tracking

    public func recordPnL(_ amount: Double) {
        let today = dateString()
        if today != dailyDate {
            dailyPnL = 0
            dailyDate = today
        }
        dailyPnL += amount
        weeklyPnL += amount

        // Weekly reset (Montag)
        let cal = Calendar.current
        let weekId = "\(cal.component(.yearForWeekOfYear, from: Date()))-W\(cal.component(.weekOfYear, from: Date()))"
        if weekId != weeklyDate {
            weeklyPnL = 0
            weeklyDate = weekId
        }
    }

    public func getDailyPnL() -> Double { dailyPnL }
    public func getWeeklyPnL() -> Double { weeklyPnL }

    // MARK: - Emergency Controls

    public func emergencyStop(reason: String) {
        isHalted = true
        haltReason = reason
        print("[RiskManager] EMERGENCY STOP: \(reason)")
    }

    public func resumeTrading() {
        isHalted = false
        haltReason = ""
        resetCircuitBreaker()
        print("[RiskManager] Trading resumed")
    }

    public func getIsHalted() -> (halted: Bool, reason: String) {
        (isHalted, haltReason)
    }

    // MARK: - Status

    public func getStatus() -> [String: Any] {
        var status: [String: Any] = [
            "halted": isHalted,
            "halt_reason": haltReason,
            "daily_pnl": dailyPnL,
            "weekly_pnl": weeklyPnL,
            "daily_date": dailyDate,
            "regime": currentRegime.rawValue,
            "max_trade_size_pct": regimeMaxTradeSizePct(),
            "max_trade_size_pct_base": maxTradeSizePct,
            "max_daily_loss_pct": maxDailyLossPct,
            "max_weekly_loss_pct": maxWeeklyLossPct,
            "max_open_positions": regimeMaxOpenPositions(),
            "max_open_positions_base": maxOpenPositions,
            "max_single_asset_pct": regimeMaxSingleAssetPct(),
            "max_single_asset_pct_base": maxSingleAssetPct,
            "trailing_stop_pct": regimeTrailingStopPct(),
            "trailing_stop_pct_base": trailingStopPct,
            "take_profit_pct": takeProfitPct,
            "fixed_stop_loss_pct": fixedStopLossPct,
            "tp_sl_mode": tpSlMode,
            "circuit_breakers_enabled": circuitBreakersEnabled,
            "circuit_breaker_reason": circuitBreakerReason,
        ]
        let cbActive: Bool = circuitBreakerPausedUntil != nil && Date() < (circuitBreakerPausedUntil ?? .distantPast)
        status["circuit_breaker_active"] = cbActive
        status["consecutive_stops"] = consecutiveStops
        status["atr_stop_multiplier"] = atrStopMultiplier
        status["atr_tp_multiplier"] = atrTakeProfitMultiplier
        // Strategy performance summary
        let perfCount = strategyPerformance.values.reduce(0) { $0 + $1.totalTrades }
        status["total_tracked_trades"] = perfCount
        return status
    }

    // MARK: - Zombie-Position-Decay (TP sinkt mit Haltezeit)

    /// Berechnet einen reduzierten Take-Profit basierend auf der Haltezeit.
    /// Positionen die zu lange nicht ins Plus kommen, werden schrittweise mit
    /// niedrigerem TP geschlossen, um Kapital freizugeben.
    ///
    /// - Erste 24h: Voller TP (z.B. 8%)
    /// - Alle 24h danach: TP sinkt um 1%
    /// - Minimum: Round-Trip-Fees + 0.5% (z.B. 2.4% + 0.5% = 2.9%)
    /// - Nach 7 Tagen: Position wird bei Break-Even + Fees geschlossen
    ///
    /// Returns: (decayedTP: Double, isZombie: Bool, message: String)
    public func zombieDecayTP(holdingHours: Double, feeRate: Double) -> (decayedTP: Double, isZombie: Bool, message: String) {
        let baseTP = takeProfitPct
        let roundTripFee = feeRate * 2 * 100  // z.B. 2.4%
        let minimumTP = roundTripFee + 0.5    // Minimum: Fees + 0.5% Gewinn

        // Keine Decay in den ersten 24 Stunden
        guard holdingHours > 24 else {
            return (baseTP, false, "")
        }

        // Decay: -1% pro 24h nach den ersten 24h
        let decayDays = Int((holdingHours - 24) / 24)
        let decayPct = Double(min(decayDays, 5))  // Max 5% Reduktion
        let decayedTP = max(baseTP - decayPct, minimumTP)

        // Nach 7 Tagen: Breakeven-Exit (nur Fees decken)
        if holdingHours > 168 {  // 7 × 24
            return (minimumTP, true, "Zombie-Position (>\(Int(holdingHours / 24))d) — TP auf \(String(format: "%.1f%%", minimumTP)) gesenkt (Breakeven-Exit)")
        }

        if decayPct > 0 {
            return (decayedTP, true, "TP-Decay: \(String(format: "%.1f%%", baseTP)) → \(String(format: "%.1f%%", decayedTP)) (Haltezeit \(Int(holdingHours / 24))d)")
        }

        return (baseTP, false, "")
    }

    // MARK: - Regime-Aware Risk Adjustments

    /// Setzt das aktuelle Marktregime (vom TradingEngine pro Zyklus aufgerufen)
    public func updateRegime(_ regime: MarketRegime) {
        currentRegime = regime
    }

    /// Dynamische max offene Positionen je Regime
    /// Bull: Basis × 2 (mehr Spielraum im Aufwärtstrend)
    /// Sideways: Basis (normal)
    /// Bear: max(1, Basis - 1) (konservativ)
    /// Crash: 0 (keine neuen Positionen)
    public func regimeMaxOpenPositions() -> Int {
        switch currentRegime {
        case .bull:    return maxOpenPositions * 2    // Bull: doppelt so viele erlaubt
        case .sideways, .unknown: return maxOpenPositions
        case .bear:    return max(1, maxOpenPositions - 1)
        case .crash:   return 0
        }
    }

    /// Dynamische max Asset-Konzentration (% des Portfolios pro Coin)
    /// Bull: 50% (Trends laufen lassen)
    /// Sideways: 30% (Standard)
    /// Bear: 15% (Klumpenrisiko minimieren)
    public func regimeMaxSingleAssetPct() -> Double {
        switch currentRegime {
        case .bull:    return min(maxSingleAssetPct * 1.5, 50.0)    // Bull: bis 50%
        case .sideways, .unknown: return maxSingleAssetPct          // Default: 30%
        case .bear:    return max(10.0, maxSingleAssetPct * 0.5)    // Bear: 15%
        case .crash:   return 10.0                                   // Crash: max 10%
        }
    }

    /// Dynamischer Trailing-Stop je Regime
    /// Bear: weiterer Stop (mehr Puffer gegen Volatilität)
    /// Bull: Standard (Gewinne laufen lassen, aber nicht zu weit)
    public func regimeTrailingStopPct() -> Double {
        switch currentRegime {
        case .bull:    return trailingStopPct                          // Standard
        case .sideways, .unknown: return trailingStopPct
        case .bear:    return trailingStopPct * 1.5                    // Bear: 50% weiter (z.B. 4% → 6%)
        case .crash:   return trailingStopPct * 2.0                    // Crash: doppelt (schneller raus)
        }
    }

    /// Dynamische Trade-Size je Regime
    /// Bear: halbe Positionsgröße
    public func regimeMaxTradeSizePct() -> Double {
        switch currentRegime {
        case .bull:    return maxTradeSizePct
        case .sideways, .unknown: return maxTradeSizePct
        case .bear:    return maxTradeSizePct * 0.5                    // Bear: halbe Size
        case .crash:   return 0
        }
    }

    // MARK: - Helpers

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func formatEUR(_ v: Double) -> String {
        String(format: "%.2f€", v)
    }
}
#endif
