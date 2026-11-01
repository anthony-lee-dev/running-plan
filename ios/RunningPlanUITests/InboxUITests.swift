import XCTest

/// Slices 7 and 8: a run added by hand lands in the import inbox, is matched to a session, and the check-in shows plan
/// vs actual. Health itself needs a real device (a manual gate), so the tests use the manual fallback.
final class InboxUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// From Next: adds a 5 km run in 32 minutes by hand and confirms it to today's session, or picks one when nothing
    /// fits today. The check-in screen then opens.
    @MainActor
    private func addAndConfirmARun(_ app: XCUIApplication) {
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

        let confirm = app.buttons["inbox.confirm"]
        let match = app.buttons["inbox.match"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10) || match.exists, app.debugDescription)
        if confirm.exists {
            confirm.tap()
        } else {
            match.tap()
            let pick = app.buttons["inbox.pick"].firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 5), "No session to match: \(app.debugDescription)")
            pick.tap()
        }
        XCTAssertTrue(app.staticTexts["screen.checkin"].waitForExistence(timeout: 10), "The check-in follows the match: \(app.debugDescription)")
    }

    @MainActor
    func testARunAddedByHandIsConfirmedToASession() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        addAndConfirmARun(app)
        // The UI-test server lives for the whole run, so counts are compared before and after.
        let checkInsBefore = try await LocalAPI.requestCount(api, "POST /v1/sessions/*")
        app.buttons["checkin.skip"].tap()

        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["inbox.undo"].exists, "The confirmed match offers Undo")
        let uploads = try await LocalAPI.requestCount(api, "POST /v1/activities:batch")
        XCTAssertGreaterThanOrEqual(uploads, 1, "The run went to the API")
        let matches = try await LocalAPI.requestCount(api, "PUT /v1/sessions/*")
        XCTAssertGreaterThanOrEqual(matches, 1, "The match went to the API")
        let checkIns = try await LocalAPI.requestCount(api, "POST /v1/sessions/*")
        XCTAssertEqual(checkIns, checkInsBefore, "Skip for now sends no check-in")
    }

    /// Slice 8's Done when: check in after a matched session and see plan vs actual.
    @MainActor
    func testACheckInAfterAMatchShowsPlanVsActualAndIsSaved() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        addAndConfirmARun(app)
        let time = app.otherElements["checkin.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(time.label.hasSuffix("32 minutes"), time.label)
        XCTAssertTrue(app.staticTexts["Plan vs actual"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["checkin.guidance"].exists, "Pain guidance always shows")

        let checkInsBefore = try await LocalAPI.requestCount(api, "POST /v1/sessions/*")
        let save = app.buttons["checkin.save"]
        XCTAssertFalse(save.isEnabled, "Save waits for an answer")
        app.buttons.matching(identifier: "checkin.feel").matching(NSPredicate(format: "label == 'About right'")).firstMatch.tap()
        app.buttons["checkin.pain.no"].tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["inbox.empty"].waitForExistence(timeout: 10), "Saving returns to the inbox: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["inbox.undo"].exists, "A saved check-in takes away Undo")
        let checkIns = try await LocalAPI.requestCount(api, "POST /v1/sessions/*")
        XCTAssertEqual(checkIns, checkInsBefore + 1, "The check-in went to the API")
    }

    /// Issue #105: a matched run can be unmatched, then matched again, from the all-imported-runs list.
    @MainActor
    func testAMatchedRunIsUnmatchedAndRematchedFromTheRunsList() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        addAndConfirmARun(app)
        app.buttons["checkin.skip"].tap()
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
