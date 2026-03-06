#if os(macOS)
import Foundation

// MARK: - Market Regime

public enum MarketRegime: String, Sendable, Codable, CaseIterable {
    case bull = "BULL"
    case bear = "BEAR"
    case sideways = "SIDEWAYS"
    case crash = "CRASH"
    case unknown = "UNKNOWN"

    public var emoji: String {
        switch self {
        case .bull: return "🟢"
        case .bear: return "🔴"
        case .sideways: return "🟡"
        case .crash: return "⚫"
        case .unknown: return "⚪"
        }
    }

    public var tradingAdvice: String {
        switch self {
        case .bull: return "Trend-following, Momentum-Strategien bevorzugt"
        case .bear: return "Vorsicht, nur Short oder Absicherung"
        case .sideways: return "Mean-Reversion-Strategien bevorzugt"
        case .crash: return "TRADING PAUSIERT — Nur Emergency-Exits"
        case .unknown: return "Warte auf ausreichend Daten"
        }
    }
}

// MARK: - Market Regime Detector

public struct MarketRegimeDetector: Sendable {

    // Konfigurierbare Schwellenwerte
    public var emaSlopeThreshold: Double = 0.15       // EMA50 slope % für Trend
    public var atrLowMultiplier: Double = 0.5         // ATR < 0.5x Durchschnitt = low vol
    public var atrCrashMultiplier: Double = 2.0       // ATR > 2x Durchschnitt = crash vol
    public var crashDropThreshold: Double = 5.0       // 5% Drop in 4h = Crash
    public var crashWindowCandles: Int = 4            // Anzahl Candles für Crash-Detection (bei 1h = 4h)

    public init() {}

    /// Erkennt das aktuelle Marktregime basierend auf Candles und Indikatoren
    public func detect(candles: [Candle], indicators: IndicatorSnapshot) -> MarketRegime {
        guard candles.count >= 50 else { return .unknown }

        // Crash Detection (höchste Priorität)
        if isCrash(candles: candles, indicators: indicators) {
            return .crash
        }

        let emaSlope = indicators.emaSlope50
        let priceAboveEMA = candles.last!.close > indicators.ema50
        let atr = indicators.atr

        // ATR-Durchschnitt der letzten 50 Candles berechnen
        let atrValues = TechnicalAnalysis.atr(candles)
        let recentATR = Array(atrValues.suffix(50))
        let avgATR = recentATR.reduce(0, +) / Double(max(recentATR.count, 1))

        // Sideways: Niedrige Volatilität + flacher Trend
        if atr < avgATR * atrLowMultiplier && abs(emaSlope) < emaSlopeThreshold {
            return .sideways
        }

        // Bull: Aufwärtstrend + Preis über EMA50
        if emaSlope > emaSlopeThreshold && priceAboveEMA {
            return .bull
        }

        // Bear: Abwärtstrend + Preis unter EMA50
        if emaSlope < -emaSlopeThreshold && !priceAboveEMA {
            return .bear
        }

        // Default: Sideways wenn kein klarer Trend
        return .sideways
    }

    private func isCrash(candles: [Candle], indicators: IndicatorSnapshot) -> Bool {
        guard candles.count > crashWindowCandles else { return false }

        // Prüfe Preissturz über das Crash-Fenster
        let recentClose = candles.last!.close
        let windowStart = candles[candles.count - 1 - crashWindowCandles].close
        let dropPct = (windowStart - recentClose) / windowStart * 100

        // ATR-Durchschnitt
        let atrValues = TechnicalAnalysis.atr(candles)
        let longATR = Array(atrValues.suffix(50))
        let avgATR = longATR.reduce(0, +) / Double(max(longATR.count, 1))

        // Crash: starker Drop UND hohe Volatilität
        return dropPct > crashDropThreshold && indicators.atr > avgATR * atrCrashMultiplier
    }

    /// Trend-Stärke (0-100) basierend auf EMA-Alignment und RSI
    public func trendStrength(indicators: IndicatorSnapshot) -> Double {
        var score = 0.0

        // EMA-Alignment (0-40 Punkte)
        if indicators.ema9 > indicators.ema21 && indicators.ema21 > indicators.ema50 {
            score += 40 // Perfektes bullisches Alignment
        } else if indicators.ema9 < indicators.ema21 && indicators.ema21 < indicators.ema50 {
            score += 40 // Perfektes bärisches Alignment
        } else {
            score += 15 // Mixed
        }

        // EMA50 Slope (0-30 Punkte)
        let slopeScore = min(abs(indicators.emaSlope50) / 0.5 * 30, 30)
        score += slopeScore

        // RSI Extreme (0-30 Punkte)
        let rsiDist = abs(indicators.rsi - 50)
        score += min(rsiDist / 30 * 30, 30)

        return min(score, 100)
    }

    /// Support und Resistance Levels basierend auf Pivot Points
    public func supportResistance(candles: [Candle]) -> (support: [Double], resistance: [Double]) {
        guard candles.count >= 20 else { return ([], []) }
        let recent = Array(candles.suffix(20))
        let high = recent.map(\.high).max() ?? 0
        let low = recent.map(\.low).min() ?? 0
        let close = recent.last!.close
        let pivot = (high + low + close) / 3

        let s1 = 2 * pivot - high
        let s2 = pivot - (high - low)
        let r1 = 2 * pivot - low
        let r2 = pivot + (high - low)

        return (support: [s1, s2].sorted(by: >), resistance: [r1, r2].sorted())
    }
}
#endif
