import XCTest

/// Slice 9's Done when: a UI test opens a due review and accepts a proposal, and the plan changes.
///
/// The plan starts in the previous month, so a week has finished and its review is due (the default review day is the
/// week's last day, and a review stays due for a week). The key sessions of the finished weeks were never run, so the
/// engine proposes dropping them; accepting one makes the server change the plan.
final class ReviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A plan that started on the 15th of the previous month (14 to 46 days back, always in the past and always a real
    /// day), so a week has finished.
    private func lastMonth15th() -> Date {
        var parts = Calendar.current.dateComponents([.year, .month], from: Date())
        parts.month! -= 1
        parts.day = 15
        return Calendar.current.date(from: parts)!
    }

    @MainActor
    func testADueReviewOpensAndAcceptingAProposalChangesThePlan() async throws {
        let api = try LocalAPI.url()
        let app = try await LocalAPI.signedInApp(api, startingOn: lastMonth15th())

        let card = app.buttons["next.review"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Next offers the due review: \(app.debugDescription)")
        card.tap()

        XCTAssertTrue(app.staticTexts["screen.review"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "review.tile").count, 2, "The week at a glance")
        let accept = app.buttons["proposal.accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "A key session nobody ran gives a proposal: \(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["proposal.card"].firstMatch.exists)

        let acceptsBefore = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        accept.tap()

        XCTAssertTrue(app.descendants(matching: .any)["proposal.applied"].firstMatch.waitForExistence(timeout: 10), "The accepted proposal shows as Applied: \(app.debugDescription)")
        let accepts = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        XCTAssertEqual(accepts, acceptsBefore + 1, "The accept went to the API, which changed the plan")
        XCTAssertFalse(app.staticTexts["review.error"].exists)
        XCTAssertFalse(app.staticTexts["proposal.error"].exists)

        // Closing the review returns to Next, which still offers it (it is still due).
        app.buttons["review.back"].tap()
        XCTAssertTrue(app.staticTexts["next.plan"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testADismissedProposalIsRemovedAndTheReviewStaysAvailable() async throws {
        let api = try LocalAPI.url()
        let app = try await LocalAPI.signedInApp(api, startingOn: lastMonth15th())

        let card = app.buttons["next.review"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        card.tap()
        let dismiss = app.buttons["proposal.dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), app.debugDescription)
        let count = app.buttons.matching(identifier: "proposal.dismiss").count

        let before = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        dismiss.tap()

        let deadline = Date().addingTimeInterval(10)
        while app.buttons.matching(identifier: "proposal.dismiss").count >= count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertLessThan(app.buttons.matching(identifier: "proposal.dismiss").count, count, "The card is gone")
        let dismissed = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        XCTAssertEqual(dismissed, before + 1)
        XCTAssertTrue(app.staticTexts["screen.review"].exists)
    }
}
