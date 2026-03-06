#if os(macOS)
import Foundation
import Accelerate

// MARK: - OHLCV Candle

public struct Candle: Sendable, Codable {
    public let timestamp: Double   // Unix epoch
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double

    public init(timestamp: Double, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.timestamp = timestamp; self.open = open; self.high = high
        self.low = low; self.close = close; self.volume = volume
    }
}

// MARK: - Indicator Results

public struct IndicatorSnapshot: Sendable {
    public let rsi: Double
    public let macdLine: Double
    public let macdSignal: Double
    public let macdHistogram: Double
    public let ema9: Double
    public let ema21: Double
    public let ema50: Double
    public let ema200: Double
    public let bbUpper: Double
    public let bbMiddle: Double
    public let bbLower: Double
    public let bbPercentB: Double    // Position within bands (0-1)
    public let atr: Double
    public let volumeSMA: Double
    public let volumeRatio: Double   // Current volume / SMA
    public let emaSlope50: Double    // Slope of EMA50 (normalized)
}

// MARK: - Technical Analysis Engine

public enum TechnicalAnalysis {

    // MARK: - EMA (Exponential Moving Average)

    public static func ema(_ values: [Double], period: Int) -> [Double] {
        guard values.count >= period else { return values }
        let k = 2.0 / Double(period + 1)
        var result = [Double](repeating: 0, count: values.count)
        // SMA as seed for first EMA value
        var sum = 0.0
        for i in 0..<period { sum += values[i] }
        result[period - 1] = sum / Double(period)
        for i in period..<values.count {
            result[i] = values[i] * k + result[i - 1] * (1 - k)
        }
        return result
    }

    // MARK: - RSI (Relative Strength Index)

