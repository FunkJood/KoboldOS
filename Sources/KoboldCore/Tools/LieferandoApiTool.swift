#if os(macOS)
import Foundation

// MARK: - Lieferando API Tool (Takeaway.com / Just Eat Takeaway API)
public struct LieferandoApiTool: Tool {
    public let name = "lieferando_api"
    public let description = "Lieferando: Restaurants suchen, Speisekarten lesen, Bestellstatus prüfen. Benötigt API-Credentials in Einstellungen → Verbindungen."
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: search_restaurants, get_menu, order_status, get_address", enumValues: ["search_restaurants", "get_menu", "order_status", "get_address"], required: true),
            "query": ToolSchemaProperty(type: "string", description: "Suchbegriff (z.B. 'Pizza', 'Sushi') oder Restaurant-Slug"),
            "postal_code": ToolSchemaProperty(type: "string", description: "Postleitzahl für Restaurant-Suche"),
            "restaurant_id": ToolSchemaProperty(type: "string", description: "Restaurant-ID für Speisekarte"),
            "order_id": ToolSchemaProperty(type: "string", description: "Bestell-ID für Status-Abfrage")
        ], required: ["action"])
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""
        let query = arguments["query"] ?? ""
        let postalCode = arguments["postal_code"] ?? UserDefaults.standard.string(forKey: "kobold.lieferando.postalCode") ?? ""
        let restaurantId = arguments["restaurant_id"] ?? ""

        let apiKey = UserDefaults.standard.string(forKey: "kobold.lieferando.apiKey") ?? ""

        switch action {
        case "search_restaurants":
            guard !postalCode.isEmpty else {
                return "Error: Postleitzahl benötigt. Setze 'postal_code' oder konfiguriere sie in Einstellungen → Verbindungen → Lieferando."
            }
            return await searchRestaurants(postalCode: postalCode, query: query, apiKey: apiKey)

        case "get_menu":
            guard !restaurantId.isEmpty else {
                return "Error: 'restaurant_id' wird benötigt."
            }
            return await getMenu(restaurantId: restaurantId, apiKey: apiKey)

        case "order_status":
            let orderId = arguments["order_id"] ?? ""
            guard !orderId.isEmpty else {
                return "Error: 'order_id' wird für Status-Abfrage benötigt."
            }
            return await getOrderStatus(orderId: orderId, apiKey: apiKey)

        case "get_address":
            let address = UserDefaults.standard.string(forKey: "kobold.lieferando.address") ?? ""
            let plz = UserDefaults.standard.string(forKey: "kobold.lieferando.postalCode") ?? ""
            return "Gespeicherte Adresse: \(address), PLZ: \(plz)"

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: search_restaurants, get_menu, order_status, get_address"
        }
    }

    private func searchRestaurants(postalCode: String, query: String, apiKey: String) async -> String {
        // Takeaway.com API (Lieferando parent)
        var components = URLComponents(string: "https://cw-api.takeaway.com/api/v33/restaurants")!
        components.queryItems = [
            URLQueryItem(name: "deliveryAreaId", value: postalCode),
            URLQueryItem(name: "postalCode", value: postalCode),
            URLQueryItem(name: "lat", value: "0"),
            URLQueryItem(name: "lng", value: "0"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "isAccurate", value: "true"),
            URLQueryItem(name: "filterShowTestRestaurants", value: "false")
        ]
        guard let url = components.url else { return "Error: URL-Fehler" }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("6", forHTTPHeaderField: "X-Country-Code") // Germany
        request.setValue("de-DE", forHTTPHeaderField: "X-Language-Code")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                // Fallback: Versuche über Web-Scraping
                return "API-Fehler (HTTP \(status)). Tipp: Nutze den In-App-Browser mit app_browser navigate zu 'lieferando.de' für manuelle Suche, oder konfiguriere API-Credentials."
            }
            let text = String(data: data.prefix(6000), encoding: .utf8) ?? "(leer)"
            if !query.isEmpty {
                return "Restaurants in PLZ \(postalCode) (Suche: '\(query)'):\n\(text)"
            }
            return "Restaurants in PLZ \(postalCode):\n\(text)"
        } catch {
            return "Error: \(error.localizedDescription). Tipp: Nutze app_browser für manuelle Lieferando-Suche."
        }
    }

    private func getMenu(restaurantId: String, apiKey: String) async -> String {
        guard let url = URL(string: "https://cw-api.takeaway.com/api/v33/restaurant?slug=\(restaurantId)") else {
            return "Error: Ungültige Restaurant-ID"
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("6", forHTTPHeaderField: "X-Country-Code")
        request.setValue("de-DE", forHTTPHeaderField: "X-Language-Code")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(8000), encoding: .utf8) ?? "(leer)"
            if status >= 400 { return "Error: HTTP \(status): \(text)" }
            return "Speisekarte (\(restaurantId)):\n\(text)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func getOrderStatus(orderId: String, apiKey: String) async -> String {
        guard !apiKey.isEmpty else {
            return "Error: Kein API-Key konfiguriert. Bestellstatus benötigt Authentifizierung."
        }
        guard let url = URL(string: "https://cw-api.takeaway.com/api/v33/orders/\(orderId)") else {
            return "Error: Ungültige Bestell-ID"
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(4000), encoding: .utf8) ?? "(leer)"
            if status >= 400 { return "Error: HTTP \(status): \(text)" }
            return "Bestellstatus (\(orderId)):\n\(text)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation
public struct LieferandoApiTool: Tool {
    public let name = "lieferando_api"
    public let description = "Lieferando API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Lieferando API ist auf Linux deaktiviert." }
}
#endif
