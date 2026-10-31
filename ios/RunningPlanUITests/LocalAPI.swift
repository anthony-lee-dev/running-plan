import XCTest

/// The local UI-test API (`npm run ui-test-server -w api`), never the deployed one. `scripts/verify.sh ios` starts that
/// server and passes its address as `LOCAL_API_URL`.
enum LocalAPI {
    static func url() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["LOCAL_API_URL"], let url = URL(string: text) else {
            throw XCTSkip("Start the UI-test API (npm run ui-test-server -w api) and set LOCAL_API_URL=http://127.0.0.1:8790 in the test scheme")
        }
        return url
    }

    /// How many successful requests the local API has served for `operation` (`METHOD /path`); a key ending in `*`
    /// counts every path that starts with what comes before it.
    static func requestCount(_ api: URL, _ operation: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: api.appending(path: "__test/stats"))
        let stats = try JSONDecoder().decode([String: [String: Int]].self, from: data)
        let requests = stats["requests"] ?? [:]
        guard operation.hasSuffix("*") else { return requests[operation] ?? 0 }
        return requests.filter { $0.key.hasPrefix(operation.dropLast()) }.values.reduce(0, +)
    }

    /// The last sign-in code the local API sent to `email`, waiting a little for it to arrive.
    static func latestCode(_ api: URL, email: String) async throws -> String {
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

    /// The app pointed at the local API. `signedOut` clears the Keychain tokens first: they outlive a reinstall, and an
    /// earlier test's plan would replace "Set a goal". A relaunch that should keep the session leaves it false.
    @MainActor
    static func app(_ api: URL, signedOut: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["API_BASE_URL"] = api.absoluteString
        // Hide any draft saved by an earlier run (a launch argument beats the stored value), so the API is called.
        app.launchArguments += ["-preview.draft", ""]
        if signedOut { app.launchArguments += ["-auth.reset", "YES"] }
        return app
    }

    /// Launches signed out with no saved draft, then answers the interview with 10K and skips the rest, waiting for
    /// week 1 of the preview.
    @MainActor
    static func openPreview(_ api: URL) -> XCUIApplication {
        let app = app(api, signedOut: true)
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

    /// From the preview: Save, sign in with a fresh address and its emailed code, and wait for Next to show the plan.
    @MainActor
    static func saveAndSignIn(_ app: XCUIApplication, _ api: URL) async throws {
        // A new address each run, so no earlier code or rate limit gets in the way.
        let email = "ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"
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

        XCTAssertTrue(app.staticTexts["next.plan"].waitForExistence(timeout: 15), app.debugDescription)
    }
}
