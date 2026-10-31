import XCTest

/// Interim delete-plan action (until Goal and settings): delete the saved plan, see "Set a goal" on Plan and Next, and
/// the plan stays gone after a relaunch because the server deleted it.
final class DeletePlanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDeletingThePlanReturnsToSetAGoal() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)
        let deletesBefore = try await LocalAPI.requestCount(api, "DELETE /v1/plans/*")

        app.buttons["Plan"].firstMatch.tap()
        let delete = app.buttons["plan.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()

        let confirm = app.buttons["Yes, delete it"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()

        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 10), app.debugDescription)
        let deletesAfter = try await LocalAPI.requestCount(api, "DELETE /v1/plans/*")
        XCTAssertEqual(deletesAfter, deletesBefore + 1)

        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 5), app.debugDescription)

        // Relaunch signed in: the server no longer has the plan.
        app.terminate()
        let again = LocalAPI.app(api, signedOut: false)
        again.launch()
        XCTAssertTrue(again.buttons["Set a goal"].waitForExistence(timeout: 15), again.debugDescription)
    }
}
