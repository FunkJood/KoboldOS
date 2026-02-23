import SwiftUI
import CoreLocation

// MARK: - WeatherManager
// Open-Meteo integration for Dashboard weather widget (no API key needed)

@MainActor
class WeatherManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherManager()

    @Published var temperature: Double? = nil
    @Published var weatherDescription: String = ""
    @Published var iconName: String = "cloud.fill"
    @Published var cityName: String = ""
    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private var lastFetch: Date? = nil
    private let cacheInterval: TimeInterval = 1800 // 30 min
    private var locationManager: CLLocationManager?

    @AppStorage("kobold.weather.city") var manualCity: String = ""

    override init() {
        super.init()
    }

    func fetchWeatherIfNeeded() {
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheInterval { return }
        fetchWeather()
    }

    func fetchWeather() {
        isLoading = true
        lastError = nil

        if !manualCity.isEmpty {
            geocodeAndFetch(manualCity)
        } else {
            // Use CoreLocation for automatic detection
            locationManager = CLLocationManager()
            locationManager?.delegate = self
            locationManager?.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager?.requestWhenInUseAuthorization()
            locationManager?.requestLocation()
        }
    }

    // MARK: - Geocoding (city name -> lat/lon via Apple CLGeocoder)

    private func geocodeAndFetch(_ city: String) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(city) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Geocoding fehlgeschlagen: \(error.localizedDescription)"
                    self.isLoading = false
                    return
                }
                guard let placemark = placemarks?.first,
                      let location = placemark.location else {
                    self.lastError = "Stadt nicht gefunden: \(city)"
                    self.isLoading = false
                    return
                }
                let resolvedCity = placemark.locality ?? placemark.name ?? city
                self.fetchByLocation(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    resolvedCity: resolvedCity
                )
            }
        }
    }

    // MARK: - Open-Meteo API Request

    private func fetchByLocation(lat: Double, lon: Double, resolvedCity: String? = nil) {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day,wind_speed_10m&timezone=auto"
        guard let url = URL(string: urlStr) else {
            lastError = "Ungültige URL"
            isLoading = false
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = json["current"] as? [String: Any] else {
                    self.lastError = "Ungültige API-Antwort"
                    self.isLoading = false
                    return
                }

                // Parse temperature
                if let temp = current["temperature_2m"] as? Double {
                    self.temperature = temp
                }

                // Parse weather code and is_day
                let weatherCode = current["weather_code"] as? Int ?? -1
                let isDay = (current["is_day"] as? Int ?? 1) == 1

                self.weatherDescription = wmoDescription(for: weatherCode)
                self.iconName = wmoIcon(for: weatherCode, isDay: isDay)

                // Set city name: use resolved city or reverse-geocode
                if let city = resolvedCity, !city.isEmpty {
                    self.cityName = city
                } else {
                    self.reverseGeocodeCity(lat: lat, lon: lon)
                }

                self.lastFetch = Date()
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // MARK: - Reverse Geocoding (lat/lon -> city name)

    private func reverseGeocodeCity(lat: Double, lon: Double) {
        let location = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let placemark = placemarks?.first {
                    self.cityName = placemark.locality ?? placemark.name ?? ""
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            self.fetchByLocation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            self.locationManager = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.manualCity.isEmpty {
                // Fallback: Berlin coordinates
                self.fetchByLocation(lat: 52.52, lon: 13.405, resolvedCity: "Berlin")
            }
            self.locationManager = nil
        }
    }

    // MARK: - WMO Weather Code Mapping

    private func wmoDescription(for code: Int) -> String {
        switch code {
        case 0:
            return "Klarer Himmel"
        case 1:
            return "Überwiegend klar"
        case 2:
            return "Teilweise bewölkt"
        case 3:
            return "Bedeckt"
        case 45, 48:
            return "Nebel"
        case 51, 53, 55:
            return "Nieselregen"
        case 61, 63:
            return "Regen"
        case 65:
            return "Starker Regen"
        case 71, 73, 75, 77:
            return "Schnee"
        case 80:
            return "Leichte Schauer"
        case 81, 82:
            return "Schauer"
        case 95, 96, 99:
            return "Gewitter"
        default:
            return "Unbekannt"
        }
    }

    private func wmoIcon(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1:
            return isDay ? "sun.min.fill" : "moon.fill"
        case 2:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55:
            return "cloud.drizzle.fill"
        case 61, 63:
            return "cloud.rain.fill"
        case 65:
            return "cloud.heavyrain.fill"
        case 71, 73, 75, 77:
            return "cloud.snow.fill"
        case 80:
            return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 81, 82:
            return "cloud.rain.fill"
        case 95, 96, 99:
            return "cloud.bolt.fill"
        default:
            return "cloud.fill"
        }
    }
}
