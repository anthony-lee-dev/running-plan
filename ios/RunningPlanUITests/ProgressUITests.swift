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
}
