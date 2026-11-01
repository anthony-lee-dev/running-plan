import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// An imported activity as the API lists it.
func activityFixture(
    id: String, date: String, type: String = "running", durationSec: Int = 1994, distanceM: Int? = 5100,
    heartRate: Int? = 148, source: String = "Apple Watch", matchedSession: String? = nil
) throws -> Components.Schemas.Activity {
    let distance = distanceM.map { #""distanceM":\#($0),"# } ?? ""
    let hr = heartRate.map { #""avgHeartRate":\#($0),"# } ?? ""
    let match = matchedSession.map { #","match":{"sessionId":"\#($0)","activityId":"\#(id)","status":"suggested","updatedAt":"2026-10-28T07:42:00.000Z"}"# } ?? ""
    let json = #"{"id":"\#(id)","source":"apple_health","externalId":"hk-\#(id)","sourceApp":"\#(source)","workoutType":"\#(type)","startedAt":"\#(date)T06:30:00.000Z","localDate":"\#(date)",\#(distance)\#(hr)"durationSec":\#(durationSec),"importedAt":"2026-10-28T07:42:00.000Z","disposition":"inbox"\#(match)}"#
    return try APIConfiguration.decoder.decode(Components.Schemas.Activity.self, from: Data(json.utf8))
}

struct LocalDayTests {
    @Test func aWorkoutBelongsToTheDayItStartedOnInItsOwnZone() {
        // Monday 05:53 UTC is still Sunday evening (22:53) in Vancouver.
        let start = Date(timeIntervalSince1970: 1_792_994_000) // 2026-10-26 05:53:20 UTC
        let vancouver = TimeZone(identifier: "America/Vancouver")!
        let utc = TimeZone(identifier: "UTC")!
        #expect(LocalDay.string(from: start, in: utc) == "2026-10-26")
        #expect(LocalDay.string(from: start, in: vancouver) == "2026-10-25")
    }

    @Test func nearMidnightStaysOnTheStartDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 59))!
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 0, minute: 1))!
        #expect(LocalDay.string(from: late, in: calendar.timeZone) == "2026-10-27")
        #expect(LocalDay.string(from: early, in: calendar.timeZone) == "2026-10-28")
    }

    @Test func headingNamesTheWeekday() {
        #expect(LocalDay.heading("2026-10-26") == "Mon, Oct 26")
    }
}

struct InboxModelTests {
    private let monday = "00000000-0000-4000-8000-000000000000"
    private var plan: Components.Schemas.PlanDetail { get throws { try PlanFixture.detail() } }

    /// The fixture's week 4 sessions with Monday's easy run open again, so it can be matched.
    private func sessions(openingMonday: Bool = true) throws -> [Components.Schemas.Session] {
        var all = try plan.value2.sessions
        if openingMonday, let index = all.firstIndex(where: { $0.value2.date == "2026-10-26" && $0.value2._type == .easy }) {
            all[index].value2.status = .planned
        }
        return all
    }

    private func model(_ activities: [Components.Schemas.Activity], suggestions: [String: String] = [:], today: String = "2026-10-28") throws -> InboxModel {
        InboxModel(activities: activities, sessions: try sessions(), suggestions: suggestions, today: today)
    }

    @Test func aRunOnAPlannedDayIsALikelyMatch() throws {
        let card = try model([activityFixture(id: "a1", date: "2026-10-26", durationSec: 1990)]).cards[0]
        guard case .likelyMatch(_, let label) = card.kind else { Issue.record("expected a likely match, got \(card.kind)"); return }
        #expect(label == "Easy run · 5 km")
        #expect(card.heading == "Mon, Oct 26 · Apple Watch")
        #expect(card.headline == "5.1 km · 33:10")
        #expect(card.detail == "6:30/km average · 148 bpm")
    }

    @Test func aPlanThatHasNotStartedHasNoMissedSessionsAndNothingIsMarkedMissed() throws {
        // Today (Sep 20) is before the plan's first day: every open session is ahead, none missed.
        let m = try model([activityFixture(id: "a1", date: "2026-09-20", durationSec: 1800)], today: "2026-09-20")
        #expect(m.missedCount == 0)
        let choices = m.choices(for: "a1")
        #expect(!choices.isEmpty)
        #expect(!choices.contains { $0.when.contains("missed") })
    }

    @Test func aRunOnADayWithNothingPlannedIsAnExtraRun() throws {
        // Sunday Oct 25 is the last day of week 3, whose sessions are done.
        let card = try model([activityFixture(id: "a1", date: "2026-10-25", durationSec: 1325, distanceM: 3200, heartRate: nil)]).cards[0]
        #expect(card.kind == .extraRun)
        #expect(card.headline == "3.2 km · 22:05")
        #expect(card.detail == "6:54/km average")
    }

    @Test func aRunOnARestDayIsAnExtraRun() throws {
        let rest = try sessions() + [PlanFixtureRest.thursday]
        let model = InboxModel(activities: [try activityFixture(id: "a1", date: "2026-10-29")], sessions: rest, today: "2026-10-30")
        #expect(model.cards[0].kind == .extraRun)
    }

