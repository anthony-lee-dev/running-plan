import APIClient
import Foundation

/// Why a preview could not be made, in terms the screen can explain.
enum PreviewError: Error, Equatable {
    case noPlanFits(String)
    case tooManyRequests
    case invalidAnswers
    case offline
    case server
}

/// Turns interview answers into a suggested plan. Stateless and needs no account (design §7).
protocol PlanGenerating: Sendable {
    func generate(answers: InterviewAnswers, today: String) async throws -> Components.Schemas.PlanDraft
}

/// Calls `POST /v1/plans/generate` through the generated client.
struct APIPlanGenerator: PlanGenerating {
    let client: Client
    let deviceID: UUID

    func generate(answers: InterviewAnswers, today: String) async throws -> Components.Schemas.PlanDraft {
        // The app's answers already have the spec's JSON shape, so they cross to the generated type as JSON.
        let generated: Components.Schemas.InterviewAnswers
        do {
            generated = try JSONDecoder().decode(Components.Schemas.InterviewAnswers.self, from: JSONEncoder().encode(answers))
        } catch {
            throw PreviewError.invalidAnswers
        }
        let output: Operations.generatePlan.Output
        do {
            output = try await client.generatePlan(
                .init(
                    headers: .init(X_hyphen_Device_hyphen_Id: deviceID.uuidString.lowercased()),
                    body: .json(.init(answers: generated, today: today))
                )
            )
        } catch {
            // The client wraps whatever its transport threw. Cancellation is not a failure to show; no network is an
            // offline problem; anything else (an unreadable response, say) is the server's.
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError ? PreviewError.offline : PreviewError.server
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .unprocessableContent(let response):
            throw PreviewError.noPlanFits((try? response.body.application_problem_plus_json.title) ?? "No plan fits those answers.")
        case .tooManyRequests:
            throw PreviewError.tooManyRequests
        case .badRequest, .contentTooLarge:
            throw PreviewError.invalidAnswers
        case .undocumented:
            throw PreviewError.server
        }
    }
}

/// A random per-install id, sent only so the server can rate limit; it identifies nobody.
enum DeviceIdentity {
    private static let key = "device.id"

    static func current(defaults: UserDefaults = .standard) -> UUID {
        if let text = defaults.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }
}

enum APIConfiguration {
    /// Local development server by default. Override with the `API_BASE_URL` environment variable or the
    /// `apiBaseURL` default. The production URL is set once the API is deployed.
    static var baseURL: URL {
        let text = ProcessInfo.processInfo.environment["API_BASE_URL"] ?? UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:8787"
        return URL(string: text) ?? URL(string: "http://localhost:8787")!
    }

    static func liveGenerator() -> PlanGenerating {
        APIPlanGenerator(client: Client(serverURL: baseURL, transport: URLSessionTransport()), deviceID: DeviceIdentity.current())
    }
}
