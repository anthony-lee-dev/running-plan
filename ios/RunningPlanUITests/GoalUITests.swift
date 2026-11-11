import XCTest

/// Slice 11's Done when: a UI test changes a setting and re-runs the interview, which arrives as a proposal.
final class GoalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Swipes the Goal screen up until `element` can be tapped.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    private func openGoalTab(_ app: XCUIApplication) {
        app.buttons["Goal"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["screen.goal"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testChangingASettingAndRerunningTheInterviewGivesAProposal() async throws {
        let api = try LocalAPI.url()
        let app = try await LocalAPI.signedInApp(api)
        openGoalTab(app)

        // Turn reviews off, then back on: the way back that the review's footer never offered.
        let review = app.buttons["settings.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        let patchesBefore = try await LocalAPI.requestCount(api, "PATCH /v1/profile")
        review.tap()
        XCTAssertTrue(app.staticTexts["screen.reviewSettings"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "identifier == 'reviewSettings.frequency' AND label BEGINSWITH 'Off'")).firstMatch.tap()
        // The slower the simulator, the later the save lands: wait for it, then for the day picker to go.
        var saved = patchesBefore
        let offDeadline = Date().addingTimeInterval(30)
        while saved == patchesBefore, Date() < offDeadline {
            try await Task.sleep(for: .milliseconds(300))
            saved = try await LocalAPI.requestCount(api, "PATCH /v1/profile")
        }
        XCTAssertEqual(saved, patchesBefore + 1, "Turning reviews off was saved")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["reviewSettings.day"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed, "Off has no review day")
        app.buttons.matching(NSPredicate(format: "identifier == 'reviewSettings.frequency' AND label BEGINSWITH 'Weekly plus urgent'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["reviewSettings.day"].waitForExistence(timeout: 30), "Back on shows the review day again: \(app.debugDescription)")
        app.buttons["reviewSettings.done"].tap()
        let patchesAfterReview = try await LocalAPI.requestCount(api, "PATCH /v1/profile")
        XCTAssertEqual(patchesAfterReview, patchesBefore + 2)
        XCTAssertTrue(review.label.contains("Weekly plus urgent"), review.label)

        // The target display is a setting of its own.
        let effort = app.segmentedControls["settings.targetDisplay"].buttons["Effort"]
        XCTAssertTrue(effort.waitForExistence(timeout: 15), app.debugDescription)
        effort.tap()
        let deadline = Date().addingTimeInterval(30)
        var patches = patchesAfterReview
        while patches == patchesAfterReview, Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            patches = try await LocalAPI.requestCount(api, "PATCH /v1/profile")
        }
        XCTAssertEqual(patches, patchesAfterReview + 1)
        XCTAssertFalse(app.staticTexts["settings.error"].exists)

        // Re-run the interview: it starts from the plan and the new setting, and ends in one proposal.
        let rerun = app.buttons["goal.rerun"]
        reveal(rerun, in: app)
        let postsBefore = try await LocalAPI.requestCount(api, "POST /v1/plans/*")
        let proposalCallsBefore = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        rerun.tap()
        XCTAssertTrue(app.staticTexts["screen.interview"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons["I'd rather build my own plan"].exists, "A saved plan is not replaced by a blank one")
        let proposals = app.staticTexts["screen.goalProposals"]
        for _ in 0..<20 where !proposals.exists {
            // Continue keeps a prefilled answer; Skip clears one, so it is only for questions with none.
            let next = app.buttons["Continue"]
            if next.waitForExistence(timeout: 3), next.isEnabled {
                next.tap()
            } else if app.buttons["Skip"].exists {
                app.buttons["Skip"].tap()
            }
        }
        XCTAssertTrue(proposals.waitForExistence(timeout: 20), "The interview ends in a proposal: \(app.debugDescription)")
        let card = app.descendants(matching: .any)["proposal.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["proposal.accept"].firstMatch.exists)
        let postsAfter = try await LocalAPI.requestCount(api, "POST /v1/plans/*")
        XCTAssertEqual(postsAfter, postsBefore + 1, "One call asked the engine to plan again")
        XCTAssertFalse(app.staticTexts["goal.error"].exists)

        // Nothing changed until accepted: no proposal was accepted or dismissed by the re-run.
        let proposalCallsAfter = try await LocalAPI.requestCount(api, "POST /v1/proposals/*")
        XCTAssertEqual(proposalCallsAfter, proposalCallsBefore)
        app.buttons["goalProposals.done"].tap()
        XCTAssertTrue(app.staticTexts["screen.goal"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testExportingTheDataAndSigningOut() async throws {
        let api = try LocalAPI.url()
        let app = try await LocalAPI.signedInApp(api)
        openGoalTab(app)

        let export = app.buttons["privacy.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        reveal(export, in: app)
        let before = try await LocalAPI.requestCount(api, "POST /v1/account/export")
        export.tap()
        XCTAssertTrue(app.buttons["privacy.export.share"].waitForExistence(timeout: 10), "The file is ready to share: \(app.debugDescription)")
        let after = try await LocalAPI.requestCount(api, "POST /v1/account/export")
        XCTAssertEqual(after, before + 1)

        let signOut = app.buttons["account.signOut"]
        reveal(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(app.buttons["goal.set"].waitForExistence(timeout: 10), "Signed out shows the empty state: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["account.signOut"].exists)

        // Still signed out after a relaunch.
        app.terminate()
        let again = LocalAPI.app(api, signedOut: false)
        again.launch()
        again.buttons["Goal"].firstMatch.tap()
        XCTAssertTrue(again.buttons["goal.set"].waitForExistence(timeout: 15), again.debugDescription)
    }
}
