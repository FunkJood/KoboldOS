#if os(macOS)
import Foundation

// MARK: - Trading Tool (Agent Interface)

public struct TradingTool: Tool {
    public let name = "trading"
    public let description = """
        Krypto-Trading-System: Status, Analytics, Forecasts, Positionen, Backtest abrufen. \
        Aktionen: status (Engine-Status), analytics (Performance-Metriken), \
        forecast (Markt-Prognose, braucht pair z.B. BTC-EUR), \
        trade_history (letzte Trades, optional limit), \
        open_positions (offene Positionen), \
        start (Engine starten), stop (Engine stoppen), \
        emergency_stop (Notfall-Halt, schließt alle Positionen), \
        backtest (Strategie backtesten, braucht strategy + pair + days), \
        products (alle handelbaren Coins), \
        staking (Staking-Rewards anzeigen), \
        regime (Markt-Regime für ein Paar, braucht pair), \
        create_strategy (Custom-Strategie erstellen, braucht name + rules JSON + optional regime_filter), \
        list_strategies (alle Strategien auflisten), \
        delete_strategy (Custom-Strategie löschen, braucht name).
        """
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion", enumValues: [
                "status", "analytics", "forecast", "trade_history", "open_positions",
                "start", "stop", "emergency_stop", "backtest", "products", "staking", "regime",
                "create_strategy", "list_strategies", "delete_strategy"
            ], required: true),
            "pair": ToolSchemaProperty(type: "string", description: "Handelspaar z.B. BTC-EUR, ETH-EUR"),
            "strategy": ToolSchemaProperty(type: "string", description: "Strategie-Name"),
            "days": ToolSchemaProperty(type: "string", description: "Anzahl Tage für Backtest (z.B. 30)"),
            "limit": ToolSchemaProperty(type: "string", description: "Anzahl Ergebnisse (z.B. 20)"),
            "name": ToolSchemaProperty(type: "string", description: "Name der Custom-Strategie"),
            "rules": ToolSchemaProperty(type: "string", description: "JSON-Array mit Regeln: [{\"indicator\":\"rsi\",\"condition\":\"below\",\"value\":30,\"weight\":0.6,\"action\":\"buy\"}]"),
            "regime_filter": ToolSchemaProperty(type: "string", description: "Komma-getrennte Regime-Liste: BULL,SIDEWAYS,BEAR")
        ], required: ["action"])
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        switch action {

        case "status":
            let status = await TradingEngine.shared.getStatus()
            return formatStatus(status)

        case "analytics":
            let analytics = await TradingEngine.shared.getAnalytics(period: "all")
            return formatAnalytics(analytics)

        case "forecast":
            let pair = arguments["pair"] ?? "BTC-EUR"
            let forecasts = await TradingEngine.shared.getForecasts(pair: pair)
            if forecasts.isEmpty {
                return "Keine Forecasts verfügbar für \(pair). Ist die Trading Engine aktiv?"
            }
            return formatForecasts(pair: pair, forecasts: forecasts)

        case "trade_history":
            let limit = Int(arguments["limit"] ?? "20") ?? 20
            let trades = (try? await TradingDatabase.shared.getTradeHistory(limit: limit)) ?? []
            if trades.isEmpty { return "Keine Trades vorhanden." }
            return formatTradeHistory(trades)

        case "open_positions":
            let trades = (try? await TradingDatabase.shared.getOpenTrades()) ?? []
            if trades.isEmpty { return "Keine offenen Positionen." }
            return formatOpenPositions(trades)

        case "start":
            let isRunning = await TradingEngine.shared.getIsRunning()
            if isRunning { return "Trading Engine läuft bereits." }
            await TradingEngine.shared.start()
            return "Trading Engine gestartet."

        case "stop":
            await TradingEngine.shared.stop()
            return "Trading Engine gestoppt."

        case "emergency_stop":
            await TradingEngine.shared.emergencyStop()
            return "EMERGENCY STOP ausgeführt. Alle Positionen geschlossen. Trading gehaltet."

        case "backtest":
            let strategy = arguments["strategy"] ?? "momentum"
            let pair = arguments["pair"] ?? "BTC-EUR"
            let days = Int(arguments["days"] ?? "30") ?? 30
            let result = await TradingEngine.shared.runBacktest(strategyName: strategy, pair: pair, days: days)
            if let r = result {
                return formatBacktest(r)
            }
            return "Backtest fehlgeschlagen — nicht genug historische Daten oder ungültige Strategie."

        case "products":
            let products = await TradeExecutor.shared.getAllProducts()
            if products.isEmpty { return "Keine Produkte gefunden. Coinbase API-Key konfiguriert?" }
            let eurProducts = products.filter { $0.quoteCurrency == "EUR" && $0.status == "online" }
            var result = "Handelbare EUR-Paare (\(eurProducts.count)):\n"
            for p in eurProducts.prefix(50) {
                result += "• \(p.id) (\(p.baseCurrency)/\(p.quoteCurrency))\n"
            }
            if products.count > eurProducts.count {
                result += "\nGesamt: \(products.count) Paare (inkl. USD, USDT, etc.)"
            }
            return result

        case "staking":
            return await TradeExecutor.shared.getStakingRewards()

        case "regime":
            let pair = arguments["pair"] ?? "BTC-EUR"
            let regime = await TradingEngine.shared.getRegime(pair: pair)
            return "\(regime.emoji) \(pair): \(regime.rawValue)\n\(regime.tradingAdvice)"

        case "create_strategy":
            guard let name = arguments["name"], !name.isEmpty else {
                return "Fehler: 'name' Parameter erforderlich."
            }
            guard let rulesJson = arguments["rules"], !rulesJson.isEmpty else {
                return "Fehler: 'rules' Parameter erforderlich. Beispiel: [{\"indicator\":\"rsi\",\"condition\":\"below\",\"value\":30,\"weight\":0.6,\"action\":\"buy\"}]"
            }
            guard let rulesData = rulesJson.data(using: .utf8),
                  let rules = try? JSONDecoder().decode([StrategyRule].self, from: rulesData) else {
                return "Fehler: Ungültiges JSON in 'rules'. Format: [{\"indicator\":\"rsi\",\"condition\":\"below\",\"value\":30,\"weight\":0.6,\"action\":\"buy\"}]"
            }
            let regimeFilter = (arguments["regime_filter"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let strategy = CustomStrategy(name: name, rules: rules, regimeFilter: regimeFilter)
            let result = await StrategyEngine.shared.addCustomStrategy(strategy)
            return result

        case "list_strategies":
            let all = await StrategyEngine.shared.getActiveStrategies()
            let custom = await StrategyEngine.shared.getCustomStrategies()
            var result = "Strategien (\(all.count)):\n"
            for s in all {
                let isCustom = custom.contains(where: { $0.name == s.name })
                result += "• \(s.name) v\(s.version) [\(s.enabled ? "aktiv" : "deaktiviert")]\(isCustom ? " (Custom)" : "")\n"
            }
            for cs in custom {
                result += "\n\(cs.name) Regeln:\n"
                for r in cs.rules {
                    result += "  → \(r.indicator) \(r.condition) \(String(format: "%.2f", r.value)) (Gewicht: \(String(format: "%.1f", r.weight)), Aktion: \(r.action))\n"
                }
                if !cs.regimeFilter.isEmpty {
                    result += "  Regime-Filter: \(cs.regimeFilter.joined(separator: ", "))\n"
                }
            }
            return result

        case "delete_strategy":
            let name = arguments["name"] ?? arguments["strategy"] ?? ""
            guard !name.isEmpty else { return "Fehler: 'name' Parameter erforderlich." }
            let result = await StrategyEngine.shared.removeCustomStrategy(name: name)
            return result

        default:
            return "Unbekannte Aktion: \(action). Verfügbar: status, analytics, forecast, trade_history, open_positions, start, stop, emergency_stop, backtest, products, staking, regime, create_strategy, list_strategies, delete_strategy"
        }
    }

    // MARK: - Formatting

    private func formatStatus(_ s: TradingStatus) -> String {
        """
        Trading Engine Status:
        • Status: \(s.running ? "🟢 Läuft" : "🔴 Gestoppt")
        • Regime: \(s.regime)
        • Portfolio: \(String(format: "%.2f€", s.portfolioValue))
        • Offene Positionen: \(s.openPositions)
        • Trades gesamt: \(s.totalTrades)
        • Tages-P&L: \(String(format: "%+.2f€", s.dailyPnL))
        • Aktive Paare: \(s.activePairs.joined(separator: ", "))
        • Strategien: \(s.activeStrategies.joined(separator: ", "))
        • Uptime: \(s.uptime)
        \(s.halted ? "⚠️ GEHALTET: \(s.haltReason)" : "")
        """
    }

    private func formatAnalytics(_ a: TradingAnalytics) -> String {
        """
        Trading Analytics (\(a.period)):
        • Trades: \(a.totalTrades) (\(a.wins)W / \(a.losses)L)
        • Win Rate: \(String(format: "%.1f%%", a.winRate))
        • Gesamt P&L: \(String(format: "%+.2f€", a.totalPnL))
        • Sharpe Ratio: \(String(format: "%.2f", a.sharpeRatio))
        • Max Drawdown: \(String(format: "%.2f€", a.maxDrawdown)) (\(String(format: "%.1f%%", a.maxDrawdownPct)))
        • Profit Factor: \(String(format: "%.2f", a.profitFactor))
        • Avg Profit: \(String(format: "%.2f€", a.avgProfit))
        • Avg Loss: \(String(format: "%.2f€", a.avgLoss))
        • Bester Trade: \(String(format: "%+.2f€", a.bestTrade))
        • Schlechtester: \(String(format: "%+.2f€", a.worstTrade))
        """
    }

    private func formatForecasts(pair: String, forecasts: [ForecastResult]) -> String {
        var result = "Forecast \(pair):\n"
        for f in forecasts {
            let arrow = f.direction == "UP" ? "↑" : f.direction == "DOWN" ? "↓" : "→"
            result += "• \(f.horizon): \(arrow) \(f.direction) (\(String(format: "%.0f%%", f.confidence * 100))) → \(String(format: "%.2f€", f.targetPrice)) (\(String(format: "%+.2f%%", f.targetPct)))\n"
        }
        if let first = forecasts.first {
            result += "\nFaktoren:\n"
            for factor in first.factors { result += "  • \(factor)\n" }
        }
        return result
    }

    private func formatTradeHistory(_ trades: [TradeRecord]) -> String {
        var result = "Letzte \(trades.count) Trades:\n"
        for t in trades {
            let pnlStr = t.pnl.map { String(format: "%+.2f€", $0) } ?? "offen"
            result += "• \(t.timestamp.prefix(16)) \(t.side) \(t.pair) @ \(String(format: "%.2f€", t.price)) — \(pnlStr) [\(t.strategy)]\n"
        }
        return result
    }

    private func formatOpenPositions(_ trades: [TradeRecord]) -> String {
        var result = "Offene Positionen (\(trades.count)):\n"
        for t in trades {
            result += "• \(t.pair) \(t.side) \(String(format: "%.8f", t.size)) @ \(String(format: "%.2f€", t.price)) [\(t.strategy)] Konfidenz: \(String(format: "%.0f%%", t.confidence * 100))\n"
        }
        return result
    }

    private func formatBacktest(_ r: BacktestResult) -> String {
        """
        Backtest: \(r.strategy) auf \(r.pair) (\(r.periodDays) Tage)
        • Zeitraum: \(r.startDate) — \(r.endDate)
        • Total Return: \(String(format: "%.2f%%", r.totalReturn))
        • Sharpe Ratio: \(String(format: "%.2f", r.sharpeRatio))
        • Max Drawdown: \(String(format: "%.2f%%", r.maxDrawdown))
        • Win Rate: \(String(format: "%.1f%%", r.winRate))
        • Trades: \(r.totalTrades)
        • Profit Factor: \(String(format: "%.2f", r.profitFactor))
        • Avg Trade: \(String(format: "%.2f%%", r.avgTradeReturn))
        """
    }
}
#endif
