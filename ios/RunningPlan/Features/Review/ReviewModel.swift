import APIClient
import Foundation

/// What DK-Review shows above the proposals, from the server's `WeeklyReview`: the header, the "week at a glance" tiles,
/// the key runs, a line from the check-ins and the inbox card. Pure and unit-tested.
///
/// The board's "A steady week, Anthony" and its per-run notes ("Felt harder than planned") need a name and per-session
/// feel, which the API does not return, so the headline drops the name and the notes are the run's outcome.
struct ReviewModel: Equatable {
    typealias Review = Components.Schemas.WeeklyReview

    enum Outcome: Equatable {
        case hit, missed, skipped, upcoming
    }

    struct Tile: Equatable {
        let value: String
        let label: String
    }

    struct KeyRun: Equatable, Identifiable {
        let id: String
        let title: String
        let outcome: Outcome
        let note: String
    }

    let weekIndex: Int
    let due: Bool
    let eyebrow: String
    let headline: String
    let summary: String
    let tiles: [Tile]
    let keyRuns: [KeyRun]
    /// "2 check-ins: they felt harder than planned", or nil with none.
    let checkInLine: String?
    /// Nil when nothing waits in the import inbox.
    let inboxTitle: String?
    let inboxDetail: String
    let nextCardTitle: String

    init(review: Review) {
        weekIndex = review.weekIndex
        due = review.due
        let sessions = review.summary.sessions
        eyebrow = "WEEK \(review.weekIndex + 1) REVIEW · \(Self.range(review.startDate, review.endDate))"
        (headline, summary) = Self.words(sessions.planned, sessions.done, sessions.missed)
        tiles = Self.tiles(review)
        keyRuns = review.summary.keySessions.map { key in
            let outcome: Outcome = switch key.outcome {
            case .hit: .hit
            case .missed: .missed
            case .skipped: .skipped
            case .upcoming: .upcoming
            }
            return KeyRun(id: key.sessionId, title: key.title ?? "Key run", outcome: outcome, note: Self.note(outcome))
        }
        checkInLine = Self.checkInLine(review.summary.checkIns)
        let waiting = review.looseEnds.inboxActivities
        inboxTitle = waiting > 0 ? "\(waiting) workout\(waiting == 1 ? "" : "s") still in your inbox" : nil
        inboxDetail = "Confirm them so this summary is complete"
        let count = review.proposals.count
        nextCardTitle = review.due ? "Your week \(review.weekIndex + 1) review is ready" : count == 1 ? "A suggestion is waiting" : "\(count) suggestions are waiting"
    }

    // MARK: Words

    /// The headline and the sentence under it, from how much of the week's plan was done.
    private static func words(_ planned: Int, _ done: Int, _ missed: Int) -> (String, String) {
        guard planned > 0 else { return ("A rest week", "Nothing was planned for this week.") }
        guard done > 0 else { return ("A quiet week", "Nothing is logged for this week yet.") }
        let share = Double(done) / Double(planned)
        let (headline, lead) = done >= planned ? ("A full week", "You did everything on the plan.")
            : share >= 0.7 ? ("A steady week", "You did nearly everything.")
            : ("A lighter week", "You did part of the plan, and that still counts.")
        guard missed > 0 else { return (headline, lead) }
        return (headline, lead + (missed == 1 ? " One missed session is nothing to make up." : " Missed sessions are nothing to make up."))
    }

    private static func tiles(_ review: Review) -> [Tile] {
        let sessions = review.summary.sessions
        let distance = review.summary.distance
        let keys = review.summary.keySessions
        var tiles = [Tile(value: "\(sessions.done) of \(sessions.planned)", label: "Sessions done")]
        let ran = PlanPreview.kilometres(Double(distance.actualM) / 1000)
        tiles.append(distance.plannedM > 0 ? Tile(value: ran, label: "of \(PlanPreview.kilometres(Double(distance.plannedM) / 1000)) km") : Tile(value: ran, label: "km run"))
        if !keys.isEmpty {
            tiles.append(Tile(value: "\(keys.filter { $0.outcome == .hit }.count) of \(keys.count)", label: "Key runs"))
        }
        return tiles
    }

    private static func note(_ outcome: Outcome) -> String {
        switch outcome {
        case .hit: "Done"
        case .missed: "Missed, no make-up"
        case .skipped: "Skipped"
        case .upcoming: "Coming up"
        }
    }

    /// Perceived effort is 4, 6 or 8 for Easier, About right, Harder (`CheckInModel`), so the average sorts them.
    private static func checkInLine(_ checkIns: Review.summaryPayload.checkInsPayload) -> String? {
        guard checkIns.count > 0 else { return nil }
        let noun = checkIns.count == 1 ? "check-in" : "check-ins"
        var parts: [String] = []
        if let effort = checkIns.averageEffortFelt {
            let plural = checkIns.count != 1
            let how = effort >= 7 ? "harder than planned" : effort <= 5 ? "easier than planned" : "about right"
            parts.append("\(plural ? "they" : "it") felt \(how)")
        }
        switch checkIns.painFlags {
        case 0: break
        case 1: parts.append("you flagged pain once")
        default: parts.append("you flagged pain \(checkIns.painFlags) times")
        }
        return parts.isEmpty ? "\(checkIns.count) \(noun)" : "\(checkIns.count) \(noun): " + parts.joined(separator: "; ")
    }

    /// "OCT 19–25", or "OCT 26–NOV 1" across a month end.
    private static func range(_ start: String, _ end: String) -> String {
        guard let first = ProposalCardModel.monthDay(start), let last = ProposalCardModel.monthDay(end) else { return "\(start)–\(end)" }
        let tail = first.month == last.month ? "\(last.day)" : "\(last.month.uppercased()) \(last.day)"
        return "\(first.month.uppercased()) \(first.day)–\(tail)"
    }
}
