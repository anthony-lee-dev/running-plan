import XCTest

/// Slice 7: a run added by hand lands in the import inbox and is matched to a session. Health itself needs a real
/// device (a manual gate), so the test uses the manual fallback.
final class InboxUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARunAddedByHandIsConfirmedToASession() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        app.buttons["next.inbox"].tap()
        XCTAssertTrue(app.staticTexts["screen.inbox"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), "Nothing is waiting yet: \(app.debugDescription)")

        app.buttons["inbox.manual"].tap()
        let distance = app.textFields["manual.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5), app.debugDescription)
        distance.tap()
        distance.typeText("5")
        let minutes = app.textFields["manual.minutes"]
        minutes.tap()
        minutes.typeText("32")
        app.buttons["manual.save"].tap()

        // Today's session (a likely match), or a way to pick one when nothing fits today.
        let confirm = app.buttons["inbox.confirm"]
        let match = app.buttons["inbox.match"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10) || match.exists, app.debugDescription)
        if confirm.exists {
            confirm.tap()
        } else {
            match.tap()
            let pick = app.buttons["inbox.pick"].firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 5), "No session within a week to match: \(app.debugDescription)")
            pick.tap()
        }

        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["inbox.undo"].exists, "The confirmed match offers Undo")
        let uploads = try await LocalAPI.requestCount(api, "POST /v1/activities:batch")
        XCTAssertGreaterThanOrEqual(uploads, 1, "The run went to the API")
        let matches = try await LocalAPI.requestCount(api, "PUT /v1/sessions/*")
        XCTAssertGreaterThanOrEqual(matches, 1, "The match went to the API")
    }

    /// Issue #105: a matched run can be unmatched, then matched again, from the all-imported-runs list.
    @MainActor
    func testAMatchedRunIsUnmatchedAndRematchedFromTheRunsList() async throws {
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
        minutes.typeText("32")
        app.buttons["manual.save"].tap()

        let confirm = app.buttons["inbox.confirm"]
        let match = app.buttons["inbox.match"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10) || match.exists, app.debugDescription)
        if confirm.exists {
            confirm.tap()
        } else {
            match.tap()
            let pick = app.buttons["inbox.pick"].firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 5), app.debugDescription)
            pick.tap()
        }
        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["inbox.allRuns"].tap()
        XCTAssertTrue(app.staticTexts["screen.runs"].waitForExistence(timeout: 5), app.debugDescription)
        let status = app.staticTexts["runs.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(status.label.hasPrefix("Matched to"), status.label)

        app.buttons["runs.unmatch"].firstMatch.tap()
        let rematch = app.buttons["runs.match"].firstMatch
        XCTAssertTrue(rematch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["runs.status"].firstMatch.label, "In your inbox")

        rematch.tap()
        let pick = app.buttons["inbox.pick"].firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), app.debugDescription)
        pick.tap()
        XCTAssertTrue(app.buttons["runs.unmatch"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        let unmatched = try await LocalAPI.requestCount(api, "DELETE /v1/sessions/*")
        XCTAssertGreaterThanOrEqual(unmatched, 1, "The unmatch went to the API")
        let matches = try await LocalAPI.requestCount(api, "PUT /v1/sessions/*")
        XCTAssertGreaterThanOrEqual(matches, 2, "Both matches went to the API")
    }
}
