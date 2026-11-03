import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct ProgressModelTests {
    @Test func theBoardsNumbers() throws {
        let model = try ProgressFixture.model()
        #expect(model.headline == "Three steady weeks in. You've been showing up, and it's adding up.")
        #expect(model.goal.title == "Goal: 10K in 55:00")
        #expect(model.goal.countdown == "46 days")
        #expect(model.goal.detail == "to race day, Sunday Dec 13")
        #expect(model.goal.badge == .onTrack)
        #expect(model.goal.note == "You've done 23 of the 25 sessions due so far. Keep it steady.")
        #expect(model.sessions == ProgressModel.Tile(value: "92%", label: "Sessions done", detail: "23 of 25"))
        #expect(model.keyRuns == ProgressModel.Tile(value: "5 of 6", label: "Key runs", detail: "Long and intervals"))
        #expect(model.strength == ProgressModel.Tile(value: "5 of 6", label: "Strength", detail: "Counted apart"))
    }

    @Test func barsRunThroughThisWeekWithThisWeekStandingOut() throws {
        let bars = try ProgressFixture.model().bars
        #expect(bars.map(\.label) == ["W1", "W2", "W3", "W4"])
        #expect(bars.map(\.plannedKm) == [16, 18, 21, 25])
        let ran: [Double?] = [15.3, 18.5, 20, 5]
        #expect(bars.map(\.ranKm) == ran)
        #expect(bars.map(\.isCurrent) == [false, false, false, true])
    }

    @Test func theChartShowsAtMostTheLastEightWeeks() throws {
        // Ten weeks at the end of the plan would not fit 390 points; the most recent eight do.
        let model = try ProgressFixture.model(progress: try ProgressFixture.progress(asOf: "2026-12-20"))
        #expect(model.bars.map(\.label) == (3...10).map { "W\($0)" })
        #expect(!model.bars.contains { $0.isCurrent })
    }

    @Test func beforeTheFirstFinishedWeekOnlyPlannedBarsShow() throws {
        let progress = try ProgressFixture.progress(asOf: "2026-10-07", adherence: .init(due: 2, done: 1, skipped: 0, missed: 0), key: (0, 0), strength: (1, 1),
                                                     goal: #"{"date":"2026-12-13","daysToGo":67,"onTrack":"unknown"}"#, ran: [5] + Array(repeating: 0, count: 9))
        let model = try ProgressFixture.model(progress: progress)
        #expect(model.bars.map(\.label) == ["W1"])
        #expect(model.bars.map(\.ranKm) == [nil])
        #expect(model.firstWeekNote == "Your first week's progress appears on your review day.")
        #expect(model.headline == "Your first week is under way.")
        #expect(model.goal.badge == nil)
        #expect(model.goal.note == "A few more sessions and we can say how it's going.")
        #expect(model.keyRuns.value == "0 of 0")
        #expect(model.keyRuns.detail == "None due yet")
        #expect(model.win == nil)
        #expect(try ProgressFixture.model().firstWeekNote == nil)
    }

    @Test func aPlanThatHasNotStarted() throws {
        let progress = try ProgressFixture.progress(asOf: "2026-10-01", adherence: .init(due: 0, done: 0, skipped: 0, missed: 0), key: (0, 0), strength: (0, 0),
                                                     goal: #"{"date":"2026-12-13","daysToGo":73,"onTrack":"unknown"}"#, ran: Array(repeating: 0, count: 10))
        let model = try ProgressFixture.model(progress: progress)
        #expect(model.headline == "Your plan starts Monday, Oct 5.")
        #expect(model.sessions.value == "0%")
        #expect(model.sessions.detail == "None due yet")
        #expect(model.bars.map(\.label) == ["W1"])
        #expect(model.firstWeekNote != nil)
    }

    @Test func behindSaysSoKindly() throws {
        let progress = try ProgressFixture.progress(adherence: .init(due: 25, done: 15, skipped: 4, missed: 6),
                                                     goal: #"{"date":"2026-12-13","daysToGo":46,"onTrack":"behind"}"#)
        let model = try ProgressFixture.model(progress: progress)
        #expect(model.goal.badge == .behind)
        #expect(model.goal.note == "You've done 15 of the 25 sessions due so far. Missed a few? That's fine: pick up with the next one.")
        #expect(model.headline == "Three weeks in. Every session you do counts, so pick up with the next one.")
        #expect(model.sessions.value == "60%")
    }

    @Test func sessionsStillToDoTodayDoNotMakeTheHeadlineSayBehind() throws {
        // Two of today's sessions are due but not missed yet: 6 of 8 judged is steady, though 6 of 10 due is not.
        let progress = try ProgressFixture.progress(adherence: .init(due: 10, done: 6, skipped: 1, missed: 1))
        #expect(try ProgressFixture.model(progress: progress).headline == "Three steady weeks in. You've been showing up, and it's adding up.")
    }

    @Test func thePercentNeverRoundsUpToAll() throws {
        let progress = try ProgressFixture.progress(adherence: .init(due: 200, done: 199, skipped: 0, missed: 1))
        #expect(try ProgressFixture.model(progress: progress).sessions.value == "99%")
    }

    @Test func raceDayAndARaceAlreadyRun() throws {
        let today = try ProgressFixture.model(progress: try ProgressFixture.progress(asOf: "2026-12-13", goal: #"{"date":"2026-12-13","daysToGo":0,"onTrack":"on_track"}"#))
        #expect(today.goal.countdown == "Race day")
        #expect(today.goal.detail == "Today, Sunday Dec 13")
        let one = try ProgressFixture.model(progress: try ProgressFixture.progress(asOf: "2026-12-12", goal: #"{"date":"2026-12-13","daysToGo":1,"onTrack":"on_track"}"#))
        #expect(one.goal.countdown == "1 day")
        let past = try ProgressFixture.model(progress: try ProgressFixture.progress(asOf: "2026-12-20", goal: #"{"date":"2026-12-13","onTrack":"on_track"}"#))
        #expect(past.goal.countdown == "Race done")
        #expect(past.goal.detail == "Race day was Sunday Dec 13")
        #expect(past.headline == "Plan finished. Look back at how far you've come.")
    }

    @Test func withoutARaceDateTheCountdownIsToThePlansEnd() throws {
        let progress = try ProgressFixture.progress(goal: #"{"onTrack":"unknown"}"#)
        let model = try ProgressFixture.model(goal: #"{"type":"none"}"#, progress: progress)
        #expect(model.goal.title == "Your plan")
        #expect(model.goal.countdown == "46 days")
        #expect(model.goal.detail == "to the end of your plan, Sunday Dec 13")
        #expect(model.goal.badge == nil)
        // Enough sessions to judge, but no race to judge them against: just the count.
        #expect(model.goal.note == "You've done 23 of the 25 sessions due so far.")
        let ended = try ProgressFixture.model(goal: #"{"type":"none"}"#, progress: try ProgressFixture.progress(asOf: "2026-12-20", goal: #"{"onTrack":"unknown"}"#))
        #expect(ended.goal.countdown == "Plan done")
        #expect(ended.goal.detail == "Your plan ended Sunday Dec 13")
    }

    @Test func aWinIsTheBiggestWeekWhenItIsTheLatestFinishedOne() throws {
        #expect(try ProgressFixture.model().win == "Week 3 was your biggest week yet: 20 km run.")
        let dip = try ProgressFixture.progress(ran: [15.3, 18.5, 12, 5, 0, 0, 0, 0, 0, 0])
        #expect(try ProgressFixture.model(progress: dip).win == nil)
    }

    @Test func voiceOverReadsTheChartAsSentences() throws {
        let spoken = try ProgressFixture.model().chartSpoken
        #expect(spoken == "Running volume in kilometres per week. Week 1: 16 planned, 15.3 run. Week 2: 18 planned, 18.5 run. Week 3: 21 planned, 20 run. Week 4, this week: 25 planned, 5 run.")
    }
}
