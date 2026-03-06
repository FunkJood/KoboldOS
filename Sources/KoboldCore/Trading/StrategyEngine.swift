#if os(macOS)
import Foundation

// MARK: - Trading Signal

public enum TradeAction: String, Sendable, Codable {
    case buy = "BUY"
    case sell = "SELL"
    case hold = "HOLD"
}

public struct TradingSignal: Sendable {
    public let action: TradeAction
    public let confidence: Double        // 0.0 - 1.0
    public let reason: String
    public let strategy: String
    public let pair: String
    public let suggestedSize: Double?    // Optional size suggestion

    public init(action: TradeAction, confidence: Double, reason: String,
                strategy: String, pair: String, suggestedSize: Double? = nil) {
        self.action = action
        self.confidence = min(max(confidence, 0), 1)
        self.reason = reason; self.strategy = strategy
        self.pair = pair; self.suggestedSize = suggestedSize
    }
}

// MARK: - Strategy Protocol

public protocol TradingStrategy: Sendable {
    var name: String { get }
    var version: Int { get }
    var params: StrategyParams { get set }
    func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal
}

// MARK: - Strategy Parameters

public struct StrategyParams: Sendable, Codable {
    // Momentum
    public var rsiOversold: Double = 30
    public var rsiOverbought: Double = 70
    public var macdThreshold: Double = 0

    // Breakout (48h = 2 Tage auf 1h-Candles — signifikantere Widerstände)
    public var breakoutPeriod: Int = 48
    public var volumeMultiplier: Double = 1.5

    // Mean Reversion
    public var bbStdDev: Double = 2.0
    public var reversionThreshold: Double = 0.95  // BollingerBand %B

    public init() {}
}

// MARK: - Momentum Strategy (Enhanced — Graduated RSI Scoring)

