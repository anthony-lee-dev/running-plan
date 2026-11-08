import XCTest

/// Issue #129: after Sign out, "Sign in" takes the email and code and brings back the account's own plan, with no
/// second plan created. A signed-in account with no plan goes to "Set a goal".
final class SignInAgainUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func signOut(_ app: XCUIApplication) {
        app.buttons["Goal"].firstMatch.tap()
        let signOut = app.buttons["account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        XCTAssertTrue(app.buttons["goal.set"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testSigningInAgainBringsBackTheSamePlanWithoutCreatingAnother() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        let email = try await LocalAPI.saveAndSignIn(app, api)
        let createdBefore = try await LocalAPI.requestCount(api, "POST /v1/plans")
        let planLabel = app.staticTexts["next.plan"].label

        signOut(app)
        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 5), app.debugDescription)

        try await LocalAPI.signInAgain(app, api, email: email)

        XCTAssertTrue(app.staticTexts["next.plan"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["next.plan"].label, planLabel)
        let createdAfter = try await LocalAPI.requestCount(api, "POST /v1/plans")
        XCTAssertEqual(createdAfter, createdBefore, "signing in must not create a plan")
    }

    @MainActor
    func testASignedInAccountWithNoPlanGoesToSetAGoalWithoutSignIn() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        let email = try await LocalAPI.saveAndSignIn(app, api)

        // Delete the plan, sign out, sign in again: the account has no plan.
        app.buttons["Goal"].firstMatch.tap()
        let delete = app.buttons["plan.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.buttons["Yes, delete it"].tap()
        XCTAssertTrue(app.buttons["goal.set"].waitForExistence(timeout: 10), app.debugDescription)
        signOut(app)
        try await LocalAPI.signInAgain(app, api, email: email)

        XCTAssertTrue(app.buttons["goal.set"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["account.signin"].firstMatch.exists, "already signed in")
    }
}
