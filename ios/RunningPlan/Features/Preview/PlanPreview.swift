import APIClient
import Foundation

/// Everything DK-Preview shows, worked out from the draft the API returned. Plain values, so it is easy to test.
struct PlanPreview: Equatable {
    enum Phase: String, Equatable {
        case base, build, peak, taper
        var title: String { rawValue.capitalized }
    }

    struct WeekBar: Equatable, Identifiable {
        let index: Int
        let kilometres: Double
        let phase: Phase
        var id: Int { index }
    }

    struct DayRow: Equatable, Identifiable {
        let weekday: String
        let text: String
        let isRest: Bool
        var id: String { weekday }
    }

    struct Sample: Equatable {
        let title: String
        let detail: String
        let why: String
    }

    struct Notice: Equatable, Identifiable {
        let code: String
        let message: String
        let isCaution: Bool
        var id: String { "\(code)|\(message)" }
    }

    let headline: String
    let bars: [WeekBar]
    let chartNote: String
    let chartDescription: String
    let weekTitle: String
    let weekPhase: String
    let days: [DayRow]
    let sample: Sample?
    let assumptions: [String]
    let warnings: [Notice]

    init(draft: Components.Schemas.PlanDraft) {
        let start = Self.dayNumber(draft.startDate)
        let runTypes: Set<Components.Schemas.SessionType> = [.easy, .long, .intervals, .tempo]
        func week(of session: Components.Schemas.SessionContent) -> Int { Int((Double(Self.dayNumber(session.date) - start) / 7).rounded(.down)) }

        // Weekly distance, and the phase of each week.
        var metres = [Double](repeating: 0, count: max(draft.weekCount, 0))
        for session in draft.sessions where week(of: session) >= 0 && week(of: session) < metres.count {
            metres[week(of: session)] += Self.metres(of: session)
        }
        var phases: [Int: Phase] = [:]
        for w in draft.weeks { phases[w.index] = w.phase.flatMap { Phase(rawValue: $0.rawValue) } }
        let bars = metres.indices.map { WeekBar(index: $0, kilometres: metres[$0] / 1000, phase: phases[$0] ?? .base) }
        self.bars = bars

        // The headline: goal, date, length, runs a week.
        let first = draft.sessions.filter { week(of: $0) == 0 }
        let runs = first.filter { runTypes.contains($0._type) }.count
        let strength = first.filter { $0._type == .strength }.count
        var parts = [Self.goalName(draft.goal)]
        if let date = draft.goal.date { parts[0] += " on \(Self.shortDate(date))" }
        parts.append("\(draft.weekCount) weeks")
        parts.append(strength > 0 ? "\(runs) runs and \(strength) strength session\(strength == 1 ? "" : "s") a week" : "\(runs) runs a week")
        headline = parts.joined(separator: " · ")

        chartNote = Self.chartSentence(bars)
        chartDescription = "Bar chart of weekly running distance over \(bars.count) weeks: "
            + bars.map { Self.kilometres($0.kilometres) }.joined(separator: ", ") + " kilometres"

        // Week 1, one row per day from the start date.
        weekTitle = "Week 1 · \(Self.kilometres(bars.first?.kilometres ?? 0)) km"
        weekPhase = bars.first?.phase.title ?? ""
        days = (0..<7).map { offset in
            let day = start + offset
            let name = Self.weekdayName(day)
            let sessions = first.filter { Self.dayNumber($0.date) == day && $0._type != .rest }
            guard !sessions.isEmpty else { return DayRow(weekday: name, text: "Rest day", isRest: true) }
            return DayRow(weekday: name, text: sessions.map(Self.rowText).joined(separator: " + "), isRest: false)
        }

        sample = (first.first { $0._type == .easy } ?? first.first { runTypes.contains($0._type) }).map(Self.makeSample)

        assumptions = draft.assumptions.map(\.message)
        warnings = draft.warnings.map { Notice(code: $0.code, message: $0.message, isCaution: $0.severity == .caution) }
    }

    // MARK: Sessions

    /// The pace the server's validators assume for a run set by time, so the bars agree with its warnings.
    static let fallbackSecondsPerKm = 420.0

    /// "Easy run · 4 km", or "Strength · 20 min" for a session that is not measured in distance.
    private static func rowText(_ session: Components.Schemas.SessionContent) -> String {
        let title = session.title ?? typeName(session._type)
        let distance = metres(of: session)
        if distance > 0 { return "\(title) · \(kilometres(distance / 1000)) km" }
        let minutes = Int((seconds(of: session) / 60).rounded())
        return minutes > 0 ? "\(title) · \(minutes) min" : title
    }

    /// Time goals in a session, in seconds: time steps, and sets of timed exercises.
    static func seconds(of session: Components.Schemas.SessionContent) -> Double {
        func time(_ step: Components.Schemas.RunStep) -> Double { step.goal._type == .time ? Double(step.goal.value ?? 0) : 0 }
        return (session.steps ?? []).reduce(0) { total, step in
            switch step {
            case .warmup(let s), .work(let s), .recovery(let s), .cooldown(let s): total + time(s)
            case ._repeat(let r): total + Double(r.count) * r.steps.reduce(0) { $0 + time($1) }
            case .exercise(let e): total + Double(e.sets) * Double(e.durationSec ?? 0)
            }
        }
    }

