import Foundation
import Testing
@testable import RunningPlan

@MainActor
struct InterviewFlowTests {
    private func json(_ answers: InterviewAnswers) throws -> [String: Any] {
        let data = try JSONEncoder().encode(answers)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func startsAtQuestionOneOfTwelve() {
        let flow = InterviewFlow()
        #expect(InterviewQuestion.allCases.count == 12)
        #expect(flow.question == .goalDistance)
        #expect(flow.progressLabel == "Question 1 of 12 · about 2 minutes")
        #expect(abs(flow.progress - 1.0 / 12.0) < 0.001)
        #expect(!flow.canGoBack)
    }

    @Test func continueNeedsAnAnswerButSkipNeverDoes() {
        let flow = InterviewFlow()
        #expect(!flow.canContinue)
        flow.setDistance(.tenK)
        #expect(flow.canContinue)
        flow.skip()
        #expect(flow.question == .goalDateAndTime)
    }

    @Test func forwardAndBackKeepAnswers() {
        let flow = InterviewFlow()
        flow.setDistance(.tenK)
        flow.next()
        #expect(flow.question == .goalDateAndTime)
        flow.back()
        #expect(flow.question == .goalDistance)
        #expect(flow.answers.goal.distance == .tenK)
        flow.back()
        #expect(flow.question == .goalDistance)
    }

    @Test func skippingEverythingGivesTheDefaultGoalOnly() throws {
        let flow = InterviewFlow()
        for _ in InterviewQuestion.allCases { flow.skip() }
        #expect(flow.isFinished)
        let object = try json(flow.answers)
        #expect(Set(object.keys) == ["goal"])
        let goal = try #require(object["goal"] as? [String: Any])
        #expect(goal["distance"] as? String == "5k")
        #expect(goal.count == 1)
    }

    @Test func skippingClearsAnEarlierAnswer() {
        let flow = InterviewFlow()
        flow.setDistance(.halfMarathon)
        flow.skip()
        flow.back()
        flow.skip()
        #expect(flow.answers.goal.distance == .fiveK)
        #expect(!flow.canContinue)
    }

    @Test func answersEncodeToTheSpecShape() throws {
        let flow = InterviewFlow()
        flow.setDistance(.halfMarathon)
        flow.setGoalDate("2027-03-14")
        flow.setGoalTimeMinutes(110)
        flow.setRecentResult(distance: .tenK, minutes: 58)
        flow.setWeeklyKm(25)
        flow.setLongestRunKm(10)
        flow.setHistory(.oneToThreeYears)
        flow.setRunsPerWeek(4)
        flow.toggleUnavailable(.mon)
        flow.toggleUnavailable(.fri)
        flow.setLongRunDay(.sun)
        flow.setPain(false)
        flow.setStrength(.dumbbells)
        flow.setTargetDisplay(.heartRate)
        flow.setMaxHeartRate(188)

        let object = try json(flow.answers)
        let goal = try #require(object["goal"] as? [String: Any])
        #expect(goal["distance"] as? String == "half_marathon")
        #expect(goal["date"] as? String == "2027-03-14")
        #expect(goal["targetTimeSec"] as? Int == 6600)
        let recent = try #require(object["recentResult"] as? [String: Any])
        #expect(recent["distanceM"] as? Int == 10000)
        #expect(recent["timeSec"] as? Int == 3480)
        #expect(object["weeklyDistanceM"] as? Int == 25000)
        #expect(object["longestRunM"] as? Int == 10000)
        #expect(object["runningHistory"] as? String == "1_to_3_years")
        #expect(object["runsPerWeek"] as? Int == 4)
        #expect(object["unavailableDays"] as? [String] == ["mon", "fri"])
        #expect(object["longRunDay"] as? String == "sun")
        #expect(object["pain"] as? Bool == false)
        let strength = try #require(object["strength"] as? [String: Any])
        #expect(strength["enabled"] as? Bool == true)
        #expect(strength["equipment"] as? String == "dumbbells")
        #expect(object["targetDisplay"] as? String == "heart_rate")
        let heartRate = try #require(object["heartRate"] as? [String: Any])
        #expect(heartRate["maxBpm"] as? Int == 188)
    }

    @Test func strengthOffEncodesWithoutEquipment() throws {
        let flow = InterviewFlow()
        flow.setStrength(.none)
        let strength = try #require(try json(flow.answers)["strength"] as? [String: Any])
        #expect(strength["enabled"] as? Bool == false)
        #expect(strength["equipment"] == nil)
    }

    @Test func atMostFourDaysCanBeUnavailable() {
        let flow = InterviewFlow()
        for day in [Weekday.mon, .tue, .wed, .thu, .fri] { flow.toggleUnavailable(day) }
        #expect(flow.answers.unavailableDays == [.mon, .tue, .wed, .thu])
        flow.toggleUnavailable(.tue)
        #expect(flow.answers.unavailableDays == [.mon, .wed, .thu])
    }

    @Test func numbersStayInsideTheSpecRanges() {
        let flow = InterviewFlow()
        flow.setWeeklyKm(900)
        flow.setLongestRunKm(-3)
        flow.setMaxHeartRate(20)
        flow.setGoalTimeMinutes(5)
        #expect(flow.answers.weeklyDistanceM == 200_000)
        #expect(flow.answers.longestRunM == 0)
        #expect(flow.answers.heartRate?.maxBpm == 100)
        #expect(flow.answers.goal.targetTimeSec == 600)
    }

    @Test func finishingAfterTheLastQuestionAndBuildingYourOwnPlan() {
        let flow = InterviewFlow()
        for _ in 0..<11 { flow.skip() }
        #expect(flow.question == .heartRate)
        #expect(!flow.isFinished)
        flow.next()
        #expect(!flow.isFinished)  // nothing answered, so Continue does nothing
        flow.setMaxHeartRate(185)
        flow.next()
        #expect(flow.isFinished)

        let own = InterviewFlow()
        own.buildOwnPlan()
        #expect(own.wantsBlankPlan)
        #expect(own.isFinished)
    }

    @Test func aRecentResultNeedsBothADistanceAndATime() {
        let flow = InterviewFlow()
        for _ in 0..<2 { flow.skip() }
        #expect(flow.question == .recentResult)
        flow.setRecentResult(distance: .tenK)
        #expect(flow.answers.recentResult == nil)
        #expect(!flow.canContinue)
        flow.setRecentResult(minutes: 55)
        #expect(flow.answers.recentResult == .init(distanceM: 10_000, timeSec: 3300))
        #expect(flow.canContinue)
        flow.skip()
        #expect(flow.answers.recentResult == nil)
        #expect(flow.recentDistance == nil && flow.recentMinutes == nil)
    }

    @Test func aGoalDateAloneOrAGoalTimeAloneCountsAsAnswered() {
        let flow = InterviewFlow()
        flow.skip()
        flow.setGoalDate("2027-03-14")
        #expect(flow.canContinue)
        flow.setGoalDate(nil)
        #expect(!flow.canContinue)
        flow.setGoalTimeMinutes(30)
        #expect(flow.canContinue)
    }

    @Test func runsAndUnavailableDaysCannotContradictEachOther() {
        let flow = InterviewFlow()
        flow.setRunsPerWeek(5)
        flow.toggleUnavailable(.mon)
        flow.toggleUnavailable(.tue)
        flow.toggleUnavailable(.wed)  // would leave 4 days for 5 runs
        #expect(flow.answers.unavailableDays == [.mon, .tue])
        flow.toggleUnavailable(.mon)
        flow.toggleUnavailable(.tue)
        flow.toggleUnavailable(.mon)
        flow.toggleUnavailable(.tue)
        flow.toggleUnavailable(.wed)
        flow.toggleUnavailable(.thu)
        #expect(flow.answers.unavailableDays?.count == 2)
        let fresh = InterviewFlow()
        for day in [Weekday.mon, .tue, .wed, .thu] { fresh.toggleUnavailable(day) }
        fresh.setRunsPerWeek(4)  // only 3 days free
        #expect(fresh.answers.runsPerWeek == nil)
        fresh.setRunsPerWeek(3)
        #expect(fresh.answers.runsPerWeek == 3)
    }

    @Test func theLongRunDayCannotBeAnUnavailableDay() {
        let flow = InterviewFlow()
        flow.toggleUnavailable(.sat)
        flow.setLongRunDay(.sat)
        #expect(flow.answers.longRunDay == nil)
        flow.setLongRunDay(.sun)
        flow.toggleUnavailable(.sun)
        #expect(flow.answers.longRunDay == nil)
        #expect(!flow.isAnswered(.longRunDay))
    }
}
