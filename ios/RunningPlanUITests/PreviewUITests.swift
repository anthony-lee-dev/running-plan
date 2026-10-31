import XCTest

/// Interview to preview (and on to a saved plan) against the local UI-test API (`LocalAPI`).
final class PreviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testInterviewToPreviewUsesTheLocalAPI() async throws {
        let api = try LocalAPI.url()
        let before = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")

        let app = LocalAPI.openPreview(api)
        XCTAssertTrue(app.staticTexts["Your suggested plan"].exists)

        let after = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")
        XCTAssertGreaterThan(after, before, "The preview did not come from the local API")
    }

    @MainActor
    func testSaveSignsInWithAnEmailCodeAndShowsThePlanOnAllThreeScreens() async throws {
        let api = try LocalAPI.url()
        let before = try await LocalAPI.requestCount(api, "POST /v1/plans")
        let loadsBefore = try await LocalAPI.requestCount(api, "GET /v1/plans/*")

        let app = LocalAPI.openPreview(api)
        try await LocalAPI.saveAndSignIn(app, api)

        // Next now shows the saved plan, loaded back from the server.
        XCTAssertFalse(app.buttons["Set a goal"].exists)
        let after = try await LocalAPI.requestCount(api, "POST /v1/plans")
        XCTAssertEqual(after, before + 1, "Exactly one plan should have been created on the local API")
        let loadsAfter = try await LocalAPI.requestCount(api, "GET /v1/plans/*")
        XCTAssertGreaterThan(loadsAfter, loadsBefore, "The saved plan was not loaded back from the local API")

        // Plan: this week, then the whole plan, then a week opened from it. The plan starts on the real today, so only
        // the structure is checked here; the content is pinned by the model and snapshot tests.
        app.buttons["Plan"].firstMatch.tap() // the tab; wide iPhones show tabs in a bar and a rail
        // The title and the element combining it with its dates both carry the identifier.
        let weekTitle = app.staticTexts["week.title"].firstMatch
        XCTAssertTrue(weekTitle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(weekTitle.label.hasPrefix("Week 1"), "A plan saved today opens on week 1, got \(weekTitle.label)")
        app.buttons["Whole plan"].tap()
        let secondWeek = app.buttons["whole.week.2"]
        XCTAssertTrue(secondWeek.waitForExistence(timeout: 5), app.debugDescription)
        secondWeek.tap()
        XCTAssertTrue(weekTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(weekTitle.label.hasPrefix("Week 2"), "Tapping week 2 should open it, got \(weekTitle.label)")
    }

    @MainActor
    func testTheCloseButtonLeavesThePreview() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)

        app.buttons["Close"].tap()

        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
