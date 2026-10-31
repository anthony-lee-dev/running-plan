import Foundation

/// The arithmetic behind the step editor's scroll dials: each value is split across two wheels and put back together.
/// Pure and unit-tested. Ranges follow the API (a goal is 1 to 200000 seconds or metres, a pace 2:00 to 20:00 per km).
enum DialValues {
    static let maxGoal = 200_000
    static let maxMinutes = maxGoal / 60
    static let maxKm = 200
    static let paceRange = 120...1200

    // MARK: Time (minute and second wheels)

    static func minutes(_ seconds: Int) -> Int { min(maxMinutes, max(0, seconds) / 60) }

    static func secondsPart(_ seconds: Int) -> Int { max(0, seconds) % 60 }

    /// A time from the two wheels; never below one second, which the API requires.
    static func time(minutes: Int, seconds: Int) -> Int { min(maxGoal, max(1, minutes * 60 + seconds)) }

    // MARK: Distance (whole-km and hundredths-of-a-km wheels, so 10 m steps)

    static func km(_ metres: Int) -> Int { min(maxKm, max(0, metres) / 1000) }

    /// Hundredths of a km (0...99), rounded down; a value off the 10 m grid shows its lower step.
    static func hundredths(_ metres: Int) -> Int { max(0, metres) % 1000 / 10 }

    /// Moving the km wheel keeps the metres below the km, so an off-grid saved value only changes by what was asked.
    static func distance(km: Int, keepingFractionOf metres: Int) -> Int { clampDistance(km * 1000 + max(0, metres) % 1000) }

    /// Moving the decimal wheel sets the fraction and keeps the whole km.
    static func distance(hundredths: Int, keepingKmOf metres: Int) -> Int { clampDistance(km(metres) * 1000 + hundredths * 10) }

    private static func clampDistance(_ metres: Int) -> Int { min(maxGoal, max(10, metres)) }

    // MARK: Pace (minute and second wheels, per km)

    static let paceMinutes = 2...20

    static func paceMinutes(_ seconds: Int) -> Int { min(paceMinutes.upperBound, max(paceMinutes.lowerBound, seconds / 60)) }

    static func paceSecondsPart(_ seconds: Int) -> Int { max(0, seconds) % 60 }

    static func pace(minutes: Int, seconds: Int) -> Int { min(paceRange.upperBound, max(paceRange.lowerBound, minutes * 60 + seconds)) }
}
