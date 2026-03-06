#if os(macOS)
import Foundation
import CryptoKit

// MARK: - Trade Executor
// Orchestriert die Trade-Ausführung: Signal → Risk Check → Coinbase Order → Log → Report

public actor TradeExecutor {
    public static let shared = TradeExecutor()

    private let apiBase = "https://api.coinbase.com"
    private let apiHost = "api.coinbase.com"

    private var validProductIds: Set<String> = []
    private var productsLoaded = false

    private init() {}

    /// Lädt und cached valide Product-IDs von Coinbase
    public func loadValidProducts() async {
        guard !productsLoaded else { return }
        let products = await getAllProducts()
        validProductIds = Set(products.filter { $0.status == "online" }.map { $0.id })
        productsLoaded = true
        print("[TradeExecutor] \(validProductIds.count) valide Products geladen")
    }

    /// Prüft ob ein Product-ID auf Coinbase existiert
    public func isValidProduct(_ productId: String) async -> Bool {
        if !productsLoaded { await loadValidProducts() }
        return validProductIds.contains(productId)
    }

    // MARK: - Central Request Builder

    /// Erstellt einen authentifizierten URLRequest mit allen nötigen Headers (CB-VERSION, Accept, Auth)
    private func buildRequest(method: String, path: String, fullURL: String? = nil) -> URLRequest? {
        // JWT path = OHNE query params
        let jwtPath = path.components(separatedBy: "?").first ?? path
        guard let jwt = generateJWT(method: method, path: jwtPath) else {
            print("[TradeExecutor] JWT generation failed for \(method) \(jwtPath)")
            return nil
        }

        let urlString = fullURL ?? "\(apiBase)\(path)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("2024-01-01", forHTTPHeaderField: "CB-VERSION")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    // MARK: - Execute Trade

    // Cooldown für fehlgeschlagene Orders (verhindert Spam)
    private var failedCooldown: [String: Date] = [:]

    public func execute(signal: TradingSignal, currentPrice: Double, portfolioValue: Double,
                        regime: MarketRegime) async -> TradeRecord? {

        let pair = signal.pair
        let side = signal.action == .buy ? "BUY" : "SELL"

        // Cooldown prüfen: Nach FAILED 15 Minuten warten
        let cooldownKey = "\(pair)-\(side)"
        if let lastFailed = failedCooldown[cooldownKey], Date().timeIntervalSince(lastFailed) < 900 {
            return nil
        }

        // Trade-Größe: min(fixedSize, portfolioPercent) — der kleinere Wert gewinnt
        let fixedSize = UserDefaults.standard.double(forKey: "kobold.trading.fixedTradeSize")
        let effectiveFixed = fixedSize > 0 ? fixedSize : 5.0
        let maxSizePct = UserDefaults.standard.double(forKey: "kobold.trading.maxTradeSize")
        let sizePct = maxSizePct > 0 ? maxSizePct : 2.0
        let pctValue = portfolioValue * (sizePct / 100.0)
        let tradeValue = pctValue > 0 ? min(effectiveFixed, pctValue) : effectiveFixed

        // EUR-Reserve prüfen bei Kauf (inkl. Fees — Coinbase zieht Fees zusätzlich ab!)
        if side == "BUY" {
            let eurReserve = UserDefaults.standard.double(forKey: "kobold.trading.eurReserve")
            let feeRateVal = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
            let effFeeRate = feeRateVal > 0 ? feeRateVal : 0.012
            let tradeWithFees = tradeValue * (1 + effFeeRate)  // Trade + Coinbase Fee
            let eurBalance = await getEURBalance()
            let available = eurBalance - eurReserve
            if available < tradeWithFees {
                await TradingActivityLog.shared.add("[\(pair)] Kauf abgelehnt: \(String(format: "%.2f€", available)) verfügbar (Balance \(String(format: "%.2f€", eurBalance)) - Reserve \(String(format: "%.0f€", eurReserve))) < Trade+Fee \(String(format: "%.2f€", tradeWithFees))", type: .risk)
                return nil
            }
        }
        let size = tradeValue / currentPrice

        let openTrades = (try? await TradingDatabase.shared.getOpenTrades()) ?? []
        let riskCheck = await TradingRiskManager.shared.checkTradeAllowed(
            pair: pair, side: side, size: size, price: currentPrice,
            portfolioValue: portfolioValue, openPositions: openTrades
        )

        guard riskCheck.allowed else {
            print("[TradeExecutor] Risk denied: \(riskCheck.reason)")
            await TradingReporter.shared.sendRiskAlert(reason: riskCheck.reason)
            return nil
        }

        // Volatility Scaling: RiskManager kann Position verkleinern
        let finalTradeValue: Double
        if let adjusted = riskCheck.adjustedSize, adjusted < size {
            let adjustedValue = adjusted * currentPrice
            finalTradeValue = adjustedValue
            await TradingActivityLog.shared.add("[\(pair)] Volatility Scaling: \(String(format: "%.2f€", tradeValue)) → \(String(format: "%.2f€", adjustedValue))", type: .risk)
        } else {
            finalTradeValue = tradeValue
        }
        let finalSize = finalTradeValue / currentPrice

        let autoTrade = UserDefaults.standard.bool(forKey: "kobold.trading.autoTrade")
        guard autoTrade else {
            print("[TradeExecutor] Auto-Trade AUS — Signal \(side) \(pair) ignoriert")
            return nil
        }

        let orderId: String?
        if side == "BUY" {
            orderId = await placeMarketBuy(productId: pair, quoteSize: String(format: "%.2f", finalTradeValue))
        } else {
            orderId = await placeMarketSell(productId: pair, baseSize: formatBaseSize(productId: pair, amount: finalSize))
        }

        guard let oid = orderId else {
            failedCooldown[cooldownKey] = Date()
            print("[TradeExecutor] \(side) \(pair) FAILED — 15 Min Cooldown")
            await TradingActivityLog.shared.add("[\(pair)] Order \(side) fehlgeschlagen — nächster Versuch in 15 Min", type: .error)
            return nil
        }

        // Fill-Verification: Echten Fill-Preis und Gebühren von Coinbase holen
        let fillPrice: Double
        let fillSize: Double
        let fillFee: Double
        if let fill = await getOrderFill(orderId: oid) {
            if fill.status != "FILLED" {
                await TradingActivityLog.shared.add("[\(pair)] Order \(oid.prefix(12)) Status: \(fill.status) — nicht gefüllt!", type: .error)
                failedCooldown[cooldownKey] = Date()
                return nil
            }
            fillPrice = fill.averagePrice > 0 ? fill.averagePrice : currentPrice
            fillSize = fill.filledSize > 0 ? fill.filledSize : finalSize
            fillFee = fill.fee
            let slippage = currentPrice > 0 ? ((fillPrice - currentPrice) / currentPrice * 100) : 0
            if abs(slippage) > 0.05 {
                await TradingActivityLog.shared.add("[\(pair)] Slippage: \(String(format: "%+.2f%%", slippage)) (Spot: \(String(format: "%.2f€", currentPrice)) → Fill: \(String(format: "%.2f€", fillPrice)), Fee: \(String(format: "%.4f€", fillFee)))", type: .risk)
            }
        } else {
            // Fallback: Spot-Preis verwenden wenn Order-Check fehlschlägt
            fillPrice = currentPrice
            fillSize = finalSize
            fillFee = 0
            await TradingActivityLog.shared.add("[\(pair)] Fill-Verification fehlgeschlagen — verwende Spot-Preis", type: .info)
        }

        let record = TradeRecord(
            pair: pair, side: side, size: fillSize, price: fillPrice,
            strategy: signal.strategy, regime: regime.rawValue,
            confidence: signal.confidence,
            status: "OPEN",
            orderId: oid, notes: signal.reason
        )

        try? await TradingDatabase.shared.logTrade(record)
        await TradingReporter.shared.sendTradeAlert(trade: record, regime: regime)
        failedCooldown.removeValue(forKey: cooldownKey)

        print("[TradeExecutor] \(side) \(pair) @ \(String(format: "%.2f", fillPrice)) (Fill) — Order: \(oid.prefix(12)), Fee: \(String(format: "%.4f€", fillFee))")
        return record
    }

    // MARK: - Close Position

    public func closePosition(_ trade: TradeRecord, currentPrice: Double) async {
        let side = trade.side == "BUY" ? "SELL" : "BUY"
        let orderId: String?

        if side == "SELL" {
            orderId = await placeMarketSell(productId: trade.pair, baseSize: formatBaseSize(productId: trade.pair, amount: trade.size))
        } else {
            let quoteSize = trade.size * currentPrice
            orderId = await placeMarketBuy(productId: trade.pair, quoteSize: String(format: "%.2f", quoteSize))
        }

        if orderId != nil {
            // Fee-Berechnung: Coinbase Advanced Trade ~0.4-0.6% Taker
            let feeRate = UserDefaults.standard.double(forKey: "kobold.trading.feeRate")
            let effectiveFeeRate = feeRate > 0 ? feeRate : 0.012 // Default 1.2% Coinbase Taker Fee
            let entryFee = trade.price * trade.size * effectiveFeeRate
            let exitFee = currentPrice * trade.size * effectiveFeeRate
            let totalFees = entryFee + exitFee

            let rawPnl = trade.side == "BUY"
                ? (currentPrice - trade.price) * trade.size
                : (trade.price - currentPrice) * trade.size
            let pnl = rawPnl - totalFees

            let duration = holdingTimeSince(trade.timestamp)
            try? await TradingDatabase.shared.closeTrade(
                id: trade.id, exitPrice: currentPrice, pnl: pnl, holdingTime: duration
            )
            await TradingRiskManager.shared.recordPnL(pnl)

            var closedTrade = trade
            closedTrade.exitPrice = currentPrice
            closedTrade.pnl = pnl
            closedTrade.holdingTime = duration
            await TradingReporter.shared.sendTradeClosedAlert(trade: closedTrade)
            print("[TradeExecutor] Closed \(trade.pair) — P&L: \(String(format: "%+.2f€", pnl))")
        }
    }

    // MARK: - Coinbase API Calls

    public func placeMarketBuy(productId: String, quoteSize: String) async -> String? {
        // Validierung: Product-ID muss existieren
        let valid = await isValidProduct(productId)
        if !valid {
            print("[TradeExecutor] BUY BLOCKED: \(productId) nicht auf Coinbase Advanced Trade")
            return nil
        }
        let body: [String: Any] = [
            "client_order_id": UUID().uuidString,
            "product_id": productId, "side": "BUY",
            "order_configuration": ["market_market_ioc": ["quote_size": quoteSize]]
        ]
        print("[TradeExecutor] BUY ORDER: \(productId) quote_size=\(quoteSize)")
        return await placeOrder(body)
    }

    public func placeMarketSell(productId: String, baseSize: String) async -> String? {
        let body: [String: Any] = [
            "client_order_id": UUID().uuidString,
            "product_id": productId, "side": "SELL",
            "order_configuration": ["market_market_ioc": ["base_size": baseSize]]
        ]
        return await placeOrder(body)
    }

    /// Holt die tatsächliche verfügbare Balance über die v3 Brokerage API (mit Holds!)
    public func getV3AvailableBalance(currency: String) async -> Double? {
        let path = "/api/v3/brokerage/accounts?limit=100"
        guard let request = buildRequest(method: "GET", path: path) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = json["accounts"] as? [[String: Any]] else { return nil }

            for account in accounts {
                let curr = account["currency"] as? String ?? ""
                if curr.uppercased() == currency.uppercased() {
                    let availStr = (account["available_balance"] as? [String: Any])?["value"] as? String ?? "0"
                    let available = Double(availStr) ?? 0
                    let holdStr = (account["hold"] as? [String: Any])?["value"] as? String ?? "0"
                    let hold = Double(holdStr) ?? 0
                    print("[TradeExecutor] v3 Balance \(currency): available=\(availStr) hold=\(holdStr)")
                    return available
                }
            }
            return nil
        } catch { return nil }
    }

    /// EUR-Balance (v3 API, mit Holds)
    public func getEURBalance() async -> Double {
        return await getV3AvailableBalance(currency: "EUR") ?? 0
    }

    /// Verkauft ALLES von einer Währung — holt v3-Balance, formatiert korrekt, sendet Order
    public func sellAll(currency: String) async -> (orderId: String?, error: String?) {
        let pair = "\(currency)-EUR"

        // 1. Product validieren
        let valid = await isValidProduct(pair)
        if !valid {
            return (nil, "Produkt \(pair) nicht auf Coinbase Advanced Trade verfügbar")
        }

        // 2. Echte verfügbare Balance von v3 API holen (mit Holds!)
        guard let available = await getV3AvailableBalance(currency: currency), available > 0 else {
            return (nil, "Keine verfügbare Balance für \(currency) (v3 API)")
        }

        // 3. Korrekt formatieren (base_increment beachten)
        let size = await formatBaseSizeAsync(productId: pair, amount: available)
        if size.isEmpty || size == "0" || (Double(size) ?? 0) <= 0 {
            return (nil, "Formatierte Menge ist 0 (available=\(available), formatted=\(size))")
        }

        print("[TradeExecutor] SELL ALL \(currency): v3_available=\(available) → formatted=\(size)")

        // 4. Order senden
        let body: [String: Any] = [
            "client_order_id": UUID().uuidString,
            "product_id": pair, "side": "SELL",
            "order_configuration": ["market_market_ioc": ["base_size": size]]
        ]
        return await placeOrderWithFeedback(body)
    }

    /// Verkauf mit Feedback — gibt (orderId, error) zurück statt nur nil
    public func placeMarketSellWithFeedback(productId: String, baseSize: String) async -> (orderId: String?, error: String?) {
        // Validierung: Product-ID muss auf Coinbase existieren
        let valid = await isValidProduct(productId)
        if !valid {
            print("[TradeExecutor] INVALID PRODUCT: \(productId) — nicht auf Coinbase Advanced Trade verfügbar")
            return (nil, "Produkt \(productId) nicht auf Coinbase Advanced Trade verfügbar.")
        }

        if baseSize.isEmpty || baseSize == "0" || baseSize == "0.00" || (Double(baseSize) ?? 0) <= 0 {
            print("[TradeExecutor] INVALID SIZE: \(baseSize) für \(productId)")
            return (nil, "Ungültige Menge: \(baseSize)")
        }

        let body: [String: Any] = [
            "client_order_id": UUID().uuidString,
            "product_id": productId, "side": "SELL",
            "order_configuration": ["market_market_ioc": ["base_size": baseSize]]
        ]
        print("[TradeExecutor] SELL ORDER: \(productId) base_size=\(baseSize)")
        return await placeOrderWithFeedback(body)
    }

    private func placeOrder(_ body: [String: Any]) async -> String? {
        let result = await placeOrderWithFeedback(body)
        return result.orderId
    }

    private func placeOrderWithFeedback(_ body: [String: Any]) async -> (orderId: String?, error: String?) {
        let path = "/api/v3/brokerage/orders"
        guard var request = buildRequest(method: "POST", path: path) else {
            return (nil, "JWT-Generierung fehlgeschlagen — API-Key prüfen")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "Keine HTTP-Antwort")
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            if http.statusCode == 200 {
                if let orderId = json?["order_id"] as? String { return (orderId, nil) }
                if let success = json?["success"] as? Bool, success,
                   let result = json?["success_response"] as? [String: Any],
                   let orderId = result["order_id"] as? String { return (orderId, nil) }
                // Success but couldn't parse order ID
                if let success = json?["success"] as? Bool, !success,
                   let errResp = json?["error_response"] as? [String: Any],
                   let errMsg = errResp["message"] as? String {
                    return (nil, errMsg)
                }
            }

            let errStr = String(data: data.prefix(500), encoding: .utf8) ?? "?"
            print("[TradeExecutor] Order failed (HTTP \(http.statusCode)): \(errStr)")

            // Parse Coinbase error message
            if let errMsg = json?["message"] as? String {
                return (nil, "HTTP \(http.statusCode): \(errMsg)")
            }
            if let errResp = json?["error_response"] as? [String: Any],
               let errMsg = errResp["message"] as? String {
                return (nil, errMsg)
            }

            return (nil, "HTTP \(http.statusCode): \(errStr.prefix(200))")
        } catch {
            print("[TradeExecutor] Order request failed: \(error.localizedDescription)")
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Order Fill Verification

    /// Ruft den tatsächlichen Order-Status und Fill-Preis von Coinbase ab.
    /// Wartet kurz bis die IOC-Order gefüllt ist (max 3 Versuche, 2s Abstand).
    public struct OrderFill: Sendable {
        public let orderId: String
        public let status: String          // "FILLED", "CANCELLED", "PENDING", etc.
        public let filledSize: Double      // Tatsächlich gefüllte Menge
        public let filledValue: Double     // Tatsächlicher EUR-Wert
        public let averagePrice: Double    // Durchschnittlicher Fill-Preis
        public let fee: Double             // Gezahlte Gebühren
    }

    public func getOrderFill(orderId: String) async -> OrderFill? {
        for attempt in 1...3 {
            let path = "/api/v3/brokerage/orders/historical/\(orderId)"
            guard let request = buildRequest(method: "GET", path: path) else { return nil }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let order = json["order"] as? [String: Any] else {
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    continue
                }

                let status = order["status"] as? String ?? "UNKNOWN"

                // Bei PENDING: warten und nochmal versuchen
                if status == "PENDING" || status == "OPEN" {
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    continue
                }

                let filledSizeStr = order["filled_size"] as? String ?? "0"
                let filledValueStr = order["filled_value"] as? String ?? "0"
                let totalFeesStr = order["total_fees"] as? String ?? "0"
                let avgPriceStr = order["average_filled_price"] as? String ?? "0"

                return OrderFill(
                    orderId: orderId,
                    status: status,
                    filledSize: Double(filledSizeStr) ?? 0,
                    filledValue: Double(filledValueStr) ?? 0,
                    averagePrice: Double(avgPriceStr) ?? 0,
                    fee: Double(totalFeesStr) ?? 0
                )
            } catch {
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        return nil
    }

    // MARK: - List Recent Orders (für Agent-Verifizierung)

    public func listRecentOrders(productId: String, side: String, windowSeconds: Int = 120) async -> [OrderFill] {
        let path = "/api/v3/brokerage/orders/historical?product_id=\(productId)&order_side=\(side)&limit=5&order_status=FILLED"
        guard let request = buildRequest(method: "GET", path: path) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let orders = json["orders"] as? [[String: Any]] else { return [] }

            let cutoff = Date().addingTimeInterval(-Double(windowSeconds))
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            return orders.compactMap { order -> OrderFill? in
                let status = order["status"] as? String ?? ""
                guard status == "FILLED" else { return nil }

                // Zeitfenster prüfen
                if let createdAt = order["created_time"] as? String, let date = fmt.date(from: createdAt) {
                    guard date > cutoff else { return nil }
                }

                let filledSize = Double(order["filled_size"] as? String ?? "0") ?? 0
                let filledValue = Double(order["filled_value"] as? String ?? "0") ?? 0
                let avgPrice = Double(order["average_filled_price"] as? String ?? "0") ?? 0
                let fee = Double(order["total_fees"] as? String ?? "0") ?? 0
                let orderId = order["order_id"] as? String ?? ""

                guard filledSize > 0 else { return nil }
                return OrderFill(orderId: orderId, status: status, filledSize: filledSize,
                                 filledValue: filledValue, averagePrice: avgPrice, fee: fee)
            }
        } catch {
            return []
        }
    }

    // MARK: - Get Spot Price

    public func getSpotPrice(pair: String) async -> Double? {
        let path = "/v2/prices/\(pair)/spot"
        guard let request = buildRequest(method: "GET", path: path) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                print("[TradeExecutor] getSpotPrice \(pair) HTTP \(http.statusCode)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let priceStr = dataObj["amount"] as? String,
               let price = Double(priceStr) {
                return price
            }
            return nil
        } catch { return nil }
    }

    // MARK: - Get Account Balances (Individual Holdings, with EUR valuation)

    public struct AccountBalance: Sendable {
        public let currency: String
        public let balance: Double          // Gesamt-Balance
        public let availableBalance: Double // Verfügbar (balance - hold)
        public let nativeValue: Double      // EUR-Wert (berechnet via Spot-Price)
        public let nativeCurrency: String
    }

    /// Holt alle Accounts und berechnet den EUR-Wert über Spot-Prices
    /// (native_balance der v2 API gibt bei CDP-Keys immer "0" zurück)
    public func getAccountBalances() async -> [AccountBalance] {
        let path = "/v2/accounts?limit=100"
        guard let request = buildRequest(method: "GET", path: path) else {
            print("[TradeExecutor] getAccountBalances: buildRequest failed")
            return []
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data.prefix(300), encoding: .utf8) ?? "?"
                print("[TradeExecutor] getAccountBalances HTTP \(code): \(body)")
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = json["data"] as? [[String: Any]] else {
                print("[TradeExecutor] getAccountBalances: JSON parse failed")
                return []
            }

            // 1. Parse raw balances (balance - hold = available)
            var rawHoldings: [(currency: String, balance: Double, available: Double)] = []
            for account in accounts {
                let code = (account["currency"] as? [String: Any])?["code"] as? String ?? "?"
                let balanceStr = (account["balance"] as? [String: Any])?["amount"] as? String ?? "0"
                let balance = Double(balanceStr) ?? 0
                // Coinbase v2: "hold" Feld enthält gesperrten Betrag
                let holdStr = (account["hold"] as? [String: Any])?["amount"] as? String ?? "0"
                let hold = Double(holdStr) ?? 0
                let available = max(balance - hold, 0)
                if balance > 0.000001 {
                    rawHoldings.append((code, balance, available))
                }
            }

            // 2. Fetch spot prices for all non-EUR holdings (parallel)
            var spotPrices: [String: Double] = [:]
            await withTaskGroup(of: (String, Double?).self) { group in
                for h in rawHoldings where h.currency != "EUR" {
                    let pair = "\(h.currency)-EUR"
                    group.addTask {
                        let price = await self.getSpotPrice(pair: pair)
                        return (h.currency, price)
                    }
                }
                for await (currency, price) in group {
                    if let p = price { spotPrices[currency] = p }
                }
            }

            // 3. Build AccountBalance with calculated EUR values
            let result = rawHoldings.map { h -> AccountBalance in
                let eurValue: Double
                if h.currency == "EUR" || h.currency == "EURC" {
                    eurValue = h.balance
                } else if let price = spotPrices[h.currency] {
                    eurValue = h.balance * price
                } else {
                    eurValue = 0
                }
                return AccountBalance(currency: h.currency, balance: h.balance,
                                      availableBalance: h.available,
                                      nativeValue: eurValue, nativeCurrency: "EUR")
            }.sorted { $0.nativeValue > $1.nativeValue }

            let total = result.reduce(0) { $0 + $1.nativeValue }
            print("[TradeExecutor] getAccountBalances: \(result.count) holdings, total=\(String(format: "%.2f", total))€")
            return result
        } catch {
            print("[TradeExecutor] getAccountBalances error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Get Portfolio Value

    public func getPortfolioValue() async -> Double {
        let balances = await getAccountBalances()
        let total = balances.reduce(0) { $0 + $1.nativeValue }
        return total
    }

    // MARK: - Get Candles

    public func getCandles(pair: String, granularity: String = "ONE_HOUR", limit: Int = 300) async -> [Candle] {
        let seconds: Int
        switch granularity {
        case "ONE_HOUR": seconds = 3600
        case "SIX_HOUR": seconds = 21600
        case "ONE_DAY": seconds = 86400
        default: seconds = 3600
        }

        // Coinbase limits to 300 candles per request — paginate if needed
        let maxPerRequest = 300
        var allCandles: [Candle] = []
        var remaining = limit
        var currentEnd = Int(Date().timeIntervalSince1970)

        while remaining > 0 {
            let batchSize = min(remaining, maxPerRequest)
            let batchStart = currentEnd - (seconds * batchSize)

            let path = "/api/v3/brokerage/products/\(pair)/candles?start=\(batchStart)&end=\(currentEnd)&granularity=\(granularity)"
            guard let request = buildRequest(method: "GET", path: path) else { break }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { break }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candles = json["candles"] as? [[String: Any]] {
                    let parsed = candles.compactMap { c -> Candle? in
                        guard let ts = c["start"] as? String, let timestamp = Double(ts),
                              let low = Double(c["low"] as? String ?? ""),
                              let high = Double(c["high"] as? String ?? ""),
                              let open = Double(c["open"] as? String ?? ""),
                              let close = Double(c["close"] as? String ?? ""),
                              let volume = Double(c["volume"] as? String ?? "") else { return nil }
                        return Candle(timestamp: timestamp, open: open, high: high, low: low, close: close, volume: volume)
                    }
                    allCandles.append(contentsOf: parsed)
                    if parsed.count < batchSize { break }  // No more data available
                } else { break }
            } catch { break }

            remaining -= batchSize
            currentEnd = batchStart  // Next batch ends where this one started
        }

        return allCandles.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Get All Tradeable Products

    // Gespeicherte base_increment pro Product-ID (z.B. "SOL-EUR" → "0.01")
    private var baseIncrements: [String: String] = [:]

    /// Formatiert eine Menge passend zur Coinbase-Precision des Produkts (ABRUNDEN + Safety Margin!)
    public func formatBaseSize(productId: String, amount: Double) -> String {
        if let increment = baseIncrements[productId], let incVal = Double(increment), incVal > 0 {
            // Abrunden UND 1 Increment als Sicherheit abziehen (gegen holds/rounding)
            let steps = floor(amount / incVal)
            let safeSteps = max(steps - 1, 0)
            let truncated = safeSteps * incVal
            let decimals = max(0, -Int(floor(log10(incVal))))
            let result = String(format: "%.\(decimals)f", truncated)
            print("[TradeExecutor] formatBaseSize(\(productId)): amount=\(amount) inc=\(increment) → \(result)")
            return result
        }
        // Fallback: 99.5% des Betrags, abrunden, trailing zeros entfernen
        let safeAmount = amount * 0.995
        let factor = 100_000_000.0
        let truncated = floor(safeAmount * factor) / factor
        let s = String(format: "%.8f", truncated)
        let result = s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        print("[TradeExecutor] formatBaseSize(\(productId)) FALLBACK: amount=\(amount) → \(result)")
        return result
    }

    /// Async Version: Lädt Products falls nötig, dann formatiert
    public func formatBaseSizeAsync(productId: String, amount: Double) async -> String {
        if baseIncrements.isEmpty { _ = await getAllProducts() }
        return formatBaseSize(productId: productId, amount: amount)
    }

    public func getAllProducts() async -> [(id: String, baseCurrency: String, quoteCurrency: String, status: String)] {
        var allProducts: [(id: String, baseCurrency: String, quoteCurrency: String, status: String)] = []
        var cursor: String? = nil
        var page = 0

        repeat {
            page += 1
            var path = "/api/v3/brokerage/products?limit=250&product_type=SPOT"
            if let c = cursor, !c.isEmpty { path += "&cursor=\(c)" }
            guard let request = buildRequest(method: "GET", path: path) else { break }

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let products = json["products"] as? [[String: Any]] else { break }

                for p in products {
                    if let id = p["product_id"] as? String,
                       let inc = p["base_increment"] as? String {
                        baseIncrements[id] = inc
                    }
                }

                let batch: [(id: String, baseCurrency: String, quoteCurrency: String, status: String)] = products.compactMap { p in
                    guard let id = p["product_id"] as? String,
                          let base = p["base_currency_id"] as? String,
                          let quote = p["quote_currency_id"] as? String else { return nil }
                    let status = p["status"] as? String ?? "unknown"
                    return (id, base, quote, status)
                }
                allProducts.append(contentsOf: batch)

                // Nächste Seite? Coinbase gibt "cursor" zurück wenn es mehr gibt
                cursor = json["cursor"] as? String
                if batch.count < 250 { cursor = nil } // Letzte Seite
            } catch { break }
        } while cursor != nil && page < 10 // Max 10 Seiten (2500 Produkte)

        print("[TradeExecutor] \(allProducts.count) Produkte geladen, \(baseIncrements.count) mit base_increment")
        return allProducts
    }

    // MARK: - Staking Support

    public func getStakingRewards() async -> String {
        let path = "/v2/accounts?limit=100"
        guard let request = buildRequest(method: "GET", path: path) else { return "JWT-Fehler" }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accounts = json["data"] as? [[String: Any]] {
                var stakingInfo: [String] = []
                for account in accounts {
                    let currency = account["currency"] as? [String: Any]
                    let code = currency?["code"] as? String ?? "?"
                    let rewards = account["rewards"] as? [String: Any]
                    if let apy = rewards?["apy"] as? String, !apy.isEmpty {
                        let balance = (account["balance"] as? [String: Any])?["amount"] as? String ?? "0"
                        stakingInfo.append("\(code): Balance \(balance), APY \(apy)%")
                    }
                }
                return stakingInfo.isEmpty ? "Keine Staking-Positionen gefunden" : stakingInfo.joined(separator: "\n")
            }
            return "Parse-Fehler"
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    // MARK: - JWT Generation (ES256)

    private func generateJWT(method: String, path: String) -> String? {
        let defaults = UserDefaults.standard
        guard let keyName = defaults.string(forKey: "kobold.coinbase.keyName"), !keyName.isEmpty,
              let keySecret = defaults.string(forKey: "kobold.coinbase.keySecret"), !keySecret.isEmpty else { return nil }

        let normalized = keySecret
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: normalized) else {
            print("[TradeExecutor] Failed to parse PEM key")
            return nil
        }

        let now = Int(Date().timeIntervalSince1970)
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()

        let uri = "\(method) \(apiHost)\(path)"

        let header: [String: Any] = ["alg": "ES256", "kid": keyName, "nonce": nonce, "typ": "JWT"]
        let payload: [String: Any] = ["iss": "cdp", "sub": keyName, "nbf": now, "exp": now + 120, "uri": uri]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let headerB64 = base64URLEncode(headerData)
        let payloadB64 = base64URLEncode(payloadData)
        guard let signingData = "\(headerB64).\(payloadB64)".data(using: .utf8) else { return nil }

        guard let signature = try? privateKey.signature(for: signingData) else { return nil }
        return "\(headerB64).\(payloadB64).\(base64URLEncode(signature.rawRepresentation))"
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Transaction History (for Cost Basis / Gesamt-P&L)

    public struct Transaction: Sendable {
        public let type: String      // "buy", "sell", "send", "receive", "trade"
        public let currency: String
        public let amount: Double    // Crypto-Menge (positiv = Zugang, negativ = Abgang)
        public let nativeAmount: Double  // EUR-Gegenwert zum Zeitpunkt
        public let date: String
    }

    /// Holt Transaktionshistorie für ein spezifisches Coin-Konto
    public func getTransactions(currency: String) async -> [Transaction] {
        // Erst Account-ID für diese Währung finden
        let accountsPath = "/v2/accounts?limit=100"
        guard let accountsReq = buildRequest(method: "GET", path: accountsPath) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(for: accountsReq)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = json["data"] as? [[String: Any]] else { return [] }

            // Account-ID für gewünschte Währung finden
            guard let account = accounts.first(where: {
                ($0["currency"] as? [String: Any])?["code"] as? String == currency
            }), let accountId = account["id"] as? String else { return [] }

            // Transaktionen laden
            let txPath = "/v2/accounts/\(accountId)/transactions?limit=100&order=desc"
            guard let txReq = buildRequest(method: "GET", path: txPath) else { return [] }

            let (txData, txResponse) = try await URLSession.shared.data(for: txReq)
            guard let txHttp = txResponse as? HTTPURLResponse, txHttp.statusCode == 200,
                  let txJson = try? JSONSerialization.jsonObject(with: txData) as? [String: Any],
                  let txs = txJson["data"] as? [[String: Any]] else { return [] }

            return txs.compactMap { tx -> Transaction? in
                guard let type = tx["type"] as? String,
                      let amountObj = tx["amount"] as? [String: Any],
                      let amountStr = amountObj["amount"] as? String,
                      let amount = Double(amountStr) else { return nil }
                let nativeObj = tx["native_amount"] as? [String: Any]
                let nativeStr = nativeObj?["amount"] as? String ?? "0"
                let nativeAmount = Double(nativeStr) ?? 0
                let date = tx["created_at"] as? String ?? ""
                return Transaction(type: type, currency: currency, amount: amount,
                                   nativeAmount: nativeAmount, date: date)
            }
        } catch { return [] }
    }

    /// Berechnet den gewichteten Durchschnitts-Kaufpreis (Cost Basis) für ein Coin
    public func getCostBasis(currency: String) async -> (avgPrice: Double, totalInvested: Double)? {
        let txs = await getTransactions(currency: currency)
        guard !txs.isEmpty else { return nil }

        // Chronologisch sortieren (API liefert desc → umkehren)
        let sorted = txs.reversed()

        var totalCostEUR = 0.0
        var totalQuantity = 0.0

        for tx in sorted {
            // Käufe/Empfang/Staking/Trade → Zugang
            if tx.amount > 0 {
                let cost = abs(tx.nativeAmount)
                // Staking/Rewards haben 0 EUR Kosten → Cost Basis 0 (geschenkt)
                totalCostEUR += cost
                totalQuantity += tx.amount
            }
            // Verkäufe/Sends → Abgang: Cost Basis proportional reduzieren
            if tx.amount < 0 && totalQuantity > 0 {
                let sellQty = abs(tx.amount)
                let sellRatio = min(sellQty / totalQuantity, 1.0)
                totalCostEUR *= (1 - sellRatio)
                totalQuantity = max(0, totalQuantity - sellQty)
            }
        }

        guard totalQuantity > 0.001 else { return nil }
        let avgPrice = totalCostEUR / totalQuantity
        return (avgPrice, totalCostEUR)
    }

    // MARK: - Connection Diagnostics

    /// Prüft Schritt für Schritt ob die Coinbase-Verbindung funktioniert und gibt Diagnose zurück
    public func diagnoseConnection() async -> String {
        var log = [String]()

        // 1. Check API keys
        let keyName = UserDefaults.standard.string(forKey: "kobold.coinbase.keyName") ?? ""
        let keySecret = UserDefaults.standard.string(forKey: "kobold.coinbase.keySecret") ?? ""
        if keyName.isEmpty || keySecret.isEmpty {
            log.append("FEHLER: API-Keys fehlen (keyName=\(keyName.isEmpty ? "leer" : "gesetzt"), keySecret=\(keySecret.isEmpty ? "leer" : "gesetzt"))")
            return log.joined(separator: "\n")
        }
        log.append("OK: API-Keys vorhanden (keyName=\(keyName.prefix(12))...)")

        // 2. Check PEM parsing
        let normalized = keySecret
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (try? P256.Signing.PrivateKey(pemRepresentation: normalized)) == nil {
            log.append("FEHLER: PEM-Key kann nicht geparst werden. Erste 30 Zeichen: \(String(normalized.prefix(30)))")
            return log.joined(separator: "\n")
        }
        log.append("OK: PEM-Key erfolgreich geparst")

        // 3. Check JWT generation
        guard let jwt = generateJWT(method: "GET", path: "/v2/accounts") else {
            log.append("FEHLER: JWT-Generierung fehlgeschlagen")
            return log.joined(separator: "\n")
        }
        log.append("OK: JWT generiert (\(jwt.count) Zeichen)")

        // 4. Try actual API call
        let url = URL(string: "\(apiBase)/v2/accounts?limit=100")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("2024-01-01", forHTTPHeaderField: "CB-VERSION")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let body = String(data: data.prefix(2000), encoding: .utf8) ?? "(leer)"

            log.append("HTTP Status: \(statusCode)")

            if statusCode != 200 {
                log.append("FEHLER: HTTP \(statusCode)")
                log.append("Response: \(body)")
                return log.joined(separator: "\n")
            }

            log.append("OK: HTTP 200")

            // 5. Parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = Array(json.keys)
                log.append("JSON Top-Level Keys: \(keys)")

                if let accounts = json["data"] as? [[String: Any]] {
                    log.append("Accounts gefunden: \(accounts.count)")
                    var total = 0.0
                    for (i, account) in accounts.prefix(10).enumerated() {
                        let currency = (account["currency"] as? [String: Any])?["code"] as? String ?? "?"
                        let balanceAmt = (account["balance"] as? [String: Any])?["amount"] as? String ?? "0"
                        let nativeAmt = (account["native_balance"] as? [String: Any])?["amount"] as? String ?? "0"
                        let nativeVal = Double(nativeAmt) ?? 0
                        total += nativeVal
                        if nativeVal > 0.01 {
                            log.append("  [\(i)] \(currency): balance=\(balanceAmt), native=\(nativeAmt)€")
                        }
                    }
                    log.append("Portfolio Total: \(String(format: "%.2f", total))€")
                    if accounts.count > 10 { log.append("  (... und \(accounts.count - 10) weitere)") }

                    // Check pagination
                    if let pagination = json["pagination"] as? [String: Any] {
                        let nextUri = pagination["next_uri"] as? String ?? "nil"
                        log.append("Pagination: next_uri=\(nextUri)")
                    }
                } else {
                    log.append("FEHLER: json[\"data\"] ist kein Array")
                    log.append("Response (prefix): \(body.prefix(500))")
                }
            } else {
                log.append("FEHLER: JSON-Parsing fehlgeschlagen")
                log.append("Response: \(body.prefix(500))")
            }
        } catch {
            log.append("FEHLER: Netzwerk-Fehler: \(error.localizedDescription)")
        }

        return log.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func holdingTimeSince(_ timestamp: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let entryDate = fmt.date(from: timestamp) else { return "?" }
        let minutes = Int(Date().timeIntervalSince(entryDate) / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
#endif
