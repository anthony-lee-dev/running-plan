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
        let edited = GoalModel.edited(goal, date: "2027-01-10", targetSeconds: 1500)
        #expect(edited == Components.Schemas.Goal(_type: .custom, label: "Parkrun PB", date: "2027-01-10", targetTimeSec: 1500))
    }

    @Test func clearingTheDateAndTimeLeavesThemOut() throws {
        let edited = GoalModel.edited(try ProfileFixture.goal(PlanFixture.goal), date: nil, targetSeconds: nil)
        #expect(edited == Components.Schemas.Goal(_type: ._10k))
    }

    @Test func aTargetTimeStaysInsideWhatTheAPIAccepts() throws {
        let goal = try ProfileFixture.goal(PlanFixture.goal)
        #expect(GoalModel.edited(goal, date: nil, targetSeconds: 0).targetTimeSec == 60)
        #expect(GoalModel.edited(goal, date: nil, targetSeconds: 500_000).targetTimeSec == 86_400)
    }

    @Test func aDateOnlyEditKeepsTheTimesSeconds() {
        // The editor shows whole minutes (55); leaving them alone must not turn 55:30 into 55:00.
        #expect(GoalModel.targetSeconds(original: 3330, minutes: 55) == 3330)
        #expect(GoalModel.targetSeconds(original: 3330, minutes: 56) == 3360)
        #expect(GoalModel.targetSeconds(original: nil, minutes: 50) == 3000)
    }

    // MARK: The stored interview

    private func interview(_ json: String) throws -> Components.Schemas.InterviewAnswers {
        try APIConfiguration.decoder.decode(Components.Schemas.InterviewAnswers.self, from: Data(json.utf8))
    }

    @Test func theAnswersThePlanWasMadeFromAreKeptSoTheRerunDoesNotResetThem() throws {
        let stored = try interview(#"{"goal":{"distance":"10k","date":"2026-12-13"},"weeklyDistanceM":30000,"longestRunM":12000,"runningHistory":"1_to_3_years","runsPerWeek":4,"pain":true,"strength":{"enabled":true,"equipment":"dumbbells"},"recentResult":{"distanceM":5000,"timeSec":1500}}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(PlanFixture.goal), interview: stored, profile: nil, today: today))
        #expect(answers.weeklyDistanceM == 30000)
        #expect(answers.longestRunM == 12000)
        #expect(answers.runningHistory == .oneToThreeYears)
        #expect(answers.runsPerWeek == 4)
        #expect(answers.pain == true)
        #expect(answers.strength == .init(enabled: true, equipment: "dumbbells"))
        #expect(answers.recentResult == .init(distanceM: 5000, timeSec: 1500))
    }

    @Test func thePlansGoalAsItIsNowWinsOverTheStoredOne() throws {
        let stored = try interview(#"{"goal":{"distance":"5k","date":"2026-11-30","targetTimeSec":1500}}"#)
        let goal = try ProfileFixture.goal(#"{"type":"10k","date":"2027-01-10"}"#)
        let answers = try #require(GoalModel.answers(goal: goal, interview: stored, profile: nil, today: today))
        #expect(answers.goal == .init(distance: .tenK, date: "2027-01-10", targetTimeSec: nil))
    }

    @Test func theProfileWinsOverTheStoredDaysAndTheLongRunDayMustNotBeADayOff() throws {
        let stored = try interview(#"{"goal":{"distance":"10k"},"unavailableDays":["mon"],"longRunDay":"sat"}"#)
        let profile = try ProfileFixture.profile(#""scheduling":{"unavailableDays":["sat","sun"]}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"10k"}"#), interview: stored, profile: profile, today: today))
        #expect(answers.unavailableDays == [.sat, .sun])
        #expect(answers.longRunDay == nil)
    }

    @Test func aCustomGoalWithStoredAnswersStillStartsFromThem() throws {
        let stored = try interview(#"{"goal":{"distance":"half_marathon"},"runsPerWeek":3}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"custom","label":"x"}"#), interview: stored, profile: nil, today: today))
        #expect(answers.goal.distance == .halfMarathon)
        #expect(answers.runsPerWeek == 3)
    }

    // MARK: Re-running the interview

    @Test func theInterviewStartsFromTheGoalAndTheProfile() throws {
        let profile = try ProfileFixture.profile(
            #""heartRate":{"maxBpm":188},"scheduling":{"longRunDay":"sun","unavailableDays":["mon","fri"]}"#, targetDisplay: "heart_rate"
        )
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(PlanFixture.goal), interview: nil, profile:profile, today: today))
        var expected = InterviewAnswers()
        expected.goal = .init(distance: .tenK, date: "2026-12-13", targetTimeSec: 3300)
        expected.targetDisplay = .heartRate
        expected.heartRate = .init(maxBpm: 188)
        expected.unavailableDays = [.mon, .fri]
        expected.longRunDay = .sun
        #expect(answers == expected)
    }

    @Test func withoutAProfileOnlyTheGoalIsFilledIn() throws {
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"5k"}"#), interview: nil, profile:nil, today: today))
        var expected = InterviewAnswers()
        expected.goal.distance = .fiveK
        #expect(answers == expected)
    }

    @Test func aCustomOrNoGoalStartsTheInterviewFresh() throws {
        #expect(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"custom","label":"x"}"#), interview: nil, profile:nil, today: today) == nil)
        #expect(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"none"}"#), interview: nil, profile:nil, today: today) == nil)
    }

    @Test func aPastDateIsLeftOut() throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","date":"2026-10-01","targetTimeSec":3300}"#)
        let answers = try #require(GoalModel.answers(goal: goal, interview: nil, profile:nil, today: today))
        #expect(answers.goal.date == nil)
        #expect(answers.goal.targetTimeSec == 3300)
    }

    @Test(arguments: [60, 599, 21_601, 86_400])
    func aGoalTimeTheInterviewRefusesIsLeftOut(seconds: Int) throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","targetTimeSec":\#(seconds)}"#)
        #expect(try #require(GoalModel.answers(goal: goal, interview: nil, profile:nil, today: today)).goal.targetTimeSec == nil)
    }

    @Test(arguments: [600, 21_600])
    func theEdgesOfTheInterviewsTimeRangeAreKept(seconds: Int) throws {
        let goal = try ProfileFixture.goal(#"{"type":"10k","targetTimeSec":\#(seconds)}"#)
        #expect(try #require(GoalModel.answers(goal: goal, interview: nil, profile:nil, today: today)).goal.targetTimeSec == seconds)
    }

    @Test func moreUnavailableDaysThanTheInterviewAllowsAreLeftOut() throws {
        let profile = try ProfileFixture.profile(#""scheduling":{"unavailableDays":["mon","tue","wed","thu","fri"]}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"10k"}"#), interview: nil, profile:profile, today: today))
        #expect(answers.unavailableDays == nil)
    }

    @Test func aLongRunDayThatIsAlsoUnavailableIsLeftOut() throws {
        let profile = try ProfileFixture.profile(#""scheduling":{"longRunDay":"sun","unavailableDays":["sun"]}"#)
        let answers = try #require(GoalModel.answers(goal: try ProfileFixture.goal(#"{"type":"10k"}"#), interview: nil, profile:profile, today: today))
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
