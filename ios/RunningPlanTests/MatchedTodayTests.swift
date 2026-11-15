import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// Issue #186: the "Done today" card on Next.
struct MatchedTodayTests {
    private let today = PlanFixture.today

    /// The board's plan with today's intervals done.
    private func sessions(status: Components.Schemas.SessionContent.statusPayload = .done) throws -> (all: [Components.Schemas.Session], todayId: String) {
        var plan = try PlanFixture.detail()
        let index = try #require(plan.value2.sessions.firstIndex { $0.value2.date == today && $0.value2._type == .intervals })
        plan.value2.sessions[index].value2.status = status
        return (plan.value2.sessions, plan.value2.sessions[index].value1.id)
    }

    @Test func aRunMatchedToTodaysDoneSessionShowsTheCard() throws {
        let (all, id) = try sessions()
        let run = try activityFixture(id: "a1", date: today, durationSec: 2592, distanceM: 6800, matchedSession: id, disposition: "matched")
        let card = try #require(MatchedToday(sessions: all, runs: [run], today: today, answered: []))
        #expect(card.sessionId == id)
        #expect(card.activityId == "a1")
        #expect(card.title == "Intervals: 5 × 600 m")
        #expect(card.detail == "6.8 km · 43:12 · 6:21/km average")
        #expect(card.source == "Your run from Apple Watch, matched to today's session")
    }

    @Test func thereIsNoCardWithoutAMatchedRun() throws {
        let (all, _) = try sessions()
        let waiting = try activityFixture(id: "a1", date: today)
        #expect(MatchedToday(sessions: all, runs: [waiting], today: today, answered: []) == nil)
        #expect(MatchedToday(sessions: all, runs: [], today: today, answered: []) == nil)
    }

    @Test func thereIsNoCardOnceTheCheckInIsSaved() throws {
        let (all, id) = try sessions()
        let run = try activityFixture(id: "a1", date: today, matchedSession: id, disposition: "matched")
        #expect(MatchedToday(sessions: all, runs: [run], today: today, answered: [id]) == nil)
    }

    @Test func thereIsNoCardTheNextDayOrForASessionNotDone() throws {
        let (all, id) = try sessions()
        let run = try activityFixture(id: "a1", date: today, matchedSession: id, disposition: "matched")
        #expect(MatchedToday(sessions: all, runs: [run], today: "2026-10-29", answered: []) == nil)
        let (planned, plannedId) = try sessions(status: .planned)
        let other = try activityFixture(id: "a1", date: today, matchedSession: plannedId, disposition: "matched")
        #expect(MatchedToday(sessions: planned, runs: [other], today: today, answered: []) == nil)
    }

    @Test func aRunAddedByHandSaysSo() throws {
        var run = try activityFixture(id: "a1", date: today).value1
        run.source = .manual
        run.sourceApp = nil
        #expect(MatchedToday.sourceLine(run) == "Your run, added by hand, matched to today's session")
        run.source = .apple_health
        #expect(MatchedToday.sourceLine(run) == "Your run from Apple Health, matched to today's session")
        run.workoutType = .strength
        #expect(MatchedToday.sourceLine(run) == "Your workout from Apple Health, matched to today's session")
    }

    @Test func theMemoryKeepsAnsweredSessionsAndOnlyTheLatest() throws {
        let name = "MatchedTodayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let memory = CheckInMemory(defaults: defaults)
        #expect(memory.answered.isEmpty)
        memory.add("s1")
        memory.add("s1")
        #expect(memory.answered == ["s1"])
        for index in 0..<CheckInMemory.limit { memory.add("more-\(index)") }
        #expect(memory.answered.count == CheckInMemory.limit)
        #expect(!memory.answered.contains("s1"))
    }
    // The session page offers the check-in for a done session with its run, for a week, until it is answered.
    @Test func theSessionPageOffersTheCheckInForAWeek() throws {
        let (all, id) = try sessions()
        let session = try #require(all.first { $0.value1.id == id })
        #expect(MatchedToday.offersCheckIn(session, matched: true, today: today, answered: []))
        #expect(MatchedToday.offersCheckIn(session, matched: true, today: "2026-11-04", answered: []))
        #expect(!MatchedToday.offersCheckIn(session, matched: true, today: "2026-11-05", answered: []))
        #expect(!MatchedToday.offersCheckIn(session, matched: false, today: today, answered: []))
        #expect(!MatchedToday.offersCheckIn(session, matched: true, today: today, answered: [id]))
        let (planned, plannedId) = try sessions(status: .planned)
        let open = try #require(planned.first { $0.value1.id == plannedId })
        #expect(!MatchedToday.offersCheckIn(open, matched: true, today: today, answered: []))
    }
}
