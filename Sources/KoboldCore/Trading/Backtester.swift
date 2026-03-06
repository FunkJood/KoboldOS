#if os(macOS)
import Foundation
import Accelerate

// MARK: - Backtest Result

public struct BacktestResult: Sendable, Codable {
    public let strategy: String
    public let pair: String
    public let periodDays: Int
    public let totalReturn: Double          // %
    public let sharpeRatio: Double
    public let maxDrawdown: Double          // %
    public let winRate: Double              // %
    public let totalTrades: Int
    public let profitFactor: Double
    public let avgTradeReturn: Double       // %
    public let equityCurve: [Double]        // Portfolio values over time
    public let startDate: String
    public let endDate: String

    public init(strategy: String, pair: String, periodDays: Int, totalReturn: Double,
                sharpeRatio: Double, maxDrawdown: Double, winRate: Double, totalTrades: Int,
                profitFactor: Double, avgTradeReturn: Double, equityCurve: [Double],
                startDate: String, endDate: String) {
        self.strategy = strategy; self.pair = pair; self.periodDays = periodDays
        self.totalReturn = totalReturn; self.sharpeRatio = sharpeRatio
        self.maxDrawdown = maxDrawdown; self.winRate = winRate; self.totalTrades = totalTrades
        self.profitFactor = profitFactor; self.avgTradeReturn = avgTradeReturn
        self.equityCurve = equityCurve; self.startDate = startDate; self.endDate = endDate
    }
}

// MARK: - Backtester

public struct Backtester: Sendable {

    public init() {}

    /// Führt einen Backtest für eine Strategie auf historischen Candles durch.
    /// Realistisch: Echter Trailing Stop, Slippage-Modell, korrekte Gebühren, TP/SL aus Settings.
    public func run(strategy: any TradingStrategy, candles: [Candle], pair: String,
                    initialCapital: Double = 10000, positionSizePct: Double = 2.0,
                    feeRate: Double = 0, slippagePct: Double = 0.0015) -> BacktestResult {

        guard candles.count >= 200 else {
            return BacktestResult(strategy: strategy.name, pair: pair, periodDays: 0,
                                 totalReturn: 0, sharpeRatio: 0, maxDrawdown: 0,
                                 winRate: 0, totalTrades: 0, profitFactor: 0,
                                 avgTradeReturn: 0, equityCurve: [initialCapital],
                                 startDate: "", endDate: "")
        }

        // TP/SL Settings aus UserDefaults (gleich wie Live-System)
        let tpPct = UserDefaults.standard.double(forKey: "kobold.trading.takeProfit")
        let effectiveTP = tpPct > 0 ? tpPct : 8.0
        let slPct = UserDefaults.standard.double(forKey: "kobold.trading.fixedStopLoss")
        let effectiveSL = slPct > 0 ? slPct : 3.0
        let trailingPct = UserDefaults.standard.double(forKey: "kobold.trading.trailingStop")
        let effectiveTrailing = trailingPct > 0 ? trailingPct : 4.0
        let tpSlMode = UserDefaults.standard.string(forKey: "kobold.trading.tpSlMode") ?? "trailing"
        let useTrailing = tpSlMode == "trailing" || tpSlMode == "both"
        let useFixed = tpSlMode == "fixed" || tpSlMode == "both"

        let detector = MarketRegimeDetector()
        var capital = initialCapital
        var equityCurve: [Double] = [capital]
        var trades: [(entry: Double, exit: Double, pnl: Double)] = []

        // Position-Tracking mit echtem HWM für Trailing Stop
        struct OpenPosition {
            let entryPrice: Double
            let size: Double
            let entryIndex: Int
            var highWatermark: Double  // Höchster Preis seit Entry (für Trailing Stop)
        }
        var position: OpenPosition? = nil

        let startIdx = 200
        for i in startIdx..<candles.count {
            let window = Array(candles[0...i])
            guard let indicators = TechnicalAnalysis.computeSnapshot(candles: window) else { continue }
            let regime = detector.detect(candles: window, indicators: indicators)
            let signal = strategy.evaluate(pair: pair, candles: window, indicators: indicators, regime: regime)

            if var pos = position {
                let currentPrice = candles[i].close
                let intraHigh = candles[i].high
                let intraLow = candles[i].low

                // HWM updaten (Intra-Candle-High berücksichtigen)
                if intraHigh > pos.highWatermark {
                    pos.highWatermark = intraHigh
                    position = pos
                }

                // Exit-Checks (Priorität: SL > TP > Signal)
                var shouldExit = false
                var exitPrice = currentPrice

                // 1. Stop-Loss Check (auf Intra-Candle-Low prüfen für realistisches Ergebnis)
                if useTrailing {
                    let trailingStop = pos.highWatermark * (1 - effectiveTrailing / 100)
                    if intraLow <= trailingStop {
                        shouldExit = true
                        exitPrice = trailingStop  // Stop-Order füllt am Stop-Level
                    }
                }
                if !shouldExit && useFixed {
                    let fixedStop = pos.entryPrice * (1 - effectiveSL / 100)
                    if intraLow <= fixedStop {
                        shouldExit = true
                        exitPrice = fixedStop
                    }
                }

                // 2. Take-Profit Check
                if !shouldExit {
                    let tpTarget = pos.entryPrice * (1 + effectiveTP / 100)
                    if intraHigh >= tpTarget {
                        shouldExit = true
                        exitPrice = tpTarget  // TP füllt am Ziellevel
                    }
                }

                // 3. Strategie-Signal SELL
                if !shouldExit && signal.action == .sell && signal.confidence > 0.5 {
                    shouldExit = true
                    exitPrice = currentPrice
                }

                if shouldExit {
                    // Slippage + Gebühren beim Verkauf
                    let slippedExitPrice = exitPrice * (1 - slippagePct)
                    let exitValue = pos.size * slippedExitPrice * (1 - feeRate)
                    let entryValue = pos.size * pos.entryPrice
                    let pnl = exitValue - entryValue
                    capital += exitValue
                    trades.append((pos.entryPrice, slippedExitPrice, pnl))
                    position = nil
                }
            } else {
                // Entry: BUY-Signal
                if signal.action == .buy && signal.confidence > 0.5 {
                    let positionValue = capital * (positionSizePct / 100.0)
                    // Slippage + Gebühren beim Kauf
                    let slippedPrice = candles[i].close * (1 + slippagePct)
                    let costWithFee = positionValue * (1 + feeRate)
                    let size = positionValue / slippedPrice
                    if size > 0 && costWithFee < capital {
                        capital -= costWithFee
                        position = OpenPosition(
                            entryPrice: slippedPrice, size: size,
                            entryIndex: i, highWatermark: slippedPrice
                        )
                    }
                }
            }

            // Mark-to-market equity
            let posValue = position.map { $0.size * candles[i].close } ?? 0
            equityCurve.append(capital + posValue)
        }

        // Close any open position at end
        if let pos = position {
            let exitPrice = candles.last!.close * (1 - slippagePct)
            let exitValue = pos.size * exitPrice * (1 - feeRate)
            let pnl = exitValue - (pos.size * pos.entryPrice)
            capital += exitValue
            trades.append((pos.entryPrice, exitPrice, pnl))
        }

        // Compute metrics
        let totalReturn = (capital - initialCapital) / initialCapital * 100
        let pnls = trades.map(\.pnl)
        let wins = pnls.filter { $0 > 0 }.count
        let winRate = trades.isEmpty ? 0 : Double(wins) / Double(trades.count) * 100

        let grossProfit = pnls.filter { $0 > 0 }.reduce(0, +)
        let grossLoss = abs(pnls.filter { $0 < 0 }.reduce(0, +))
        let profitFactor = grossLoss > 0 ? grossProfit / grossLoss : (grossProfit > 0 ? 99 : 0)

        let sharpe = computeBacktestSharpe(equityCurve)
        let maxDD = computeBacktestDrawdown(equityCurve)

        let returns = trades.map { ($0.exit - $0.entry) / $0.entry * 100 }
        let avgReturn = returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let startDate = fmt.string(from: Date(timeIntervalSince1970: candles[startIdx].timestamp))
        let endDate = fmt.string(from: Date(timeIntervalSince1970: candles.last!.timestamp))

        // Downsample equity curve to max 200 points for UI
        let sampledCurve = downsample(equityCurve, to: 200)

        return BacktestResult(
            strategy: strategy.name, pair: pair,
            periodDays: Int(Double(candles.count) / 24), // Assuming 1h candles
            totalReturn: totalReturn, sharpeRatio: sharpe, maxDrawdown: maxDD,
            winRate: winRate, totalTrades: trades.count, profitFactor: profitFactor,
            avgTradeReturn: avgReturn, equityCurve: sampledCurve,
            startDate: startDate, endDate: endDate
        )
    }

