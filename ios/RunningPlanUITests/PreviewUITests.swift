import XCTest

/// Interview to preview (and on to a saved plan) against the local UI-test API (`npm run ui-test-server -w api`), never
/// the deployed one. `scripts/verify.sh ios` starts that server and passes its address as `LOCAL_API_URL`.
final class PreviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func localAPI() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["LOCAL_API_URL"], let url = URL(string: text) else {
            throw XCTSkip("Start the UI-test API (npm run ui-test-server -w api) and set LOCAL_API_URL=http://127.0.0.1:8790 in the test scheme")
        }
        return url
    }

    /// How many successful requests the local API has served for `operation` (`METHOD /path`).
    private func requestCount(_ api: URL, _ operation: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: api.appending(path: "__test/stats"))
        let stats = try JSONDecoder().decode([String: [String: Int]].self, from: data)
        return stats["requests"]?[operation] ?? 0
    }

    /// The last sign-in code the local API sent to `email`, waiting a little for it to arrive.
    private func latestCode(_ api: URL, email: String) async throws -> String {
        var components = URLComponents(url: api.appending(path: "__test/codes/latest"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "email", value: email)]
        for _ in 0..<20 {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let body = try? JSONDecoder().decode([String: String].self, from: data), let code = body["code"] {
                return code
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("No sign-in code arrived for \(email)")
        return ""
    }

    /// Launches against the local API with no saved draft (and, when asked, signed out), then answers the interview
    /// with 10K and skips the rest, waiting for week 1 of the preview.
    @MainActor
    private func openPreview(_ api: URL, signedOut: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_BASE_URL"] = api.absoluteString
        // Hide any draft saved by an earlier run (a launch argument beats the stored value), so the API is called.
        app.launchArguments += ["-preview.draft", ""]
        // Keychain tokens outlive a reinstall; start without them.
        if signedOut { app.launchArguments += ["-auth.reset", "YES"] }
        app.launch()

        app.buttons["Set a goal"].tap()
        XCTAssertTrue(app.staticTexts["screen.interview"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["10K"].tap()
        app.buttons["Continue"].tap()

        // Skip the remaining questions; each takes the engine's default.
        let preview = app.otherElements["screen.preview"].firstMatch
        for _ in 0..<15 where !preview.exists {
            let skip = app.buttons["Skip"]
            guard skip.waitForExistence(timeout: 3) else { break }
            skip.tap()
        }

        let week = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Week 1 ·'")).firstMatch
        let error = app.staticTexts["preview.error"]
        XCTAssertTrue(week.waitForExistence(timeout: 15) || error.exists, app.debugDescription)
        XCTAssertFalse(error.exists, "The preview failed: \(error.label)")
        return app
    }

    @MainActor
    func testInterviewToPreviewUsesTheLocalAPI() async throws {
        let api = try localAPI()
        let before = try await requestCount(api, "POST /v1/plans/generate")

        let app = openPreview(api)
        XCTAssertTrue(app.staticTexts["Your suggested plan"].exists)

        let after = try await requestCount(api, "POST /v1/plans/generate")
        XCTAssertGreaterThan(after, before, "The preview did not come from the local API")
    }

    @MainActor
    func testSaveSignsInWithAnEmailCodeAndSavesThePlan() async throws {
        let api = try localAPI()
        let before = try await requestCount(api, "POST /v1/plans")
        // A new address each run, so no earlier code or rate limit gets in the way.
        let email = "ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"

        let app = openPreview(api, signedOut: true)
        app.buttons["preview.save"].tap()

        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), app.debugDescription)
        emailField.tap()
        emailField.typeText(email)
        app.buttons["signin.send"].tap()

        let codeField = app.textFields["signin.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), app.debugDescription)
        let code = try await latestCode(api, email: email)
        codeField.tap()
        codeField.typeText(code)
        app.buttons["signin.verify"].tap()

        XCTAssertTrue(app.staticTexts["plan.saved"].waitForExistence(timeout: 15), app.debugDescription)
        let after = try await requestCount(api, "POST /v1/plans")
        XCTAssertEqual(after, before + 1, "Exactly one plan should have been created on the local API")
    }

    @MainActor
    func testTheCloseButtonLeavesThePreview() async throws {
        let api = try localAPI()
        let app = openPreview(api)

        app.buttons["Close"].tap()

        XCTAssertTrue(app.buttons["Set a goal"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
