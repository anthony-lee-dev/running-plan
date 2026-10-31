import XCTest

/// Slice 6: a run's spec sheet offers Add to Apple Watch, and the control to keep upcoming sessions on the watch. The
/// buttons are not tapped: the preview and the permission prompt are system UI that the simulator cannot answer.
final class WatchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARunSessionOffersAddToAppleWatch() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        app.buttons["Plan"].firstMatch.tap()
        let rows = app.buttons.matching(identifier: "week.session")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // The generated plan starts on the real today, so look through the week for a run (a rest day or strength has none).
        var found = false
        for index in 0..<min(rows.count, 7) where !found {
            rows.element(boundBy: index).tap()
            XCTAssertTrue(app.staticTexts["session.title"].waitForExistence(timeout: 5), app.debugDescription)
            found = app.buttons["session.addToWatch"].exists
            if found {
                XCTAssertTrue(app.buttons["session.watchSync"].exists, "A run offers to keep upcoming sessions on the watch")
                XCTAssertTrue(app.buttons["session.copy"].exists, "Copy steps stays beside it")
            }
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to'")).firstMatch.tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        }
        XCTAssertTrue(found, "No session this week offered Add to Apple Watch")
    }
}
