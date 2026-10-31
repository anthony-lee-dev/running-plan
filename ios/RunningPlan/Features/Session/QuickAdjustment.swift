import APIClient
import Foundation

/// One session write: the session, the revision it was read at (sent as `If-Match`), and the change.
struct SessionEdit: Equatable {
    let sessionId: String
    let revision: Int
    let update: Components.Schemas.SessionUpdate
}

/// "Not feeling it today?" on DK-Session (design §8.4). Every adjustment sends more than `status`, so the server hands
/// the session to the user (`api/src/domain/session-edit.ts` keeps the engine's ownership only for a status-only
/// edit). The amounts are starting values for the coach review (backlog H.1).
enum QuickAdjustment: CaseIterable {
    case shorter, easier, skip

    var title: String {
        switch self {
        case .shorter: "Shorter"
        case .easier: "Easier"
        case .skip: "Skip"
        }
    }

    /// Shorter takes about a quarter off; Easier slows paces by this much (or turns hard work into an easy run).
    static let shorterShare = 0.75
    static let easierSecPerKm = 15

    /// The change, or nil when the adjustment does not apply (rest days).
    func update(for s: Components.Schemas.SessionContent) -> Components.Schemas.SessionUpdate? {
        guard s._type != .rest else { return nil }
        switch self {
        case .skip:
            // The unchanged date makes this more than a status edit, so the session becomes the user's.
            return .init(date: s.date, status: .skipped)
        case .shorter:
            return Self.shorter(s)
        case .easier:
            return Self.easier(s)
        }
    }

    // MARK: Shorter

    private static func shorter(_ s: Components.Schemas.SessionContent) -> Components.Schemas.SessionUpdate? {
        switch s._type {
        case .custom:
            // Nothing to shorten without a time or distance.
            guard var custom = s.custom, let goal = custom.goal, goal.value != nil else { return nil }
            custom.goal = shrink(goal)
            return .init(custom: custom)
        case .strength:
            return .init(steps: (s.steps ?? []).map { step in
                guard case .exercise(var e) = step else { return step }
                e.sets = max(1, e.sets - 1)
                return .exercise(e)
            })
        default:
            return .init(steps: (s.steps ?? []).map { step in
                switch step {
                case .work(let r): return .work(shrink(r))
                case ._repeat(var group):
                    // Fewer reps rather than shorter ones; a repeat already at two shortens its work instead.
                    if group.count > 2 {
                        group.count = max(2, group.count - max(1, Int((Double(group.count) * (1 - shorterShare)).rounded())))
                    } else {
                        group.steps = group.steps.map { $0.kind == .work ? shrink($0) : $0 }
                    }
                    return ._repeat(group)
                default: return step
                }
            })
        }
    }

    private static func shrink(_ r: Components.Schemas.RunStep) -> Components.Schemas.RunStep {
        var r = r
        r.goal = shrink(r.goal)
        return r
    }

    /// A quarter off: distances to the nearest 100 m, times to the nearest minute.
    private static func shrink(_ goal: Components.Schemas.StepGoal) -> Components.Schemas.StepGoal {
        guard let value = goal.value else { return goal }
        let unit = goal._type == .distance ? 100.0 : 60.0
        let shorter = Int((Double(value) * shorterShare / unit).rounded() * unit)
        // Never below one unit, but never longer than it was either (a 30 s step stays 30 s).
        return .init(_type: goal._type, value: max(min(Int(unit), value), shorter))
    }

    // MARK: Easier

    private static func easier(_ s: Components.Schemas.SessionContent) -> Components.Schemas.SessionUpdate {
        switch s._type {
        case .custom:
            var custom = s.custom ?? .init()
            custom.effort = custom.effort == .hard ? .moderate : .easy
            return .init(custom: custom)
        case .strength:
            return .init(steps: (s.steps ?? []).map { step in
                guard case .exercise(var e) = step else { return step }
                e.effort = .easy
                return .exercise(e)
            })
        case .intervals, .tempo:
            // The same distance (or time) as one easy run, at the warm-up's easy pace when it has one.
            let runs = (s.steps ?? []).flatMap(spelledOut)
            let metres = runs.reduce(0) { $0 + ($1.goal._type == .distance ? $1.goal.value ?? 0 : 0) }
            let seconds = runs.reduce(0) { $0 + ($1.goal._type == .time ? $1.goal.value ?? 0 : 0) }
            let easyTarget = runs.first { $0.kind != .work && $0.target.map(isPace) == true }?.target
                ?? .effort(.init(_type: .effort, effort: .easy))
            let goal: Components.Schemas.StepGoal = metres > 0
                ? .init(_type: .distance, value: max(100, Int((Double(metres) / 100).rounded()) * 100))
                : .init(_type: .time, value: max(60, seconds))
            // An easy run is not a key session, so missing it later is not flagged as a missed key session.
            return .init(_type: .easy, title: "Easy run", key: false, steps: [.work(.init(kind: .work, goal: goal, target: easyTarget))])
        default:
            return .init(steps: (s.steps ?? []).map(slower))
        }
    }

