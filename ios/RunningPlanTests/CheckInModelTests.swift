import APIClient
import Foundation
import Testing
@testable import RunningPlan

/// DK-CheckIn: plan vs actual for a confirmed match, and the after-session answers.
struct CheckInModelTests {
    static func session(on date: String) throws -> Components.Schemas.SessionContent {
        try #require(try PlanFixture.detail().value2.sessions.first { $0.value2.date == date }).value2
    }

    /// The board's case: Monday's easy 5 km (6:25–7:10/km), run as 5.1 km in 33:14.
    static func board() throws -> CheckInModel {
        CheckInModel(session: try session(on: "2026-10-26"), activity: try activityFixture(id: "a1", date: "2026-10-26").value1)
    }

    @Test func theBoardsEasyRunShowsPlanVsActual() throws {
        let m = try Self.board()
        #expect(m.eyebrow == "MATCHED · EASY RUN")
        #expect(m.headline == "Nice work, that's a solid one")
        #expect(m.summary == "You ran a little over plan and kept the pace easy, right where it should be.")

        let distance = try #require(m.distance)
        #expect(distance.planned == "5.0 planned")
        #expect(distance.actual == "5.1 km")
        #expect(distance.fill == 1)

        #expect(m.time.planned == "~34 min planned")
        #expect(m.time.actual == "33:14")
        let fill = try #require(m.time.fill)
        #expect(fill > 0.97 && fill < 0.99)

        let pace = try #require(m.pace)
        #expect(pace.planned == "6:25–7:10 target")
        #expect(pace.actual == "6:31/km")
        #expect(pace.verdict == "In your easy range")
        #expect(pace.inRange == true)
        let band = try #require(pace.band)
        #expect(abs(band.lowerBound - 1.0 / 3) < 0.001 && abs(band.upperBound - 2.0 / 3) < 0.001)
        let marker = try #require(pace.marker)
        #expect(marker > band.lowerBound && marker < band.upperBound)
    }

    @Test func spokenLabelsReadPacesInWords() throws {
        let m = try Self.board()
        #expect(m.distance?.spoken == "Distance: 5.0 kilometres planned, 5.1 kilometres run")
        #expect(m.time.spoken == "Time: about 34 minutes planned, 33 minutes 14 seconds")
        #expect(m.pace?.spoken == "Pace: 6 minutes 25 to 7 minutes 10 per kilometre target, 6 minutes 31 per kilometre. In your easy range")
    }

    @Test func aFastEasyRunSaysSoKindly() throws {
        // 5 km in 28:20 is 5:40/km, well under the 6:25 end of the range.
        let m = CheckInModel(session: try Self.session(on: "2026-10-26"), activity: try activityFixture(id: "a1", date: "2026-10-26", durationSec: 1700, distanceM: 5000).value1)
        #expect(m.headline == "Nice work, a little quick")
        #expect(m.pace?.verdict == "Faster than your easy range")
        #expect(m.pace?.inRange == false)
        #expect(m.pace?.marker == 0)
    }

    @Test func aShortRunStillCounts() throws {
        let m = CheckInModel(session: try Self.session(on: "2026-10-26"), activity: try activityFixture(id: "a1", date: "2026-10-26", durationSec: 1200, distanceM: 3000).value1)
        #expect(m.headline == "Done, and it all counts")
        #expect(m.distance?.fill == 0.6)
    }

    @Test func intervalsCompareTheAverageNotTheRepPace() throws {
        // A run's average includes the warm-up and the jogs, so it is never judged against the fast-rep target.
        let m = CheckInModel(session: try Self.session(on: "2026-10-28"), activity: try activityFixture(id: "a1", date: "2026-10-28", durationSec: 2600, distanceM: 6900).value1)
        #expect(m.eyebrow == "MATCHED · INTERVALS")
        let pace = try #require(m.pace)
        #expect(pace.verdict == nil)
        #expect(pace.band == nil)
        #expect(pace.marker == nil)
        #expect(pace.planned.hasSuffix("planned average"))
        #expect(pace.actual == "6:17/km")
        #expect(m.headline == "Nice work, that's a solid one")
    }

    @Test func strengthShowsTimeOnly() throws {
        let m = CheckInModel(session: try Self.session(on: "2026-10-27"), activity: try activityFixture(id: "a1", date: "2026-10-27", type: "strength", durationSec: 1260, distanceM: nil).value1)
        #expect(m.eyebrow == "MATCHED · STRENGTH")
        #expect(m.distance == nil)
        #expect(m.pace == nil)
        #expect(m.time.actual == "21:00")
        #expect(m.time.planned == "~20 min planned")
    }

    @Test func aTimedCrossTrainingSessionIsNotEstimated() throws {
        let m = CheckInModel(session: try Self.session(on: "2026-11-01"), activity: try activityFixture(id: "a1", date: "2026-11-01", type: "cycling", durationSec: 2700, distanceM: 15000).value1)
        #expect(m.time.planned == "45 min planned")
        #expect(m.time.fill == 1)
        #expect(m.distance == nil)
        #expect(m.pace == nil)
    }

    @Test func aRunWithNoDistanceHasNoDistanceOrPaceRow() throws {
        let m = CheckInModel(session: try Self.session(on: "2026-10-26"), activity: try activityFixture(id: "a1", date: "2026-10-26", durationSec: 1994, distanceM: nil).value1)
        #expect(m.distance == nil)
        #expect(m.pace == nil)
        #expect(m.time.actual == "33:14")
    }

    @Test func theFeelingsReachTheServersProposalRules() {
        // api/src/domain/proposals.ts: "much harder" is effort 8 or more; "easy" is feel 4 or more and effort 4 or less.
        #expect(AfterFeeling.harder.effortFelt >= 8)
        #expect(AfterFeeling.easier.feel >= 4 && AfterFeeling.easier.effortFelt <= 4)
        #expect(AfterFeeling.aboutRight.feel == 3 && (5...7).contains(AfterFeeling.aboutRight.effortFelt))
        let titles = AfterFeeling.allCases.map(\.title)
        let expected = ["Easier than I expected", "About right", "Harder than I expected"]
        #expect(titles == expected)
    }

    @Test func painGuidanceShowsWithOrWithoutPain() {
        #expect(CheckInModel.painGuidance(pain: false).text == CheckInModel.guidance)
        #expect(CheckInModel.painGuidance(pain: false).isNotice == false)
        #expect(CheckInModel.painGuidance(pain: true).text == CheckInModel.guidance)
        #expect(CheckInModel.painGuidance(pain: true).isNotice == true)
    }
}
