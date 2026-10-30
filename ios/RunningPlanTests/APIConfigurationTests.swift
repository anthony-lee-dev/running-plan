import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct APIConfigurationTests {
    @Test func defaultsToTheDeployedAPI() {
        let url = APIConfiguration.baseURL(environment: [:], override: nil)
        #expect(url == URL(string: "https://running-plan-api.anthonyhklee.workers.dev")!)
        #expect(url.scheme == "https")
    }

    @Test func environmentVariableWinsForLocalDevelopment() {
        let url = APIConfiguration.baseURL(environment: ["API_BASE_URL": "http://localhost:8787"], override: "https://example.test")
        #expect(url == URL(string: "http://localhost:8787")!)
    }

    @Test func storedOverrideComesNext() {
        #expect(APIConfiguration.baseURL(environment: [:], override: "https://example.test") == URL(string: "https://example.test")!)
    }

    @Test func anUnusableValueFallsBackToTheDeployedAPI() {
        #expect(APIConfiguration.baseURL(environment: ["API_BASE_URL": ""], override: nil) == APIConfiguration.deployedURL)
    }

    @Test(arguments: ["2026-10-30T19:56:28.041Z", "2026-10-30T19:56:28Z"])
    func datesFromTheServerAreReadWithOrWithoutMilliseconds(text: String) throws {
        let date = try APIConfiguration.dateTranscoder.decode(text)
        #expect(abs(date.timeIntervalSince1970 - 1_793_390_188) < 1)
        #expect(try APIConfiguration.dateTranscoder.decode(APIConfiguration.dateTranscoder.encode(date)) == date)
    }
}
