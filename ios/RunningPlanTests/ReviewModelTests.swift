import APIClient
import Testing
@testable import RunningPlan

/// DK-Review's text, from a review shaped like the board (week 3, Oct 19 to 25).
struct ReviewModelTests {
    @Test func theBoardsHeaderAndTiles() throws {
        let model = ReviewModel(review: try ReviewFixture.review())

        #expect(model.eyebrow == "WEEK 3 REVIEW · OCT 19–25")
        #expect(model.headline == "A steady week")
        #expect(model.summary == "You did nearly everything. One missed session is nothing to make up.")
        let tiles = model.tiles.map { [$0.value, $0.label] }
        let expected = [["5 of 6", "Sessions done"], ["20.1", "of 21 km"], ["1 of 2", "Key runs"]]
        #expect(tiles == expected)
    }

    @Test func keyRunsShowTheirOutcomeInWords() throws {
        let model = ReviewModel(review: try ReviewFixture.review(keys: [
            (ReviewFixture.longRunID, "Long run", "hit"), (ReviewFixture.tempoID, "Tempo run", "missed"),
            ("a", "Intervals", "skipped"), ("b", "Long run", "upcoming"),
        ]))

        let rows = model.keyRuns.map { [$0.title, $0.note] }
        let expected = [["Long run", "Done"], ["Tempo run", "Missed, no make-up"], ["Intervals", "Skipped"], ["Long run", "Coming up"]]
        #expect(rows == expected)
        let outcomes = model.keyRuns.map(\.outcome)
        let expectedOutcomes: [ReviewModel.Outcome] = [.hit, .missed, .skipped, .upcoming]
        #expect(outcomes == expectedOutcomes)
    }

    @Test func aWeekSpanningTwoMonthsNamesBoth() throws {
        let model = ReviewModel(review: try ReviewFixture.review(week: 3, start: "2026-10-26", end: "2026-11-01"))
        #expect(model.eyebrow == "WEEK 4 REVIEW · OCT 26–NOV 1")
    }

    @Test func aFullWeekAndALightOne() throws {
        let full = ReviewModel(review: try ReviewFixture.review(sessions: (6, 6, 0, 0)))
        #expect(full.headline == "A full week")
        #expect(full.summary == "You did everything on the plan.")

        let light = ReviewModel(review: try ReviewFixture.review(sessions: (6, 3, 1, 2)))
        #expect(light.headline == "A lighter week")
        #expect(light.summary == "You did part of the plan, and that still counts. Missed sessions are nothing to make up.")
    }

    @Test func aWeekWithNothingLoggedOrNothingPlanned() throws {
        let quiet = ReviewModel(review: try ReviewFixture.review(sessions: (6, 0, 0, 0)))
        #expect(quiet.headline == "A quiet week")
        #expect(quiet.summary == "Nothing is logged for this week yet.")

        let rest = ReviewModel(review: try ReviewFixture.review(sessions: (0, 0, 0, 0)))
        #expect(rest.headline == "A rest week")
        #expect(rest.summary == "Nothing was planned for this week.")
    }

    private func line(_ json: String) throws -> String? {
        ReviewModel(review: try ReviewFixture.review(checkIns: json)).checkInLine
    }

    @Test func checkInsAreSummarisedFromTheAverages() throws {
        let harder = try line(#"{"count":2,"averageFeel":2.5,"averageEffortFelt":8,"painFlags":0}"#)
        #expect(harder == "2 check-ins: they felt harder than planned")
        let easier = try line(#"{"count":1,"averageFeel":4,"averageEffortFelt":4,"painFlags":0}"#)
        #expect(easier == "1 check-in: it felt easier than planned")
        let right = try line(#"{"count":3,"averageFeel":3,"averageEffortFelt":6,"painFlags":0}"#)
        #expect(right == "3 check-ins: they felt about right")
    }

    @Test func painIsMentionedPlainly() throws {
        let once = try line(#"{"count":2,"averageFeel":3,"painFlags":1}"#)
        #expect(once == "2 check-ins: you flagged pain once")
        let twice = try line(#"{"count":2,"averageFeel":3,"averageEffortFelt":8,"painFlags":2}"#)
        #expect(twice == "2 check-ins: they felt harder than planned; you flagged pain 2 times")
        let none = try line(#"{"count":0,"painFlags":0}"#)
        #expect(none == nil)
    }

    @Test func theInboxCardCountsWaitingWorkouts() throws {
        let two = ReviewModel(review: try ReviewFixture.review(inbox: 2))
        #expect(two.inboxTitle == "2 workouts still in your inbox")
        #expect(two.inboxDetail == "Confirm them so this summary is complete")
        #expect(ReviewModel(review: try ReviewFixture.review(inbox: 1)).inboxTitle == "1 workout still in your inbox")
        #expect(ReviewModel(review: try ReviewFixture.review(inbox: 0)).inboxTitle == nil)
    }

    @Test func theNextCardSaysWhyTheReviewIsThere() throws {
        #expect(ReviewModel(review: try ReviewFixture.review(due: true)).nextCardTitle == "Your week 3 review is ready")
        let urgent = ReviewModel(review: try ReviewFixture.review(due: false, proposals: [ReviewFixture.proposalJSON(urgent: true)]))
        #expect(urgent.nextCardTitle == "A suggestion is waiting")
        let both = [ReviewFixture.proposalJSON(urgent: true), ReviewFixture.proposalJSON(id: ReviewFixture.otherProposalID, urgent: true)]
        let two = ReviewModel(review: try ReviewFixture.review(due: false, proposals: both))
        #expect(two.nextCardTitle == "2 suggestions are waiting")
    }
}
