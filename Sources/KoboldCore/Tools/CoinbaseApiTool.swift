#if os(macOS)
import Foundation
import CryptoKit

// MARK: - Coinbase API Tool (CDP API Key + ES256 JWT)
// v2 API für Accounts/Preise/User, v3 Advanced Trade API für Orders/Trading
public struct CoinbaseApiTool: Tool {
    public let name = "coinbase_api"
    public let description = """
        Coinbase: Krypto-Wallets verwalten, traden, Preise abrufen. \
        Aktionen: accounts (alle Wallets), account_detail (braucht account_id), \
        transactions (Historie, braucht account_id), send (Krypto senden, braucht account_id + to + amount + currency), \
        spot_price (Preis, braucht currency_pair z.B. BTC-EUR), exchange_rates (Wechselkurse, optional currency), \
        user (eigenes Profil), addresses (Empfangsadressen, braucht account_id), \
        create_address (neue Adresse, braucht account_id), payment_methods (Zahlungsmethoden), \
        buy (Krypto kaufen via Market Order, braucht product_id z.B. BTC-EUR + quote_size z.B. 10 in EUR), \
        sell (Krypto verkaufen via Market Order, braucht product_id z.B. BTC-EUR + base_size z.B. 0.001 in BTC), \
        limit_buy (Limit-Kauf, braucht product_id + base_size + limit_price), \
        limit_sell (Limit-Verkauf, braucht product_id + base_size + limit_price), \
        cancel_order (Order stornieren, braucht order_id), \
        list_orders (offene Orders auflisten), order_detail (braucht order_id), \
        products (handelbare Paare auflisten), product_detail (braucht product_id), \
        preview_buy (Kauf vorschauen ohne auszuführen, braucht product_id + quote_size), \
        preview_sell (Verkauf vorschauen, braucht product_id + base_size). \
        Benötigt API-Key in Einstellungen → Integrationen → Coinbase.
        """
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion", enumValues: [
                "accounts", "account_detail", "transactions", "send",
                "spot_price", "exchange_rates", "user", "addresses", "create_address",
                "payment_methods", "buy", "sell", "limit_buy", "limit_sell",
                "cancel_order", "list_orders", "order_detail",
                "products", "product_detail", "preview_buy", "preview_sell"
            ], required: true),
            "account_id": ToolSchemaProperty(type: "string", description: "Coinbase Account/Wallet UUID (von 'accounts' abrufen)"),
            "to": ToolSchemaProperty(type: "string", description: "Empfänger für send: E-Mail, Krypto-Adresse oder User-ID"),
            "amount": ToolSchemaProperty(type: "string", description: "Betrag für send (z.B. '0.01')"),
            "currency": ToolSchemaProperty(type: "string", description: "Währung für send/exchange_rates (z.B. 'BTC', 'ETH', 'EUR')"),
            "currency_pair": ToolSchemaProperty(type: "string", description: "Währungspaar für spot_price (z.B. 'BTC-EUR')"),
            "product_id": ToolSchemaProperty(type: "string", description: "Handelspaar für buy/sell/limit Orders (z.B. 'BTC-EUR', 'ETH-USD')"),
            "quote_size": ToolSchemaProperty(type: "string", description: "Betrag in Quote-Währung für buy (z.B. '50' = 50 EUR bei BTC-EUR)"),
            "base_size": ToolSchemaProperty(type: "string", description: "Betrag in Base-Währung für sell/limit (z.B. '0.001' = 0.001 BTC)"),
            "limit_price": ToolSchemaProperty(type: "string", description: "Limit-Preis für limit_buy/limit_sell (z.B. '60000')"),
            "order_id": ToolSchemaProperty(type: "string", description: "Order UUID für cancel_order/order_detail"),
            "description": ToolSchemaProperty(type: "string", description: "Optionale Beschreibung für send")
        ], required: ["action"])
    }

    public init() {}

    private let apiBase = "https://api.coinbase.com"
    private let apiHost = "api.coinbase.com"

    // MARK: - JWT Generation (ES256)

    private func generateJWT(method: String, path: String) -> String? {
        let defaults = UserDefaults.standard
        guard let keyName = defaults.string(forKey: "kobold.coinbase.keyName"), !keyName.isEmpty,
              let keySecret = defaults.string(forKey: "kobold.coinbase.keySecret"), !keySecret.isEmpty else {
            return nil
        }

        // Normalize PEM: handle literal "\n" strings, extra whitespace, single-line pasting
        let normalized = keySecret
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: normalized)
        } catch {
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
        let signingInput = "\(headerB64).\(payloadB64)"

        guard let signingData = signingInput.data(using: .utf8) else { return nil }

        do {
            let signature = try privateKey.signature(for: signingData)
            return "\(headerB64).\(payloadB64).\(base64URLEncode(signature.rawRepresentation))"
        } catch {
            return nil
        }
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Execute

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        let defaults = UserDefaults.standard
        guard let kn = defaults.string(forKey: "kobold.coinbase.keyName"), !kn.isEmpty,
              let ks = defaults.string(forKey: "kobold.coinbase.keySecret"), !ks.isEmpty else {
            return "Error: Coinbase API Key nicht konfiguriert. Bitte unter Einstellungen → Integrationen → Coinbase den API Key Name und Secret eintragen."
        }

        switch action {

        // ── v2 API: Accounts & Wallet ──

        case "accounts":
            return await coinbaseGET("/v2/accounts?limit=100")

        case "account_detail":
            guard let id = arguments["account_id"], !id.isEmpty else {
                return "Error: 'account_id' fehlt. Nutze zuerst 'accounts'."
            }
            return await coinbaseGET("/v2/accounts/\(id)")

        case "transactions":
            guard let id = arguments["account_id"], !id.isEmpty else {
                return "Error: 'account_id' fehlt."
            }
            return await coinbaseGET("/v2/accounts/\(id)/transactions?limit=25&order=desc")

        case "send":
            guard let id = arguments["account_id"], !id.isEmpty else { return "Error: 'account_id' fehlt." }
            guard let to = arguments["to"], !to.isEmpty else { return "Error: 'to' fehlt." }
            guard let amount = arguments["amount"], !amount.isEmpty else { return "Error: 'amount' fehlt." }
            guard let currency = arguments["currency"], !currency.isEmpty else { return "Error: 'currency' fehlt." }
            var body: [String: Any] = ["type": "send", "to": to, "amount": amount, "currency": currency]
            if let desc = arguments["description"], !desc.isEmpty { body["description"] = desc }
            return await coinbasePOST("/v2/accounts/\(id)/transactions", body: body)

        case "spot_price":
            let pair = arguments["currency_pair"] ?? "BTC-USD"
            return await coinbaseGET("/v2/prices/\(pair)/spot")

        case "exchange_rates":
            let currency = arguments["currency"] ?? "USD"
            return await coinbaseGET("/v2/exchange-rates?currency=\(currency)")

        case "user":
            return await coinbaseGET("/v2/user")

        case "addresses":
            guard let id = arguments["account_id"], !id.isEmpty else { return "Error: 'account_id' fehlt." }
            return await coinbaseGET("/v2/accounts/\(id)/addresses")

        case "create_address":
            guard let id = arguments["account_id"], !id.isEmpty else { return "Error: 'account_id' fehlt." }
            return await coinbasePOST("/v2/accounts/\(id)/addresses", body: [:])

        // ── v3 Advanced Trade API: Orders & Trading ──

        case "payment_methods":
            return await coinbaseGET("/api/v3/brokerage/payment_methods")

        case "products":
            return await coinbaseGET("/api/v3/brokerage/products?limit=50")

        case "product_detail":
            guard let pid = arguments["product_id"], !pid.isEmpty else { return "Error: 'product_id' fehlt (z.B. BTC-EUR)." }
            return await coinbaseGET("/api/v3/brokerage/products/\(pid)")

        case "buy":
            guard let pid = arguments["product_id"], !pid.isEmpty else {
                return "Error: 'product_id' fehlt (z.B. BTC-EUR)."
            }
            guard let quoteSize = arguments["quote_size"], !quoteSize.isEmpty else {
                return "Error: 'quote_size' fehlt (Betrag in Quote-Währung, z.B. '50' für 50 EUR)."
            }
            let body: [String: Any] = [
                "client_order_id": UUID().uuidString,
                "product_id": pid,
                "side": "BUY",
                "order_configuration": [
                    "market_market_ioc": [
                        "quote_size": quoteSize
                    ]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders", body: body)

        case "sell":
            guard let pid = arguments["product_id"], !pid.isEmpty else {
                return "Error: 'product_id' fehlt (z.B. BTC-EUR)."
            }
            guard let baseSize = arguments["base_size"], !baseSize.isEmpty else {
                return "Error: 'base_size' fehlt (Menge in Base-Währung, z.B. '0.001' für 0.001 BTC)."
            }
            let body: [String: Any] = [
                "client_order_id": UUID().uuidString,
                "product_id": pid,
                "side": "SELL",
                "order_configuration": [
                    "market_market_ioc": [
                        "base_size": baseSize
                    ]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders", body: body)

        case "limit_buy":
            guard let pid = arguments["product_id"], !pid.isEmpty else { return "Error: 'product_id' fehlt." }
            guard let baseSize = arguments["base_size"], !baseSize.isEmpty else { return "Error: 'base_size' fehlt." }
            guard let limitPrice = arguments["limit_price"], !limitPrice.isEmpty else { return "Error: 'limit_price' fehlt." }
            let body: [String: Any] = [
                "client_order_id": UUID().uuidString,
                "product_id": pid,
                "side": "BUY",
                "order_configuration": [
                    "limit_limit_gtc": [
                        "base_size": baseSize,
                        "limit_price": limitPrice,
                        "post_only": false
                    ] as [String : Any]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders", body: body)

        case "limit_sell":
            guard let pid = arguments["product_id"], !pid.isEmpty else { return "Error: 'product_id' fehlt." }
            guard let baseSize = arguments["base_size"], !baseSize.isEmpty else { return "Error: 'base_size' fehlt." }
            guard let limitPrice = arguments["limit_price"], !limitPrice.isEmpty else { return "Error: 'limit_price' fehlt." }
            let body: [String: Any] = [
                "client_order_id": UUID().uuidString,
                "product_id": pid,
                "side": "SELL",
                "order_configuration": [
                    "limit_limit_gtc": [
                        "base_size": baseSize,
                        "limit_price": limitPrice,
                        "post_only": false
                    ] as [String : Any]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders", body: body)

        case "preview_buy":
            guard let pid = arguments["product_id"], !pid.isEmpty else { return "Error: 'product_id' fehlt." }
            guard let quoteSize = arguments["quote_size"], !quoteSize.isEmpty else { return "Error: 'quote_size' fehlt." }
            let body: [String: Any] = [
                "product_id": pid,
                "side": "BUY",
                "order_configuration": [
                    "market_market_ioc": ["quote_size": quoteSize]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders/preview", body: body)

        case "preview_sell":
            guard let pid = arguments["product_id"], !pid.isEmpty else { return "Error: 'product_id' fehlt." }
            guard let baseSize = arguments["base_size"], !baseSize.isEmpty else { return "Error: 'base_size' fehlt." }
            let body: [String: Any] = [
                "product_id": pid,
                "side": "SELL",
                "order_configuration": [
                    "market_market_ioc": ["base_size": baseSize]
                ]
            ]
            return await coinbasePOST("/api/v3/brokerage/orders/preview", body: body)

        case "cancel_order":
            guard let oid = arguments["order_id"], !oid.isEmpty else { return "Error: 'order_id' fehlt." }
            let body: [String: Any] = ["order_ids": [oid]]
            return await coinbasePOST("/api/v3/brokerage/orders/batch_cancel", body: body)

        case "list_orders":
            return await coinbaseGET("/api/v3/brokerage/orders/historical/batch?order_status=OPEN")

        case "order_detail":
            guard let oid = arguments["order_id"], !oid.isEmpty else { return "Error: 'order_id' fehlt." }
            return await coinbaseGET("/api/v3/brokerage/orders/historical/\(oid)")

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    // MARK: - API Requests

    private func coinbaseGET(_ path: String) async -> String {
        let jwtPath = path.components(separatedBy: "?").first ?? path
        guard let jwt = generateJWT(method: "GET", path: jwtPath) else {
            return "Error: JWT-Generierung fehlgeschlagen. Prüfe API Key in Einstellungen → Integrationen → Coinbase."
        }
        guard let url = URL(string: "\(apiBase)\(path)") else {
            return "Error: Ungültige URL."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("2024-01-01", forHTTPHeaderField: "CB-VERSION")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        return await performRequest(request)
    }

    private func coinbasePOST(_ path: String, body: [String: Any]) async -> String {
        guard let jwt = generateJWT(method: "POST", path: path) else {
            return "Error: JWT-Generierung fehlgeschlagen. Prüfe API Key in Einstellungen."
        }
        guard let url = URL(string: "\(apiBase)\(path)") else {
            return "Error: Ungültige URL."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("2024-01-01", forHTTPHeaderField: "CB-VERSION")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        if !body.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        return await performRequest(request)
    }

    private func performRequest(_ request: URLRequest) async -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(8192), encoding: .utf8) ?? "(leer)"
            if status == 401 {
                return "Error: Coinbase 401 Unauthorized — API Key ungültig oder Berechtigungen fehlen."
            }
            if status >= 400 { return "Error: HTTP \(status): \(text)" }
            return text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation

public struct CoinbaseApiTool: Tool {
    public let name = "coinbase_api"
    public let description = "Coinbase API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Coinbase API ist auf Linux deaktiviert." }
}
#endif
