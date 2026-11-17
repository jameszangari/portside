import AppKit
import SwiftUI
import os.log

/// Current temperature and conditions from Open-Meteo (free, no API key).
/// Location comes from the city in the system time zone, so no Location
/// Services prompt.
final class WeatherWidget: DockWidget {
    static let kind = "weather"
    let name = "Weather"
    var hoverTitle: String {
        let reading = temperature.map { "\(Int($0.rounded()))°\(usesFahrenheit ? "F" : "C")" } ?? "Loading"
        return "\(place ?? "Weather") · \(reading)"
    }
    let icon = Image(systemName: "cloud.sun")
    let size = WidgetSize.small
    let refreshInterval: TimeInterval = 15 * 60

    @Published private(set) var temperature: Double?
    @Published private(set) var symbol = "cloud"
    @Published private(set) var place: String?
    /// Today's high and low, and the conditions in words (Notch Shelf card).
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var condition: String?
    /// WMO code now and for the next hours, for the shelf's weather alert.
    @Published private(set) var code: Int?
    @Published private(set) var hourly: [(date: Date, code: Int)] = []

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
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        struct Hourly: Decodable { let time: [Double]; let weather_code: [Int] }
        let current: Current
        let daily: Daily?
        let hourly: Hourly?
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
            temperature = current.current.temperature_2m
            symbol = WeatherWidget.symbol(code: current.current.weather_code, isDay: current.current.is_day == 1)
            condition = WeatherWidget.condition(code: current.current.weather_code)
            high = current.daily?.temperature_2m_max.first
            low = current.daily?.temperature_2m_min.first
            code = current.current.weather_code
            hourly = current.hourly.map { hours in
                zip(hours.time, hours.weather_code).map { (date: Date(timeIntervalSince1970: $0.0), code: $0.1) }
            } ?? []
            logger.info("weather: \(current.current.temperature_2m, format: .fixed(precision: 1))deg code \(current.current.weather_code)")
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

    private static func current(lat: Double, lon: Double, fahrenheit: Bool) async throws -> ForecastResponse {
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "hourly", value: "weather_code"),
            .init(name: "forecast_hours", value: "3"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await URLSession.shared.data(from: forecast.url!)
        return try JSONDecoder().decode(ForecastResponse.self, from: data)
    }

    /// WMO weather codes in words.
    private static func condition(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77, 85, 86: "Snow"
        case 80...82: "Showers"
        case 95...99: "Thunderstorms"
        default: "Cloudy"
        }
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
                    .font(.system(size: WidgetTypography.fontSize(9.5, tile: tile)))
                Text(temperature.map { "\(Int($0.rounded()))°" } ?? "--")
                    .font(.system(size: WidgetTypography.fontSize(11, tile: tile), weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
