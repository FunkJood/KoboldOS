#if os(macOS)
import Foundation

// MARK: - Trading Reporter (Telegram)
// Sendet Trade-Alerts, Risk-Alerts, Daily Summaries und Regime-Changes

public actor TradingReporter {
    public static let shared = TradingReporter()

    private var lastMessageTime: Date = .distantPast
    private let minInterval: TimeInterval = 5  // Min 5s zwischen Nachrichten
    private var messageQueue: [String] = []
    private var isProcessingQueue = false

    private init() {}

    // MARK: - Report Types

    public func sendTradeAlert(trade: TradeRecord, regime: MarketRegime) async {
        let side = trade.side == "BUY" ? "🟢 KAUF" : "🔴 VERKAUF"
        let msg = """
        📊 *Trade ausgeführt*

        \(side)
        *Paar:* `\(trade.pair)`
        *Strategie:* \(trade.strategy)
        *Preis:* \(String(format: "%.2f€", trade.price))
        *Menge:* \(String(format: "%.8f", trade.size))
        *Wert:* \(String(format: "%.2f€", trade.size * trade.price))
        *Konfidenz:* \(String(format: "%.0f%%", trade.confidence * 100))
        *Regime:* \(regime.emoji) \(regime.rawValue)
        """
        await enqueue(msg)
    }

    public func sendTradeClosedAlert(trade: TradeRecord) async {
        let pnl = trade.pnl ?? 0
        let emoji = pnl >= 0 ? "✅" : "❌"
        let msg = """
        \(emoji) *Trade geschlossen*

        *Paar:* `\(trade.pair)`
        *Entry:* \(String(format: "%.2f€", trade.price))
        *Exit:* \(String(format: "%.2f€", trade.exitPrice ?? 0))
        *P&L:* \(String(format: "%+.2f€", pnl))
        *Haltedauer:* \(trade.holdingTime ?? "?")
        *Strategie:* \(trade.strategy)
        """
        await enqueue(msg)
    }

    public func sendRiskAlert(reason: String) async {
        let msg = """
        ⚠️ *RISK ALERT*

        \(reason)

        _Trading wurde automatisch pausiert._
        """
        await enqueue(msg)
    }

    public func sendDailySummary(analytics: TradingAnalytics, regime: MarketRegime, openPositions: Int) async {
        let pnlEmoji = analytics.totalPnL >= 0 ? "📈" : "📉"
        let msg = """
        📋 *Tages-Zusammenfassung*

        \(pnlEmoji) *P&L:* \(String(format: "%+.2f€", analytics.totalPnL))
        *Trades:* \(analytics.totalTrades) (\(analytics.wins)W / \(analytics.losses)L)
        *Win Rate:* \(String(format: "%.1f%%", analytics.winRate))
        *Sharpe:* \(String(format: "%.2f", analytics.sharpeRatio))
        *Max Drawdown:* \(String(format: "%.2f€", analytics.maxDrawdown))
        *Gebühren:* \(String(format: "%.2f€", analytics.totalFees))

        *Regime:* \(regime.emoji) \(regime.rawValue)
        *Offene Positionen:* \(openPositions)
        """
        await enqueue(msg)
    }

    public func sendRegimeChange(from: MarketRegime, to: MarketRegime, pair: String) async {
        let msg = """
        🔄 *Regime-Wechsel*

        *Paar:* `\(pair)`
        *Von:* \(from.emoji) \(from.rawValue)
        *Zu:* \(to.emoji) \(to.rawValue)

        _\(to.tradingAdvice)_
        """
        await enqueue(msg)
    }

    public func sendEngineStatus(status: String) async {
        await enqueue("🤖 *Trading Engine:* \(status)")
    }

    // MARK: - Message Queue

    private func enqueue(_ message: String) async {
        let d = UserDefaults.standard
        let alertsEnabled = d.bool(forKey: "kobold.trading.telegramAlerts")
        guard alertsEnabled else { return }
        messageQueue.append(message)
        if !isProcessingQueue {
            await processQueue()
        }
    }

    private func processQueue() async {
        isProcessingQueue = true
        while !messageQueue.isEmpty {
            let msg = messageQueue.removeFirst()
            let now = Date()
            let elapsed = now.timeIntervalSince(lastMessageTime)
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
            await sendTelegram(msg)
            lastMessageTime = Date()
        }
        isProcessingQueue = false
    }

    // MARK: - Telegram Send

    private func sendTelegram(_ text: String) async {
        let d = UserDefaults.standard
        guard let token = d.string(forKey: "kobold.telegram.botToken"), !token.isEmpty else { return }
        let chatIdStr = d.string(forKey: "kobold.telegram.chatId") ?? ""
        guard let chatId = Int64(chatIdStr.trimmingCharacters(in: .whitespaces)), chatId != 0 else { return }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[TradingReporter] Telegram error: HTTP \(http.statusCode)")
            }
        } catch {
            print("[TradingReporter] Telegram send failed: \(error.localizedDescription)")
        }
    }
}
#endif
