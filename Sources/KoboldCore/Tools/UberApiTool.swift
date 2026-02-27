#if os(macOS)
import Foundation

// MARK: - Uber API Tool (OAuth2-basiert)
public struct UberApiTool: Tool {
    public let name = "uber_api"
    public let description = "Uber: Fahrpreis schätzen, Fahrt anfragen, Fahrtstatus prüfen, Account-Info. Benötigt OAuth-Verbindung in Einstellungen → Verbindungen."
    public let riskLevel: RiskLevel = .high // Kann echte Fahrten buchen

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: estimate, request_ride, ride_status, cancel_ride, account_info, ride_history", enumValues: ["estimate", "request_ride", "ride_status", "cancel_ride", "account_info", "ride_history"], required: true),
            "pickup_lat": ToolSchemaProperty(type: "string", description: "Abholort Breitengrad"),
            "pickup_lng": ToolSchemaProperty(type: "string", description: "Abholort Längengrad"),
            "pickup_address": ToolSchemaProperty(type: "string", description: "Abholadresse (alternativ zu Koordinaten)"),
            "dropoff_lat": ToolSchemaProperty(type: "string", description: "Zielort Breitengrad"),
            "dropoff_lng": ToolSchemaProperty(type: "string", description: "Zielort Längengrad"),
            "dropoff_address": ToolSchemaProperty(type: "string", description: "Zieladresse (alternativ zu Koordinaten)"),
            "ride_id": ToolSchemaProperty(type: "string", description: "Fahrt-ID für Status/Stornierung"),
            "product_id": ToolSchemaProperty(type: "string", description: "Produkt-ID (z.B. UberX, UberXL)")
        ], required: ["action"])
    }

    public init() {}

    private let oauth = OAuthTokenHelper(
        prefix: "kobold.uber",
        tokenURL: "https://login.uber.com/oauth/v2/token"
    )

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        guard let accessToken = await oauth.getValidToken() else {
            return "Error: Nicht mit Uber verbunden oder Token abgelaufen. Bitte unter Einstellungen → Verbindungen → Uber authentifizieren."
        }

        switch action {
        case "estimate":
            let pickupLat = arguments["pickup_lat"] ?? ""
            let pickupLng = arguments["pickup_lng"] ?? ""
            let dropoffLat = arguments["dropoff_lat"] ?? ""
            let dropoffLng = arguments["dropoff_lng"] ?? ""
            guard !pickupLat.isEmpty && !dropoffLat.isEmpty else {
                return "Error: pickup_lat/lng und dropoff_lat/lng werden benötigt für Preisschätzung."
            }
            return await getEstimate(pickupLat: pickupLat, pickupLng: pickupLng, dropoffLat: dropoffLat, dropoffLng: dropoffLng, token: accessToken)

        case "request_ride":
            let pickupLat = arguments["pickup_lat"] ?? ""
            let pickupLng = arguments["pickup_lng"] ?? ""
            let dropoffLat = arguments["dropoff_lat"] ?? ""
            let dropoffLng = arguments["dropoff_lng"] ?? ""
            let productId = arguments["product_id"] ?? ""
            guard !pickupLat.isEmpty && !dropoffLat.isEmpty else {
                return "Error: Koordinaten benötigt für Fahrtanfrage."
            }
            return await requestRide(pickupLat: pickupLat, pickupLng: pickupLng, dropoffLat: dropoffLat, dropoffLng: dropoffLng, productId: productId, token: accessToken)

        case "ride_status":
            let rideId = arguments["ride_id"] ?? ""
            guard !rideId.isEmpty else {
                return "Error: 'ride_id' wird für Status-Abfrage benötigt."
            }
            return await getRideStatus(rideId: rideId, token: accessToken)

        case "cancel_ride":
            let rideId = arguments["ride_id"] ?? ""
            guard !rideId.isEmpty else {
                return "Error: 'ride_id' wird zum Stornieren benötigt."
            }
            return await cancelRide(rideId: rideId, token: accessToken)

        case "account_info":
            return await getAccountInfo(token: accessToken)

        case "ride_history":
            return await getRideHistory(token: accessToken)

        default:
            return "Error: Unbekannte Aktion '\(action)'. Verfügbar: estimate, request_ride, ride_status, cancel_ride, account_info, ride_history"
        }
    }

    // MARK: - API Calls

    private func getEstimate(pickupLat: String, pickupLng: String, dropoffLat: String, dropoffLng: String, token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/estimates/price?start_latitude=\(pickupLat)&start_longitude=\(pickupLng)&end_latitude=\(dropoffLat)&end_longitude=\(dropoffLng)") else {
            return "Error: URL-Fehler"
        }
        return await apiCall(url: url, method: "GET", token: token)
    }

    private func requestRide(pickupLat: String, pickupLng: String, dropoffLat: String, dropoffLng: String, productId: String, token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/requests") else {
            return "Error: URL-Fehler"
        }

        var body: [String: Any] = [
            "start_latitude": Double(pickupLat) ?? 0,
            "start_longitude": Double(pickupLng) ?? 0,
            "end_latitude": Double(dropoffLat) ?? 0,
            "end_longitude": Double(dropoffLng) ?? 0
        ]
        if !productId.isEmpty {
            body["product_id"] = productId
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Error: JSON-Fehler"
        }
        return await apiCall(url: url, method: "POST", token: token, body: bodyData)
    }

    private func getRideStatus(rideId: String, token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/requests/\(rideId)") else {
            return "Error: URL-Fehler"
        }
        return await apiCall(url: url, method: "GET", token: token)
    }

    private func cancelRide(rideId: String, token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/requests/\(rideId)") else {
            return "Error: URL-Fehler"
        }
        return await apiCall(url: url, method: "DELETE", token: token)
    }

    private func getAccountInfo(token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/me") else {
            return "Error: URL-Fehler"
        }
        return await apiCall(url: url, method: "GET", token: token)
    }

    private func getRideHistory(token: String) async -> String {
        guard let url = URL(string: "https://api.uber.com/v1.2/history?limit=10") else {
            return "Error: URL-Fehler"
        }
        return await apiCall(url: url, method: "GET", token: token)
    }

    private func apiCall(url: URL, method: String, token: String, body: Data? = nil) async -> String {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Auto-refresh on 401
            if status == 401 {
                if let newToken = await oauth.refreshToken() {
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let retryText = String(data: retryData.prefix(6000), encoding: .utf8) ?? "(leer)"
                    if retryStatus >= 400 { return "Error: HTTP \(retryStatus): \(retryText)" }
                    return retryText
                } else {
                    return "Error: Uber-Token abgelaufen und Refresh fehlgeschlagen. Bitte erneut anmelden unter Einstellungen → Verbindungen → Uber."
                }
            }

            let text = String(data: data.prefix(6000), encoding: .utf8) ?? "(leer)"
            if status >= 400 { return "Error: HTTP \(status): \(text)" }
            return text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

#elseif os(Linux)
import Foundation
public struct UberApiTool: Tool {
    public let name = "uber_api"
    public let description = "Uber API (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Uber API ist auf Linux deaktiviert." }
}
#endif
