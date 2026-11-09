import Foundation

/// The weather Health recorded with a workout (issue #131). Read on open with the other readings and never uploaded.
struct RunWeather: Equatable, Sendable {
    var temperatureC: Double?
    var humidityPercent: Int?
    /// A short word such as "Clear" or "Rain"; nil for a condition we have no word for.
    var condition: String?

    /// "Clear · 18°C · 62% humidity", leaving out what was not recorded; nil when nothing was (no footer then).
    var text: String? {
        var parts: [String] = []
        if let condition { parts.append(condition) }
        if let temperatureC { parts.append("\(Int(temperatureC.rounded()))°C") }
        if let humidityPercent { parts.append("\(humidityPercent)% humidity") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Health stores humidity as a 0 to 1 fraction in percent units; anything outside that is dropped.
    static func percent(fromFraction value: Double) -> Int? {
        (0...1).contains(value) ? Int((value * 100).rounded()) : nil
    }
}
