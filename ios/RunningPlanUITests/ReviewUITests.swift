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

    /// From the preview: sets the start date to the 15th of the previous month (14 to 46 days back, always in the past
    /// and always a real day) and waits for the plan to be rebuilt. The popup opens on today's month.
    @MainActor
    private func startInThePast(_ app: XCUIApplication, _ api: URL) async throws {
        let before = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month], from: Date())
        parts.month! -= 1
        parts.day = 15
        let target = calendar.date(from: parts)!
        let picker = app.datePickers["preview.startDate"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        picker.buttons.firstMatch.tap()
        app.buttons["Previous Month"].tap()
        let label = DateFormatter()
        label.dateFormat = "EEEE, MMMM d"
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label.string(from: target))).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), app.debugDescription)
        day.tap()

        let deadline = Date().addingTimeInterval(15)
        var after = before
        while after <= before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            after = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")
        }
        XCTAssertGreaterThan(after, before, "Choosing a start date should rebuild the plan")
        let week = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Week 1 ·'")).firstMatch
        XCTAssertTrue(week.waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testADueReviewOpensAndAcceptingAProposalChangesThePlan() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await startInThePast(app, api)
        try await LocalAPI.saveAndSignIn(app, api)

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
        let app = LocalAPI.openPreview(api)
        try await startInThePast(app, api)
        try await LocalAPI.saveAndSignIn(app, api)

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