    /// Running distance of a session: distance goals, repeat groups multiplied out, and runs set by time at the
    /// validators' fallback pace. Strength and rest count for nothing.
    static func metres(of session: Components.Schemas.SessionContent) -> Double {
        guard session._type != .strength, session._type != .rest, session._type != .custom else { return 0 }
        func distance(_ step: Components.Schemas.RunStep) -> Double {
            switch step.goal._type {
            case .distance: Double(step.goal.value ?? 0)
            case .time: Double(step.goal.value ?? 0) / fallbackSecondsPerKm * 1000
            case .open: 0
            }
        }
        return (session.steps ?? []).reduce(0) { total, step in
            switch step {
            case .warmup(let s), .work(let s), .recovery(let s), .cooldown(let s): total + distance(s)
            case ._repeat(let r): total + Double(r.count) * r.steps.reduce(0) { $0 + distance($1) }
            case .exercise: total
            }
        }
    }

    private static func makeSample(_ session: Components.Schemas.SessionContent) -> Sample {
        let km = kilometres(metres(of: session) / 1000)
        let name = session.title ?? typeName(session._type)
        var detail = [effortWord(session._type)]
        if case .work(let step)? = (session.steps ?? []).first(where: { if case .work = $0 { return true } else { return false } }),
           let target = step.target {
            switch target {
            case .pace(let pace):
                detail.append(PaceFormat.range(min: pace.range.minSecPerKm, max: pace.range.maxSecPerKm))
                let middle = Double(pace.range.minSecPerKm + pace.range.maxSecPerKm) / 2
                let minutes = Int((middle * (workMetres(of: session) / 1000) / 60).rounded())
                if minutes > 0 { detail.append("about \(minutes) min") }
            case .heart_rate(let hr):
                detail.append("\(hr.range.minBpm)–\(hr.range.maxBpm) bpm")
            case .effort, .none:
                break
            }
        }
        return Sample(title: "Sample: \(name), \(km) km", detail: detail.joined(separator: " · "), why: "Why: \(why(session._type))")
    }

    /// Distance covered at the session's main pace: the work steps, not the warm-up and cool-down.
    private static func workMetres(of session: Components.Schemas.SessionContent) -> Double {
        (session.steps ?? []).reduce(0) { total, step in
            switch step {
            case .work(let s): total + (s.goal._type == .distance ? Double(s.goal.value ?? 0) : 0)
            case ._repeat(let r): total + Double(r.count) * r.steps.reduce(0) { $0 + ($1.kind == .work && $1.goal._type == .distance ? Double($1.goal.value ?? 0) : 0) }
            default: total
            }
        }
    }

    private static func effortWord(_ type: Components.Schemas.SessionType) -> String {
        switch type {
        case .tempo: "Moderate effort"
        case .intervals: "Hard effort"
        default: "Easy effort"
        }
    }

    private static func why(_ type: Components.Schemas.SessionType) -> String {
        switch type {
        case .long: "a long, steady run builds the endurance you race on."
        case .tempo: "comfortably hard running teaches you to hold your pace."
        case .intervals: "short fast reps build speed, with plenty of recovery."
        default: "easy miles build your base without strain."
        }
    }

    private static func typeName(_ type: Components.Schemas.SessionType) -> String {
        switch type {
        case .easy: "Easy run"
        case .long: "Long run"
        case .intervals: "Intervals"
        case .tempo: "Tempo run"
        case .strength: "Strength"
        case .rest: "Rest day"
        case .custom: "Workout"
        }
    }

    // MARK: Chart note

    private static func chartSentence(_ bars: [WeekBar]) -> String {
        // A down week is a middle week that is lower than the one before it.
        let down = bars.indices.dropFirst().filter { bars[$0].phase != .taper && bars[$0].kilometres < bars[$0 - 1].kilometres }.map { $0 + 1 }
        let tapers = bars.contains { $0.phase == .taper }
        guard !down.isEmpty else { return tapers ? "The final two weeks pull back so you arrive fresh." : "" }
        let weeks: String
        switch down.count {
        case 1: weeks = "Week \(down[0])"
        default: weeks = "Weeks " + down.dropLast().map(String.init).joined(separator: ", ") + " and \(down.last!)"
        }
        return tapers ? "\(weeks) and the final two weeks pull back so you arrive fresh." : "\(weeks) pull back so you arrive fresh."
    }

    // MARK: Formatting

    /// `4`, `4.5`: whole kilometres without a decimal point.
    static func kilometres(_ km: Double) -> String {
        let rounded = (km * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private static func goalName(_ goal: Components.Schemas.Goal) -> String {
        switch goal._type {
        case ._5k: "5K"
        case ._10k: "10K"
        case .half_marathon: "Half marathon"
        case .custom: goal.label ?? "Your goal"
        case .none: "Your plan"
        }
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `2027-01-10` as `Jan 10`.
    static func shortDate(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return date }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    /// Whole days since 1970-01-01 for a `YYYY-MM-DD` local date (no time zone involved).
    static func dayNumber(_ date: String) -> Int {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date(timeIntervalSince1970: 0)
        return Int((day.timeIntervalSince1970 / 86_400).rounded())
    }

    /// 1970-01-01 was a Thursday.
    static func weekdayName(_ day: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][((day + 3) % 7 + 7) % 7]
    }
}
