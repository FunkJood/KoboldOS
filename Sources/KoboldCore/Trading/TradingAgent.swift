#if os(macOS)
import Foundation

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self > 0 ? self : fallback }
}

// MARK: - Trading Agent
// Standalone KI-Agent der von der TradingEngine getriggert wird.
// Eigener AgentLoop mit eigenem LLMRunner — blockiert die Chat-UI NICHT.
// Bei "beschäftigt" → Request wird in Queue eingereiht und nach aktuellem Run verarbeitet.

public actor TradingAgent {
    public static let shared = TradingAgent()

    private var agentLoop: AgentLoop?
    private var isProcessing = false
    private let log = TradingActivityLog.shared

    // Metadata für Trade-Logging (Agent-Trades → DB)
    private struct TradeMeta {
        let pair: String
        let side: String       // "BUY" oder "SELL"
        let strategy: String
        let amount: Double?    // EUR-Betrag (bei Buy)
    }

    // Queue für ausstehende Requests (wenn Agent beschäftigt)
    private struct PendingRequest {
        let prompt: String
        let context: String
        let tradeMeta: TradeMeta?
    }
    private var pendingQueue: [PendingRequest] = []
    private let maxQueueSize = 5

    private init() {}

    // MARK: - Lazy AgentLoop Setup

    private func getOrCreateLoop() async -> AgentLoop {
        if let loop = agentLoop { return loop }
        let loop = AgentLoop(agentID: "default", llmRunner: LLMRunner())
        await loop.setSkipApproval(true)
        agentLoop = loop
        ensureSkillInstalled()
        return loop
    }

    // MARK: - Settings Context (wird in jeden Prompt injiziert)

    private func buildSettingsContext() -> String {
        let d = UserDefaults.standard
        let confidence = d.object(forKey: "kobold.trading.confidenceThreshold") != nil
            ? d.double(forKey: "kobold.trading.confidenceThreshold") : 0.8
        let maxTradePct = d.object(forKey: "kobold.trading.maxTradeSize") != nil
            ? d.double(forKey: "kobold.trading.maxTradeSize") : 2.0
        let fixedTradeSize = d.object(forKey: "kobold.trading.fixedTradeSize") != nil
            ? d.double(forKey: "kobold.trading.fixedTradeSize") : 5.0
        let eurReserve = d.object(forKey: "kobold.trading.eurReserve") != nil
            ? d.double(forKey: "kobold.trading.eurReserve") : 5.0
        let maxDailyLoss = d.object(forKey: "kobold.trading.maxDailyLoss") != nil
            ? d.double(forKey: "kobold.trading.maxDailyLoss") : 3.0
        let maxPositions = d.object(forKey: "kobold.trading.maxOpenPositions") != nil
            ? d.integer(forKey: "kobold.trading.maxOpenPositions") : 3
        let tpPct = d.object(forKey: "kobold.trading.takeProfit") != nil
            ? d.double(forKey: "kobold.trading.takeProfit") : 8.0
        let slPct = d.object(forKey: "kobold.trading.fixedStopLoss") != nil
            ? d.double(forKey: "kobold.trading.fixedStopLoss") : 3.0
        let trailingStop = d.object(forKey: "kobold.trading.trailingStop") != nil
            ? d.double(forKey: "kobold.trading.trailingStop") : 4.0
        let tpSlMode = d.string(forKey: "kobold.trading.tpSlMode") ?? "trailing"
        let hodlCoin = d.string(forKey: "kobold.trading.hodlCoin") ?? ""
        let dcaEnabled = d.bool(forKey: "kobold.trading.dcaEnabled")
        let dcaDropPct = d.object(forKey: "kobold.trading.dcaDropPct") != nil
            ? d.double(forKey: "kobold.trading.dcaDropPct") : 5.0
        let dcaBuyAmount = d.object(forKey: "kobold.trading.dcaBuyAmount") != nil
            ? d.double(forKey: "kobold.trading.dcaBuyAmount") : 10.0
        let noLossSell = d.bool(forKey: "kobold.trading.noLossSell")

        let buySignalsOn = d.object(forKey: "kobold.trading.buySignalsEnabled") == nil || d.bool(forKey: "kobold.trading.buySignalsEnabled")
        let sellSignalsOn = d.object(forKey: "kobold.trading.sellSignalsEnabled") == nil || d.bool(forKey: "kobold.trading.sellSignalsEnabled")

        let strategies = ["momentum", "breakout", "mean_reversion", "trend_following", "scalping"]
        let activeStrategies = strategies.filter { name in
            d.object(forKey: "kobold.trading.strategies.\(name)") == nil || d.bool(forKey: "kobold.trading.strategies.\(name)")
        }

        return """
        == AKTUELLE USER-EINSTELLUNGEN (MÜSSEN beachtet werden!) ==
        Konfidenz-Schwelle: \(String(format: "%.0f%%", confidence * 100)) (NUR handeln wenn Signal ≥ \(String(format: "%.0f%%", confidence * 100)))
        Trade-Größe: \(String(format: "%.0f€", fixedTradeSize)) pro Kauf (fest)
        Max. Trade % vom Portfolio: \(String(format: "%.1f%%", maxTradePct))
        EUR-Reserve: \(String(format: "%.0f€", eurReserve)) (NICHT antasten — immer mindestens so viel EUR behalten!)
        Max. Tagesverlust: \(String(format: "%.1f%%", maxDailyLoss))
        Max. offene Positionen: \(maxPositions)
        Take-Profit: \(String(format: "%.1f%%", tpPct))
        Stop-Loss: \(String(format: "%.1f%%", slPct)) (Trailing: \(String(format: "%.1f%%", trailingStop)))
        TP/SL Modus: \(tpSlMode)
        HODL-Coin (NIEMALS verkaufen): \(hodlCoin.isEmpty ? "keiner" : hodlCoin)
        Nie im Minus verkaufen: \(noLossSell ? "JA (KEIN Verkauf wenn Position im Verlust!)" : "NEIN (Verkauf bei SL erlaubt)")
        DCA: \(dcaEnabled ? "AN (Nachkauf bei -\(String(format: "%.0f%%", dcaDropPct)), Betrag: \(String(format: "%.0f€", dcaBuyAmount)))" : "AUS")
        Buy-Signale: \(buySignalsOn ? "AKTIV" : "DEAKTIVIERT (keine neuen Käufe!)")
        Sell-Signale: \(sellSignalsOn ? "AKTIV" : "DEAKTIVIERT (nur TP/SL verkauft!)")
        Aktive Strategien: \(activeStrategies.joined(separator: ", "))
        Fee-Rate: \(String(format: "%.2f%%", (d.double(forKey: "kobold.trading.feeRate").nonZeroOr(0.005)) * 100)) pro Trade (Entry + Exit = \(String(format: "%.2f%%", (d.double(forKey: "kobold.trading.feeRate").nonZeroOr(0.005)) * 200)) Round-Trip)
        WICHTIG: Trade-Größe = min(fester Betrag, Portfolio × Max-%). Bei Kauf: Balance - Reserve = verfügbar.
        WICHTIG: Bei P&L-Berechnung IMMER Entry- UND Exit-Fee berücksichtigen! Break-Even = Entry + Round-Trip-Fee.
        """
    }

    // MARK: - Public API

    /// Einfache Evaluate-Variante für Self-Improvement und generische Analysen.
    public func evaluate(signal: String, context: String) async -> String {
        return await processRequest(prompt: context, context: "Self-Improve: \(signal)")
    }

    /// Engine hat ein Signal generiert — Agent soll bewerten und ggf. ausführen.
    /// Bekommt vollen Marktkontext: Backtests, Forecasts, Portfolio, Regime, Daily P&L.
    /// ownerStrategy: Welche Strategie die aktuelle Position eröffnet hat.
    /// positionContext: Info über bestehende Position (bei Nachkauf-Evaluierung).
    public func evaluate(signal: TradingSignal, pair: String, currentPrice: Double,
                         regime: String, costBasis: Double?, portfolio: String,
                         ownerStrategy: String? = nil,
                         positionContext: String? = nil) async -> String {

        let pnlInfo: String
        if let cb = costBasis, cb > 0 {
            let pnlPct = ((currentPrice - cb) / cb) * 100
            pnlInfo = "Cost Basis: \(String(format: "%.2f€", cb)), P&L: \(String(format: "%+.1f%%", pnlPct))"
        } else {
            pnlInfo = "Cost Basis: unbekannt"
        }

        let strategyInfo: String
        if let owner = ownerStrategy {
            strategyInfo = "Position eröffnet durch: \(owner) (beachte Zeithorizont!)"
        } else {
            strategyInfo = "Position-Strategie: unbekannt (extern oder vor Engine-Start)"
        }

        let settings = buildSettingsContext()
        let marketContext = await buildMarketContext(pair: pair)

        // Nachkauf-Warnung wenn Position schon existiert
        let positionWarning = positionContext ?? ""

        let prompt = """
        Die Trading Engine hat folgendes Signal generiert:

        Signal: \(signal.action.rawValue) \(pair) (Konfidenz: \(String(format: "%.0f%%", signal.confidence * 100)))
        Signal-Strategie: \(signal.strategy) (\(strategyDescription(signal.strategy)))
        Grund: \(signal.reason)
        Regime: \(regime) | Aktueller Preis: \(String(format: "%.2f€", currentPrice))
        \(pnlInfo)
        \(strategyInfo)
        Portfolio: \(portfolio)
        \(positionWarning)

        \(settings)

        \(marketContext)

        == STRATEGIE-KONTEXT ==
        Handele gemäß der Strategie "\(signal.strategy)":
        \(strategyGuidance(signal.strategy))

        == DEINE AUFGABE ==
        Analysiere ALLE oben stehenden Daten (Backtests, Forecasts, Portfolio, Marktlage, Regime, bestehende Positionen).
        Triff die bestmögliche Entscheidung wie ein erfahrener Daytrader:
        - Prüfe EUR-Balance (coinbase_api action "accounts") — ziehe die Reserve ab!
        - Beachte die Konfidenz-Schwelle aus den Einstellungen
        - Bei Kauf: kaufe für genau den eingestellten Trade-Betrag (nicht mehr!)
        - Bei Nachkauf: Nur wenn der Preis deutlich attraktiver geworden ist UND die Gesamtposition nicht zu groß wird!
          Frage dich: Würde ein Profi-Trader hier nachkaufen oder ist die Position schon groß genug?
        - Bei Verkauf: beachte die Strategie der Position und Marktprognosen
        - Wenn Backtests für diese Strategie schlecht sind, sei skeptischer
        - Wenn Prognosen gegen das Signal sprechen, lehne ab
        Führe den Trade aus mit coinbase_api (action: \(signal.action == .buy ? "buy" : "sell")) oder lehne begründet ab.
        Antworte kompakt (max 3 Sätze).
        """

        let context = "Signal \(signal.action.rawValue) \(pair) [\(signal.strategy)]"
        let meta = TradeMeta(
            pair: pair, side: signal.action.rawValue,
            strategy: signal.strategy, amount: nil
        )

        if isProcessing {
            return await enqueue(prompt: prompt, context: context, tradeMeta: meta)
        }

        return await processRequest(prompt: prompt, context: context, tradeMeta: meta)
    }

    // MARK: - Market Context Builder (Backtests + Forecasts + Portfolio + Positionen)

    /// Baut den vollständigen Marktkontext für den Agent.
    /// Bezieht Backtests, Forecasts, offene Positionen, Daily P&L, Holding-Monitor-Info ein.
    private func buildMarketContext(pair: String) async -> String {
        var sections: [String] = []

        // 1. Backtests — Performance der Strategien (pair-spezifisch + Überblick)
        let pairBacktests = await TradingEngine.shared.getBacktestsForPair(pair)
        let allBacktests = await TradingEngine.shared.getLatestBacktests()
        if !pairBacktests.isEmpty || !allBacktests.isEmpty {
            var bt = "== BACKTEST-ERGEBNISSE (letzte 14 Tage) =="

            // Primär: Backtests für das aktuelle Pair
            if !pairBacktests.isEmpty {
                bt += "\n--- \(pair) ---"
                for (key, result) in pairBacktests.sorted(by: { $0.key < $1.key }) {
                    let stratName = key.split(separator: ":").first.map(String.init) ?? key
                    bt += "\n\(stratName): Return \(String(format: "%+.1f%%", result.totalReturn)), WinRate \(String(format: "%.0f%%", result.winRate)), Sharpe \(String(format: "%.2f", result.sharpeRatio)), MaxDD \(String(format: "%.1f%%", result.maxDrawdown)), Trades: \(result.totalTrades)"
                }
            }

            // Sekundär: Andere Paare (kompakt, als Vergleich)
            let otherBacktests = allBacktests.filter { !$0.value.pair.isEmpty && $0.value.pair != pair }
            if !otherBacktests.isEmpty {
                // Gruppiere nach Pair
                var byPair: [String: [(String, BacktestResult)]] = [:]
                for (key, result) in otherBacktests {
                    byPair[result.pair, default: []].append((key, result))
                }
                for (otherPair, results) in byPair.sorted(by: { $0.key < $1.key }).prefix(3) {
                    bt += "\n--- \(otherPair) (Vergleich) ---"
                    for (key, result) in results.sorted(by: { $0.0 < $1.0 }) {
                        let stratName = key.split(separator: ":").first.map(String.init) ?? key
                        bt += "\n\(stratName): \(String(format: "%+.1f%%", result.totalReturn)), WR \(String(format: "%.0f%%", result.winRate))"
                    }
                }
            }

            bt += "\nHINWEIS: Strategien mit negativem Return oder Sharpe < 0.5 sind aktuell unrentabel!"
            sections.append(bt)
        }

        // 2. Forecasts
        let forecasts = await TradingEngine.shared.getForecasts(pair: pair)
        if !forecasts.isEmpty {
            var fc = "== PROGNOSEN für \(pair) =="
            for f in forecasts.prefix(3) {
                fc += "\n\(f.horizon): \(f.direction) \(String(format: "%+.1f%%", f.targetPct)) Konfidenz \(String(format: "%.0f%%", f.confidence * 100)) — \(f.factors.joined(separator: ", "))"
            }
            fc += "\nHINWEIS: Prognosen die dem Signal widersprechen erhöhen das Risiko!"
            sections.append(fc)
        }

        // 3. Regime
        let currentRegime = await TradingEngine.shared.getRegime(pair: pair)
        sections.append("== MARKTREGIME == \(pair): \(currentRegime.rawValue)")

        // 4. Engine-Status (offene Positionen, Daily P&L)
        let status = await TradingEngine.shared.getStatus()
        var statusStr = "== ENGINE-STATUS =="
        statusStr += "\nPortfolio: \(String(format: "%.2f€", status.portfolioValue))"
        statusStr += "\nTages-P&L: \(String(format: "%+.2f%%", status.dailyPnL))"
        let maxPos = UserDefaults.standard.integer(forKey: "kobold.trading.maxOpenPositions")
        statusStr += "\nOffene Positionen: \(status.openPositions)/\(maxPos > 0 ? maxPos : 5)"
        if status.halted { statusStr += "\nACHTUNG: Trading gehaltet! Grund: \(status.haltReason)" }
        sections.append(statusStr)

        // 5. Holding Monitor Info (Entry-Preis, Höchstkurs, Strategie pro Coin)
        let monitors = await TradingEngine.shared.getHoldingMonitorInfo()
        if !monitors.isEmpty {
            var hm = "== ÜBERWACHTE POSITIONEN =="
            for (currency, info) in monitors.sorted(by: { $0.key < $1.key }) {
                hm += "\n\(currency): Entry \(String(format: "%.2f€", info.entryPrice)), HWM \(String(format: "%.2f€", info.highWatermark)), Regime \(info.regime), Strategie: \(info.strategy ?? "unbekannt")"
            }
            sections.append(hm)
        }

        // 6. Forecast-Accuracy (7 Tage)
        let acc1h = (try? await TradingDatabase.shared.getForecastAccuracy(horizon: "1h", days: 7)) ?? (0, 0, 0.0)
        let acc4h = (try? await TradingDatabase.shared.getForecastAccuracy(horizon: "4h", days: 7)) ?? (0, 0, 0.0)
        if acc1h.0 > 0 || acc4h.0 > 0 {
            var accStr = "== FORECAST-ACCURACY (7 Tage) =="
            if acc1h.0 > 0 {
                accStr += "\n1h: \(String(format: "%.0f%%", acc1h.2 * 100)) (\(acc1h.0) Forecasts, \(acc1h.1) korrekt)"
            }
            if acc4h.0 > 0 {
                accStr += "\n4h: \(String(format: "%.0f%%", acc4h.2 * 100)) (\(acc4h.0) Forecasts, \(acc4h.1) korrekt)"
            }
            accStr += "\nHINWEIS: Bei Accuracy <50% sind Prognosen unzuverlässig — sei skeptischer bei Forecast-basierten Signalen!"
            sections.append(accStr)
        }

        // 7. Strategie Hot/Cold Status
        let multipliers = await StrategyEngine.shared.getMultipliers()
        let stratPerfs = await TradingRiskManager.shared.getStrategyPerformance()
        if !stratPerfs.isEmpty {
            var hotCold = "== STRATEGIE-STATUS =="
            for p in stratPerfs {
                let mul = multipliers[p.name] ?? 1.0
                let status: String
                if p.winRate >= 60 { status = "HOT" }
                else if p.winRate <= 40 { status = "COLD" }
                else { status = "NEUTRAL" }
                hotCold += "\n\(p.name): \(status) (WR: \(String(format: "%.0f%%", p.winRate)), \(p.totalTrades) Trades, Multiplier: \(String(format: "%.2f", mul)))"
            }
            hotCold += "\nHINWEIS: COLD-Strategien haben reduzierte Confidence. HOT-Strategien sind aktuell profitabel."
            sections.append(hotCold)
        }

        // 8. Letzte Trades (für Kontext: was wurde kürzlich gemacht?)
        let recentTrades = (try? await TradingDatabase.shared.getTradeHistory(limit: 5)) ?? []
        if !recentTrades.isEmpty {
            var rt = "== LETZTE 5 TRADES =="
            for t in recentTrades {
                let pnlStr = t.pnl.map { String(format: "%+.2f€", $0) } ?? "offen"
                rt += "\n\(String(t.timestamp.prefix(16))) \(t.side) \(t.pair) @ \(String(format: "%.2f€", t.price)) P&L: \(pnlStr) [\(t.strategy)]"
            }
            sections.append(rt)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Strategy Knowledge (für Agent-Prompts)

    private func strategyDescription(_ name: String) -> String {
        switch name {
        case "scalping": return "Kurzfrist-Strategie, Minuten bis Stunden, schnelle Ein-/Ausstiege"
        case "momentum": return "Mittelfrist, RSI/MACD-basiert, Stunden bis Tage"
        case "breakout": return "Mittelfrist, Ausbruch über Widerstände, Stunden bis Tage"
        case "mean_reversion": return "Mittelfrist, Rückkehr zum Mittelwert, Stunden bis Tage"
        case "trend_following": return "Langfrist-Strategie, EMA-Crossover, Tage bis Wochen"
        default: return "Custom-Strategie"
        }
    }

    private func strategyGuidance(_ name: String) -> String {
        switch name {
        case "scalping":
            return """
            - Schnelle Gewinne mitnehmen (1-3% Ziel)
            - Enge Stop-Loss (max 1-2%)
            - Nicht zu lange halten — Scalping-Positionen sind kurzfristig!
            - Volumen und BB-Squeeze beachten
            - Bei seitwärts-Markt am profitabelsten
            """
        case "momentum":
            return """
            - RSI überverkauft (<30) = Kaufgelegenheit, überkauft (>70) = Verkauf
            - MACD-Crossover bestätigt Richtung
            - Trend mit EMA-Alignment verifizieren (9>21>50 = bullish)
            - Mittlere Haltezeit, nicht bei erstem Rücksetzer verkaufen
            - Volumen-Bestätigung erhöht Zuverlässigkeit
            """
        case "breakout":
            return """
            - Kauf bei Ausbruch über Perioden-Hoch mit Volumen-Bestätigung
            - Verkauf bei Ausbruch unter Perioden-Tief
            - Falsche Ausbrüche vermeiden: Volumen muss >1.5x Durchschnitt sein
            - Stop-Loss knapp unter dem Breakout-Level setzen
            - Trend-Richtung (EMA-Slope) muss den Breakout unterstützen
            """
        case "mean_reversion":
            return """
            - Kauf wenn Preis unter unterem Bollinger Band (überverkauft)
            - Verkauf wenn Preis über oberem Bollinger Band (überkauft)
            - Am besten in Seitwärts-Märkten (Regime: SIDEWAYS)
            - In Trend-Märkten reduzierte Konfidenz
            - RSI als Bestätigung nutzen
            """
        case "trend_following":
            return """
            - Langfristige Trends reiten: NICHT bei kleinen Rücksetzern verkaufen!
            - Golden Cross (EMA9 > EMA21) = Kaufsignal
            - Death Cross (EMA9 < EMA21) = Verkaufssignal
            - Nur verkaufen wenn der Trend wirklich dreht (mehrere Indikatoren)
            - Größere Stop-Loss akzeptabel (3-5%) da Haltedauer länger
            - Scalping-Rausch ignorieren — Geduld ist Trumpf
            """
        default:
            return "Handele nach bestem Ermessen basierend auf den Indikatoren."
        }
    }

    /// Verkauf einer Position (von UI-Button oder TP/SL).
    /// holdingInfo: Optional — wird von monitorExternalHoldings() mitgegeben damit der Agent
    /// auch extern gekaufte Positionen sieht (nicht nur Engine-DB-Trades).
    public func executeSell(currency: String, reason: String,
                            holdingInfo: (balance: Double, nativeValue: Double, entryPrice: Double)? = nil) async -> String {
        let settings = buildSettingsContext()
        let pair = "\(currency)-EUR"
        let marketContext = await buildMarketContext(pair: pair)

        // Externe Holding-Info für den Agent-Kontext aufbereiten
        var holdingContext = ""
        if let h = holdingInfo {
            let pnlPct = h.entryPrice > 0 ? ((h.nativeValue / h.balance - h.entryPrice) / h.entryPrice) * 100 : 0
            holdingContext = """

            == COINBASE-POSITION (VERIFIZIERT) ==
            \(currency): \(String(format: "%.6f", h.balance)) Stück
            Wert: \(String(format: "%.2f€", h.nativeValue))
            Einkaufspreis: \(String(format: "%.4f€", h.entryPrice))
            P&L: \(String(format: "%+.1f%%", pnlPct))
            WICHTIG: Diese Position existiert auf Coinbase — auch wenn sie nicht in der Engine-DB ist!
            """
        }

        let prompt = """
        Verkaufe die gesamte \(currency)-Position.
        Grund: \(reason)

        \(settings)

        \(marketContext)
        \(holdingContext)

        WICHTIG: Die Position existiert garantiert auf Coinbase (vom Risk-Management verifiziert).
        Führe den Verkauf aus ohne die Position erneut zu prüfen.
        Nutze coinbase_api mit action "sell" und currency_pair "\(pair)".
        Setze amount auf "all" um alles zu verkaufen.
        Bestätige den Verkauf oder melde den Fehler.
        Antworte kompakt (max 2 Sätze).
        """

        let meta = TradeMeta(pair: pair, side: "SELL", strategy: "manual", amount: nil)

        if isProcessing {
            return await enqueue(prompt: prompt, context: "Sell \(currency)", tradeMeta: meta)
        }

        return await processRequest(prompt: prompt, context: "Sell \(currency)", tradeMeta: meta)
    }

    /// Kauf (DCA oder Signal).
    public func executeBuy(pair: String, amount: Double, reason: String) async -> String {
        let settings = buildSettingsContext()
        let marketContext = await buildMarketContext(pair: pair)

        let prompt = """
        Kaufe \(pair) für \(String(format: "%.2f€", amount)).
        Grund: \(reason)

        \(settings)

        \(marketContext)

        Prüfe die Marktlage, Backtests und Prognosen oben.
        WICHTIG: Prüfe zuerst die EUR-Balance und ziehe die Reserve ab!
        Wenn der Kauf sinnvoll ist: Nutze coinbase_api mit action "buy", currency_pair "\(pair)", amount "\(String(format: "%.2f", amount))".
        Bestätige den Kauf oder lehne begründet ab.
        Antworte kompakt (max 2 Sätze).
        """

        let meta = TradeMeta(pair: pair, side: "BUY", strategy: "dca", amount: amount)

        if isProcessing {
            return await enqueue(prompt: prompt, context: "Buy \(pair)", tradeMeta: meta)
        }

        return await processRequest(prompt: prompt, context: "Buy \(pair)", tradeMeta: meta)
    }

    // MARK: - Queue Management

    private func enqueue(prompt: String, context: String, tradeMeta: TradeMeta? = nil) async -> String {
        if pendingQueue.count >= maxQueueSize {
            await log.add("[KI] Queue voll (\(maxQueueSize)) — \(context) verworfen", type: .info)
            return "Queue voll"
        }
        pendingQueue.append(PendingRequest(prompt: prompt, context: context, tradeMeta: tradeMeta))
        await log.add("[KI] \(context) in Queue eingereiht (Position \(pendingQueue.count))", type: .agent)
        return "In Queue (Position \(pendingQueue.count))"
    }

    private func processQueue() async {
        while !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            await log.add("[KI] Queue: verarbeite \(next.context)...", type: .agent)
            let _ = await runAgent(prompt: next.prompt, context: next.context, tradeMeta: next.tradeMeta)
        }
    }

    // MARK: - Request Processing

    private func processRequest(prompt: String, context: String, tradeMeta: TradeMeta? = nil) async -> String {
        isProcessing = true
        let result = await runAgent(prompt: prompt, context: context, tradeMeta: tradeMeta)
        isProcessing = false

        // Queue abarbeiten
        await processQueue()

        return result
    }

    // MARK: - Agent Runner

    private func runAgent(prompt: String, context: String, tradeMeta: TradeMeta? = nil) async -> String {
        await log.add("[KI] \(context) — Agent wird gefragt...", type: .agent)

        let loop = await getOrCreateLoop()

        do {
            let result = try await loop.run(userMessage: prompt)
            let answer = result.finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            if result.success {
                // Volle Antwort im Log (nicht kürzen — User will alles lesen)
                await log.add("[KI] \(context): \(answer)", type: .agent)

                // Trade in DB loggen wenn erfolgreich — mit Agent-Begründung in notes
                if let meta = tradeMeta {
                    await logAgentTrade(answer: answer, meta: meta)
                }
            } else {
                await log.add("[KI] \(context) fehlgeschlagen: \(answer)", type: .error)
            }

            await loop.clearHistory()
            return answer
        } catch {
            let errMsg = "Agent-Fehler: \(error.localizedDescription)"
            await log.add("[KI] \(errMsg)", type: .error)
            await loop.clearHistory()
            return errMsg
        }
    }

    // MARK: - Agent Trade Logging

    /// Verifiziert ob der Agent tatsächlich eine Order platziert hat (Order-ID-basiert statt Keywords).
    /// Prüft die letzten Coinbase-Orders und vergleicht mit dem Zeitfenster des Agent-Runs.
    private func logAgentTrade(answer: String, meta: TradeMeta) async {
        let lower = answer.lowercased()

        // Schneller Ausschluss: Wenn Agent klar abgelehnt hat, keine Order-Prüfung nötig
        let failureKeywords = ["fehler", "error", "abgelehnt", "rejected", "nicht genug",
                               "insufficient", "failed", "scheitert", "nicht möglich",
                               "verworfen", "nicht ausgeführt", "nicht handeln", "kein kauf",
                               "kein verkauf", "abgebrochen", "cancelled", "nicht sinnvoll",
                               "lehne ab", "nicht kaufen", "nicht verkaufen"]
        if failureKeywords.contains(where: { lower.contains($0) }) { return }

        // PRIMÄR: Order-ID-basierte Verifizierung über Coinbase API
        // Hole die letzten Orders der letzten 2 Minuten und prüfe ob eine neue Order existiert
        let verifiedOrder = await verifyRecentOrder(pair: meta.pair, side: meta.side)

        let price: Double
        let size: Double
        let fee: Double
        let orderId: String?

        if let order = verifiedOrder {
            // Echte Order gefunden → verwende echte Fill-Daten
            price = order.averagePrice
            size = order.filledSize
            fee = order.fee
            orderId = order.orderId
            await log.add("[KI] Order verifiziert: \(order.orderId.prefix(12)) Fill: \(String(format: "%.6f", size)) @ \(String(format: "%.2f€", price)), Fee: \(String(format: "%.4f€", fee))", type: .trade)
        } else {
            // FALLBACK: Keyword-basierte Erkennung (wenn API-Check fehlschlägt)
            let successKeywords = ["gekauft", "verkauft", "ausgeführt", "executed", "order",
                                   "erfolgreich", "bestätigt", "confirmed", "bought", "sold"]
            guard successKeywords.contains(where: { lower.contains($0) }) else { return }

            // Spot-Preis als Fallback
            price = await TradeExecutor.shared.getSpotPrice(pair: meta.pair) ?? 0
            if meta.side == "BUY" {
                let tradeAmount = meta.amount ?? UserDefaults.standard.double(forKey: "kobold.trading.fixedTradeSize")
                size = price > 0 ? (tradeAmount > 0 ? tradeAmount : 5.0) / price : 0
            } else {
                let balances = await TradeExecutor.shared.getAccountBalances()
                let currency = meta.pair.split(separator: "-").first.map(String.init) ?? ""
                size = balances.first(where: { $0.currency == currency })?.balance ?? 0
            }
            fee = 0
            orderId = nil
            await log.add("[KI] Order NICHT verifiziert — Keyword-Fallback verwendet", type: .info)
        }

        guard price > 0 && size > 0 else { return }

        // Agent-Begründung extrahieren (erste 200 Zeichen der Antwort als Zusammenfassung)
        let agentReason = String(answer.prefix(200))

        let trade = TradeRecord(
            pair: meta.pair, side: meta.side, size: size, price: price,
            strategy: "KI:\(meta.strategy)",
            regime: "",
            confidence: 0,
            status: meta.side == "BUY" ? "OPEN" : "CLOSED",
            orderId: orderId,
            notes: agentReason
        )

        do {
            try await TradingDatabase.shared.logTrade(trade)
            await log.add("[KI] Trade geloggt: \(meta.side) \(meta.pair) @ \(String(format: "%.2f€", price)) [\(meta.strategy)]", type: .trade)
        } catch {
            await log.add("[KI] Trade-Logging fehlgeschlagen: \(error.localizedDescription)", type: .error)
        }
    }

    /// Prüft ob in den letzten 2 Minuten eine Order für das gegebene Pair/Side auf Coinbase erstellt wurde.
    private func verifyRecentOrder(pair: String, side: String) async -> TradeExecutor.OrderFill? {
        // Hole letzte Orders via Coinbase API
        let orders = await getRecentOrders(pair: pair, side: side)
        // Die neueste gefüllte Order in den letzten 120 Sekunden
        return orders.first
    }

    /// Holt die letzten Orders von Coinbase und filtert nach Pair/Side/Zeitfenster (letzte 2 Minuten).
    private func getRecentOrders(pair: String, side: String) async -> [TradeExecutor.OrderFill] {
        let orders = await TradeExecutor.shared.listRecentOrders(
            productId: pair, side: side, windowSeconds: 120
        )
        return orders
    }

    // MARK: - Skill Installation

    private func ensureSkillInstalled() {
        let skillDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/Skills")
        let skillFile = skillDir.appendingPathComponent("trading_engine.md")

        // Immer aktualisieren damit neue Features ankommen
        let content = """
        # Trading Engine Skill — Profi-Daytrader

        Du bist der autonome Trading-Agent von KoboldOS. Du handelst wie ein erfahrener Daytrader.
        Die Trading Engine triggert dich bei Signalen. Du bewertest sie professionell und führst aus.

        ## Deine Aufgaben
        1. Bewerte das Signal (Marktlage, Regime, P&L, Konfidenz vs. User-Schwelle)
        2. Beachte den STRATEGIE-KONTEXT — jede Strategie hat einen anderen Zeithorizont!
        3. Nutze `trading_tool` mit action "status" für Engine-Daten (Regime, offene Positionen, P&L)
        4. Nutze `coinbase_api` für Kauf/Verkauf
        5. Begründe deine Entscheidung kompakt (max 3 Sätze)

        ## WICHTIGE Regeln
        - Beachte IMMER die User-Einstellungen die im Prompt stehen
        - Konfidenz-Schwelle: Handele NUR wenn Signal-Konfidenz ≥ der eingestellten Schwelle
        - Trade-Größe: Kaufe für genau den eingestellten EUR-Betrag (nicht mehr!)
        - EUR-Reserve: Berechne verfügbar = EUR-Balance - Reserve. NICHT unter Reserve fallen!
        - HODL-Coin: NIEMALS den eingestellten HODL-Coin verkaufen
        - Prüfe IMMER verfügbare Balance via `coinbase_api` action "accounts" vor dem Handeln
        - Bei Unsicherheit: NICHT handeln, begründe warum
        - Antworte auf Deutsch

        ## Strategien & Zeithorizonte (KRITISCH!)

        Die Engine verwendet 5 Strategien mit VERSCHIEDENEN Zeithorizonten.
        Jeder Trade gehört zu seiner Strategie — handle entsprechend!

        ### Kurzfrist: Scalping (Minuten bis Stunden)
        - Schnelle Ein-/Ausstiege, 1-3% Gewinnziel
        - RSI-Dips + BB-Squeeze + kurzfristiges Momentum
        - Enge Stop-Loss (1-2%), nicht zu lange halten!
        - Bei Seitwärts-Markt am profitabelsten
        - NIEMALS eine Trend-Following-Position schließen!

        ### Mittelfrist: Momentum, Breakout, Mean Reversion (Stunden bis Tage)
        - **Momentum**: RSI überverkauft/überkauft + MACD Crossover + EMA-Alignment
        - **Breakout**: Ausbruch über Perioden-Hoch/Tief + Volumen-Bestätigung (>1.5x)
        - **Mean Reversion**: Bollinger Band Extreme → Rückkehr zum Mittelwert
        - Mittlere Haltezeit, nicht bei erstem Rücksetzer panisch verkaufen
        - Stop-Loss 2-3%, Take-Profit 3-5%

        ### Langfrist: Trend Following (Tage bis Wochen)
        - EMA-Crossover (Golden Cross / Death Cross) als Hauptsignal
        - Trends REITEN — kleine Rücksetzer NICHT als Verkaufssignal werten!
        - Nur verkaufen wenn Trend wirklich dreht (mehrere Indikatoren bestätigen)
        - Größere Stop-Loss akzeptabel (3-5%) da längere Haltedauer
        - Geduld ist Trumpf — Scalping-Rausch ignorieren

        ## Strategie-Kompatibilität
        - Scalping-SELL darf KEINE Trend-Following oder Momentum-Position schließen!
        - Nur kompatible Strategien dürfen eine Position schließen
        - TP/SL (Risk Management) übersteuert immer — das ist Sicherheitsnetz
        - Wenn "Position eröffnet durch: X" im Prompt steht, handle entsprechend X!

        ## Profi-Daytrader Regeln
        1. Verluste begrenzen, Gewinne laufen lassen
        2. Nie gegen den Trend handeln (Regime beachten!)
        3. Volumen ist der wichtigste Bestätigungsindikator
        4. FOMO vermeiden — besser eine Gelegenheit verpassen als in eine Falle tappen
        5. Position-Sizing strikt einhalten (nie mehr als eingestellt!)
        6. Bei Crash-Regime: NICHT kaufen, Cash halten
        7. DCA nur bei fundamentaler Überzeugung und als Strategie, nicht aus Panik

        ## Verfügbare Tools
        - `coinbase_api`: accounts, spot_price, buy, sell, limit_buy, limit_sell, list_orders, preview_buy, preview_sell
        - `trading_tool`: status, analytics, forecast, trade_history, regime, **backtest**
        - `settings_read`: Engine-Settings lesen/ändern (kobold.trading.*)
        - `web_search`: Krypto-News recherchieren bei Unsicherheit

        ## Backtests on Demand
        Du kannst jederzeit eigene Backtests durchführen wenn du unsicher bist:
        ```
        trading_tool action="backtest" strategy="momentum" pair="BTC-EUR" days=14
        ```
        Verfügbare Strategien: momentum, breakout, mean_reversion, trend_following, scalping
        Nutze Backtests um zu prüfen ob eine Strategie im aktuellen Markt profitabel ist!

        ## Einstellungen anpassen
        Du darfst NUR folgende Settings in diesen Grenzen ändern:
        - kobold.trading.confidenceThreshold: min 0.50, max 0.95
        - kobold.trading.fixedTradeSize: min 1.0, max 50.0
        - kobold.trading.takeProfit: min 2.0, max 20.0
        - kobold.trading.fixedStopLoss: min 1.0, max 10.0
        - kobold.trading.trailingStop: min 1.0, max 10.0
        VERBOTEN: eurReserve, maxDailyLoss, maxWeeklyLoss, autoTrade, agentEnabled
        Mache das NUR wenn du einen guten Grund hast und erkläre warum.
        """

        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try? content.write(to: skillFile, atomically: true, encoding: .utf8)
    }
}
#endif
