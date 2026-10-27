import AppKit
import SwiftUI
import os.log

/// Current temperature and conditions from Open-Meteo (free, no API key).
/// Location comes from the city in the system time zone, so no Location
/// Services prompt.
final class WeatherWidget: DockWidget {
    static let kind = "weather"
    let name = "Weather"
    let icon = Image(systemName: "cloud.sun")
    let size = WidgetSize.small
    let refreshInterval: TimeInterval = 15 * 60

    @Published private(set) var temperature: Double?
    @Published private(set) var symbol = "cloud"
    @Published private(set) var place: String?

    private var coordinate: (lat: Double, lon: Double)?
    private var inFlight = false
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    private var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let fahrenheit = usesFahrenheit
        Task { @MainActor [weak self] in
            await self?.load(fahrenheit: fahrenheit)
            self?.inFlight = false
        }
    }

    func activate() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var body: some View {
        WeatherView(temperature: temperature, symbol: symbol, place: place)
    }

    // MARK: - Networking

    private struct GeocodeResponse: Decodable {
        struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
        let results: [Result]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        let current: Current
    }

    /// Runs on the main actor; only the two fetches suspend off it.
    @MainActor
    private func load(fahrenheit: Bool) async {
        do {
            if coordinate == nil {
                let city = TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
                guard let first = try await WeatherWidget.geocode(city) else {
                    logger.error("weather: no geocode result for \(city, privacy: .public)")
                    return
                }
                coordinate = (first.latitude, first.longitude)
                place = first.name
            }
            guard let coordinate else { return }
            let current = try await WeatherWidget.current(lat: coordinate.lat, lon: coordinate.lon, fahrenheit: fahrenheit)
            temperature = current.temperature_2m
            symbol = WeatherWidget.symbol(code: current.weather_code, isDay: current.is_day == 1)
            logger.info("weather: \(current.temperature_2m, format: .fixed(precision: 1))deg code \(current.weather_code)")
        } catch {
            logger.error("weather: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func geocode(_ city: String) async throws -> GeocodeResponse.Result? {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        let (data, _) = try await URLSession.shared.data(from: geo.url!)
        return try JSONDecoder().decode(GeocodeResponse.self, from: data).results?.first
    }

    private static func current(lat: Double, lon: Double, fahrenheit: Bool) async throws -> ForecastResponse.Current {
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await URLSession.shared.data(from: forecast.url!)
        return try JSONDecoder().decode(ForecastResponse.self, from: data).current
    }

    /// WMO weather codes -> SF Symbols.
    private static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

private struct WeatherView: View {
    let temperature: Double?
    let symbol: String
    let place: String?
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        WidgetTile(size: .small) {
            VStack(spacing: tile * 0.02) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: tile * 0.3))
                Text(temperature.map { "\(Int($0.rounded()))°" } ?? "--")
                    .font(.system(size: tile * 0.22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .help(place.map { "Weather in \($0)" } ?? "Weather")
    }
}
