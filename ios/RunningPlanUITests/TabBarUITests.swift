import XCTest

final class TabBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Tabs are found by label, not through `app.tabBars`: on wide iPhones iOS shows them as a side rail.
    @MainActor
    func testFourTabsAndSwitching() {
        let app = XCUIApplication()
        app.launchArguments += ["-auth.reset", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["screen.next"].waitForExistence(timeout: 10),
                      "Next not shown first\n\(app.debugDescription)")
        for title in ["Next", "Plan", "Progress", "Goal"] {
            XCTAssertTrue(app.buttons[title].exists, "missing tab \(title)\n\(app.debugDescription)")
        }

        app.buttons["Goal"].tap()
        XCTAssertTrue(app.staticTexts["screen.goal"].waitForExistence(timeout: 5),
                      "Goal not shown after tapping it\n\(app.debugDescription)")
    }
}