public struct MomentumStrategy: TradingStrategy {
    public let name = "momentum"
    public var version: Int = 2
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        guard !candles.isEmpty else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Keine Candles", strategy: name, pair: pair)
        }
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime — kein Trading", strategy: name, pair: pair)
        }

        var buyScore = 0.0
        var sellScore = 0.0
        var reasons: [String] = []

        // Graduated RSI Signal (verschärft: keine Signale im Normalbereich 38-62)
        let rsi = indicators.rsi
        if rsi < 25 {
            buyScore += 0.40; reasons.append("RSI(\(String(format: "%.0f", rsi))) stark überverkauft")
        } else if rsi < 30 {
            buyScore += 0.35; reasons.append("RSI(\(String(format: "%.0f", rsi))) überverkauft")
        } else if rsi < 38 {
            buyScore += 0.20; reasons.append("RSI(\(String(format: "%.0f", rsi))) leicht überverkauft")
        }

        if rsi > 75 {
            sellScore += 0.40; reasons.append("RSI(\(String(format: "%.0f", rsi))) stark überkauft")
        } else if rsi > 70 {
            sellScore += 0.35; reasons.append("RSI(\(String(format: "%.0f", rsi))) überkauft")
        } else if rsi > 62 {
            sellScore += 0.20; reasons.append("RSI(\(String(format: "%.0f", rsi))) leicht überkauft")
        }

        // EMA200 Trend-Bestätigung (langfristiger Trend)
        let price = candles.last!.close
        if price > indicators.ema200 { buyScore += 0.08; reasons.append("Über EMA200 (bullish)") }
        else { sellScore += 0.08; reasons.append("Unter EMA200 (bearish)") }

        // MACD Crossover + Histogram-Stärke
        if indicators.macdHistogram > 0 && indicators.macdLine > indicators.macdSignal {
            let strength = min(abs(indicators.macdHistogram) / (candles.last!.close * 0.001), 1.0)
            buyScore += 0.20 + strength * 0.10
            reasons.append("MACD bullish (\(String(format: "%.4f", indicators.macdHistogram)))")
        } else if indicators.macdHistogram < 0 && indicators.macdLine < indicators.macdSignal {
            let strength = min(abs(indicators.macdHistogram) / (candles.last!.close * 0.001), 1.0)
            sellScore += 0.20 + strength * 0.10
            reasons.append("MACD bearish (\(String(format: "%.4f", indicators.macdHistogram)))")
        }

        // EMA Trend Confirmation (gestaffelt)
        if indicators.ema9 > indicators.ema21 && indicators.ema21 > indicators.ema50 {
            buyScore += 0.20; reasons.append("EMA bullish (9>21>50)")
        } else if indicators.ema9 > indicators.ema21 {
            buyScore += 0.10; reasons.append("EMA9 > EMA21")
        }
        if indicators.ema9 < indicators.ema21 && indicators.ema21 < indicators.ema50 {
            sellScore += 0.20; reasons.append("EMA bearish (9<21<50)")
        } else if indicators.ema9 < indicators.ema21 {
            sellScore += 0.10; reasons.append("EMA9 < EMA21")
        }

        // EMA Slope (Trend-Stärke)
        if indicators.emaSlope50 > 0.1 { buyScore += 0.08; reasons.append("Starker Aufwärtstrend") }
        else if indicators.emaSlope50 < -0.1 { sellScore += 0.08; reasons.append("Starker Abwärtstrend") }

        // Volume Confirmation
        if indicators.volumeRatio > 1.5 {
            buyScore *= 1.20; sellScore *= 1.20
            reasons.append("Hohes Volumen (\(String(format: "%.1fx", indicators.volumeRatio)))")
        } else if indicators.volumeRatio > 1.2 {
            buyScore *= 1.10; sellScore *= 1.10
            reasons.append("Volumen +\(String(format: "%.0f%%", (indicators.volumeRatio - 1) * 100))")
        }

        // Regime-Adjustierung
        if regime == .bull { buyScore *= 1.15 }
        if regime == .bear {
            sellScore *= 1.15
            buyScore *= 0.70  // Bear: Buys stark reduziert
            reasons.append("Bear-Regime (Buy ×0.70)")
        }
        if regime == .sideways { buyScore *= 0.90; sellScore *= 0.90 }

        // Signal-Threshold: 0.35 — weniger Signale, höhere Qualität
        if buyScore > sellScore && buyScore > 0.35 {
            return TradingSignal(action: .buy, confidence: min(buyScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        } else if sellScore > buyScore && sellScore > 0.35 {
            return TradingSignal(action: .sell, confidence: min(sellScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Kein klares Signal", strategy: name, pair: pair)
    }
}

// MARK: - Breakout Strategy

public struct BreakoutStrategy: TradingStrategy {
    public let name = "breakout"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        guard !candles.isEmpty else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Keine Candles", strategy: name, pair: pair)
        }
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }

        guard candles.count >= params.breakoutPeriod + 1 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        let lookback = Array(candles.suffix(params.breakoutPeriod + 1).dropLast())
        let current = candles.last!

        let periodHigh = lookback.map(\.high).max() ?? current.high
        let periodLow = lookback.map(\.low).min() ?? current.low
        var reasons: [String] = []

        // Bullish Breakout
        if current.close > periodHigh {
            var confidence = 0.50
            reasons.append("Breakout über \(params.breakoutPeriod)p-Hoch (\(String(format: "%.2f", periodHigh)))")

            if indicators.volumeRatio > params.volumeMultiplier {
                confidence += 0.25
                reasons.append("Vol-Bestätigung (\(String(format: "%.1fx", indicators.volumeRatio)))")
            }
            if indicators.emaSlope50 > 0 { confidence += 0.10 }
            if regime == .bull { confidence += 0.10 }
            // Bear: Bullische Breakouts sehr riskant (Bärenmarkt-Rallyes = Fallen)
            if regime == .bear { confidence *= 0.55; reasons.append("Bear-Regime (Breakout-Buy ×0.55)") }
            // Sideways: False-Breakout-Risiko hoch → nur mit starkem Volumen
            if regime == .sideways {
                if indicators.volumeRatio < params.volumeMultiplier {
                    confidence *= 0.50; reasons.append("Sideways ohne Vol-Bestätigung (×0.50)")
                } else {
                    confidence *= 0.80; reasons.append("Sideways-Breakout (×0.80)")
                }
            }

            return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        // Near-Breakout: Preis innerhalb 0.5% vom Perioden-Hoch (NUR mit Volumen-Bestätigung)
        let nearBreakoutPct = (periodHigh - current.close) / periodHigh * 100
        if nearBreakoutPct > 0 && nearBreakoutPct < 0.5 && indicators.emaSlope50 > 0 && indicators.volumeRatio > 1.2 {
            // Bear + Sideways: Near-Breakouts komplett unterdrücken (zu riskant)
            if regime == .bear || regime == .sideways {
                return TradingSignal(action: .hold, confidence: 0,
                    reason: "\(regime.rawValue)-Regime — Near-Breakout unterdrückt", strategy: name, pair: pair)
            }
            var confidence = 0.40
            reasons.append("Near-Breakout (\(String(format: "%.2f%%", nearBreakoutPct)) vom Hoch)")
            reasons.append("Vol-Bestätigung (\(String(format: "%.1fx", indicators.volumeRatio)))")
            if regime == .bull { confidence += 0.10 }
            if current.close > indicators.ema200 { confidence += 0.05 }
            return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        // Bearish Breakout
        if current.close < periodLow {
            var confidence = 0.50
            reasons.append("Breakout unter \(params.breakoutPeriod)p-Tief (\(String(format: "%.2f", periodLow)))")

            if indicators.volumeRatio > params.volumeMultiplier {
                confidence += 0.25
                reasons.append("Vol-Bestätigung")
            }
            if indicators.emaSlope50 < 0 { confidence += 0.10 }
            if regime == .bear { confidence += 0.10 }

            return TradingSignal(action: .sell, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Kein Breakout", strategy: name, pair: pair)
    }
}

// MARK: - Mean Reversion Strategy (Enhanced — Works in ALL regimes)

public struct MeanReversionStrategy: TradingStrategy {
    public let name = "mean_reversion"
    public var version: Int = 2
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        guard !candles.isEmpty else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Keine Candles", strategy: name, pair: pair)
        }
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }

        var reasons: [String] = []

        // Regime-basierter Confidence-Modifier
        let regimeMultiplier: Double = regime == .sideways ? 1.0 : 0.75

        // Trend-Filter: Kein Buy bei starkem Abwärtstrend (Falling Knife Protection)
        if indicators.emaSlope50 < -0.2 {
            return TradingSignal(action: .hold, confidence: 0,
                reason: "Starker Abwärtstrend (EMA50 Slope \(String(format: "%.2f%%", indicators.emaSlope50))) — Falling Knife", strategy: name, pair: pair)
        }

        // Preis unter unterem Bollinger Band → Buy
        if indicators.bbPercentB < (1 - params.reversionThreshold) {
            var confidence = 0.50 * regimeMultiplier
            reasons.append("Preis unter BB (%%B=\(String(format: "%.2f", indicators.bbPercentB)))")

            if indicators.rsi < 35 { confidence += 0.20; reasons.append("RSI überverkauft") }
            else if indicators.rsi < 45 { confidence += 0.10; reasons.append("RSI niedrig") }
            if indicators.volumeRatio < 1.0 { confidence += 0.10; reasons.append("Verkaufsdruck lässt nach") }
            if regime != .sideways { reasons.append("Regime: \(regime.rawValue) (reduziert)") }

            return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        // Preis über oberem Bollinger Band → Sell
        if indicators.bbPercentB > params.reversionThreshold {
            var confidence = 0.50 * regimeMultiplier
            reasons.append("Preis über BB (%%B=\(String(format: "%.2f", indicators.bbPercentB)))")

            if indicators.rsi > 65 { confidence += 0.20; reasons.append("RSI überkauft") }
            else if indicators.rsi > 55 { confidence += 0.10; reasons.append("RSI hoch") }
            if indicators.volumeRatio < 1.0 { confidence += 0.10; reasons.append("Kaufdruck lässt nach") }
            if regime != .sideways { reasons.append("Regime: \(regime.rawValue) (reduziert)") }

            return TradingSignal(action: .sell, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Im normalen Band-Bereich", strategy: name, pair: pair)
    }
}

// MARK: - Trend Following Strategy (NEW — EMA Crossover System)

public struct TrendFollowingStrategy: TradingStrategy {
    public let name = "trend_following"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }
        guard candles.count >= 60 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        var buyScore = 0.0
        var sellScore = 0.0
        var reasons: [String] = []

        // EMA Crossover Detection (vergleicht aktuelle vs. vorherige Candle)
        let prevCandles = Array(candles.dropLast())
        if let prevIndicators = TechnicalAnalysis.computeSnapshot(candles: prevCandles) {
            // Golden Cross: EMA9 kreuzt über EMA21
            if indicators.ema9 > indicators.ema21 && prevIndicators.ema9 <= prevIndicators.ema21 {
                buyScore += 0.45
                reasons.append("Golden Cross (EMA9 kreuzt EMA21)")
            }
            // Death Cross: EMA9 kreuzt unter EMA21
            if indicators.ema9 < indicators.ema21 && prevIndicators.ema9 >= prevIndicators.ema21 {
                sellScore += 0.45
                reasons.append("Death Cross (EMA9 unter EMA21)")
            }

            // MACD-Histogramm Richtungswechsel
            if indicators.macdHistogram > 0 && prevIndicators.macdHistogram <= 0 {
                buyScore += 0.20
                reasons.append("MACD dreht positiv")
            }
            if indicators.macdHistogram < 0 && prevIndicators.macdHistogram >= 0 {
                sellScore += 0.20
                reasons.append("MACD dreht negativ")
            }
        }

        // Trend-Stärke via EMA-Slope
        if indicators.emaSlope50 > 0.1 {
            buyScore += 0.15
            reasons.append("EMA50 steigt (\(String(format: "+%.2f%%", indicators.emaSlope50)))")
        } else if indicators.emaSlope50 < -0.1 {
            sellScore += 0.15
            reasons.append("EMA50 fällt (\(String(format: "%.2f%%", indicators.emaSlope50)))")
        }

        // Preis über/unter EMA50 + EMA200 als Trend-Bestätigung
        let price = candles.last!.close
        if price > indicators.ema50 { buyScore += 0.08 }
        else { sellScore += 0.08 }
        // EMA200 = ultimativer Trend-Filter
        if price > indicators.ema200 && indicators.ema50 > indicators.ema200 {
            buyScore += 0.10; reasons.append("Über EMA200 (bullish Struktur)")
        } else if price < indicators.ema200 && indicators.ema50 < indicators.ema200 {
            sellScore += 0.10; reasons.append("Unter EMA200 (bearish Struktur)")
        }

        // Volume Spike
        if indicators.volumeRatio > 1.3 {
            buyScore *= 1.15; sellScore *= 1.15
            reasons.append("Vol-Spike (\(String(format: "%.1fx", indicators.volumeRatio)))")
        }

        // Regime-Adjustierung
        if regime == .bull { buyScore *= 1.15 }
        if regime == .bear {
            sellScore *= 1.15
            buyScore *= 0.60  // Bear: Trend-following Buys gefährlich (Bärenmarkt-Rallyes)
            reasons.append("Bear-Regime (Buy ×0.60)")
        }
        if regime == .sideways { buyScore *= 0.85; sellScore *= 0.85; reasons.append("Sideways (×0.85)") }

        // Threshold: 0.45 — nur klare Crossover-Signale (vorher 0.20 = viel zu niedrig)
        if buyScore > sellScore && buyScore > 0.45 {
            return TradingSignal(action: .buy, confidence: min(buyScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        } else if sellScore > buyScore && sellScore > 0.45 {
            return TradingSignal(action: .sell, confidence: min(sellScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Kein Trend-Signal", strategy: name, pair: pair)
    }
}

// MARK: - Scalping Strategy (NEW — Schnelle Gewinnmitnahmen)

public struct ScalpingStrategy: TradingStrategy {
    public let name = "scalping"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }
        guard candles.count >= 20 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        var buyScore = 0.0
        var sellScore = 0.0
        var reasons: [String] = []

        // Short-Term RSI (nur extreme Werte = stärkere Reversal-Wahrscheinlichkeit)
        let rsi = indicators.rsi
        if rsi < 30 {
            buyScore += 0.35 + (30 - rsi) / 30 * 0.20  // 0.35-0.55
            reasons.append("RSI stark überverkauft (\(String(format: "%.0f", rsi)))")
        } else if rsi < 35 {
            buyScore += 0.25
            reasons.append("RSI-Dip (\(String(format: "%.0f", rsi)))")
        }
        if rsi > 70 {
            sellScore += 0.35 + (rsi - 70) / 30 * 0.20  // 0.35-0.55
            reasons.append("RSI stark überkauft (\(String(format: "%.0f", rsi)))")
        } else if rsi > 65 {
            sellScore += 0.25
            reasons.append("RSI-Peak (\(String(format: "%.0f", rsi)))")
        }

        // Kurzfristiger Preis-Momentum (letzte 6 Candles) — nur große Moves (>2% statt 1%)
        let recent = Array(candles.suffix(7))
        if recent.count >= 7 {
            let momentum = (recent.last!.close - recent.first!.close) / recent.first!.close * 100
            if momentum < -2.0 {
                buyScore += 0.25  // Starker Pullback = größere Reversal-Chance
                reasons.append("Starker Pullback \(String(format: "%.1f%%", momentum))")
            } else if momentum < -1.5 {
                buyScore += 0.15
                reasons.append("Pullback \(String(format: "%.1f%%", momentum))")
            }
            if momentum > 2.0 {
                sellScore += 0.25
                reasons.append("Starke Rally \(String(format: "+%.1f%%", momentum))")
            } else if momentum > 1.5 {
                sellScore += 0.15
                reasons.append("Rally \(String(format: "+%.1f%%", momentum))")
            }
        }

        // Bollinger Band — nur extreme Positionen
        let bbWidth = indicators.bbMiddle > 0
            ? (indicators.bbUpper - indicators.bbLower) / indicators.bbMiddle : 0
        if bbWidth < 0.02 {
            if indicators.macdHistogram > 0 { buyScore += 0.15 }
            else { sellScore += 0.15 }
            reasons.append("BB-Squeeze (Breite=\(String(format: "%.3f", bbWidth)))")
        } else if indicators.bbPercentB > 0.95 {
            sellScore += 0.18
            reasons.append("BB extrem überdehnt (%%B=\(String(format: "%.2f", indicators.bbPercentB)))")
        } else if indicators.bbPercentB < 0.05 {
            buyScore += 0.18
            reasons.append("BB extrem überverkauft (%%B=\(String(format: "%.2f", indicators.bbPercentB)))")
        }

        // MACD Histogram Direction
        if indicators.macdHistogram > 0 { buyScore += 0.12 }
        else { sellScore += 0.12 }

        // Price vs EMA9 — nur bei stärkerer Abweichung
        let price = candles.last!.close
        let ema9dist = (price - indicators.ema9) / indicators.ema9 * 100
        if ema9dist < -0.5 {
            buyScore += 0.12
            reasons.append("Unter EMA9 (\(String(format: "%.1f%%", ema9dist)))")
        }
        if ema9dist > 0.5 {
            sellScore += 0.12
            reasons.append("Über EMA9 (\(String(format: "+%.1f%%", ema9dist)))")
        }

        // EMA200 Trend-Bestätigung
        if price > indicators.ema200 { buyScore += 0.08 }
        else { sellScore += 0.08 }

        // Volume als Bestätigung — höhere Schwelle
        if indicators.volumeRatio > 1.5 {
            buyScore *= 1.18; sellScore *= 1.18
            reasons.append("Starkes Vol \(String(format: "%.1fx", indicators.volumeRatio))")
        }

        // Regime-Adjustierung
        if regime == .bull { buyScore *= 1.10 }
        if regime == .bear {
            sellScore *= 1.10
            buyScore *= 0.65  // Bear: Scalp-Buys riskant (Trend gegen uns)
            reasons.append("Bear-Regime (Scalp-Buy ×0.65)")
        }
        if regime == .sideways { buyScore *= 1.05; sellScore *= 1.05 }  // Sideways = Scalp-freundlich

        // Fee-Awareness: ATR muss mind. 3× Round-Trip-Fees decken
        let feeRate = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
        let effFee = feeRate > 0 ? feeRate : 0.012
        let roundTrip = effFee * 2  // 2.4%
        let atrPct = price > 0 ? indicators.atr / price : 0
        if atrPct < roundTrip * 1.5 {  // ATR muss mind. 3.6% des Preises sein
            buyScore *= 0.60; sellScore *= 0.60  // Starke Penalty bei geringer Volatilität
            reasons.append("Niedrige ATR (\(String(format: "%.2f%%", atrPct * 100)) < \(String(format: "%.1f%%", roundTrip * 1.5 * 100)) Minimum)")
        }

        // Threshold: 0.55 — verschärft (vorher 0.40) weil Fees bei 1.2% höher
        if buyScore > sellScore && buyScore > 0.55 {
            return TradingSignal(action: .buy, confidence: min(buyScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        } else if sellScore > buyScore && sellScore > 0.55 {
            return TradingSignal(action: .sell, confidence: min(sellScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Kein Scalp-Setup", strategy: name, pair: pair)
    }
}

// MARK: - Ultra Scalper Strategy (Leverage-Ready — 1-3h Haltedauer, A+ Setups only)
// Extrem selektiv: Braucht 4+ gleichzeitige Bestätigungen für einen Entry.
// Designt für Hebel-Trading: Enge Stops (0.5× ATR), Targets (1.5× ATR), schnelle Exits.
// Nur die besten 5-10% aller Setups werden gehandelt.

public struct UltraScalpStrategy: TradingStrategy {
    public let name = "ultra_scalp"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        // Crash = absolutes No-Go für Leverage
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime — kein Leverage", strategy: name, pair: pair)
        }
        guard candles.count >= 30 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        let current = candles.last!
        let prev = candles[candles.count - 2]
        let prev2 = candles[candles.count - 3]
        var buyChecks = 0
        var sellChecks = 0
        var buyScore = 0.0
        var sellScore = 0.0
        var reasons: [String] = []

        // ═══ CHECK 1: BB-Squeeze-Release (Volatilitäts-Explosion) ═══
        // Bandbreite der letzten 5 Candles war eng, jetzt expandiert sie
        let bbWidth = indicators.bbMiddle > 0
            ? (indicators.bbUpper - indicators.bbLower) / indicators.bbMiddle : 0

        // Historische BB-Breite (Durchschnitt der letzten 10 Candles als Proxy)
        let recentCandles = Array(candles.suffix(12))
        var recentWidths: [Double] = []
        for i in 3..<(recentCandles.count - 2) {
            // Simplified: Verwende High-Low-Range als Volatilitäts-Proxy
            let range = recentCandles[i].high - recentCandles[i].low
            let avgPrice = (recentCandles[i].high + recentCandles[i].low) / 2
            if avgPrice > 0 { recentWidths.append(range / avgPrice) }
        }
        let avgRecentWidth = recentWidths.isEmpty ? bbWidth : recentWidths.reduce(0, +) / Double(recentWidths.count)
        let squeezeRelease = bbWidth > avgRecentWidth * 1.5 && avgRecentWidth < 0.015

        if squeezeRelease {
            if current.close > prev.close {
                buyChecks += 1; buyScore += 0.20
                reasons.append("BB-Squeeze-Release bullish (Breite \(String(format: "%.4f→%.4f", avgRecentWidth, bbWidth)))")
            } else {
                sellChecks += 1; sellScore += 0.20
                reasons.append("BB-Squeeze-Release bearish")
            }
        }

        // ═══ CHECK 2: MACD-Histogramm Beschleunigung (3 steigende/fallende Bars) ═══
        if candles.count >= 5 {
            let prev3Candles = Array(candles.suffix(5).dropLast())
            if let prevSnap = TechnicalAnalysis.computeSnapshot(candles: Array(candles.dropLast())),
               let prevSnap2 = TechnicalAnalysis.computeSnapshot(candles: Array(candles.dropLast(2))) {
                // Bullish: Histogramm wird positiver (beschleunigt nach oben)
                if indicators.macdHistogram > prevSnap.macdHistogram &&
                   prevSnap.macdHistogram > prevSnap2.macdHistogram &&
                   indicators.macdHistogram > 0 {
                    buyChecks += 1; buyScore += 0.18
                    reasons.append("MACD beschleunigt ↑ (\(String(format: "%.4f", indicators.macdHistogram)))")
                }
                // Bearish: Histogramm wird negativer
                if indicators.macdHistogram < prevSnap.macdHistogram &&
                   prevSnap.macdHistogram < prevSnap2.macdHistogram &&
                   indicators.macdHistogram < 0 {
                    sellChecks += 1; sellScore += 0.18
                    reasons.append("MACD beschleunigt ↓ (\(String(format: "%.4f", indicators.macdHistogram)))")
                }
            }
        }

        // ═══ CHECK 3: Volume-Explosion (>2× Durchschnitt) ═══
        if indicators.volumeRatio > 2.0 {
            if current.close > current.open {
                buyChecks += 1; buyScore += 0.18
            } else {
                sellChecks += 1; sellScore += 0.18
            }
            reasons.append("Volume-Explosion (\(String(format: "%.1fx", indicators.volumeRatio)))")
        } else if indicators.volumeRatio > 1.5 {
            if current.close > current.open { buyChecks += 1; buyScore += 0.10 }
            else { sellChecks += 1; sellScore += 0.10 }
            reasons.append("Erhöhtes Volumen (\(String(format: "%.1fx", indicators.volumeRatio)))")
        }

        // ═══ CHECK 4: Starke Candle (Body > 60% der Range = Momentum-Candle) ═══
        let body = abs(current.close - current.open)
        let range = current.high - current.low
        let bodyRatio = range > 0 ? body / range : 0

        if bodyRatio > 0.60 && range > 0 {
            let pctMove = body / min(current.open, current.close) * 100
            if pctMove > 0.3 { // Mindestens 0.3% Bewegung
                if current.close > current.open {
                    buyChecks += 1; buyScore += 0.15
                    reasons.append("Momentum-Candle bullish (\(String(format: "+%.2f%%", pctMove)), Body \(String(format: "%.0f%%", bodyRatio * 100)))")
                } else {
                    sellChecks += 1; sellScore += 0.15
                    reasons.append("Momentum-Candle bearish (\(String(format: "-%.2f%%", pctMove)), Body \(String(format: "%.0f%%", bodyRatio * 100)))")
                }
            }
        }

        // ═══ CHECK 5: EMA9-Slope (kurzfristiger Mikro-Trend) ═══
        let ema9dist = (current.close - indicators.ema9) / indicators.ema9 * 100
        if ema9dist > 0.1 && current.close > prev.close {
            buyChecks += 1; buyScore += 0.12
            reasons.append("Über EMA9 (\(String(format: "+%.2f%%", ema9dist)))")
        } else if ema9dist < -0.1 && current.close < prev.close {
            sellChecks += 1; sellScore += 0.12
            reasons.append("Unter EMA9 (\(String(format: "%.2f%%", ema9dist)))")
        }

        // ═══ CHECK 6: RSI im Momentum-Bereich (nicht extrem, sondern in Bewegung) ═══
        let rsi = indicators.rsi
        if rsi > 45 && rsi < 65 && current.close > prev.close {
            buyChecks += 1; buyScore += 0.10
            reasons.append("RSI-Momentum bullish (\(String(format: "%.0f", rsi)))")
        } else if rsi < 55 && rsi > 35 && current.close < prev.close {
            sellChecks += 1; sellScore += 0.10
            reasons.append("RSI-Momentum bearish (\(String(format: "%.0f", rsi)))")
        }

        // ═══ ATR-basierte Stop/Target Empfehlung ═══
        let atr = indicators.atr
        let stopDistance = atr * 0.5
        let targetDistance = atr * 1.5
        let riskReward = targetDistance / max(stopDistance, 0.01)

        // ═══ Fee-Awareness: ATR-Target muss Round-Trip-Fees decken ═══
        let feeRate = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
        let effFee = feeRate > 0 ? feeRate : 0.012
        let roundTripFee = current.close * effFee * 2  // 2.4% in EUR
        let targetCoversFeeds = targetDistance > roundTripFee * 1.5  // Target mind. 150% der Fees

        // ═══ SIGNAL-ENTSCHEIDUNG: Minimum 4 von 6 Checks + Fee-Check ═══
        let minChecks = 4

        if buyChecks >= minChecks && buyScore > sellScore {
            buyScore += 0.12 // Bonus für Multi-Konfirmation (erhöht von 0.10)
            if buyChecks >= 5 { buyScore += 0.08; reasons.append("5+ Checks — A++ Setup") }
            reasons.append("[\(buyChecks)/6 Checks] Stop: \(String(format: "%.2f€", stopDistance)) | Target: \(String(format: "%.2f€", targetDistance)) | R:R \(String(format: "%.1f", riskReward))")

            // Fee-Penalty: Wenn ATR-Target Fees kaum deckt → Confidence reduzieren
            if !targetCoversFeeds {
                buyScore *= 0.65
                reasons.append("ATR-Target < 1.5× Fees ⚠")
            }

            // Regime-Penalty (gemildert: 0.85 statt 0.70 für Bear)
            if regime == .bear { buyScore *= 0.85; reasons.append("Bear-Regime ⚠") }
            else if regime == .bull { buyScore *= 1.10 }

            return TradingSignal(action: .buy, confidence: min(buyScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair,
                                suggestedSize: nil)
        }

        if sellChecks >= minChecks && sellScore > buyScore {
            sellScore += 0.12
            if sellChecks >= 5 { sellScore += 0.08; reasons.append("5+ Checks — A++ Setup") }
            reasons.append("[\(sellChecks)/6 Checks] Stop: \(String(format: "%.2f€", stopDistance)) | Target: \(String(format: "%.2f€", targetDistance)) | R:R \(String(format: "%.1f", riskReward))")

            if !targetCoversFeeds {
                sellScore *= 0.65
                reasons.append("ATR-Target < 1.5× Fees ⚠")
            }

            if regime == .bull { sellScore *= 0.85; reasons.append("Bull-Regime ⚠") }
            else if regime == .bear { sellScore *= 1.10 }

            return TradingSignal(action: .sell, confidence: min(sellScore, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair,
                                suggestedSize: nil)
        }

        // Nicht genug Bestätigungen
        let maxChecks = max(buyChecks, sellChecks)
        return TradingSignal(action: .hold, confidence: 0,
            reason: maxChecks > 0 ? "Nur \(maxChecks)/\(minChecks) Checks — kein A+ Setup" : "Kein Ultra-Scalp-Setup",
            strategy: name, pair: pair)
    }
}

// MARK: - RSI Divergence Strategy (Preis vs. RSI Divergenz — eines der stärksten Signale)
// Bullish Divergence: Preis macht tiefere Tiefs, RSI macht höhere Tiefs → Abwärtstrend verliert Kraft
// Bearish Divergence: Preis macht höhere Hochs, RSI macht tiefere Hochs → Aufwärtstrend verliert Kraft

public struct DivergenceStrategy: TradingStrategy {
    public let name = "divergence"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }
        guard candles.count >= 50 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        var reasons: [String] = []

        // Swing-Tiefs und -Hochs über die letzten 30 Candles finden
        let lookback = Array(candles.suffix(30))
        var swingLows: [(idx: Int, price: Double, rsi: Double)] = []
        var swingHighs: [(idx: Int, price: Double, rsi: Double)] = []

        for i in 2..<(lookback.count - 2) {
            let low = lookback[i].low
            let high = lookback[i].high
            // Swing Low: tiefer als 2 Nachbarn links und rechts
            if low < lookback[i-1].low && low < lookback[i-2].low &&
               low < lookback[i+1].low && low < lookback[i+2].low {
                // RSI für diesen Punkt berechnen (aus den Candles bis hier)
                let subCloses = candles.prefix(candles.count - lookback.count + i + 1).map(\.close)
                let rsiArr = TechnicalAnalysis.rsi(subCloses, period: 14)
                let rsi = rsiArr.last ?? 50
                swingLows.append((i, low, rsi))
            }
            // Swing High
            if high > lookback[i-1].high && high > lookback[i-2].high &&
               high > lookback[i+1].high && high > lookback[i+2].high {
                let subCloses = candles.prefix(candles.count - lookback.count + i + 1).map(\.close)
                let rsiArr = TechnicalAnalysis.rsi(subCloses, period: 14)
                let rsi = rsiArr.last ?? 50
                swingHighs.append((i, high, rsi))
            }
        }

        // Bullish Divergence: Preis tiefere Tiefs + RSI höhere Tiefs
        if swingLows.count >= 2 {
            let prev = swingLows[swingLows.count - 2]
            let curr = swingLows[swingLows.count - 1]
            if curr.price < prev.price && curr.rsi > prev.rsi {
                var confidence = 0.55
                reasons.append("Bullish Divergenz (Preis: \(String(format: "%.0f→%.0f", prev.price, curr.price)), RSI: \(String(format: "%.0f→%.0f", prev.rsi, curr.rsi)))")
                // Stärke: Je größer die RSI-Divergenz, desto stärker
                let rsiDiff = curr.rsi - prev.rsi
                if rsiDiff > 10 { confidence += 0.15; reasons.append("Starke RSI-Divergenz (+\(String(format: "%.0f", rsiDiff)))") }
                else if rsiDiff > 5 { confidence += 0.08 }
                // EMA200 Bestätigung
                if candles.last!.close > indicators.ema200 { confidence += 0.08 }
                if regime == .bull { confidence += 0.05 }
                if regime == .bear { confidence *= 0.60; reasons.append("Bear-Regime (Bullish Div ×0.60)") }
                if indicators.volumeRatio > 1.2 { confidence += 0.05 }

                return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                    reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
            }
        }

        // Bearish Divergence: Preis höhere Hochs + RSI tiefere Hochs
        if swingHighs.count >= 2 {
            let prev = swingHighs[swingHighs.count - 2]
            let curr = swingHighs[swingHighs.count - 1]
            if curr.price > prev.price && curr.rsi < prev.rsi {
                var confidence = 0.55
                reasons.append("Bearish Divergenz (Preis: \(String(format: "%.0f→%.0f", prev.price, curr.price)), RSI: \(String(format: "%.0f→%.0f", prev.rsi, curr.rsi)))")
                let rsiDiff = prev.rsi - curr.rsi
                if rsiDiff > 10 { confidence += 0.15; reasons.append("Starke RSI-Divergenz (-\(String(format: "%.0f", rsiDiff)))") }
                else if rsiDiff > 5 { confidence += 0.08 }
                if candles.last!.close < indicators.ema200 { confidence += 0.08 }
                if regime == .bear { confidence += 0.10 }  // Bear: Bearish Div stärker (+0.10)
                if regime == .bull { confidence *= 0.80; reasons.append("Bull-Regime (Bearish Div ×0.80)") }
                if indicators.volumeRatio > 1.2 { confidence += 0.05 }

                return TradingSignal(action: .sell, confidence: min(confidence, 1.0),
                                    reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
            }
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Keine Divergenz", strategy: name, pair: pair)
    }
}

// MARK: - Volume Accumulation Strategy (Smart Money Detection)
// Erkennt Phasen wo "Smart Money" leise akkumuliert (steigende Volumen bei stabilen/fallenden Preisen)
// oder distribuiert (fallendes Volumen bei steigenden Preisen)

public struct VolumeAccumulationStrategy: TradingStrategy {
    public let name = "accumulation"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }
        guard candles.count >= 40 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten", strategy: name, pair: pair)
        }

        var reasons: [String] = []
        let recent20 = Array(candles.suffix(20))
        let prior20 = Array(candles.suffix(40).prefix(20))

        // On-Balance Volume (OBV) Trend berechnen
        var obv: [Double] = [0]
        for i in 1..<recent20.count {
            let prev = obv.last!
            if recent20[i].close > recent20[i-1].close { obv.append(prev + recent20[i].volume) }
            else if recent20[i].close < recent20[i-1].close { obv.append(prev - recent20[i].volume) }
            else { obv.append(prev) }
        }

        // OBV-Trend: Steigt OBV während Preis flach/fällt?
        let obvFirst = obv.prefix(5).reduce(0, +) / 5
        let obvLast = obv.suffix(5).reduce(0, +) / 5
        let obvTrend = obvFirst != 0 ? (obvLast - obvFirst) / abs(obvFirst) * 100 : 0

        // Preis-Trend der letzten 20 Candles
        let priceChange = (recent20.last!.close - recent20.first!.close) / recent20.first!.close * 100

        // Durchschnittsvolumen: Recent vs. Prior
        let recentAvgVol = recent20.map(\.volume).reduce(0, +) / Double(recent20.count)
        let priorAvgVol = prior20.map(\.volume).reduce(0, +) / Double(prior20.count)
        let volumeChange = priorAvgVol > 0 ? (recentAvgVol - priorAvgVol) / priorAvgVol * 100 : 0

        // Akkumulation: Volumen steigt, Preis flach oder leicht fallend
        if obvTrend > 15 && priceChange < 2 && priceChange > -5 {
            var confidence = 0.45
            reasons.append("Akkumulation erkannt (OBV +\(String(format: "%.0f%%", obvTrend)), Preis \(String(format: "%+.1f%%", priceChange)))")
            if volumeChange > 20 { confidence += 0.15; reasons.append("Volumen +\(String(format: "%.0f%%", volumeChange)) vs Vorperiode") }
            else if volumeChange > 10 { confidence += 0.08 }
            if indicators.rsi < 45 { confidence += 0.10; reasons.append("RSI niedrig (\(String(format: "%.0f", indicators.rsi)))") }
            if candles.last!.close > indicators.ema200 { confidence += 0.05 }
            if regime == .sideways { confidence += 0.08; reasons.append("Sideways-Regime (ideal)") }
            if regime == .bear { confidence *= 0.60; reasons.append("Bear-Regime (Akku-Buy ×0.60)") }

            return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        // Distribution: Volumen fällt, Preis steigt = Verkaufsdruck kommt
        if obvTrend < -15 && priceChange > 0 && priceChange < 8 {
            var confidence = 0.45
            reasons.append("Distribution erkannt (OBV \(String(format: "%.0f%%", obvTrend)), Preis \(String(format: "+%.1f%%", priceChange)))")
            if volumeChange < -15 { confidence += 0.12; reasons.append("Volumen \(String(format: "%.0f%%", volumeChange)) vs Vorperiode") }
            if indicators.rsi > 55 { confidence += 0.10; reasons.append("RSI hoch (\(String(format: "%.0f", indicators.rsi)))") }
            if candles.last!.close < indicators.ema200 { confidence += 0.05 }

            return TradingSignal(action: .sell, confidence: min(confidence, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Keine Akkumulation/Distribution", strategy: name, pair: pair)
    }
}

// MARK: - Support/Resistance Strategy (Key-Level-Erkennung + Bounce/Break)
// Findet horizontale Support/Resistance-Levels aus Preis-Historie
// Handelt Bounces (Abpraller) und bestätigte Breakouts

public struct SupportResistanceStrategy: TradingStrategy {
    public let name = "support_resistance"
    public var version: Int = 1
    public var params: StrategyParams

    public init(params: StrategyParams = StrategyParams()) {
        self.params = params
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        if regime == .crash {
            return TradingSignal(action: .hold, confidence: 0, reason: "Crash-Regime", strategy: name, pair: pair)
        }
        guard candles.count >= 100 else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Nicht genug Daten (min. 100 Candles)", strategy: name, pair: pair)
        }

        var reasons: [String] = []
        let current = candles.last!
        let lookback = Array(candles.suffix(100))

        // Key-Levels finden: Preiszonen die mehrfach getestet wurden
        let priceRange = (lookback.map(\.high).max()! - lookback.map(\.low).min()!)
        let zoneTolerance = priceRange * 0.005 // 0.5% Toleranz für "gleiche" Zone

        // Alle Swing-Highs und Swing-Lows sammeln
        var levels: [Double] = []
        for i in 2..<(lookback.count - 2) {
            let c = lookback[i]
            // Swing High
            if c.high >= lookback[i-1].high && c.high >= lookback[i-2].high &&
               c.high >= lookback[i+1].high && c.high >= lookback[i+2].high {
                levels.append(c.high)
            }
            // Swing Low
            if c.low <= lookback[i-1].low && c.low <= lookback[i-2].low &&
               c.low <= lookback[i+1].low && c.low <= lookback[i+2].low {
                levels.append(c.low)
            }
        }

        // Clustere Levels die nahe beieinander liegen
        var clusters: [(level: Double, touches: Int)] = []
        for level in levels {
            if let idx = clusters.firstIndex(where: { abs($0.level - level) < zoneTolerance }) {
                clusters[idx] = (level: (clusters[idx].level + level) / 2, touches: clusters[idx].touches + 1)
            } else {
                clusters.append((level: level, touches: 1))
            }
        }

        // Nur Levels mit mindestens 2 Berührungen sind signifikant
        let significantLevels = clusters.filter { $0.touches >= 2 }.sorted { $0.level < $1.level }

        guard !significantLevels.isEmpty else {
            return TradingSignal(action: .hold, confidence: 0, reason: "Keine signifikanten Levels", strategy: name, pair: pair)
        }

        // Nächsten Support (unter aktuellem Preis) und Resistance (über aktuellem Preis) finden
        let supports = significantLevels.filter { $0.level < current.close }
        let resistances = significantLevels.filter { $0.level > current.close }

        // Support-Bounce: Preis nähert sich starkem Support von oben
        if let nearestSupport = supports.last {
            let distancePct = (current.close - nearestSupport.level) / current.close * 100
            if distancePct < 1.0 && distancePct > 0 {
                var confidence = 0.40
                reasons.append("Support-Bounce bei \(String(format: "%.2f", nearestSupport.level)) (\(nearestSupport.touches)× getestet, \(String(format: "%.1f%%", distancePct)) entfernt)")
                if nearestSupport.touches >= 3 { confidence += 0.15; reasons.append("Starker Support (\(nearestSupport.touches)×)") }
                if indicators.rsi < 40 { confidence += 0.10 }
                if indicators.volumeRatio > 1.3 { confidence += 0.08 }
                if current.close > indicators.ema200 { confidence += 0.05 }
                // Regime-Adjustierung: Bear = Support bricht oft, Sideways = S/R ideal
                if regime == .bear { confidence *= 0.55; reasons.append("Bear-Regime (Support ×0.55)") }
                if regime == .sideways { confidence *= 1.10; reasons.append("Sideways (S/R ideal)") }

                return TradingSignal(action: .buy, confidence: min(confidence, 1.0),
                                    reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
            }
        }

        // Resistance-Rejection: Preis nähert sich Widerstand von unten und prallt ab
        if let nearestResistance = resistances.first {
            let distancePct = (nearestResistance.level - current.close) / current.close * 100
            if distancePct < 1.0 && distancePct > 0 {
                // Prüfe ob aktuelle Candle Ablehnung zeigt (langer oberer Docht)
                let upperWick = current.high - max(current.open, current.close)
                let body = abs(current.close - current.open)
                let isRejection = upperWick > body * 1.5

                if isRejection {
                    var confidence = 0.40
                    reasons.append("Resistance-Rejection bei \(String(format: "%.2f", nearestResistance.level)) (\(nearestResistance.touches)× getestet)")
                    reasons.append("Langer oberer Docht = Ablehnung")
                    if nearestResistance.touches >= 3 { confidence += 0.15 }
                    if indicators.rsi > 60 { confidence += 0.10 }
                    if current.close < indicators.ema200 { confidence += 0.05 }
                    // Regime: Bear-Regime verstärkt Sell-Signale, Sideways = S/R ideal
                    if regime == .bear { confidence += 0.10; reasons.append("Bear (Resistance +0.10)") }
                    if regime == .sideways { confidence *= 1.10; reasons.append("Sideways (S/R ideal)") }

                    return TradingSignal(action: .sell, confidence: min(confidence, 1.0),
                                        reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
                }
            }
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Kein S/R-Signal", strategy: name, pair: pair)
    }
}

// MARK: - Strategy Engine (verwaltet alle Strategien)

public actor StrategyEngine {
    public static let shared = StrategyEngine()

    private var strategies: [any TradingStrategy] = [
        MomentumStrategy(),
        BreakoutStrategy(),
        MeanReversionStrategy(),
        TrendFollowingStrategy(),
        ScalpingStrategy(),
        UltraScalpStrategy(),
        DivergenceStrategy(),
        VolumeAccumulationStrategy(),
        SupportResistanceStrategy()
    ]

    private var customStrategies: [CustomStrategy] = []
    private var confidenceThreshold: Double = 0.8
    private let strategiesPath: URL

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/trading")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        strategiesPath = base.appendingPathComponent("strategies.json")
        customStrategies = CustomStrategyStore.load()
    }

    public func syncFromDefaults() {
        let d = UserDefaults.standard
        let threshold = d.double(forKey: "kobold.trading.confidenceThreshold")
        if threshold > 0 { confidenceThreshold = threshold }
    }

    /// Evaluiert alle aktiven Strategien (built-in + custom) und gibt Signale über dem Threshold zurück
    public func evaluateAll(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) async -> [TradingSignal] {
        let d = UserDefaults.standard
        let log = TradingActivityLog.shared
        var signals: [TradingSignal] = []

        // Built-in Strategien
        for strategy in strategies {
            let key = "kobold.trading.strategies.\(strategy.name)"
            let enabled = d.object(forKey: key) != nil ? d.bool(forKey: key) : true
            guard enabled else { continue }

            let signal = strategy.evaluate(pair: pair, candles: candles, indicators: indicators, regime: regime)
            if signal.action != .hold && signal.confidence >= confidenceThreshold {
                signals.append(signal)
                await log.add("[\(pair)] \(strategy.name) → \(signal.action.rawValue) \(String(format: "%.0f%%", signal.confidence * 100)) ✓", type: .signal)
            } else if signal.action != .hold {
                await log.add("[\(pair)] \(strategy.name) → \(signal.action.rawValue) \(String(format: "%.0f%%", signal.confidence * 100)) < \(String(format: "%.0f%%", confidenceThreshold * 100)) Threshold", type: .signal)
            }
        }

        // Custom-Strategien
        for cs in customStrategies {
            let key = "kobold.trading.strategies.\(cs.name)"
            let enabled = d.object(forKey: key) != nil ? d.bool(forKey: key) : true
            guard enabled else { continue }

            let signal = cs.evaluate(pair: pair, candles: candles, indicators: indicators, regime: regime)
            if signal.action != .hold && signal.confidence >= confidenceThreshold {
                signals.append(signal)
                await log.add("[\(pair)] \(cs.name) → \(signal.action.rawValue) \(String(format: "%.0f%%", signal.confidence * 100)) ✓ (Custom)", type: .signal)
            } else if signal.action != .hold {
                await log.add("[\(pair)] \(cs.name) → \(signal.action.rawValue) \(String(format: "%.0f%%", signal.confidence * 100)) < Threshold (Custom)", type: .signal)
            }
        }

        // === Strategy-Familien-Deduplizierung ===
        // RSI/BB/MACD-basierte Strategien teilen Indikatoren → inflationierte Bestätigung verhindern
        // Pro Familie: nur das stärkste Signal behalten
        let families: [[String]] = [
            ["momentum", "scalping", "ultra_scalp"],       // RSI-Familie
            ["mean_reversion", "scalping", "ultra_scalp"], // Bollinger-Familie
            ["momentum", "trend_following"],                // MACD-Familie
            ["breakout", "accumulation"],                   // Volume-Familie
            ["support_resistance", "breakout"]              // Level-Familie
        ]

        for members in families {
            for action in [TradeAction.buy, TradeAction.sell] {
                let familySignals = signals.filter { members.contains($0.strategy) && $0.action == action }
                if familySignals.count > 1 {
                    let best = familySignals.max(by: { $0.confidence < $1.confidence })!
                    let removed = familySignals.filter { $0.strategy != best.strategy }
                    signals.removeAll { s in removed.contains(where: { $0.strategy == s.strategy && $0.action == s.action }) }
                    let removedNames = removed.map(\.strategy).joined(separator: ", ")
                    await log.add("[\(pair)] Dedup: \(best.strategy) behält \(action.rawValue) — entfernt: \(removedNames)", type: .signal)
                }
            }
        }

        // === Gewichtete Konflikt-Resolution + SELL-Veto ===
        let buySignals = signals.filter { $0.action == .buy }
        let sellSignals = signals.filter { $0.action == .sell }
        if !buySignals.isEmpty && !sellSignals.isEmpty {
            let buyWeight = buySignals.reduce(0.0) { $0 + $1.confidence }
            let sellWeight = sellSignals.reduce(0.0) { $0 + $1.confidence }

            // SELL-Veto: Ein einzelnes sehr starkes Sell-Signal (>85%) blockt alle Buys
            let hasSellVeto = sellSignals.contains(where: { $0.confidence > 0.85 })

            if hasSellVeto {
                signals = sellSignals
                await log.add("[\(pair)] SELL-VETO: Signal >85%% — alle BUYs blockiert", type: .signal)
            } else if buyWeight > sellWeight * 1.3 {
                // Buys brauchen 30% Übergewicht um durchzukommen
                signals = buySignals
                await log.add("[\(pair)] Konflikt: BUY-Gewicht \(String(format: "%.2f", buyWeight)) > SELL \(String(format: "%.2f", sellWeight)) × 1.3 — BUY gewinnt", type: .signal)
            } else if sellWeight > buyWeight {
                signals = sellSignals
                await log.add("[\(pair)] Konflikt: SELL-Gewicht \(String(format: "%.2f", sellWeight)) > BUY \(String(format: "%.2f", buyWeight)) — SELL gewinnt", type: .signal)
            } else {
                // Gleichstand oder BUY knapp vorne (ohne 30% Übergewicht) → nichts tun
                await log.add("[\(pair)] Konflikt: BUY \(String(format: "%.2f", buyWeight)) vs SELL \(String(format: "%.2f", sellWeight)) — Gleichstand, HOLD", type: .signal)
                signals = []
            }
        }

        // === Gebühren-Awareness: BUY-Signale nur wenn erwartete Bewegung > 3× Round-Trip-Gebühren ===
        let feeRate = d.double(forKey: "kobold.trading.feeRate")
        let effectiveFee = feeRate > 0 ? feeRate : 0.012
        let minRequiredMovePct = effectiveFee * 2 * 3 * 100  // 2× Fee × 3 = min. % Bewegung

        let filteredSignals = signals.filter { signal in
            if signal.action == .sell { return true }
            let minConfidence = minRequiredMovePct / 10.0
            return signal.confidence >= minConfidence
        }

        return filteredSignals.sorted { $0.confidence > $1.confidence }
    }

    /// Gibt alle Strategien zurück (built-in + custom)
    public func getActiveStrategies() -> [(name: String, version: Int, enabled: Bool)] {
        let d = UserDefaults.standard
        var result = strategies.map { s -> (name: String, version: Int, enabled: Bool) in
            let key = "kobold.trading.strategies.\(s.name)"
            let enabled = d.object(forKey: key) != nil ? d.bool(forKey: key) : true
            return (s.name, s.version, enabled)
        }
        for cs in customStrategies {
            let key = "kobold.trading.strategies.\(cs.name)"
            let enabled = d.object(forKey: key) != nil ? d.bool(forKey: key) : true
            result.append((cs.name, cs.version, enabled))
        }
        return result
    }

    // MARK: - Custom Strategy Management

    public func addCustomStrategy(_ strategy: CustomStrategy) -> String {
        if strategies.contains(where: { $0.name == strategy.name }) ||
           customStrategies.contains(where: { $0.name == strategy.name }) {
            return "Strategie '\(strategy.name)' existiert bereits."
        }
        customStrategies.append(strategy)
        CustomStrategyStore.save(customStrategies)
        UserDefaults.standard.set(true, forKey: "kobold.trading.strategies.\(strategy.name)")
        return "Strategie '\(strategy.name)' erstellt mit \(strategy.rules.count) Regeln."
    }

    public func removeCustomStrategy(name: String) -> String {
        guard let idx = customStrategies.firstIndex(where: { $0.name == name }) else {
            return "Custom-Strategie '\(name)' nicht gefunden."
        }
        customStrategies.remove(at: idx)
        CustomStrategyStore.save(customStrategies)
        UserDefaults.standard.removeObject(forKey: "kobold.trading.strategies.\(name)")
        return "Strategie '\(name)' gelöscht."
    }

    public func getCustomStrategies() -> [CustomStrategy] {
        return customStrategies
    }

    public func getStrategy(name: String) -> (any TradingStrategy)? {
        if let s = strategies.first(where: { $0.name == name }) { return s }
        if let cs = customStrategies.first(where: { $0.name == name }) { return cs }
        return nil
    }

    /// Speichert aktuelle Strategie-Parameter als JSON
    public func saveStrategies() {
        var dict: [String: Any] = [:]
        for s in strategies {
            dict[s.name] = [
                "version": s.version,
                "params": [
                    "rsiOversold": s.params.rsiOversold,
                    "rsiOverbought": s.params.rsiOverbought,
                    "macdThreshold": s.params.macdThreshold,
                    "breakoutPeriod": s.params.breakoutPeriod,
                    "volumeMultiplier": s.params.volumeMultiplier,
                    "bbStdDev": s.params.bbStdDev,
                    "reversionThreshold": s.params.reversionThreshold,
                ]
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: strategiesPath)
        }
    }

    /// Aktualisiert Strategy-Parameter (für Self-Improvement Loop)
    public func updateParams(strategyName: String, params: StrategyParams) {
        for i in 0..<strategies.count {
            if strategies[i].name == strategyName {
                strategies[i].params = params
                switch strategyName {
                case "momentum":
                    var s = strategies[i] as! MomentumStrategy
                    s.params = params; s.version += 1; strategies[i] = s
                case "breakout":
                    var s = strategies[i] as! BreakoutStrategy
                    s.params = params; s.version += 1; strategies[i] = s
                case "mean_reversion":
                    var s = strategies[i] as! MeanReversionStrategy
                    s.params = params; s.version += 1; strategies[i] = s
                case "trend_following":
                    var s = strategies[i] as! TrendFollowingStrategy
                    s.params = params; s.version += 1; strategies[i] = s
                case "scalping":
                    var s = strategies[i] as! ScalpingStrategy
                    s.params = params; s.version += 1; strategies[i] = s
                default: break
                }
            }
        }
        saveStrategies()
    }
}
#endif
