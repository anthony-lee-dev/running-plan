import XCTest

/// The Progress tab: signed out it offers "Set a goal"; with a saved plan it shows the server's progress, which for a
/// plan saved today is the first week (planned bars only, and when the first week's progress appears).
final class ProgressUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSignedOutOffersSetAGoal() throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.app(api, signedOut: true)
        app.launch()
        XCTAssertTrue(app.staticTexts["screen.next"].waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["Progress"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["screen.progress"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Set a goal"].exists, app.debugDescription)
    }

    @MainActor
    func testASavedPlanShowsItsProgress() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        app.buttons["Progress"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["screen.progress"].waitForExistence(timeout: 5), app.debugDescription)
        // These come only from a successful getProgress.
        let sessions = app.descendants(matching: .any)["progress.sessions"].firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["progress.chart"].firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["progress.firstWeek"].exists, app.debugDescription)
    }

    /// A run added by hand today shows in "Your running" for this week (issue #137), without being matched to a session.
    @MainActor
    func testARunAddedByHandAppearsInYourRunning() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        app.buttons["next.inbox"].tap()
        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["inbox.manual"].tap()
        let distance = app.textFields["manual.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5), app.debugDescription)
        distance.tap()
        distance.typeText("5")
        let minutes = app.textFields["manual.minutes"]
        minutes.tap()
        minutes.typeText("30")
        app.buttons["manual.save"].tap()
        XCTAssertTrue(app.buttons["inbox.confirm"].waitForExistence(timeout: 10) || app.buttons["inbox.match"].exists, app.debugDescription)
        app.buttons["Back to Next"].tap()

        app.buttons["Progress"].firstMatch.tap()
        let card = app.descendants(matching: .any)["progress.running"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        let distance5 = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '5 km'")).firstMatch
        XCTAssertTrue(distance5.waitForExistence(timeout: 10), app.debugDescription)
        let pace = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '6:00/km'")).firstMatch
        XCTAssertTrue(pace.exists, app.debugDescription)
        app.buttons["Month"].tap()
        XCTAssertTrue(app.staticTexts["This month"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
