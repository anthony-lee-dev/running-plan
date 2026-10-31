import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// "I'd rather build my own plan": an empty plan the user fills from the Plan tab (design §5: blank plans are not
/// adaptive and have no engine).
struct BlankPlanTests {
    private let id = "44444444-4444-4444-8444-444444444444"

    @Test func itStartsOnThisWeeksMondayAndIsEmpty() {
        let body = BlankPlan.body(goal: nil, today: "2026-10-28", weeks: 6, id: id)
        #expect(body.value2.id == id)
        #expect(body.value2.sessions.isEmpty)
        #expect(body.value1.startDate == "2026-10-26")
        #expect(body.value1.weekCount == 6)
        #expect(body.value1.source == .blank)
        #expect(body.value1.engine == nil)
        #expect(body.value1.adaptive == false)
        #expect(body.value1.goal._type == Components.Schemas.Goal._typePayload.none)
        #expect(BlankPlan.body(goal: nil, today: "2026-10-26", weeks: 6, id: id).value1.startDate == "2026-10-26")
        #expect(BlankPlan.body(goal: nil, today: "2026-11-01", weeks: 6, id: id).value1.startDate == "2026-10-26")
    }

    @Test func aGoalAndItsDateComeFromTheInterview() {
        let goal = InterviewAnswers.Goal(distance: .tenK, date: "2026-12-13", targetTimeSec: 3300)
        let body = BlankPlan.body(goal: goal, today: "2026-10-28", weeks: BlankPlan.suggestedWeeks(goal: goal, today: "2026-10-28"), id: id)
        let expected = Components.Schemas.Goal(_type: ._10k, date: "2026-12-13", targetTimeSec: 3300)
        #expect(body.value1.goal == expected)
        #expect(body.value1.weekCount == 7, "Mon Oct 26 to Sun Dec 13")
    }

    @Test func theSuggestedLengthIsEightWeeksWithoutADateAndStaysInRange() {
        #expect(BlankPlan.suggestedWeeks(goal: nil, today: "2026-10-28") == 8)
        #expect(BlankPlan.suggestedWeeks(goal: .init(distance: .fiveK, date: "2026-10-20"), today: "2026-10-28") == 8)
        #expect(BlankPlan.suggestedWeeks(goal: .init(distance: .fiveK, date: "2029-01-01"), today: "2026-10-28") == 52)
        #expect(BlankPlan.body(goal: nil, today: "2026-10-28", weeks: 99, id: id).value1.weekCount == 52)
    }
}
