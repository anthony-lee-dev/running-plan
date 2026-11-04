import XCTest

/// A run's session page has no per-session "Add to Apple Watch" or sync button any more (issue #112): Copy and Share stay,
/// and a run shows one watch status line with a "Watch settings" link when the device can schedule workouts. The
/// permission prompt is system UI that the simulator cannot answer, so nothing here turns sync on.
final class WatchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARunSessionHasCopyAndNoPerSessionWatchButtons() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        app.buttons["Plan"].firstMatch.tap()
        let rows = app.buttons.matching(identifier: "week.session")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        var copyShown = false
        for index in 0..<min(rows.count, 7) where !copyShown {
            rows.element(boundBy: index).tap()
            XCTAssertTrue(app.staticTexts["session.title"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["session.addToWatch"].exists, "The per-session button is gone")
            XCTAssertFalse(app.buttons["session.watchSync"].exists, "The per-session sync link is gone")
            if app.buttons["session.copy"].exists { copyShown = true }
            // A status line comes with its link (only on a device that can schedule workouts).
            if app.staticTexts["session.watchStatus"].exists {
                XCTAssertTrue(app.buttons["session.watchSettings"].exists, "The status line has a Watch settings link")
                app.buttons["session.watchSettings"].tap()
                XCTAssertTrue(app.switches["watch.settings.toggle"].waitForExistence(timeout: 5), app.debugDescription)
                app.buttons["Done"].tap()
                XCTAssertTrue(app.switches["watch.settings.toggle"].waitForNonExistence(timeout: 5), "The sheet closes")
            }
            let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to'")).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            back.tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        }
        XCTAssertTrue(copyShown, "Copy steps stays on the sessions that have a spec sheet")
    }
}
