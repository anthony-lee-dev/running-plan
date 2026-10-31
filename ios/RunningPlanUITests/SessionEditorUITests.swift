import XCTest

/// Slice 4 "Done when": edit a session, relaunch the app, and the change is still there (it went straight to the API).
final class SessionEditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAnEditedSessionKeepsItsChangeAfterARelaunch() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)
        let editsBefore = try await LocalAPI.requestCount(api, "PATCH /v1/sessions/*")

        // The plan starts on the real today, so open whichever session comes first on the Plan tab's week.
        app.buttons["Plan"].firstMatch.tap()
        let firstSession = app.buttons.matching(identifier: "week.session").firstMatch
        XCTAssertTrue(firstSession.waitForExistence(timeout: 5), app.debugDescription)
        firstSession.tap()

        XCTAssertTrue(app.staticTexts["session.title"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["session.edit"].tap()

        let title = app.textFields["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        title.tap()
        let old = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "My own run")
        app.buttons["editor.save"].tap()

        let sheetTitle = app.staticTexts["session.title"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(sheetTitle.label, "My own run")
        let editsAfter = try await LocalAPI.requestCount(api, "PATCH /v1/sessions/*")
        XCTAssertEqual(editsAfter, editsBefore + 1, "The edit should have gone to the local API once")

        // Relaunch signed in (no -auth.reset): the plan comes back from the server with the edit.
        app.terminate()
        let again = LocalAPI.app(api, signedOut: false)
        again.launch()
        XCTAssertTrue(again.staticTexts["next.plan"].waitForExistence(timeout: 15), again.debugDescription)
        again.buttons["Plan"].firstMatch.tap()
        let edited = again.buttons.matching(NSPredicate(format: "identifier == 'week.session' AND label CONTAINS 'My own run'")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "The edit did not survive a relaunch: \(again.debugDescription)")
    }
}
