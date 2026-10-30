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
}