    private static func slower(_ step: Components.Schemas.Step) -> Components.Schemas.Step {
        switch step {
        case .warmup(let r): return .warmup(slower(r))
        case .work(let r): return .work(slower(r))
        case .recovery(let r): return .recovery(slower(r))
        case .cooldown(let r): return .cooldown(slower(r))
        case ._repeat(var group):
            group.steps = group.steps.map { slower($0) }
            return ._repeat(group)
        case .exercise: return step
        }
    }

    private static func isPace(_ target: Components.Schemas.StepTarget) -> Bool {
        if case .pace = target { return true }
        return false
    }

    /// A pace target slowed by `easierSecPerKm`; a hard effort becomes easy.
    private static func slower(_ r: Components.Schemas.RunStep) -> Components.Schemas.RunStep {
        var r = r
        switch r.target {
        case .pace(var p)?:
            p.range.minSecPerKm = min(1200, p.range.minSecPerKm + easierSecPerKm)
            p.range.maxSecPerKm = min(1200, p.range.maxSecPerKm + easierSecPerKm)
            r.target = .pace(p)
        case .effort?:
            r.target = .effort(.init(_type: .effort, effort: .easy))
        default:
            break
        }
        return r
    }

    private static func spelledOut(_ step: Components.Schemas.Step) -> [Components.Schemas.RunStep] {
        switch step {
        case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r): [r]
        case ._repeat(let g): Array(repeating: g.steps, count: g.count).flatMap { $0 }
        case .exercise: []
        }
    }

    // MARK: Swap

    struct DayOption: Equatable {
        let date: String
        /// "Thursday, Oct 29 · free", "Friday, Oct 30 · swap with Easy run".
        let label: String
    }

    /// The other days of the session's week, saying what moving there does.
    static func moveOptions(_ session: Components.Schemas.Session, in schedule: PlanSchedule) -> [DayOption] {
        let week = schedule.week(of: session.value2.date)
        guard week >= 0 else { return [] }
        return schedule.days(ofWeek: week).filter { $0 != session.value2.date }.map { date in
            let there = schedule.sessions.filter { $0.value2.date == date && $0.value2._type != .rest }
            let what = there.isEmpty ? "free" : "swap with " + there.map { $0.value2.title ?? SessionSummary.effort($0.value2) }.joined(separator: " and ")
            return DayOption(date: date, label: "\(NextModel.weekday(date)), \(PlanPreview.shortDate(date)) · \(what)")
        }
    }

    /// Moves the session to `date`; whatever is on that day (rest included) takes its place, so nothing is crammed.
    static func move(_ session: Components.Schemas.Session, to date: String, in schedule: PlanSchedule) -> [SessionEdit] {
        let from = session.value2.date
        guard date != from else { return [] }
        let others = schedule.sessions.filter { $0.value2.date == date && $0.value1.id != session.value1.id }
        return [SessionEdit(sessionId: session.value1.id, revision: session.value1.revision, update: .init(date: date))]
            + others.map { SessionEdit(sessionId: $0.value1.id, revision: $0.value1.revision, update: .init(date: from)) }
    }
}

/// The optional before-session check-in on DK-Session, on the API's 1 (awful) to 5 (great) feel.
enum BeforeFeeling: CaseIterable {
    case fresh, okay, tired

    var title: String {
        switch self {
        case .fresh: "Fresh"
        case .okay: "Okay"
        case .tired: "Tired"
        }
    }

    var feel: Int {
        switch self {
        case .fresh: 5
        case .okay: 3
        case .tired: 2
        }
    }
}
