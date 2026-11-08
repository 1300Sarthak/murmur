import Foundation

/// Live weather from Open-Meteo (free, no API key). Weather questions get real current data injected into the
/// prompt, which is faster and fresher than asking a model to search the web for it.
enum Weather {
    static func isWeatherQuestion(_ q: String) -> Bool {
        q.range(of: #"\b(weather|temperature|forecast|rain|raining|snow|sunny|cloudy|humid|humidity|wind|windy|umbrella|jacket|hot|cold|degrees)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "weather in Tokyo tomorrow" -> "Tokyo"; otherwise nil (use the home location).
    static func placeMentioned(in q: String) -> String? {
        guard let r = q.range(of: #"\b(?:in|at|for)\s+([A-Z][\w.'-]*(?:[ ,]+[A-Z][\w.'-]*){0,3})"#, options: .regularExpression) else { return nil }
        let words = q[r].split(separator: " ").dropFirst().joined(separator: " ")
        let stop: Set<String> = ["Today", "Tomorrow", "Tonight", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "The"]
        return stop.contains(words) ? nil : words.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
    }

    /// Structured forecast: drawn as a native card, and summarized into the AI's prompt.
    struct Report: Equatable {
        struct Day: Equatable { let name: String; let code: Int; let high: Int; let low: Int; let rain: Int }
        struct Hour: Equatable { let label: String; let temp: Int; let rain: Int }
        let place: String, temp: Int, feels: Int, code: Int, isDay: Bool, humidity: Int, wind: Int
        let days: [Day], hours: [Hour]

        var condition: String { Weather.describe(code) }
        var summary: String {
            var lines = ["Location: \(place)",
                         "Now: \(temp)°F, feels like \(feels)°F, \(condition), humidity \(humidity)%, wind \(wind) mph"]
            lines += days.map { "\($0.name): \(Weather.describe($0.code)), high \($0.high)°F, low \($0.low)°F, \($0.rain)% chance of precipitation" }
            lines.append("Next hours (time temp rain%): " + hours.map { "\($0.label) \($0.temp)°F \($0.rain)%" }.joined(separator: ", "))
            return lines.joined(separator: "\n")
        }
    }

    static func fetch(question: String, home: String) async -> Report? {
        let place = placeMentioned(in: question) ?? home
        guard !place.isEmpty, let geo = await geocode(place) else { return nil }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: "\(geo.lat)"), .init(name: "longitude", value: "\(geo.lon)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: "fahrenheit"), .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3"), .init(name: "forecast_hours", value: "10"),
        ]
        guard let obj = await json(c.url!) else { return nil }
        let cur = obj["current"] as? [String: Any] ?? [:]
        let daily = obj["daily"] as? [String: Any] ?? [:]
        let hourly = obj["hourly"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int { (v as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? 0 }
        func col(_ d: [String: Any], _ k: String) -> [Any] { d[k] as? [Any] ?? [] }
        let names = ["Today", "Tomorrow", "Day after"]
        let days = (0..<min(3, col(daily, "time").count)).map { i in
            Report.Day(name: names[i], code: int(col(daily, "weather_code")[safe: i]), high: int(col(daily, "temperature_2m_max")[safe: i]),
                       low: int(col(daily, "temperature_2m_min")[safe: i]), rain: int(col(daily, "precipitation_probability_max")[safe: i]))
        }
        let times = col(hourly, "time").compactMap { $0 as? String }
        let hours = times.enumerated().map { i, t in
            Report.Hour(label: hourLabel(t), temp: int(col(hourly, "temperature_2m")[safe: i]), rain: int(col(hourly, "precipitation_probability")[safe: i]))
        }
        return Report(place: geo.name, temp: int(cur["temperature_2m"]), feels: int(cur["apparent_temperature"]),
                      code: int(cur["weather_code"]), isDay: int(cur["is_day"]) == 1, humidity: int(cur["relative_humidity_2m"]),
                      wind: int(cur["wind_speed_10m"]), days: days, hours: hours)
    }

    private static func hourLabel(_ iso: String) -> String {
        guard let h = Int(iso.suffix(5).prefix(2)) else { return iso }
        return h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p"
    }

    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    // MARK: Helpers

    private struct Geo { let name: String; let lat: Double; let lon: Double }

    private static func geocode(_ place: String) async -> Geo? {
        let key = "geo:" + place.lowercased()
        if let c = UserDefaults.standard.array(forKey: key) as? [Any], c.count == 3,
           let name = c[0] as? String, let lat = c[1] as? Double, let lon = c[2] as? Double {
            return Geo(name: name, lat: lat, lon: lon)
        }
        // Open-Meteo matches the city name; "Dublin, CA" -> search "Dublin", prefer the matching state/country.
        let parts = place.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: parts.first ?? place), .init(name: "count", value: "10")]
        guard let obj = await json(c.url!), let results = obj["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        let hint = parts.dropFirst().joined(separator: " ").lowercased()
        let states = ["ca": "california", "ny": "new york", "tx": "texas", "wa": "washington", "ma": "massachusetts", "il": "illinois", "on": "ontario"]
        let want = states[hint] ?? hint
        let best = results.first { r in
            guard !want.isEmpty else { return true }
            let hay = [r["admin1"], r["country"], r["country_code"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            return hay.contains(want)
        } ?? results[0]
        guard let lat = best["latitude"] as? Double, let lon = best["longitude"] as? Double else { return nil }
        let name = [best["name"], best["admin1"], best["country_code"]].compactMap { $0 as? String }.joined(separator: ", ")
        UserDefaults.standard.set([name, lat, lon], forKey: key)
        return Geo(name: name, lat: lat, lon: lon)
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// WMO weather interpretation codes.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1: "mostly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "foggy"
        case 51, 53, 55, 56, 57: "drizzle"
        case 61, 63, 66: "rain"
        case 65, 67: "heavy rain"
        case 71, 73, 75, 77: "snow"
        case 80, 81: "rain showers"
        case 82: "violent rain showers"
        case 85, 86: "snow showers"
        case 95, 96, 99: "thunderstorms"
        default: "unknown conditions"
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
