import APIClient
import Foundation
@testable import RunningPlan

/// A `GET /v1/plans/{id}/reviews/2` reply shaped like DK-Review for `PlanFixture`'s plan (week 3, Oct 19 to 25): 5 of 6
/// sessions done, 20.1 of 21 km, 1 of 2 key runs, two workouts in the inbox, and one pending proposal that eases
/// Saturday's long run from 8 km to 7 km.
enum ReviewFixture {
    static let longRunID = "00000000-0000-4000-8000-000000000019"
    static let proposalID = "11111111-1111-4111-8111-aaaaaaaaaaaa"
    static let otherProposalID = "11111111-1111-4111-8111-bbbbbbbbbbbb"
    static let tempoID = "00000000-0000-4000-8000-000000000008"

    private static let pace = #"{"type":"pace","range":{"minSecPerKm":385,"maxSecPerKm":430}}"#

    /// A session's content as the proposal engine writes it: one work step of `metres` (or a 45 minute custom session).
    static func content(date: String = "2026-10-31", type: String = "long", title: String = "Long run", metres: Int = 8000, owner: String = "system", key: Bool = true) -> String {
        if type == "custom" {
            return #"{"date":"\#(date)","type":"custom","title":"\#(title)","status":"planned","owner":"\#(owner)","custom":{"activityLabel":"cycling","goal":{"type":"time","value":2700},"effort":"easy"}}"#
        }
        return #"{"date":"\#(date)","type":"\#(type)","title":"\#(title)","key":\#(key),"status":"planned","owner":"\#(owner)","steps":[{"kind":"work","goal":{"type":"distance","value":\#(metres)},"target":\#(pace)}]}"#
    }

    static func change(
        _ op: String = "update", id: String = longRunID, date: String = "2026-10-31", type: String = "long", title: String = "Long run",
        before: Int? = 8000, after: Int? = 7000, afterType: String? = nil, afterTitle: String? = nil, userOwned: Bool = false
    ) -> String {
        var parts = [#""op":"\#(op)""#, #""sessionId":"\#(id)""#]
        if let before { parts.append(#""before":\#(content(date: date, type: type, title: title, metres: before, owner: userOwned ? "user" : "system"))"#) }
        if let after { parts.append(#""after":\#(content(date: date, type: afterType ?? type, title: afterTitle ?? title, metres: after, owner: userOwned ? "user" : "system"))"#) }
        parts.append(#""userOwned":\#(userOwned)"#)
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func proposalJSON(
        id: String = proposalID, base: Int = 3, kind: String = "adjustment", urgent: Bool = false, status: String = "pending",
        reason: String = "Your last two long runs felt harder than planned. A slightly shorter one lets you finish feeling strong.",
        changes: [String]? = nil, planChanges: String? = nil
    ) -> String {
        let changes = changes ?? [change()]
        let plan = planChanges.map { #","planChanges":\#($0)"# } ?? ""
        return #"""
        {"id":"\#(id)","planId":"\#(PlanFixture.planID)","baseContentRevision":\#(base),"kind":"\#(kind)","creator":{"type":"rules","version":"0.1.0"},
         "reason":"\#(reason)","urgent":\#(urgent),"changes":[\#(changes.joined(separator: ","))]\#(plan),"status":"\#(status)",
         "createdAt":"2026-10-26T07:00:00.000Z","updatedAt":"2026-10-26T07:00:00.000Z","deletedAt":null,"resolvedAt":null}
        """#
    }

    static func proposal(
        id: String = proposalID, base: Int = 3, kind: String = "adjustment", urgent: Bool = false, status: String = "pending",
        reason: String = "Your last two long runs felt harder than planned. A slightly shorter one lets you finish feeling strong.",
        changes: [String]? = nil, planChanges: String? = nil
    ) throws -> Components.Schemas.Proposal {
        let json = proposalJSON(id: id, base: base, kind: kind, urgent: urgent, status: status, reason: reason, changes: changes, planChanges: planChanges)
        return try APIConfiguration.decoder.decode(Components.Schemas.Proposal.self, from: Data(json.utf8))
    }

    static func reviewJSON(
        week: Int = 2, start: String = "2026-10-19", end: String = "2026-10-25", due: Bool = true,
        sessions: (planned: Int, done: Int, skipped: Int, missed: Int) = (6, 5, 0, 1), distance: (planned: Int, actual: Int) = (21000, 20100),
        keys: [(id: String, title: String, outcome: String)] = [(longRunID, "Long run", "hit"), (tempoID, "Tempo run", "missed")],
        checkIns: String = #"{"count":2,"averageFeel":2.5,"averageEffortFelt":8,"painFlags":0}"#, proposals: [String]? = nil, inbox: Int = 2
    ) -> String {
        let proposals = proposals ?? [proposalJSON()]
        let keyRows = keys.map { #"{"sessionId":"\#($0.id)","title":"\#($0.title)","outcome":"\#($0.outcome)"}"# }.joined(separator: ",")
        return #"""
        {"planId":"\#(PlanFixture.planID)","weekIndex":\#(week),"startDate":"\#(start)","endDate":"\#(end)","due":\#(due),
         "summary":{"sessions":{"planned":\#(sessions.planned),"done":\#(sessions.done),"skipped":\#(sessions.skipped),"missed":\#(sessions.missed)},
          "distance":{"plannedM":\#(distance.planned),"actualM":\#(distance.actual)},"time":{"plannedSec":7800,"actualSec":7500},
          "keySessions":[\#(keyRows)],"checkIns":\#(checkIns)},
         "proposals":[\#(proposals.joined(separator: ","))],"looseEnds":{"inboxActivities":\#(inbox)}}
        """#
    }

    static func review(
        week: Int = 2, start: String = "2026-10-19", end: String = "2026-10-25", due: Bool = true,
        sessions: (planned: Int, done: Int, skipped: Int, missed: Int) = (6, 5, 0, 1), distance: (planned: Int, actual: Int) = (21000, 20100),
        keys: [(id: String, title: String, outcome: String)] = [(longRunID, "Long run", "hit"), (tempoID, "Tempo run", "missed")],
        checkIns: String = #"{"count":2,"averageFeel":2.5,"averageEffortFelt":8,"painFlags":0}"#, proposals: [String]? = nil, inbox: Int = 2
    ) throws -> Components.Schemas.WeeklyReview {
        let json = reviewJSON(week: week, start: start, end: end, due: due, sessions: sessions, distance: distance, keys: keys, checkIns: checkIns, proposals: proposals, inbox: inbox)
        return try APIConfiguration.decoder.decode(Components.Schemas.WeeklyReview.self, from: Data(json.utf8))
    }
}
