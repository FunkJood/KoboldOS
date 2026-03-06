#if os(macOS)
import Foundation

// MARK: - Forecast Result

public struct ForecastResult: Sendable, Codable {
    public let horizon: String          // "1h", "4h", "24h", "48h", "7d"
    public let direction: String        // "UP", "DOWN", "SIDEWAYS"
    public let confidence: Double       // 0.0 - 1.0
    public let targetPct: Double        // Expected % move
    public let currentPrice: Double
    public let targetPrice: Double
    public let factors: [String]        // Contributing factors

    public init(horizon: String, direction: String, confidence: Double, targetPct: Double,
                currentPrice: Double, factors: [String]) {
        self.horizon = horizon; self.direction = direction
        self.confidence = min(max(confidence, 0), 1)
        self.targetPct = targetPct; self.currentPrice = currentPrice
        self.targetPrice = currentPrice * (1 + targetPct / 100)
        self.factors = factors
    }
}

// MARK: - Forecasting Engine (v2 — umfassende technische Analyse)

public struct ForecastingEngine: Sendable {

    public init() {}

    /// Generiert Forecasts für alle Horizonte (5 Zeithorizonte)
    public func forecast(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> [ForecastResult] {
        guard candles.count >= 50, let last = candles.last else { return [] }
        let closes = candles.map(\.close)

        // Support/Resistance einmal berechnen
        let sr = MarketRegimeDetector().supportResistance(candles: candles)

        // RSI-Serie für Divergenz-Erkennung
        let rsiSeries = TechnicalAnalysis.rsi(closes)

        // Trend-Stärke für Regime-adaptive Gewichtung
        let trendStrength = MarketRegimeDetector().trendStrength(indicators: indicators)

        return [
            forecastHorizon("1h", candles: candles, closes: closes, indicators: indicators,
                           regime: regime, currentPrice: last.close, lookback: 24,
                           sr: sr, rsiSeries: rsiSeries, trendStrength: trendStrength),
            forecastHorizon("4h", candles: candles, closes: closes, indicators: indicators,
                           regime: regime, currentPrice: last.close, lookback: 48,
                           sr: sr, rsiSeries: rsiSeries, trendStrength: trendStrength),
            forecastHorizon("24h", candles: candles, closes: closes, indicators: indicators,
                           regime: regime, currentPrice: last.close, lookback: 168,
                           sr: sr, rsiSeries: rsiSeries, trendStrength: trendStrength),
            forecastHorizon("48h", candles: candles, closes: closes, indicators: indicators,
                           regime: regime, currentPrice: last.close, lookback: 250,
                           sr: sr, rsiSeries: rsiSeries, trendStrength: trendStrength),
            forecastHorizon("7d", candles: candles, closes: closes, indicators: indicators,
                           regime: regime, currentPrice: last.close, lookback: min(closes.count, 336),
                           sr: sr, rsiSeries: rsiSeries, trendStrength: trendStrength),
        ]
    }

    // MARK: - Hauptprognose pro Horizont (12 Faktoren)

    private func forecastHorizon(_ horizon: String, candles: [Candle], closes: [Double],
                                  indicators: IndicatorSnapshot, regime: MarketRegime,
                                  currentPrice: Double, lookback: Int,
                                  sr: (support: [Double], resistance: [Double]),
                                  rsiSeries: [Double], trendStrength: Double) -> ForecastResult {
        var bullScore = 0.0
        var bearScore = 0.0
        var factors: [String] = []

        // Regime-adaptive Gewichte: In Trends zählen Trend-Indikatoren mehr,
        // in Seitwärtsmärkten zählen Mean-Reversion-Indikatoren mehr
        let weights = regimeAdaptiveWeights(regime: regime)

        // === 1. RSI Score ===
        let rsiScore = rsiSignal(indicators.rsi)
        if rsiScore > 0 {
            bullScore += rsiScore * weights.rsi
            factors.append("RSI bullish (\(String(format: "%.1f", indicators.rsi)))")
        } else if rsiScore < 0 {
            bearScore += abs(rsiScore) * weights.rsi
            factors.append("RSI bearish (\(String(format: "%.1f", indicators.rsi)))")
        }

        // === 2. MACD Score + Crossover-Nähe ===
        let macdStrength = min(abs(indicators.macdHistogram) / (currentPrice * 0.001), 1)
        if indicators.macdHistogram > 0 {
            bullScore += macdStrength * weights.macd
            factors.append("MACD bullish (\(String(format: "%.4f", indicators.macdHistogram)))")
        } else {
            bearScore += macdStrength * weights.macd
            factors.append("MACD bearish (\(String(format: "%.4f", indicators.macdHistogram)))")
        }

        // MACD Crossover Proximity: kurz vor Crossover = starkes Signal
        let histAbs = abs(indicators.macdHistogram)
        let macdLineAbs = abs(indicators.macdLine)
        if macdLineAbs > 0 && histAbs / macdLineAbs < 0.15 {
            // Histogram nahe Null = Crossover imminent
            let crossoverDir = indicators.macdHistogram > 0 ? "bearish" : "bullish"
            if crossoverDir == "bullish" {
                bullScore += 0.04
            } else {
                bearScore += 0.04
            }
            factors.append("MACD Crossover nahe (\(crossoverDir))")
        }

        // === 3. EMA Slope Trend ===
        let slope = indicators.emaSlope50
        if slope > 0.05 {
            bullScore += min(slope / 0.3, 1) * weights.trend
            factors.append("EMA50-Trend aufwärts (\(String(format: "%+.2f%%", slope)))")
        } else if slope < -0.05 {
            bearScore += min(abs(slope) / 0.3, 1) * weights.trend
            factors.append("EMA50-Trend abwärts (\(String(format: "%+.2f%%", slope)))")
        }

        // === 4. EMA Alignment (NEU) ===
        let alignment = emaAlignmentScore(indicators: indicators)
        if alignment > 0 {
            bullScore += alignment * weights.emaAlignment
            factors.append("EMA bullish aligned (9>21>50)")
        } else if alignment < 0 {
            bearScore += abs(alignment) * weights.emaAlignment
            factors.append("EMA bearish aligned (9<21<50)")
        }

        // === 5. Preis vs EMA200 — Long-Term Bias (NEU) ===
        if indicators.ema200 > 0 {
            let distPct = (currentPrice - indicators.ema200) / indicators.ema200 * 100
            if distPct > 0 {
                let strength = min(distPct / 10, 1)
                bullScore += strength * weights.ema200Bias
                if distPct > 5 { factors.append("Preis \(String(format: "+%.1f%%", distPct)) über EMA200") }
            } else {
                let strength = min(abs(distPct) / 10, 1)
                bearScore += strength * weights.ema200Bias
                if distPct < -5 { factors.append("Preis \(String(format: "%.1f%%", distPct)) unter EMA200") }
            }
        }

        // === 6. Bollinger Band Position ===
        if indicators.bbPercentB > 0.8 {
            let strength = (indicators.bbPercentB - 0.8) / 0.2
            bearScore += strength * weights.bollingerBand
            factors.append("Oberes BB-Band (%B=\(String(format: "%.2f", indicators.bbPercentB)))")
        } else if indicators.bbPercentB < 0.2 {
            let strength = (0.2 - indicators.bbPercentB) / 0.2
            bullScore += strength * weights.bollingerBand
            factors.append("Unteres BB-Band (%B=\(String(format: "%.2f", indicators.bbPercentB)))")
        }

        // === 7. Volume-Analyse (verbessert) ===
        let volScore = volumeAnalysis(candles: candles, indicators: indicators, slope: slope)
        if volScore.score > 0 {
            bullScore += volScore.score * weights.volume
        } else if volScore.score < 0 {
            bearScore += abs(volScore.score) * weights.volume
        }
        if let volFactor = volScore.factor { factors.append(volFactor) }

        // === 8. Linear Regression ===
        let recentN = min(lookback, closes.count)
        let recentCloses = Array(closes.suffix(recentN))
        let lr = TechnicalAnalysis.linearRegression(recentCloses)
        let projectedPct = (lr.slope * Double(recentN)) / currentPrice * 100
        if lr.r2 > 0.3 {
            if projectedPct > 0 {
                bullScore += min(projectedPct / 5, 1) * weights.linearRegression
                factors.append("LinReg aufwärts (R\u{00B2}=\(String(format: "%.2f", lr.r2)), \(String(format: "%+.1f%%", projectedPct)))")
            } else {
                bearScore += min(abs(projectedPct) / 5, 1) * weights.linearRegression
                factors.append("LinReg abwärts (R\u{00B2}=\(String(format: "%.2f", lr.r2)), \(String(format: "%+.1f%%", projectedPct)))")
            }
        }

        // === 9. Support/Resistance Proximity (NEU) ===
        let srScore = supportResistanceScore(price: currentPrice, sr: sr)
        if srScore.score > 0 {
            bullScore += srScore.score * weights.supportResistance
        } else if srScore.score < 0 {
            bearScore += abs(srScore.score) * weights.supportResistance
        }
        if let srFactor = srScore.factor { factors.append(srFactor) }

        // === 10. RSI Divergenz (NEU — eines der stärksten Umkehr-Signale) ===
        let divScore = rsiDivergenceScore(closes: closes, rsiSeries: rsiSeries, lookback: min(lookback, 30))
        if divScore.score > 0 {
            bullScore += divScore.score * weights.rsiDivergence
        } else if divScore.score < 0 {
            bearScore += abs(divScore.score) * weights.rsiDivergence
        }
        if let divFactor = divScore.factor { factors.append(divFactor) }

        // === 11. Candle Pattern Erkennung (NEU) ===
        let patternScore = candlePatternScore(candles: candles)
        if patternScore.score > 0 {
            bullScore += patternScore.score * weights.candlePatterns
        } else if patternScore.score < 0 {
            bearScore += abs(patternScore.score) * weights.candlePatterns
        }
        if let patFactor = patternScore.factor { factors.append(patFactor) }

        // === 12. Momentum Rate of Change (NEU) ===
        let rocPeriod = min(lookback, closes.count - 1)
        if rocPeriod > 0 {
            let rocBase = closes[closes.count - 1 - rocPeriod]
            if rocBase > 0 {
                let roc = (currentPrice - rocBase) / rocBase * 100
                let rocStrength = min(abs(roc) / 10, 1)
                if roc > 1 {
                    bullScore += rocStrength * weights.momentum
                    factors.append("Momentum +\(String(format: "%.1f%%", roc)) (\(rocPeriod)h)")
                } else if roc < -1 {
                    bearScore += rocStrength * weights.momentum
                    factors.append("Momentum \(String(format: "%.1f%%", roc)) (\(rocPeriod)h)")
                }
            }
        }

        // === Regime Adjustment (verbessert) ===
        switch regime {
        case .bull:
            bullScore *= 1.15
            bearScore *= 0.90  // Bears sind schwächer im Bull-Markt
            factors.append("Bull-Regime (+15% bullish)")
        case .bear:
            bearScore *= 1.15
            bullScore *= 0.90
            factors.append("Bear-Regime (+15% bearish)")
        case .crash:
            bearScore *= 1.35
            bullScore *= 0.70  // Kaufen im Crash ist extrem riskant
            factors.append("CRASH-Regime! (+35% bearish, -30% bullish)")
        case .sideways:
            // In Seitwärtsmärkten: Beide Seiten leicht dämpfen
            bullScore *= 0.95
            bearScore *= 0.95
            factors.append("Seitwärts-Regime (neutral)")
        case .unknown: break
        }

        // === ATR-basierte Konfidenz-Dämpfung ===
        // Hohe Volatilität = weniger Vorhersagbarkeit
        let atrPct = currentPrice > 0 ? indicators.atr / currentPrice * 100 : 0
        var volDampening = 1.0
        if atrPct > 3 {
            volDampening = max(0.6, 1.0 - (atrPct - 3) * 0.1)
            factors.append("Hohe Volatilität (ATR \(String(format: "%.1f%%", atrPct))) — Konfidenz gedämpft")
        }

        // === Direction & Confidence berechnen ===
        let netScore = bullScore - bearScore
        let totalScore = bullScore + bearScore
        let direction: String
        let rawConfidence: Double
        let targetPct: Double

        if netScore > 0.06 {
            direction = "UP"
            // Dominanz-basierte Confidence: wie stark überwiegt Bull über Bear?
            let dominance = totalScore > 0 ? bullScore / totalScore : 0.5
            rawConfidence = differentiatedConfidence(dominantScore: bullScore, dominance: dominance) * volDampening
            targetPct = netScore * horizonMultiplier(horizon)
        } else if netScore < -0.06 {
            direction = "DOWN"
            let dominance = totalScore > 0 ? bearScore / totalScore : 0.5
            rawConfidence = differentiatedConfidence(dominantScore: bearScore, dominance: dominance) * volDampening
            targetPct = netScore * horizonMultiplier(horizon)
        } else {
            direction = "SIDEWAYS"
            // Sideways-Confidence: hoch wenn Scores wirklich ausgeglichen, niedrig wenn beide stark
            let balanceRatio = totalScore > 0 ? (1.0 - abs(netScore) / totalScore) : 1.0
            rawConfidence = min(0.35 + balanceRatio * 0.25, 0.65) * volDampening
            targetPct = 0
        }

        // Konflikt-Penalty: Wenn Bull und Bear fast gleich stark → Vorhersage unsicher
        let dominanceRatio = totalScore > 0 ? abs(netScore) / totalScore : 0
        let conflictPenalty: Double
        if dominanceRatio < 0.15 {
            conflictPenalty = 0.70  // Sehr starke Konflikte = -30%
        } else if dominanceRatio < 0.25 {
            conflictPenalty = 0.85  // Moderate Konflikte = -15%
        } else {
            conflictPenalty = 1.0   // Klare Richtung
        }
        let finalConfidence = min(rawConfidence * conflictPenalty, 0.95)

        return ForecastResult(horizon: horizon, direction: direction, confidence: finalConfidence,
                             targetPct: targetPct, currentPrice: currentPrice, factors: factors)
    }

    // MARK: - RSI Signal (verbessert mit Stochastic-ähnlicher Bewertung)

    private func rsiSignal(_ rsi: Double) -> Double {
        if rsi < 20 { return 1.0 }                          // Extrem überverkauft
        if rsi < 30 { return (30 - rsi) / 10 * 0.8 }        // Stark überverkauft
        if rsi < 40 { return (40 - rsi) / 20 * 0.3 }        // Leicht überverkauft
        if rsi > 80 { return -1.0 }                          // Extrem überkauft
        if rsi > 70 { return -(rsi - 70) / 10 * 0.8 }       // Stark überkauft
        if rsi > 60 { return -(rsi - 60) / 20 * 0.3 }       // Leicht überkauft
        return 0 // Neutral (40-60)
    }

    // MARK: - EMA Alignment Score

    /// Bewertet die EMA-Ausrichtung: perfekt bullish = +1, perfekt bearish = -1
    private func emaAlignmentScore(indicators: IndicatorSnapshot) -> Double {
        var score = 0.0

        // EMA 9 > 21 > 50 = bullisch
        if indicators.ema9 > indicators.ema21 { score += 0.33 }
        else { score -= 0.33 }

        if indicators.ema21 > indicators.ema50 { score += 0.33 }
        else { score -= 0.33 }

        if indicators.ema50 > indicators.ema200 && indicators.ema200 > 0 { score += 0.34 }
        else if indicators.ema200 > 0 { score -= 0.34 }

        return score
    }

    // MARK: - Volume-Analyse (verbessert)

    private func volumeAnalysis(candles: [Candle], indicators: IndicatorSnapshot, slope: Double) -> (score: Double, factor: String?) {
        guard candles.count >= 10 else { return (0, nil) }

        // 1. Volume Ratio (aktuell vs Durchschnitt)
        let volRatio = indicators.volumeRatio
        var score = 0.0
        var factorParts: [String] = []

        if volRatio > 2.0 {
            // Extremes Volumen: verstärkt die aktuelle Richtung stark
            score = slope > 0 ? 1.0 : -1.0
            factorParts.append("Extremes Volumen (\(String(format: "%.1fx", volRatio)))")
        } else if volRatio > 1.5 {
            score = slope > 0 ? 0.7 : -0.7
            factorParts.append("Hohes Volumen (\(String(format: "%.1fx", volRatio)))")
        } else if volRatio < 0.5 {
            // Niedriges Volumen: Bewegung ist weniger zuverlässig
            factorParts.append("Niedriges Volumen (\(String(format: "%.1fx", volRatio)))")
        }

        // 2. Volume-Trend: Steigt oder fällt das Volumen?
        let recentVols = candles.suffix(10).map(\.volume)
        let olderVols = Array(candles.suffix(20).prefix(10)).map(\.volume)
        let recentAvg = recentVols.reduce(0, +) / max(Double(recentVols.count), 1)
        let olderAvg = olderVols.reduce(0, +) / max(Double(olderVols.count), 1)
        if olderAvg > 0 {
            let volTrend = (recentAvg - olderAvg) / olderAvg
            if volTrend > 0.3 {
                // Steigendes Volumen bestätigt die Richtung
                if slope > 0 { score += 0.3 }
                else { score -= 0.3 }
                factorParts.append("Vol steigend (\(String(format: "+%.0f%%", volTrend * 100)))")
            } else if volTrend < -0.3 {
                // Fallendes Volumen: Schwäche im Trend
                factorParts.append("Vol fallend (\(String(format: "%.0f%%", volTrend * 100)))")
            }
        }

        let factor = factorParts.isEmpty ? nil : factorParts.joined(separator: ", ")
        return (score, factor)
    }

    // MARK: - Support/Resistance Proximity

    private func supportResistanceScore(price: Double, sr: (support: [Double], resistance: [Double])) -> (score: Double, factor: String?) {
        guard !sr.support.isEmpty || !sr.resistance.isEmpty else { return (0, nil) }

        // Nächstes Support-Level
        if let nearestSupport = sr.support.first {
            let distPct = (price - nearestSupport) / price * 100
            if distPct > 0 && distPct < 2 {
                // Nahe am Support → Bounce wahrscheinlich (bullish)
                let strength = (2 - distPct) / 2
                return (strength, "Nahe Support \(String(format: "%.0f€", nearestSupport)) (\(String(format: "%.1f%%", distPct)) entfernt)")
            }
        }

        // Nächstes Resistance-Level
        if let nearestResistance = sr.resistance.first {
            let distPct = (nearestResistance - price) / price * 100
            if distPct > 0 && distPct < 2 {
                // Nahe an Resistance → Rejection wahrscheinlich (bearish)
                let strength = (2 - distPct) / 2
                return (-strength, "Nahe Resistance \(String(format: "%.0f€", nearestResistance)) (\(String(format: "%.1f%%", distPct)) entfernt)")
            }
        }

        return (0, nil)
    }

    // MARK: - RSI Divergenz (eines der stärksten Umkehr-Signale!)

    private func rsiDivergenceScore(closes: [Double], rsiSeries: [Double], lookback: Int) -> (score: Double, factor: String?) {
        guard closes.count >= lookback + 5, rsiSeries.count == closes.count, lookback >= 10 else { return (0, nil) }

        let n = closes.count
        let windowStart = n - lookback

        // Finde lokale Extrema im Lookback-Fenster
        let priceWindow = Array(closes[windowStart..<n])
        let rsiWindow = Array(rsiSeries[windowStart..<n])

        guard priceWindow.indices.min(by: { priceWindow[$0] < priceWindow[$1] }) != nil,
              priceWindow.indices.max(by: { priceWindow[$0] < priceWindow[$1] }) != nil
        else { return (0, nil) }

        // Bullish Divergence: Preis macht tieferes Tief, RSI macht höheres Tief
        // Prüfe ob aktueller Preis nahe einem Tief ist
        let currentPrice = closes.last!
        let currentRSI = rsiSeries.last!
        let periodLow = priceWindow.min() ?? currentPrice

        if currentPrice <= periodLow * 1.02 { // Innerhalb 2% des Tiefs
            // Suche vorheriges Tief in der ersten Hälfte des Fensters
            let firstHalf = Array(priceWindow.prefix(lookback / 2))
            let firstHalfRSI = Array(rsiWindow.prefix(lookback / 2))
            if let prevLowIdx = firstHalf.indices.min(by: { firstHalf[$0] < firstHalf[$1] }) {
                let prevLow = firstHalf[prevLowIdx]
                let prevRSI = firstHalfRSI[prevLowIdx]
                // Preis tiefer, RSI höher = bullish divergence
                if currentPrice < prevLow && currentRSI > prevRSI + 3 {
                    return (0.8, "Bullish RSI-Divergenz (Preis tiefer, RSI höher)")
                }
            }
        }

        // Bearish Divergence: Preis macht höheres Hoch, RSI macht tieferes Hoch
        let periodHigh = priceWindow.max() ?? currentPrice
        if currentPrice >= periodHigh * 0.98 { // Innerhalb 2% des Hochs
            let firstHalf = Array(priceWindow.prefix(lookback / 2))
            let firstHalfRSI = Array(rsiWindow.prefix(lookback / 2))
            if let prevHighIdx = firstHalf.indices.max(by: { firstHalf[$0] < firstHalf[$1] }) {
                let prevHigh = firstHalf[prevHighIdx]
                let prevRSI = firstHalfRSI[prevHighIdx]
                if currentPrice > prevHigh && currentRSI < prevRSI - 3 {
                    return (-0.8, "Bearish RSI-Divergenz (Preis höher, RSI tiefer)")
                }
            }
        }

        return (0, nil)
    }

    // MARK: - Candle Pattern Erkennung

    private func candlePatternScore(candles: [Candle]) -> (score: Double, factor: String?) {
        guard candles.count >= 3 else { return (0, nil) }

        let c = candles[candles.count - 1]  // Aktuelle Candle
        let p = candles[candles.count - 2]  // Vorherige Candle
        let pp = candles[candles.count - 3] // Zwei zurück

        let body = abs(c.close - c.open)
        let range = c.high - c.low
        guard range > 0 else { return (0, nil) }
        let bodyRatio = body / range

        let upperShadow = c.high - max(c.open, c.close)
        let lowerShadow = min(c.open, c.close) - c.low

        // === Doji (Unentschlossenheit → mögliche Umkehr) ===
        if bodyRatio < 0.1 && range > 0 {
            // Doji nach Aufwärtsbewegung = bearish
            if p.close > p.open && p.close > pp.close {
                return (-0.4, "Doji nach Aufwärtsbewegung (Umkehr?)")
            }
            // Doji nach Abwärtsbewegung = bullish
            if p.close < p.open && p.close < pp.close {
                return (0.4, "Doji nach Abwärtsbewegung (Umkehr?)")
            }
        }

        // === Hammer (bullish reversal) ===
        // Kleiner Body oben, langer unterer Schatten (≥2x Body)
        if lowerShadow > body * 2 && upperShadow < body * 0.5 && p.close < p.open {
            return (0.6, "Hammer-Muster (bullish reversal)")
        }

        // === Inverted Hammer / Shooting Star (bearish reversal) ===
        if upperShadow > body * 2 && lowerShadow < body * 0.5 && p.close > p.open {
            return (-0.6, "Shooting Star (bearish reversal)")
        }

        // === Bullish Engulfing ===
        if c.close > c.open && p.close < p.open // Bullish nach bearish
            && c.open <= p.close && c.close >= p.open {
            return (0.7, "Bullish Engulfing")
        }

        // === Bearish Engulfing ===
        if c.close < c.open && p.close > p.open // Bearish nach bullish
            && c.open >= p.close && c.close <= p.open {
            return (-0.7, "Bearish Engulfing")
        }

        // === Three White Soldiers (starkes bullish Signal) ===
        if c.close > c.open && p.close > p.open && pp.close > pp.open
            && c.close > p.close && p.close > pp.close
            && bodyRatio > 0.5 {
            return (0.8, "Three White Soldiers (starker Aufwärtstrend)")
        }

        // === Three Black Crows (starkes bearish Signal) ===
        if c.close < c.open && p.close < p.open && pp.close < pp.open
            && c.close < p.close && p.close < pp.close
            && bodyRatio > 0.5 {
            return (-0.8, "Three Black Crows (starker Abwärtstrend)")
        }

        return (0, nil)
    }

    // MARK: - Regime-adaptive Gewichtung

    private struct ForecastWeights {
        let rsi: Double
        let macd: Double
        let trend: Double
        let emaAlignment: Double
        let ema200Bias: Double
        let bollingerBand: Double
        let volume: Double
        let linearRegression: Double
        let supportResistance: Double
        let rsiDivergence: Double
        let candlePatterns: Double
        let momentum: Double
    }

    private func regimeAdaptiveWeights(regime: MarketRegime) -> ForecastWeights {
        switch regime {
        case .bull:
            // Im Aufwärtstrend: Trend-Indikatoren wichtiger
            return ForecastWeights(
                rsi: 0.10, macd: 0.12, trend: 0.15, emaAlignment: 0.10, ema200Bias: 0.08,
                bollingerBand: 0.06, volume: 0.08, linearRegression: 0.06,
                supportResistance: 0.06, rsiDivergence: 0.08, candlePatterns: 0.04, momentum: 0.07
            )
        case .bear:
            // Im Abwärtstrend: RSI-Divergenz und S/R wichtiger (Umkehr finden)
            return ForecastWeights(
                rsi: 0.12, macd: 0.10, trend: 0.12, emaAlignment: 0.08, ema200Bias: 0.08,
                bollingerBand: 0.08, volume: 0.06, linearRegression: 0.05,
                supportResistance: 0.10, rsiDivergence: 0.10, candlePatterns: 0.06, momentum: 0.05
            )
        case .sideways:
            // Seitwärts: Mean-Reversion-Indikatoren dominieren
            return ForecastWeights(
                rsi: 0.14, macd: 0.08, trend: 0.06, emaAlignment: 0.05, ema200Bias: 0.04,
                bollingerBand: 0.14, volume: 0.06, linearRegression: 0.05,
                supportResistance: 0.14, rsiDivergence: 0.10, candlePatterns: 0.08, momentum: 0.06
            )
        case .crash:
            // Crash: Alles bearish, RSI-Divergenz für Boden-Erkennung
            return ForecastWeights(
                rsi: 0.10, macd: 0.08, trend: 0.10, emaAlignment: 0.06, ema200Bias: 0.06,
                bollingerBand: 0.08, volume: 0.10, linearRegression: 0.04,
                supportResistance: 0.12, rsiDivergence: 0.14, candlePatterns: 0.06, momentum: 0.06
            )
        case .unknown:
            // Gleichverteilt
            return ForecastWeights(
                rsi: 0.12, macd: 0.10, trend: 0.10, emaAlignment: 0.08, ema200Bias: 0.06,
                bollingerBand: 0.10, volume: 0.08, linearRegression: 0.06,
                supportResistance: 0.08, rsiDivergence: 0.08, candlePatterns: 0.06, momentum: 0.08
            )
        }
    }

    // MARK: - Differenzierte Konfidenz (Score-Stärke × Dominanz)

    /// Berechnet Confidence aus zwei Dimensionen:
    /// 1. dominantScore: absolute Stärke des dominanten Signals (0-2+)
    /// 2. dominance: Anteil des dominanten Signals am Gesamt-Score (0.5-1.0)
    /// Output: 0.25-0.95 mit deutlich besserer Spreizung als Sigmoid
    private func differentiatedConfidence(dominantScore: Double, dominance: Double) -> Double {
        // Dimension 1: Score-Stärke → Basis-Confidence (0.25 - 0.75)
        // Stufenweise statt Sigmoid für klarere Differenzierung
        let strengthBase: Double
        if dominantScore < 0.15 {
            strengthBase = 0.25 + dominantScore * 1.0         // 0.25-0.40
        } else if dominantScore < 0.35 {
            strengthBase = 0.40 + (dominantScore - 0.15) * 1.0 // 0.40-0.60
        } else if dominantScore < 0.60 {
            strengthBase = 0.60 + (dominantScore - 0.35) * 0.6 // 0.60-0.75
        } else {
            strengthBase = min(0.75 + (dominantScore - 0.60) * 0.3, 0.85) // 0.75-0.85
        }

        // Dimension 2: Dominanz-Multiplikator (0.7 - 1.15)
        // 50% Dominanz = quasi Zufall → starke Strafe
        // 80%+ Dominanz = klares Signal → leichter Bonus
        let dominanceMultiplier: Double
        if dominance < 0.55 {
            dominanceMultiplier = 0.70   // Praktisch 50/50 → -30%
        } else if dominance < 0.65 {
            dominanceMultiplier = 0.70 + (dominance - 0.55) * 2.0  // 0.70-0.90
        } else if dominance < 0.80 {
            dominanceMultiplier = 0.90 + (dominance - 0.65) * 0.67 // 0.90-1.00
        } else {
            dominanceMultiplier = min(1.0 + (dominance - 0.80) * 0.75, 1.15) // 1.00-1.15
        }

        return min(max(strengthBase * dominanceMultiplier, 0.25), 0.95)
    }

    // MARK: - Horizon Multiplier

    private func horizonMultiplier(_ horizon: String) -> Double {
        switch horizon {
        case "1h": return 1.5
        case "4h": return 3.0
        case "24h": return 6.0
        case "48h": return 10.0
        case "7d": return 16.0
        default: return 2.0
        }
    }

    // MARK: - Report Generation (verbessert)

    public func generateReport(pair: String, forecasts: [ForecastResult], indicators: IndicatorSnapshot,
                                regime: MarketRegime, candles: [Candle] = []) -> String {
        let sr = MarketRegimeDetector().supportResistance(candles: candles)
        let trendStr = String(format: "%.0f/100", MarketRegimeDetector().trendStrength(indicators: indicators))

        var md = "# Markt-Forecast: \(pair)\n\n"
        md += "**Datum:** \(ISO8601DateFormatter().string(from: Date()))\n"
        md += "**Regime:** \(regime.emoji) \(regime.rawValue)\n"
        md += "**Trend-Stärke:** \(trendStr)\n"
        md += "**Aktueller Preis:** \(String(format: "%.2f", forecasts.first?.currentPrice ?? 0))\u{20AC}\n\n"

        // Support/Resistance
        if !sr.support.isEmpty || !sr.resistance.isEmpty {
            md += "## Support & Resistance\n"
            for s in sr.support { md += "- Support: \(String(format: "%.2f", s))\u{20AC}\n" }
            for r in sr.resistance { md += "- Resistance: \(String(format: "%.2f", r))\u{20AC}\n" }
            md += "\n"
        }

        md += "## Prognosen\n\n"
        md += "| Horizont | Richtung | Konfidenz | Ziel |\n"
        md += "|----------|----------|-----------|------|\n"
        for f in forecasts {
            let arrow = f.direction == "UP" ? "\u{2191}" : f.direction == "DOWN" ? "\u{2193}" : "\u{2192}"
            md += "| \(f.horizon) | \(arrow) \(f.direction) | \(String(format: "%.0f%%", f.confidence * 100)) | \(String(format: "%.2f\u{20AC}", f.targetPrice)) (\(String(format: "%+.2f%%", f.targetPct))) |\n"
        }

        md += "\n## Technische Indikatoren\n\n"
        md += "- **RSI:** \(String(format: "%.1f", indicators.rsi))\n"
        md += "- **MACD:** \(String(format: "%.4f", indicators.macdLine)) (Signal: \(String(format: "%.4f", indicators.macdSignal)), Hist: \(String(format: "%.4f", indicators.macdHistogram)))\n"
        md += "- **EMA:** 9=\(String(format: "%.2f", indicators.ema9)) 21=\(String(format: "%.2f", indicators.ema21)) 50=\(String(format: "%.2f", indicators.ema50)) 200=\(String(format: "%.2f", indicators.ema200))\n"
        md += "- **EMA Slope:** \(String(format: "%.3f%%", indicators.emaSlope50))\n"
        md += "- **BB %%B:** \(String(format: "%.2f", indicators.bbPercentB))\n"
        md += "- **ATR:** \(String(format: "%.2f", indicators.atr))\n"
        md += "- **Volume Ratio:** \(String(format: "%.2fx", indicators.volumeRatio))\n"

        md += "\n## Faktoren\n\n"
        for f in forecasts {
            md += "### \(f.horizon)\n"
            for factor in f.factors { md += "- \(factor)\n" }
        }

        return md
    }
}
#endif
