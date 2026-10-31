import Foundation

/// Pace is minutes per kilometre, shown like `6:30/km` and, as a range, `6:25–7:10/km` (fastest end first).
enum PaceFormat {
    static func minutesSeconds(_ secondsPerKm: Int) -> String {
        let total = max(0, secondsPerKm)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func range(min: Int, max: Int) -> String {
        "\(minutesSeconds(min))–\(minutesSeconds(max))/km"
    }

    /// The same text with paces in words, for VoiceOver: "6:25–7:10/km" is "6 minutes 25 to 7 minutes 10 per
    /// kilometre" (docs/design-notes.md, VoiceOver).
    static func spoken(_ text: String) -> String {
        func words(_ minutes: Substring, _ seconds: Substring) -> String {
            seconds == "00" ? "\(minutes) minutes" : "\(minutes) minutes \(Int(seconds) ?? 0)"
        }
        let pace = /(\d+):(\d{2})(?:–(\d+):(\d{2}))?\/km/
        return text.replacing(pace) { match in
            let first = words(match.output.1, match.output.2)
            guard let toMinutes = match.output.3, let toSeconds = match.output.4 else { return "\(first) per kilometre" }
            return "\(first) to \(words(toMinutes, toSeconds)) per kilometre"
        }
    }
}
