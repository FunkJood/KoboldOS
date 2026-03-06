#if os(macOS)
import Foundation

// MARK: - Trade Analytics Results

public struct TradingAnalytics: Sendable, Codable {
    public let period: String
    public let totalTrades: Int
    public let wins: Int
    public let losses: Int
    public let winRate: Double              // 0-100%
    public let avgProfit: Double            // EUR
    public let avgLoss: Double              // EUR
    public let sharpeRatio: Double
    public let sortinoRatio: Double         // Downside-only risk-adjusted return
    public let calmarRatio: Double          // Annualized return / max drawdown
    public let maxDrawdown: Double          // EUR
    public let maxDrawdownPct: Double       // %
    public let profitFactor: Double         // Gross profit / Gross loss
    public let totalPnL: Double             // EUR
    public let totalFees: Double            // EUR
    public let avgHoldingTimeMinutes: Double
    public let bestTrade: Double            // EUR
    public let worstTrade: Double           // EUR
    public let equityCurve: [Double]        // Cumulative P&L over time
    public let drawdownCurve: [Double]      // Drawdown % over time

    public init(period: String = "all", totalTrades: Int = 0, wins: Int = 0, losses: Int = 0,
                winRate: Double = 0, avgProfit: Double = 0, avgLoss: Double = 0,
                sharpeRatio: Double = 0, sortinoRatio: Double = 0, calmarRatio: Double = 0,
                maxDrawdown: Double = 0, maxDrawdownPct: Double = 0,
                profitFactor: Double = 0, totalPnL: Double = 0, totalFees: Double = 0,
                avgHoldingTimeMinutes: Double = 0, bestTrade: Double = 0, worstTrade: Double = 0,
                equityCurve: [Double] = [], drawdownCurve: [Double] = []) {
        self.period = period; self.totalTrades = totalTrades; self.wins = wins; self.losses = losses
        self.winRate = winRate; self.avgProfit = avgProfit; self.avgLoss = avgLoss
        self.sharpeRatio = sharpeRatio; self.sortinoRatio = sortinoRatio; self.calmarRatio = calmarRatio
        self.maxDrawdown = maxDrawdown; self.maxDrawdownPct = maxDrawdownPct
        self.profitFactor = profitFactor; self.totalPnL = totalPnL; self.totalFees = totalFees
        self.avgHoldingTimeMinutes = avgHoldingTimeMinutes; self.bestTrade = bestTrade; self.worstTrade = worstTrade
        self.equityCurve = equityCurve; self.drawdownCurve = drawdownCurve
    }
}

// MARK: - Trade Analyzer

public struct TradeAnalyzer: Sendable {

    public init() {}

    /// Berechnet vollständige Analytics aus einer Liste geschlossener Trades
    public func analyze(trades: [TradeRecord], period: String = "all") -> TradingAnalytics {
        let closed = trades.filter { $0.status == "CLOSED" && $0.pnl != nil }
        guard !closed.isEmpty else {
            return TradingAnalytics(period: period)
        }

        let pnls = closed.compactMap(\.pnl)
        let fees = closed.map(\.fee)

        let profits = pnls.filter { $0 > 0 }
        let lossesArr = pnls.filter { $0 < 0 }

        let totalPnL = pnls.reduce(0, +)
        let totalFees = fees.reduce(0, +)
        let wins = profits.count
        let losses = lossesArr.count
        let winRate = Double(wins) / Double(pnls.count) * 100

        let avgProfit = profits.isEmpty ? 0 : profits.reduce(0, +) / Double(profits.count)
        let avgLoss = lossesArr.isEmpty ? 0 : abs(lossesArr.reduce(0, +)) / Double(lossesArr.count)

        let grossProfit = profits.reduce(0, +)
        let grossLoss = abs(lossesArr.reduce(0, +))
        let profitFactor = grossLoss > 0 ? grossProfit / grossLoss : (grossProfit > 0 ? .infinity : 0)

        let sharpe = computeSharpeRatio(pnls)
        let sortino = computeSortinoRatio(pnls)
        let (maxDD, maxDDPct) = computeMaxDrawdown(pnls)
        let calmar = computeCalmarRatio(pnls, maxDrawdownPct: maxDDPct)
        let (equityCurve, drawdownCurve) = computeCurves(pnls)

        let holdingTimes = closed.compactMap { parseHoldingTimeMinutes($0.holdingTime) }
        let avgHolding = holdingTimes.isEmpty ? 0 : holdingTimes.reduce(0, +) / Double(holdingTimes.count)

        return TradingAnalytics(
            period: period, totalTrades: pnls.count,
            wins: wins, losses: losses, winRate: winRate,
            avgProfit: avgProfit, avgLoss: avgLoss,
            sharpeRatio: sharpe, sortinoRatio: sortino, calmarRatio: calmar,
            maxDrawdown: maxDD, maxDrawdownPct: maxDDPct,
            profitFactor: profitFactor,
            totalPnL: totalPnL, totalFees: totalFees,
            avgHoldingTimeMinutes: avgHolding,
            bestTrade: pnls.max() ?? 0,
            worstTrade: pnls.min() ?? 0,
            equityCurve: equityCurve, drawdownCurve: drawdownCurve
        )
    }

    // MARK: - Sharpe Ratio

