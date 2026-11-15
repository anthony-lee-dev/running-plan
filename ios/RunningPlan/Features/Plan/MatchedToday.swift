import APIClient
import Foundation

/// DK-NextMatched (issue #186): the "Done today" card on Next. A session dated today that is done, has a run matched to
/// it and no after-run check-in saved on this device yet. Worked out from the plan and the run list, so it shows the
/// same after a relaunch and goes on its own when the match is removed or the day ends. Pure.
struct MatchedToday: Equatable {
    let sessionId: String
    let activityId: String
    /// The session's name, as on its card.
    let title: String
    /// The run's numbers: "6.8 km · 43:12 · 6:21/km average".
    let detail: String
    /// Where the run came from and what happened to it.
    let source: String

    init?(sessions: [Components.Schemas.Session], runs: [Components.Schemas.Activity], today: String, answered: Set<String>) {
        let done = sessions
            .filter { $0.value1.deletedAt == nil && $0.value2.date == today && $0.value2.status == .done && !answered.contains($0.value1.id) }
            .sorted { $0.value1.id < $1.value1.id }
        var found: (session: Components.Schemas.Session, run: Components.Schemas.Activity)?
        for session in done {
            if let run = RunMatchModel.matchedRun(for: session.value1.id, in: runs) {
                found = (session, run)
                break
            }
        }
        guard let found else { return nil }
        let session = found.session
        let run = found.run
        sessionId = session.value1.id
        activityId = run.value2.id
        title = session.value2.title ?? SessionSummary.effort(session.value2)
        detail = Self.numbers(run.value1)
        source = Self.sourceLine(run.value1)
    }

    /// How far back the check-in is still offered on a session's page.
    static let checkInDays = 7

    /// "How did it feel?" on the session page: a done session with its run, from the last week, not yet answered on
    /// this device. Older sessions are left alone: an answer that late says little, and one may exist from before.
    static func offersCheckIn(_ session: Components.Schemas.Session, matched: Bool, today: String, answered: Set<String>) -> Bool {
        guard matched, session.value2.status == .done, !answered.contains(session.value1.id) else { return false }
        let age = PlanPreview.dayNumber(today) - PlanPreview.dayNumber(session.value2.date)
        return age >= 0 && age <= checkInDays
    }

    /// Distance and time, then the pace for a run. No heart rate: the card stays one line.
    static func numbers(_ run: Components.Schemas.ActivityFields) -> String {
        let pace = InboxModel.detail(run).components(separatedBy: " · ").first { $0.hasSuffix("/km average") }
        return [InboxModel.headline(run), pace].compactMap { $0 }.joined(separator: " · ")
    }

    static func sourceLine(_ run: Components.Schemas.ActivityFields) -> String {
        let what = run.workoutType == .running ? "run" : "workout"
        if run.source == .manual { return "Your \(what), added by hand, matched to today's session" }
        return "Your \(what) from \(run.sourceApp ?? "Apple Health"), matched to today's session"
    }
}

/// The sessions whose after-run check-in was saved on this device, so "How did it feel?" is not offered a second time.
/// Kept in `UserDefaults`; only the most recent ids, since the offer is for today's and last week's sessions.
struct CheckInMemory {
    static let key = "checkin.answeredSessions"
    static let limit = 200
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var answered: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func add(_ sessionId: String) {
        var list = defaults.stringArray(forKey: Self.key) ?? []
        guard !list.contains(sessionId) else { return }
        list.append(sessionId)
        defaults.set(Array(list.suffix(Self.limit)), forKey: Self.key)
    }
}
