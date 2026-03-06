#if os(macOS)
import Foundation

// MARK: - Custom Strategy Rule

public struct StrategyRule: Sendable, Codable {
    public let indicator: String      // "rsi", "macd_histogram", "ema_crossover", "bb_percentb", "volume_ratio", "atr", "ema_slope"
    public let condition: String      // "above", "below", "crosses_above", "crosses_below", "between"
    public let value: Double          // Schwellenwert
    public let value2: Double?        // Zweiter Wert für "between"
    public let weight: Double         // Gewichtung 0-1
    public let action: String         // "buy", "sell"

    public init(indicator: String, condition: String, value: Double,
                value2: Double? = nil, weight: Double = 1.0, action: String = "buy") {
        self.indicator = indicator; self.condition = condition
        self.value = value; self.value2 = value2
        self.weight = min(max(weight, 0), 1); self.action = action
    }
}

// MARK: - Custom Strategy

public struct CustomStrategy: TradingStrategy, Sendable, Codable {
    public var name: String
    public var version: Int = 1
    public var params: StrategyParams = StrategyParams()
    public var rules: [StrategyRule]
    public var regimeFilter: [String]  // z.B. ["BULL", "SIDEWAYS"] — leer = alle Regimes

    public init(name: String, rules: [StrategyRule], regimeFilter: [String] = []) {
        self.name = name; self.rules = rules; self.regimeFilter = regimeFilter
    }

    public func evaluate(pair: String, candles: [Candle], indicators: IndicatorSnapshot, regime: MarketRegime) -> TradingSignal {
        // Regime-Filter prüfen
        if !regimeFilter.isEmpty && !regimeFilter.contains(regime.rawValue) {
            return TradingSignal(action: .hold, confidence: 0,
                                reason: "Regime \(regime.rawValue) nicht im Filter [\(regimeFilter.joined(separator: ","))]",
                                strategy: name, pair: pair)
        }

        var buyScore = 0.0
        var sellScore = 0.0
        var buyWeight = 0.0
        var sellWeight = 0.0
        var reasons: [String] = []

        for rule in rules {
            let indicatorValue = getIndicatorValue(rule.indicator, indicators: indicators)
            let matched = evaluateCondition(indicatorValue, condition: rule.condition,
                                            threshold: rule.value, threshold2: rule.value2)

            if matched {
                if rule.action == "buy" {
                    buyScore += rule.weight
                    buyWeight += rule.weight
                    reasons.append("\(rule.indicator) \(rule.condition) \(String(format: "%.2f", rule.value)) ✓")
                } else {
                    sellScore += rule.weight
                    sellWeight += rule.weight
                    reasons.append("\(rule.indicator) \(rule.condition) \(String(format: "%.2f", rule.value)) ✓")
                }
            } else {
                if rule.action == "buy" { buyWeight += rule.weight }
                else { sellWeight += rule.weight }
            }
        }

        // Confidence = gewichteter Anteil erfüllter Regeln
        let buyConf = buyWeight > 0 ? buyScore / buyWeight : 0
        let sellConf = sellWeight > 0 ? sellScore / sellWeight : 0

        if buyConf > sellConf && buyConf > 0.3 {
            return TradingSignal(action: .buy, confidence: min(buyConf, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        } else if sellConf > buyConf && sellConf > 0.3 {
            return TradingSignal(action: .sell, confidence: min(sellConf, 1.0),
                                reason: reasons.joined(separator: ", "), strategy: name, pair: pair)
        }

        return TradingSignal(action: .hold, confidence: 0, reason: "Regeln nicht erfüllt", strategy: name, pair: pair)
    }

    // MARK: - Indicator Value Lookup

    private func getIndicatorValue(_ indicator: String, indicators: IndicatorSnapshot) -> Double {
        switch indicator {
        case "rsi": return indicators.rsi
        case "macd_histogram": return indicators.macdHistogram
        case "macd_line": return indicators.macdLine
        case "macd_signal": return indicators.macdSignal
        case "bb_percentb": return indicators.bbPercentB
        case "volume_ratio": return indicators.volumeRatio
        case "atr": return indicators.atr
        case "ema_slope": return indicators.emaSlope50
        case "ema9": return indicators.ema9
        case "ema21": return indicators.ema21
        case "ema50": return indicators.ema50
        case "ema_crossover": return indicators.ema9 - indicators.ema21  // Positiv = bullish
        default: return 0
        }
    }

    // MARK: - Condition Evaluation

    private func evaluateCondition(_ value: Double, condition: String,
                                    threshold: Double, threshold2: Double?) -> Bool {
        switch condition {
        case "above": return value > threshold
        case "below": return value < threshold
        case "crosses_above": return value > threshold  // Vereinfacht (kein vorheriger Wert)
        case "crosses_below": return value < threshold
        case "between":
            guard let t2 = threshold2 else { return false }
            return value >= min(threshold, t2) && value <= max(threshold, t2)
        default: return false
        }
    }
}

// MARK: - Persistent Storage

public struct CustomStrategyStore: Sendable {
    private static let filePath: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/trading")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("custom_strategies.json")
    }()

    public static func load() -> [CustomStrategy] {
        guard let data = try? Data(contentsOf: filePath),
              let strategies = try? JSONDecoder().decode([CustomStrategy].self, from: data) else {
            return []
        }
        return strategies
    }

    public static func save(_ strategies: [CustomStrategy]) {
        guard let data = try? JSONEncoder().encode(strategies) else { return }
        try? data.write(to: filePath, options: .atomic)
    }
}
#endif