    // MARK: - Sharpe from Equity Curve

    private func computeBacktestSharpe(_ equity: [Double]) -> Double {
        guard equity.count > 2 else { return 0 }
        var returns: [Double] = []
        for i in 1..<equity.count {
            if equity[i - 1] > 0 {
                returns.append((equity[i] - equity[i - 1]) / equity[i - 1])
            }
        }
        guard returns.count > 1 else { return 0 }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1)
        let stdDev = sqrt(variance)
        guard stdDev > 0 else { return mean > 0 ? 3 : 0 }
        return (mean / stdDev) * sqrt(365 * 24) // Hourly data annualized (Krypto: 365 Tage/Jahr)
    }

    // MARK: - Max Drawdown from Equity Curve

    private func computeBacktestDrawdown(_ equity: [Double]) -> Double {
        guard !equity.isEmpty else { return 0 }
        var peak = equity[0]
        var maxDD = 0.0
        for val in equity {
            if val > peak { peak = val }
            let dd = (peak - val) / peak * 100
            if dd > maxDD { maxDD = dd }
        }
        return maxDD
    }

    // MARK: - Downsample

    private func downsample(_ data: [Double], to count: Int) -> [Double] {
        guard data.count > count else { return data }
        let step = Double(data.count) / Double(count)
        return (0..<count).map { i in
            let idx = min(Int(Double(i) * step), data.count - 1)
            return data[idx]
        }
    }

    // MARK: - Report

    public func generateReport(_ result: BacktestResult) -> String {
        var md = "# Backtest Report: \(result.strategy)\n\n"
        md += "**Paar:** \(result.pair)\n"
        md += "**Zeitraum:** \(result.startDate) — \(result.endDate) (\(result.periodDays) Tage)\n\n"

        md += "## Ergebnisse\n\n"
        md += "| Metrik | Wert |\n|--------|------|\n"
        md += "| Total Return | \(String(format: "%.2f%%", result.totalReturn)) |\n"
        md += "| Sharpe Ratio | \(String(format: "%.2f", result.sharpeRatio)) |\n"
        md += "| Max Drawdown | \(String(format: "%.2f%%", result.maxDrawdown)) |\n"
        md += "| Win Rate | \(String(format: "%.1f%%", result.winRate)) |\n"
        md += "| Trades | \(result.totalTrades) |\n"
        md += "| Profit Factor | \(String(format: "%.2f", result.profitFactor)) |\n"
        md += "| Avg Trade Return | \(String(format: "%.2f%%", result.avgTradeReturn)) |\n"

        return md
    }
}
#endif
