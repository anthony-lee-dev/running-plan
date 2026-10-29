import Foundation

enum Weekday: String, Codable, CaseIterable, Identifiable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

enum GoalDistance: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveK = "5k"
    case tenK = "10k"
    case halfMarathon = "half_marathon"

    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .fiveK: "5K"
        case .tenK: "10K"
        case .halfMarathon: "21K"
        }
    }
    var title: String {
        switch self {
        case .fiveK: "Your first or fastest 5K"
        case .tenK: "Build speed and stamina"
        case .halfMarathon: "Half marathon"
        }
    }
    var typicalWeeks: String {
        switch self {
        case .fiveK: "Usually 8–12 weeks"
        case .tenK: "Usually 8–14 weeks"
        case .halfMarathon: "Usually 10–16 weeks"
        }
    }
    var metres: Int {
        switch self {
        case .fiveK: 5000
        case .tenK: 10000
        case .halfMarathon: 21097
        }
    }
}

enum RunningHistory: String, Codable, CaseIterable, Identifiable, Sendable {
    case newOrReturning = "new_or_returning"
    case underOneYear = "under_1_year"
    case oneToThreeYears = "1_to_3_years"
    case overThreeYears = "over_3_years"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newOrReturning: "New or returning"
        case .underOneYear: "Under a year"
        case .oneToThreeYears: "1 to 3 years"
        case .overThreeYears: "Over 3 years"
        }
    }
}

enum TargetDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case pace
    case heartRate = "heart_rate"
    case effort

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pace: "Pace in min/km"
        case .heartRate: "Heart rate"
        case .effort: "Effort"
        }
    }
}

/// The strength question: off, or on with the equipment the user has.
enum StrengthChoice: String, CaseIterable, Identifiable, Sendable {
    case none, bodyweight, dumbbells

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No strength sessions"
        case .bodyweight: "Bodyweight"
        case .dumbbells: "Dumbbells"
        }
    }
}

/// The interview answers in the shape of `InterviewAnswers` in spec/openapi.yaml. An absent field is a skipped
/// question; the engine fills it with a conservative default and says so in its assumptions.
struct InterviewAnswers: Codable, Equatable, Sendable {
    struct Goal: Codable, Equatable, Sendable {
        var distance: GoalDistance = .fiveK
        var date: String?
        var targetTimeSec: Int?
    }
    struct RecentResult: Codable, Equatable, Sendable {
        var distanceM: Int
        var timeSec: Int
    }
    struct Strength: Codable, Equatable, Sendable {
        var enabled: Bool
        var equipment: String?
    }
    struct HeartRate: Codable, Equatable, Sendable {
        var maxBpm: Int
    }

    var goal = Goal()
    var recentResult: RecentResult?
    var weeklyDistanceM: Int?
    var longestRunM: Int?
    var runningHistory: RunningHistory?
    var runsPerWeek: Int?
    var unavailableDays: [Weekday]?
    var longRunDay: Weekday?
    var pain: Bool?
    var strength: Strength?
    var targetDisplay: TargetDisplay?
    var heartRate: HeartRate?
}
