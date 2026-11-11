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

    /// One request to the local API, tried a second time when the first times out: on a slow CI runner the Node server
    /// has been seen to stall past URLSession's 60 s default once, and a request here is safe to repeat.
    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = 90
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            return try await URLSession.shared.data(for: request)
        }
    }

    /// How many successful requests the local API has served for `operation` (`METHOD /path`); a key ending in `*`
    /// counts every path that starts with what comes before it.
    static func requestCount(_ api: URL, _ operation: String) async throws -> Int {
        let (data, _) = try await send(URLRequest(url: api.appending(path: "__test/stats")))
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
        XCTAssertTrue(app.staticTexts["screen.interview"].waitForExistence(timeout: 15), app.debugDescription)
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
        XCTAssertTrue(week.waitForExistence(timeout: 45) || error.exists, app.debugDescription)
        XCTAssertFalse(error.exists, "The preview failed: \(error.label)")
        return app
    }

    /// The app launched signed in to a fresh account that already has a saved 10K plan, waiting for Next to show it. It
    /// skips the interview, the preview and sign-in (about 40 s a test), so use it for every test that is not about
    /// those flows; `PreviewUITests`, `SignInAgainUITests` and `InterviewUITests` cover them in full. The account and
    /// plan come from the UI-test API's `/__test/seed`, `startingOn` is the plan's start date (today by default).
    @MainActor
    static func signedInApp(_ api: URL, startingOn start: Date = Date()) async throws -> XCUIApplication {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var request = URLRequest(url: api.appending(path: "__test/seed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let email = "ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "today": day.string(from: start)])
        let (data, response) = try await send(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        let seed = try JSONDecoder().decode([String: String].self, from: data)
        let tokens = [seed["accessToken"], seed["refreshToken"], seed["userId"]].compactMap { $0 }
        XCTAssertEqual(tokens.count, 3)

        let app = app(api, signedOut: true)
        app.launchArguments += ["-auth.seed", tokens.joined(separator: "|")]
        app.launch()
        XCTAssertTrue(app.staticTexts["next.plan"].waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    /// From the preview: Save, sign in with a fresh address and its emailed code, and wait for Next to show the plan.
    /// Returns the address, for a test that signs in to the same account again.
    @MainActor @discardableResult
    static func saveAndSignIn(_ app: XCUIApplication, _ api: URL) async throws -> String {
        // A new address each run, so no earlier code or rate limit gets in the way.
        let email = "ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        app.buttons["preview.save"].tap()

        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), app.debugDescription)
        emailField.tap()
        emailField.typeText(email)
        app.buttons["signin.send"].tap()

        let codeField = app.textFields["signin.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 30), app.debugDescription)
        let code = try await latestCode(api, email: email)
        codeField.tap()
        codeField.typeText(code)
        app.buttons["signin.verify"].tap()

        XCTAssertTrue(app.staticTexts["next.plan"].waitForExistence(timeout: 15), app.debugDescription)
        return email
    }

    /// From a signed-out screen: tap "Sign in" (`account.signin`), enter `email` and its emailed code, and wait for the
    /// sheet to close.
    @MainActor
    static func signInAgain(_ app: XCUIApplication, _ api: URL, email: String) async throws {
        let signIn = app.buttons["account.signin"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), app.debugDescription)
        signIn.tap()

        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), app.debugDescription)
        emailField.tap()
        emailField.typeText(email)
        app.buttons["signin.send"].tap()

        let codeField = app.textFields["signin.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 30), app.debugDescription)
        let code = try await latestCode(api, email: email)
        codeField.tap()
        codeField.typeText(code)
        app.buttons["signin.verify"].tap()
        XCTAssertTrue(codeField.waitForNonExistence(timeout: 15), app.debugDescription)
    }
}
