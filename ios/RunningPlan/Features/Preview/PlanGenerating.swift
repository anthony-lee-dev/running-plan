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
    /// The deployed API. A phone cannot reach a dev server on the Mac at `localhost`, so this is the default.
    /// `npm run smoke -w api` checks the same URL; change both together.
    static let deployedURL = URL(string: "https://running-plan-api.anthonyhklee.workers.dev")!

    /// The deployed API by default. For a local server, set the `API_BASE_URL` environment variable in the scheme
    /// (for example `http://localhost:8787` in the simulator) or the `apiBaseURL` user default.
    static var baseURL: URL {
        baseURL(environment: ProcessInfo.processInfo.environment, override: UserDefaults.standard.string(forKey: "apiBaseURL"))
    }

    static func baseURL(environment: [String: String], override: String?) -> URL {
        for text in [environment["API_BASE_URL"], override] {
            if let text, let url = URL(string: text), url.scheme != nil, url.host != nil { return url }
        }
        return deployedURL
    }

    static func liveGenerator() -> PlanGenerating {
        APIPlanGenerator(client: client(serverURL: baseURL, transport: URLSessionTransport()), deviceID: DeviceIdentity.current())
    }

    /// Every client the app makes. The server writes timestamps with milliseconds (JavaScript's `toISOString`), which
    /// the runtime's default date format rejects, so dates are read with or without them.
    static func client(serverURL: URL, transport: ClientTransport, middlewares: [ClientMiddleware] = []) -> Client {
        // The entity-tag fix runs last, nearest the transport, so every request (retries included) carries `If-Match: "3"`.
        Client(serverURL: serverURL, configuration: Configuration(dateTranscoder: dateTranscoder), transport: transport, middlewares: middlewares + [EntityTagMiddleware()])
    }

    static let dateTranscoder: DateTranscoder = FlexibleISO8601()

    /// Decodes API JSON outside the client (fixtures, stored copies) the way the client does.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            try dateTranscoder.decode(try d.singleValueContainer().decode(String.self))
        }
        return decoder
    }
}

/// ISO 8601 dates, written with milliseconds and read with or without them.
struct FlexibleISO8601: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    func decode(_ text: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an ISO 8601 date: \(text)"))
    }
}
