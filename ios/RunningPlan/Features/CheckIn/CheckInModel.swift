import APIClient
import Foundation

/// The three answers to "How did it feel?" after a session, on the API's `feel` (1 awful to 5 great) and `effortFelt`
/// (1 to 10). The values reach the server's proposal rules in `api/src/domain/proposals.ts`: effort 8 or more is
/// "much harder than planned" (`HARD_EFFORT`), and feel 4 or more with effort 4 or less is an easy session
/// (`EASY_FEEL`, `EASY_EFFORT`). Change both together.
enum AfterFeeling: CaseIterable, Equatable, Sendable {
    case easier, aboutRight, harder

    var title: String {
        switch self {
        case .easier: "Easier than I expected"
        case .aboutRight: "About right"
        case .harder: "Harder than I expected"
        }
    }

    var feel: Int {
        switch self {
        case .easier: 4
        case .aboutRight: 3
        case .harder: 2
        }
    }

    var effortFelt: Int {
        switch self {
        case .easier: 4
        case .aboutRight: 6
        case .harder: 8
        }
    }
}

/// What an after-session check-in sends.
struct AfterCheckIn: Equatable, Sendable {
    let feeling: AfterFeeling
    let pain: Bool
}

/// DK-CheckIn: plan vs actual for a session and the run just matched to it. Pure: built from the session's content and
/// the activity's fields. Imported summaries carry no rep detail, so sessions are compared as a whole (design §8.3).
struct CheckInModel: Equatable {
    struct Bar: Equatable {
        let label: String
        /// "5.0 planned", or nil when the plan has no amount to compare with.
        let planned: String?
        let actual: String
        /// How much of the plan was done, 0 to 1; nil with nothing planned.
        let fill: Double?
        let spoken: String
    }

    struct Pace: Equatable {
        /// "6:25–7:10 target", or "~6:35 planned average" for a session with more than one pace.
        let planned: String
        let actual: String
        /// The target range and the run's pace on a 0 to 1 scale (faster to the left); nil without a single target.
        let band: ClosedRange<Double>?
        let marker: Double?
        let verdict: String?
        let inRange: Bool
        let spoken: String
    }

    let eyebrow: String
    let headline: String
    let summary: String
    let distance: Bar?
    let time: Bar
    let pace: Pace?

    static let guidance = "If something hurts, stop and talk to a qualified professional. This app can't give medical advice."

    /// The pain guidance is safety information, not a plan change: it always shows, whatever the review setting (§6.6a).
    /// With pain flagged it becomes a notice card.
    static func painGuidance(pain: Bool) -> (text: String, isNotice: Bool) { (guidance, pain) }

