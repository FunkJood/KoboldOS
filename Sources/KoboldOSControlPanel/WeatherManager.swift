import SwiftUI
import CoreLocation

// MARK: - WeatherManager
// OpenWeatherMap integration for Dashboard weather widget

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

    @AppStorage("kobold.weather.apiKey") var apiKey: String = ""
    @AppStorage("kobold.weather.city") var manualCity: String = ""

    override init() {
        super.init()
    }

    func fetchWeatherIfNeeded() {
        guard !apiKey.isEmpty else { return }
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheInterval { return }
        fetchWeather()
    }

    func fetchWeather() {
        guard !apiKey.isEmpty else {
            lastError = "Kein API-Key"
            return
        }
        isLoading = true
        lastError = nil

        if !manualCity.isEmpty {
            fetchByCity(manualCity)
        } else {
            // Try CoreLocation
            locationManager = CLLocationManager()
            locationManager?.delegate = self
            locationManager?.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager?.requestWhenInUseAuthorization()
            locationManager?.requestLocation()
        }
    }

    private func fetchByCity(_ city: String) {
        let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
        let urlStr = "https://api.openweathermap.org/data/2.5/weather?q=\(encoded)&units=metric&lang=de&appid=\(apiKey)"
        guard let url = URL(string: urlStr) else { return }
        performRequest(url)
    }

    private func fetchByLocation(lat: Double, lon: Double) {
        let urlStr = "https://api.openweathermap.org/data/2.5/weather?lat=\(lat)&lon=\(lon)&units=metric&lang=de&appid=\(apiKey)"
        guard let url = URL(string: urlStr) else { return }
        performRequest(url)
    }

    private func performRequest(_ url: URL) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let main = json["main"] as? [String: Any],
                       let temp = main["temp"] as? Double {
                        self.temperature = temp
                    }
                    if let weather = json["weather"] as? [[String: Any]],
                       let first = weather.first {
                        self.weatherDescription = (first["weatherDescription"] as? String) ?? ""
                        let iconCode = (first["icon"] as? String) ?? ""
                        self.iconName = mapWeatherIcon(iconCode)
                    }
                    if let name = json["name"] as? String {
                        self.cityName = name
                    }
                    self.lastFetch = Date()
                }
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // CLLocationManagerDelegate
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            self.fetchByLocation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            self.locationManager = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Fallback: try Berlin if no location
            if self.manualCity.isEmpty {
                self.fetchByCity("Berlin")
            }
            self.locationManager = nil
        }
    }

    private func mapWeatherIcon(_ code: String) -> String {
        switch code {
        case "01d": return "sun.max.fill"
        case "01n": return "moon.fill"
        case "02d": return "cloud.sun.fill"
        case "02n": return "cloud.moon.fill"
        case "03d", "03n": return "cloud.fill"
        case "04d", "04n": return "smoke.fill"
        case "09d", "09n": return "cloud.drizzle.fill"
        case "10d": return "cloud.sun.rain.fill"
        case "10n": return "cloud.moon.rain.fill"
        case "11d", "11n": return "cloud.bolt.fill"
        case "13d", "13n": return "cloud.snow.fill"
        case "50d", "50n": return "cloud.fog.fill"
        default: return "cloud.fill"
        }
    }
}
