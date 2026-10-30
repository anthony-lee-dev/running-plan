import XCTest

/// Interview to preview against the local UI-test API (`npm run ui-test-server -w api`), never the deployed one.
/// `scripts/verify.sh ios` starts that server and passes its address as `LOCAL_API_URL`.
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

    /// How many plan drafts the local API has generated.
    private func generateCount(_ api: URL) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: api.appending(path: "__test/stats"))
        let stats = try JSONDecoder().decode([String: [String: Int]].self, from: data)
        return stats["requests"]?["POST /v1/plans/generate"] ?? 0
    }

    @MainActor
    func testInterviewToPreviewUsesTheLocalAPI() async throws {
        let api = try localAPI()
        let before = try await generateCount(api)

        let app = XCUIApplication()
        app.launchEnvironment["API_BASE_URL"] = api.absoluteString
        // Hide any draft saved by an earlier run (a launch argument beats the stored value), so the API is called.
        app.launchArguments += ["-preview.draft", ""]
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
        XCTAssertTrue(app.staticTexts["Your suggested plan"].exists)

        let after = try await generateCount(api)
        XCTAssertGreaterThan(after, before, "The preview did not come from the local API")
    }
}
