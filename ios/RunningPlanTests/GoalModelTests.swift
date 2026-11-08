import APIClient
import Foundation
import Testing
@testable import RunningPlan

enum ProfileFixture {
    /// `extra` is extra profile JSON members, for example `"scheduling":{"longRunDay":"sun"}`.
    static func profile(_ extra: String = "", targetDisplay: String = "pace", review: String = #"{"frequency":"weekly_plus_urgent"}"#, revision: Int = 1) throws -> Components.Schemas.Profile {
        var members = [
            #""targetDisplay":"\#(targetDisplay)""#, #""paces":{"source":"none"}"#, #""review":\#(review)"#,
            #""revision":\#(revision)"#, #""updatedAt":"2026-10-28T07:42:00.000Z""#,
        ]
        if !extra.contains("\"heartRate\"") { members.append(#""heartRate":{}"#) }
        if !extra.contains("\"scheduling\"") { members.append(#""scheduling":{}"#) }
        if !extra.isEmpty { members.append(extra) }
        return try APIConfiguration.decoder.decode(Components.Schemas.Profile.self, from: Data(("{" + members.joined(separator: ",") + "}").utf8))
    }

    static func goal(_ json: String) throws -> Components.Schemas.Goal {
        try APIConfiguration.decoder.decode(Components.Schemas.Goal.self, from: Data(json.utf8))
    }
}

struct GoalModelTests {
    private let today = "2026-10-28"

    @Test func theGoalCardNamesTheGoalAndTheRaceDay() throws {
        let summary = GoalModel.summary(try ProfileFixture.goal(PlanFixture.goal))
        #expect(summary.title == "10K in 55:00")
        #expect(summary.detail == "Race day Sunday, Dec 13")
    }

    @Test func aGoalWithoutADateSaysSo() throws {
        let summary = GoalModel.summary(try ProfileFixture.goal(#"{"type":"half_marathon"}"#))
        #expect(summary.title == "Half marathon")
        #expect(summary.detail == "No race date")
    }

    @Test func theReviewLineShowsFrequencyAndDayOrJustOff() {
        #expect(GoalModel.reviewLine(ReviewSetting(frequency: .weekly_plus_urgent, day: nil, revision: 1)) == "Weekly plus urgent · Last day of the week")
        #expect(GoalModel.reviewLine(ReviewSetting(frequency: .weekly, day: .sun, revision: 1)) == "Weekly · Sunday")
        #expect(GoalModel.reviewLine(ReviewSetting(frequency: .off, day: .sun, revision: 1)) == "Off")
    }

    // MARK: Editing the goal

    @Test func editingKeepsTheTypeAndLabelAndConvertsMinutes() throws {
        let goal = try ProfileFixture.goal(#"{"type":"custom","label":"Parkrun PB","date":"2026-12-13"}"#)
        let edited = GoalModel.edited(goal, date: "2027-01-10", targetMinutes: 25)
        #expect(edited == Components.Schemas.Goal(_type: .custom, label: "Parkrun PB", date: "2027-01-10", targetTimeSec: 1500))
    }

    @Test func clearingTheDateAndTimeLeavesThemOut() throws {
        let edited = GoalModel.edited(try ProfileFixture.goal(PlanFixture.goal), date: nil, targetMinutes: nil)
        #expect(edited == Components.Schemas.Goal(_type: ._10k))
    }

    @Test func aTargetTimeStaysInsideWhatTheAPIAccepts() throws {
        let goal = try ProfileFixture.goal(PlanFixture.goal)
        #expect(GoalModel.edited(goal, date: nil, targetMinutes: 0).targetTimeSec == 60)
        #expect(GoalModel.edited(goal, date: nil, targetMinutes: 5000).targetTimeSec == 86_400)
    }

    // MARK: Re-running the interview

    @Test func theInterviewStartsFromTheGoalAndTheProfile() throws {
        let profile = try ProfileFixture.profile(
            #""heartRate":{"maxBpm":188},"scheduling":{"longRunDay":"sun","unavailableDays":["mon","fri"]}"#, targetDisplay: "heart_rate"
        )
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(PlanFixture.goal), profile: profile, today: today))
        var expected = InterviewAnswers()
        expected.goal = .init(distance: .tenK, date: "2026-12-13", targetTimeSec: 3300)
        expected.targetDisplay = .heartRate
        expected.heartRate = .init(maxBpm: 188)
        expected.unavailableDays = [.mon, .fri]
        expected.longRunDay = .sun
        #expect(answers == expected)
    }

    @Test func withoutAProfileOnlyTheGoalIsFilledIn() throws {
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"5k"}"#), profile: nil, today: today))
        var expected = InterviewAnswers()
        expected.goal.distance = .fiveK
        #expect(answers == expected)
    }

    @Test func aCustomOrNoGoalStartsTheInterviewFresh() throws {
        #expect(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"custom","label":"x"}"#), profile: nil, today: today) == nil)
        #expect(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"none"}"#), profile: nil, today: today) == nil)
    }

    @Test func aPastDateIsLeftOut() throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","date":"2026-10-01","targetTimeSec":3300}"#)
        let answers = try #require(GoalModel.answers(goal: goal, profile: nil, today: today))
        #expect(answers.goal.date == nil)
        #expect(answers.goal.targetTimeSec == 3300)
    }

    @Test(arguments: [60, 599, 21_601, 86_400])
    func aGoalTimeTheInterviewRefusesIsLeftOut(seconds: Int) throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","targetTimeSec":\#(seconds)}"#)
        #expect(try #require(GoalModel.answers(goal: goal, profile: nil, today: today)).goal.targetTimeSec == nil)
    }

    @Test(arguments: [600, 21_600])
    func theEdgesOfTheInterviewsTimeRangeAreKept(seconds: Int) throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","targetTimeSec":\#(seconds)}"#)
        #expect(try #require(GoalModel.answers(goal: goal, profile: nil, today: today)).goal.targetTimeSec == seconds)
    }

    @Test func moreUnavailableDaysThanTheInterviewAllowsAreLeftOut() throws {
        let profile = try ProfileFixture.profile(#""scheduling":{"unavailableDays":["mon","tue","wed","thu","fri"]}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"10k"}"#), profile: profile, today: today))
        #expect(answers.unavailableDays == nil)
    }

    @Test func aLongRunDayThatIsAlsoUnavailableIsLeftOut() throws {
        let profile = try ProfileFixture.profile(#""scheduling":{"longRunDay":"sun","unavailableDays":["sun"]}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"10k"}"#), profile: profile, today: today))
        #expect(answers.unavailableDays == [.sun])
        #expect(answers.longRunDay == nil)
    }

    @Test func theAnswersCrossToTheAPITypeAndKeepTheirValues() throws {
        var answers = InterviewAnswers()
        answers.goal = .init(distance: .halfMarathon, date: "2027-03-07", targetTimeSec: 6300)
        answers.runsPerWeek = 4
        let api = try GoalModel.apiAnswers(answers)
        #expect(api.goal.date == "2027-03-07")
        #expect(api.goal.targetTimeSec == 6300)
        #expect(api.runsPerWeek == 4)
    }
}