    public static func rsi(_ closes: [Double], period: Int = 14) -> [Double] {
        guard closes.count > period else { return [Double](repeating: 50, count: closes.count) }
        var gains = [Double]()
        var losses = [Double]()
        for i in 1..<closes.count {
            let delta = closes[i] - closes[i - 1]
            gains.append(max(delta, 0))
            losses.append(max(-delta, 0))
        }
        var result = [Double](repeating: 50, count: closes.count)
        var avgGain = gains[0..<period].reduce(0, +) / Double(period)
        var avgLoss = losses[0..<period].reduce(0, +) / Double(period)

        for i in period..<gains.count {
            avgGain = (avgGain * Double(period - 1) + gains[i]) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + losses[i]) / Double(period)
            let rs = avgLoss > 0 ? avgGain / avgLoss : 100
            result[i + 1] = 100 - (100 / (1 + rs))
        }
        return result
    }

    // MARK: - MACD (Moving Average Convergence Divergence)

    public struct MACDResult: Sendable {
        public let macdLine: [Double]
        public let signalLine: [Double]
        public let histogram: [Double]
    }

    public static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACDResult {
        let emaFast = ema(closes, period: fast)
        let emaSlow = ema(closes, period: slow)
        var macdLine = [Double](repeating: 0, count: closes.count)
        for i in (slow - 1)..<closes.count {
            macdLine[i] = emaFast[i] - emaSlow[i]
        }
        let signalLine = ema(macdLine, period: signal)
        var histogram = [Double](repeating: 0, count: closes.count)
        for i in 0..<closes.count { histogram[i] = macdLine[i] - signalLine[i] }
        return MACDResult(macdLine: macdLine, signalLine: signalLine, histogram: histogram)
    }

    // MARK: - Bollinger Bands

    public struct BollingerResult: Sendable {
        public let upper: [Double]
        public let middle: [Double]
        public let lower: [Double]
    }

    public static func bollingerBands(_ closes: [Double], period: Int = 20, stdDev: Double = 2.0) -> BollingerResult {
        let n = closes.count
        var upper = [Double](repeating: 0, count: n)
        var middle = [Double](repeating: 0, count: n)
        var lower = [Double](repeating: 0, count: n)

        for i in (period - 1)..<n {
            let window = Array(closes[(i - period + 1)...i])
            let mean = window.reduce(0, +) / Double(period)
            let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(period)
            let sd = sqrt(variance)
            middle[i] = mean
            upper[i] = mean + stdDev * sd
            lower[i] = mean - stdDev * sd
        }
        return BollingerResult(upper: upper, middle: middle, lower: lower)
    }

    // MARK: - ATR (Average True Range)

    public static func atr(_ candles: [Candle], period: Int = 14) -> [Double] {
        guard candles.count > 1 else { return [0] }
        var trueRanges = [Double]()
        trueRanges.append(candles[0].high - candles[0].low)
        for i in 1..<candles.count {
            let hl = candles[i].high - candles[i].low
            let hc = abs(candles[i].high - candles[i - 1].close)
            let lc = abs(candles[i].low - candles[i - 1].close)
            trueRanges.append(max(hl, hc, lc))
        }
        return ema(trueRanges, period: period)
    }

    // MARK: - Volume SMA

    public static func volumeSMA(_ candles: [Candle], period: Int = 20) -> [Double] {
        let volumes = candles.map(\.volume)
        let n = volumes.count
        var result = [Double](repeating: 0, count: n)
        for i in (period - 1)..<n {
            result[i] = volumes[(i - period + 1)...i].reduce(0, +) / Double(period)
        }
        return result
    }

    // MARK: - Linear Regression

    public static func linearRegression(_ values: [Double]) -> (slope: Double, intercept: Double, r2: Double) {
        let n = Double(values.count)
        guard n > 1 else { return (0, values.first ?? 0, 0) }
        let x = (0..<values.count).map(Double.init)
        let sumX = x.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(x, values).map(*).reduce(0, +)
        let sumXX = x.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return (0, sumY / n, 0) }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        // R²
        let yMean = sumY / n
        let ssTot = values.map { ($0 - yMean) * ($0 - yMean) }.reduce(0, +)
        let ssRes: Double = zip(x, values).map { xi, yi in
            let predicted = slope * xi + intercept
            return (yi - predicted) * (yi - predicted)
        }.reduce(0.0, +)
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0
        return (slope, intercept, r2)
    }

    // MARK: - Full Indicator Snapshot

    public static func computeSnapshot(candles: [Candle]) -> IndicatorSnapshot? {
        guard candles.count >= 200 else {
            // Need at least 200 candles for EMA200
            return computePartialSnapshot(candles: candles)
        }
        let closes = candles.map(\.close)
        let n = closes.count - 1 // latest index

        let rsiValues = rsi(closes)
        let macdResult = macd(closes)
        let ema9Values = ema(closes, period: 9)
        let ema21Values = ema(closes, period: 21)
        let ema50Values = ema(closes, period: 50)
        let ema200Values = ema(closes, period: 200)
        let bb = bollingerBands(closes)
        let atrValues = atr(candles)
        let volSMA = volumeSMA(candles)

        let bbRange = bb.upper[n] - bb.lower[n]
        let bbPercentB = bbRange > 0 ? (closes[n] - bb.lower[n]) / bbRange : 0.5

        let currentVolSMA = volSMA[n] > 0 ? volSMA[n] : 1
        let volumeRatio = candles[n].volume / currentVolSMA

        // EMA50 slope: normalized change over last 5 periods
        let emaSlope = n >= 5 && ema50Values[n - 5] != 0
            ? (ema50Values[n] - ema50Values[n - 5]) / ema50Values[n - 5] * 100
            : 0

        return IndicatorSnapshot(
            rsi: rsiValues[n],
            macdLine: macdResult.macdLine[n],
            macdSignal: macdResult.signalLine[n],
            macdHistogram: macdResult.histogram[n],
            ema9: ema9Values[n], ema21: ema21Values[n],
            ema50: ema50Values[n], ema200: ema200Values[n],
            bbUpper: bb.upper[n], bbMiddle: bb.middle[n], bbLower: bb.lower[n],
            bbPercentB: bbPercentB,
            atr: atrValues[n],
            volumeSMA: volSMA[n],
            volumeRatio: volumeRatio,
            emaSlope50: emaSlope
        )
    }

    // Partial snapshot when fewer than 200 candles available
    private static func computePartialSnapshot(candles: [Candle]) -> IndicatorSnapshot? {
        guard candles.count >= 26 else { return nil }  // Minimum for MACD
        let closes = candles.map(\.close)
        let n = closes.count - 1

        let rsiValues = rsi(closes)
        let macdResult = macd(closes)
        let ema9Values = ema(closes, period: 9)
        let ema21Values = ema(closes, period: 21)
        let ema50Values = candles.count >= 50 ? ema(closes, period: 50) : ema(closes, period: min(closes.count, 20))
        let ema200Values = candles.count >= 200 ? ema(closes, period: 200) : ema50Values
        let bb = bollingerBands(closes, period: min(20, closes.count))
        let atrValues = atr(candles, period: min(14, candles.count - 1))
        let volSMA = volumeSMA(candles, period: min(20, candles.count))

        let bbRange = bb.upper[n] - bb.lower[n]
        let bbPercentB = bbRange > 0 ? (closes[n] - bb.lower[n]) / bbRange : 0.5
        let currentVolSMA = volSMA[n] > 0 ? volSMA[n] : 1
        let emaSlope = n >= 5 && ema50Values[n - 5] != 0
            ? (ema50Values[n] - ema50Values[n - 5]) / ema50Values[n - 5] * 100 : 0

        return IndicatorSnapshot(
            rsi: rsiValues[n],
            macdLine: macdResult.macdLine[n], macdSignal: macdResult.signalLine[n],
            macdHistogram: macdResult.histogram[n],
            ema9: ema9Values[n], ema21: ema21Values[n],
            ema50: ema50Values[n], ema200: ema200Values[n],
            bbUpper: bb.upper[n], bbMiddle: bb.middle[n], bbLower: bb.lower[n],
            bbPercentB: bbPercentB,
            atr: atrValues[n], volumeSMA: volSMA[n], volumeRatio: candles[n].volume / currentVolSMA,
            emaSlope50: emaSlope
        )
    }
}
#endif
