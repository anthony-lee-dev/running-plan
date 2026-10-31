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

    /// Issue #97: pick an earlier start date; the plan is rebuilt from it (a second generate call) and still saves.
    @MainActor
    func testPickingAnEarlierStartDateRebuildsThePlanAndSavesIt() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)
        let before = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")

        // The 15th of the previous month: always in the past and always exists, 14 to 46 days back. The popup opens on
        // today's month.
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month], from: Date())
        parts.month! -= 1
        parts.day = 15
        let target = calendar.date(from: parts)!
        let picker = app.datePickers["preview.startDate"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        picker.buttons.firstMatch.tap()
        app.buttons["Previous Month"].tap()
        let label = DateFormatter()
        label.dateFormat = "EEEE, MMMM d"
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label.string(from: target))).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), app.debugDescription)
        day.tap()

        let deadline = Date().addingTimeInterval(15)
        var after = before
        while after <= before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            after = try await LocalAPI.requestCount(api, "POST /v1/plans/generate")
        }
        XCTAssertGreaterThan(after, before, "Choosing a start date should rebuild the plan")

        let week = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Week 1 ·'")).firstMatch
        XCTAssertTrue(week.waitForExistence(timeout: 15), app.debugDescription)
        try await LocalAPI.saveAndSignIn(app, api)

        // The plan started at least two weeks ago, so this week is not week 1: the chosen date reached the saved plan.
        app.buttons["Plan"].firstMatch.tap()
        let weekTitle = app.staticTexts["week.title"].firstMatch
        XCTAssertTrue(weekTitle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(weekTitle.label.hasPrefix("Week 1"), "A plan started in the past should be past week 1, got \(weekTitle.label)")
    }

    @MainActor
    func testTheCloseButtonLeavesThePreview() async throws {
        let api = try LocalAPI.url()
        let app = LocalAPI.openPreview(api)

        app.buttons["Close"].tap()

        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