    @Test func strengthMatchesOnlyAStrengthSession() throws {
        let strengthDay = try model([activityFixture(id: "a1", date: "2026-10-27", type: "strength", durationSec: 1200, distanceM: nil, heartRate: nil)]).cards[0]
        // Tuesday's strength is done in the fixture, so nothing is left to match.
        #expect(strengthDay.kind == .otherWorkout)
        let onRunDay = try model([activityFixture(id: "a2", date: "2026-10-26", type: "strength", durationSec: 1200, distanceM: nil, heartRate: nil)]).cards[0]
        #expect(onRunDay.kind == .otherWorkout)
        #expect(onRunDay.detail == "Strength")
    }

    @Test func otherWorkoutsMatchACustomSession() throws {
        // Sunday Oct 1 + ... the fixture's cycling is Sun Nov 1 (a user session of type custom).
        let card = try model([activityFixture(id: "a1", date: "2026-11-01", type: "cycling", durationSec: 2700, distanceM: 20000, heartRate: nil)], today: "2026-11-01").cards[0]
        guard case .likelyMatch(_, let label) = card.kind else { Issue.record("expected a match, got \(card.kind)"); return }
        #expect(label == "Cycling")
    }

    @Test func twoRunsOnOneDayBothOfferTheSessionUntilOneIsConfirmed() throws {
        let first = try activityFixture(id: "a1", date: "2026-10-26")
        let second = try activityFixture(id: "a2", date: "2026-10-26", durationSec: 900, distanceM: 2000, heartRate: nil)
        let session = try #require(try sessions().first { $0.value2.date == "2026-10-26" && $0.value2._type == .easy }).value1.id
        // The server suggested the session to the first run; it is not offered to the second as well.
        let both = try model([first, second], suggestions: ["a1": session])
        #expect(both.cards[0].kind == .likelyMatch(sessionId: session, label: "Easy run · 5 km"))
        #expect(both.cards[1].kind == .extraRun)
        // Either can still be matched by hand to the same day's session.
        #expect(both.choices(for: "a2").map(\.id).contains(session))
    }

    @Test func aServerMatchWinsOverTheDateGuess() throws {
        let friday = try #require(try sessions().first { $0.value2.date == "2026-10-30" }).value1.id
        let card = try model([activityFixture(id: "a1", date: "2026-10-26", matchedSession: friday)]).cards[0]
        #expect(card.kind == .likelyMatch(sessionId: friday, label: "Easy run · 5 km"))
    }

    @Test func aSuggestionForADoneSessionIsIgnored() throws {
        let done = try #require(try sessions(openingMonday: false).first { $0.value2.date == "2026-10-26" }).value1.id
        let model = InboxModel(activities: [try activityFixture(id: "a1", date: "2026-10-26")], sessions: try sessions(openingMonday: false), suggestions: ["a1": done], today: "2026-10-28")
        #expect(model.cards[0].kind == .extraRun)
    }

    @Test func missedSessionsAreCountedAndOfferedInThePicker() throws {
        // Wed Oct 28 is today; Monday's easy run (opened) is a missed session, and the picker names it so.
        let model = try model([activityFixture(id: "a1", date: "2026-10-28")])
        #expect(model.missedCount == 1)
        let choices = model.choices(for: "a1")
        #expect(choices.first?.when.contains("Wed, Oct 28") == true)
        #expect(choices.contains { $0.when == "Mon, Oct 26 · missed" })
        // Only run sessions within a week, nearest first.
        #expect(choices.allSatisfy { !$0.title.hasPrefix("Strength") })
    }

    @Test func aRunFarFromEveryOpenSessionCanStillBeMatched() throws {
        // Issue #98: a plan rebuilt after the run's day. Nothing is within a week, but the run must be matchable.
        let model = try model([activityFixture(id: "a1", date: "2026-09-01")])
        #expect(model.cards[0].kind == .extraRun)
        let choices = model.choices(for: "a1")
        #expect(choices.contains { $0.when == "Mon, Oct 26 · missed" })
        #expect(choices.allSatisfy { !$0.title.hasPrefix("Strength") })
        // Nearest first.
        let sorted = choices.map(\.when)
        #expect(sorted.first?.hasPrefix("Mon, Oct 26") == true)
    }

    @Test func aWorkoutWithNoFittingSessionAnywhereSaysWhy() throws {
        let withSessions = try model([activityFixture(id: "a1", date: "2026-10-28")])
        #expect(withSessions.emptyChoicesNote(for: "a1") == nil)
        let none = InboxModel(activities: [try activityFixture(id: "a1", date: "2026-10-28")], sessions: [], today: "2026-10-28")
        #expect(none.choices(for: "a1").isEmpty)
        #expect(none.emptyChoicesNote(for: "a1") == "Your plan has no open session of this type left to match it to.")
    }

    @Test func subtitleCountsTheWorkouts() throws {
        let two = try model([activityFixture(id: "a1", date: "2026-10-26"), activityFixture(id: "a2", date: "2026-10-25")])
        #expect(two.subtitle.hasPrefix("2 workouts waiting"))
    }

    @Test func longDurationsShowHours() {
        #expect(InboxModel.duration(3912) == "1:05:12")
        #expect(InboxModel.duration(1994) == "33:14")
    }
}

private enum PlanFixtureRest {
    static var thursday: Components.Schemas.Session {
        let json = PlanFixture.json(extra: [PlanFixture.restThursday])
        let plan = try! APIConfiguration.decoder.decode(Components.Schemas.PlanDetail.self, from: json)
        return plan.value2.sessions.first { $0.value2._type == .rest }!
    }
}