    init(session: Components.Schemas.SessionContent, activity: Components.Schemas.ActivityFields) {
        let type = session._type
        let isRun = [.easy, .long, .tempo, .intervals].contains(type)
        eyebrow = "MATCHED · " + Self.typeName(type).uppercased()

        // Distance: runs with a planned distance and a measured one.
        let plannedMetres = PlanPreview.metres(of: session)
        let actualMetres = activity.distanceM.map(Double.init) ?? 0
        if isRun, plannedMetres > 0, actualMetres > 0 {
            let planned = String(format: "%.1f", plannedMetres / 1000)
            let actual = String(format: "%.1f", actualMetres / 1000)
            distance = Bar(
                label: "Distance", planned: "\(planned) planned", actual: "\(actual) km",
                fill: min(1, actualMetres / plannedMetres), spoken: "Distance: \(planned) kilometres planned, \(actual) kilometres run"
            )
        } else {
            distance = nil
        }

        // Time: exact when the plan sets it, "~" when it is estimated from distance and pace.
        let (plannedMinutes, estimated) = Self.plannedMinutes(session)
        let seconds = activity.durationSec
        let clock = StepFormat.clock(seconds)
        let spokenClock = Self.spokenClock(seconds)
        if plannedMinutes > 0 {
            let prefix = estimated ? "~" : ""
            time = Bar(
                label: "Time", planned: "\(prefix)\(plannedMinutes) min planned", actual: clock,
                fill: min(1, Double(seconds) / Double(plannedMinutes * 60)),
                spoken: "Time: \(estimated ? "about " : "")\(plannedMinutes) minutes planned, \(spokenClock)"
            )
        } else {
            time = Bar(label: "Time", planned: nil, actual: clock, fill: nil, spoken: "Time: \(spokenClock)")
        }

        // Pace: a steady run is judged against its target; a session of several paces shows the average only, since the
        // average takes in the warm-up and the jogs.
        var pace: Pace?
        if isRun, actualMetres > 0 {
            let actualPace = Int((Double(seconds) / (actualMetres / 1000)).rounded())
            let actualText = "\(PaceFormat.minutesSeconds(actualPace))/km"
            if [.easy, .long].contains(type), let range = Self.steadyRange(session) {
                let span = Double(max(30, range.max - range.min))
                let low = Double(range.min) - span
                let scale = span * 3
                let rangeName = type == .long ? "long-run range" : "easy range"
                let verdict: String
                let inRange = actualPace >= range.min && actualPace <= range.max
                if inRange { verdict = "In your \(rangeName)" } else if actualPace < range.min { verdict = "Faster than your \(rangeName)" } else { verdict = "Slower than your \(rangeName)" }
                let target = "\(PaceFormat.minutesSeconds(range.min))–\(PaceFormat.minutesSeconds(range.max))"
                pace = Pace(
                    planned: "\(target) target", actual: actualText,
                    band: ((Double(range.min) - low) / scale)...((Double(range.max) - low) / scale),
                    marker: min(1, max(0, (Double(actualPace) - low) / scale)),
                    verdict: verdict, inRange: inRange,
                    spoken: "Pace: " + PaceFormat.spoken("\(target)/km target, \(actualText). \(verdict)")
                )
            } else {
                let estimate = SessionSummary.estimatedSeconds(session)
                let planned = plannedMetres > 0 && estimate > 0
                    ? "~\(PaceFormat.minutesSeconds(Int((estimate / (plannedMetres / 1000)).rounded()))) planned average" : "Average"
                pace = Pace(
                    planned: planned, actual: actualText, band: nil, marker: nil, verdict: nil, inRange: true,
                    spoken: "Pace: " + PaceFormat.spoken(planned.replacingOccurrences(of: " planned", with: "/km planned") + ", \(actualText)")
                )
            }
        }
        self.pace = pace

        // The words at the top: always kind; short days and quick easy runs are said plainly.
        guard isRun else {
            headline = "Nice work, that's one done"
            summary = "Every session you finish builds the habit."
            return
        }
        let ratio: Double? = distance != nil ? actualMetres / plannedMetres
            : plannedMinutes > 0 ? Double(seconds) / Double(plannedMinutes * 60) : nil
        if let ratio, ratio < 0.8 {
            headline = "Done, and it all counts"
            summary = "You did less than planned. Short days happen, and the plan has room for them."
        } else if let verdict = pace?.verdict, verdict.hasPrefix("Faster") {
            headline = "Nice work, a little quick"
            summary = "You went faster than the target. These runs do their job best when they stay relaxed."
        } else {
            headline = "Nice work, that's a solid one"
            let amount = (ratio ?? 1) >= 1.02 ? "You ran a little over plan" : "You ran about what was planned"
            if let pace, pace.verdict != nil {
                summary = pace.inRange
                    ? amount + " and kept the pace \(type == .long ? "steady" : "easy"), right where it should be."
                    : amount + ", a touch slower than the target. That's fine on a day like this."
            } else {
                summary = amount + "."
            }
        }
    }

    // MARK: Helpers

    static func typeName(_ type: Components.Schemas.SessionType) -> String {
        switch type {
        case .easy: "Easy run"
        case .long: "Long run"
        case .intervals: "Intervals"
        case .tempo: "Tempo run"
        case .strength: "Strength"
        case .custom: "Your own session"
        case .rest: "Rest"
        }
    }

    /// Planned minutes, and whether they are an estimate (distance at pace, or strength sets).
    private static func plannedMinutes(_ s: Components.Schemas.SessionContent) -> (Int, Bool) {
        switch s._type {
        case .rest: return (0, false)
        case .custom:
            let seconds = s.custom?.goal?._type == .time ? s.custom?.goal?.value ?? 0 : 0
            return (Int((Double(seconds) / 60).rounded()), false)
        case .strength:
            let seconds = PlanPreview.seconds(of: s)
            return seconds > 0 ? (max(5, Int((seconds / 300).rounded()) * 5), true) : (0, true)
        case .easy, .long, .tempo, .intervals:
            let allTimed = (s.steps ?? []).allSatisfy { step in
                switch step {
                case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r): r.goal._type == .time
                case ._repeat(let g): g.steps.allSatisfy { $0.goal._type == .time }
                case .exercise: true
                }
            }
            return (Int((SessionSummary.estimatedSeconds(s) / 60).rounded()), !allTimed)
        }
    }

    /// The one pace range of a steady run: every run step with a pace target shares it.
    private static func steadyRange(_ s: Components.Schemas.SessionContent) -> (min: Int, max: Int)? {
        var ranges: [(Int, Int)] = []
        for step in s.steps ?? [] {
            switch step {
            case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r):
                if case .pace(let p)? = r.target, r.kind == .work { ranges.append((p.range.minSecPerKm, p.range.maxSecPerKm)) }
            case ._repeat: return nil
            case .exercise: continue
            }
        }
        guard let first = ranges.first, ranges.allSatisfy({ $0 == first }) else { return nil }
        return (first.0, first.1)
    }

    /// "33 minutes 14 seconds", "1 hour 2 minutes".
    static func spokenClock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { parts.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if s > 0 || parts.isEmpty { parts.append(s == 1 ? "1 second" : "\(s) seconds") }
        return parts.joined(separator: " ")
    }
}