    private func computeSharpeRatio(_ pnls: [Double]) -> Double {
        guard pnls.count > 1 else { return 0 }
        let mean = pnls.reduce(0, +) / Double(pnls.count)
        let variance = pnls.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(pnls.count - 1)
        let stdDev = sqrt(variance)
        guard stdDev > 0 else { return mean > 0 ? 3.0 : 0 }
        // Annualisiert (252 Trading-Tage)
        return (mean / stdDev) * sqrt(252)
    }

    // MARK: - Max Drawdown

    private func computeMaxDrawdown(_ pnls: [Double]) -> (absolute: Double, percent: Double) {
        guard !pnls.isEmpty else { return (0, 0) }
        var cumulative = 0.0
        var peak = 0.0
        var maxDD = 0.0

        for pnl in pnls {
            cumulative += pnl
            if cumulative > peak { peak = cumulative }
            let dd = peak - cumulative
            if dd > maxDD { maxDD = dd }
        }

        let maxDDPct = peak > 0 ? maxDD / peak * 100 : 0
        return (maxDD, maxDDPct)
    }

    // MARK: - Sortino Ratio (Downside-only volatility)

    private func computeSortinoRatio(_ pnls: [Double]) -> Double {
        guard pnls.count > 1 else { return 0 }
        let mean = pnls.reduce(0, +) / Double(pnls.count)
        let downsideReturns = pnls.filter { $0 < 0 }
        guard !downsideReturns.isEmpty else { return mean > 0 ? 3.0 : 0 }
        let downsideVariance = downsideReturns.map { $0 * $0 }.reduce(0, +) / Double(pnls.count)
        let downsideDev = sqrt(downsideVariance)
        guard downsideDev > 0 else { return mean > 0 ? 3.0 : 0 }
        return (mean / downsideDev) * sqrt(252)
    }

    // MARK: - Calmar Ratio (Return / Max Drawdown)

    private func computeCalmarRatio(_ pnls: [Double], maxDrawdownPct: Double) -> Double {
        guard maxDrawdownPct > 0, !pnls.isEmpty else { return 0 }
        let totalReturn = pnls.reduce(0, +)
        let avgReturn = totalReturn / Double(pnls.count)
        let annualizedReturn = avgReturn * 252
        return annualizedReturn / maxDrawdownPct
    }

    // MARK: - Equity & Drawdown Curves

    private func computeCurves(_ pnls: [Double]) -> (equity: [Double], drawdown: [Double]) {
        guard !pnls.isEmpty else { return ([], []) }
        var equity = [Double]()
        var drawdown = [Double]()
        var cumulative = 0.0
        var peak = 0.0

        for pnl in pnls {
            cumulative += pnl
            equity.append(cumulative)
            if cumulative > peak { peak = cumulative }
            let dd = peak > 0 ? (peak - cumulative) / peak * 100 : 0
            drawdown.append(dd)
        }
        return (equity, drawdown)
    }

    // MARK: - Holding Time Parser

    private func parseHoldingTimeMinutes(_ ht: String?) -> Double? {
        guard let ht, !ht.isEmpty else { return nil }
        // Format: "2h 15m" oder "45m" oder "1d 3h"
        var minutes = 0.0
        let parts = ht.components(separatedBy: " ")
        for part in parts {
            if part.hasSuffix("d"), let v = Double(part.dropLast()) { minutes += v * 1440 }
            else if part.hasSuffix("h"), let v = Double(part.dropLast()) { minutes += v * 60 }
            else if part.hasSuffix("m"), let v = Double(part.dropLast()) { minutes += v }
        }
        return minutes > 0 ? minutes : nil
    }

    // MARK: - Report Generation

    public func generateReport(analytics: TradingAnalytics) -> String {
        var md = "# Trade-Analyse Report\n\n"
        md += "**Zeitraum:** \(analytics.period)\n"
        md += "**Generiert:** \(ISO8601DateFormatter().string(from: Date()))\n\n"

        md += "## Übersicht\n\n"
        md += "| Metrik | Wert |\n|--------|------|\n"
        md += "| Trades gesamt | \(analytics.totalTrades) |\n"
        md += "| Gewinner | \(analytics.wins) (\(String(format: "%.1f%%", analytics.winRate))) |\n"
        md += "| Verlierer | \(analytics.losses) |\n"
        md += "| Gesamt P&L | \(String(format: "%.2f€", analytics.totalPnL)) |\n"
        md += "| Gebühren | \(String(format: "%.2f€", analytics.totalFees)) |\n\n"

        md += "## Risiko-Metriken\n\n"
        md += "| Metrik | Wert |\n|--------|------|\n"
        md += "| Sharpe Ratio | \(String(format: "%.2f", analytics.sharpeRatio)) |\n"
        md += "| Max Drawdown | \(String(format: "%.2f€", analytics.maxDrawdown)) (\(String(format: "%.1f%%", analytics.maxDrawdownPct))) |\n"
        md += "| Profit Factor | \(String(format: "%.2f", analytics.profitFactor)) |\n"
        md += "| Avg Profit | \(String(format: "%.2f€", analytics.avgProfit)) |\n"
        md += "| Avg Loss | \(String(format: "%.2f€", analytics.avgLoss)) |\n"
        md += "| Bester Trade | \(String(format: "%.2f€", analytics.bestTrade)) |\n"
        md += "| Schlechtester Trade | \(String(format: "%.2f€", analytics.worstTrade)) |\n"
        md += "| Avg Haltedauer | \(String(format: "%.0f Min", analytics.avgHoldingTimeMinutes)) |\n"

        return md
    }
}
#endif
