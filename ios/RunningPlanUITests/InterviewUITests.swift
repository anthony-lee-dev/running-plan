import XCTest

final class InterviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSetAGoalOpensTheInterviewAndContinueAdvances() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Set a goal"].tap()
        XCTAssertTrue(app.staticTexts["screen.interview"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Question 1 of 12 · about 2 minutes"].exists)

        app.buttons["10K"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 12 · about 2 minutes"].waitForExistence(timeout: 5),
                      app.debugDescription)

        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Question 3 of 12 · about 2 minutes"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 12 · about 2 minutes"].waitForExistence(timeout: 5))
    }
}
