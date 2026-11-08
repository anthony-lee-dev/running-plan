import APIClient
import Foundation

enum ReviewError: Error, Equatable {
    case signedOut
    case notFound
    /// 409 `stale_proposal`: the plan changed since the proposal was made.
    case stale
    /// 409 on anything else: the proposal was already accepted or dismissed (elsewhere, say).
    case notPending
    case invalid
    case offline
    case server
}

/// The review and proposal endpoints (`getWeeklyReview`, `generateProposals`, `listProposals`, `acceptProposal`,
/// `dismissProposal`) and the profile's review setting.
protocol ReviewServing: Sendable {
    /// One plan week's review; nil when the plan or week is gone.
    func review(planId: String, weekIndex: Int, today: String) async throws -> Components.Schemas.WeeklyReview?
    /// Runs the proposal engine (or, with `interview`, the interview re-run) and returns the proposals it made.
    func generate(planId: String, today: String, interview: Components.Schemas.InterviewAnswers?) async throws -> [Components.Schemas.Proposal]
    /// The plan's pending proposals, newest first.
    func pending(planId: String) async throws -> [Components.Schemas.Proposal]
    /// Applies a pending proposal; the reply is the whole updated plan.
    func accept(id: String, includeUserOwned: Bool) async throws -> Components.Schemas.PlanDetail
    func dismiss(id: String) async throws
}

/// The review frequency and day from the profile, with the revision an update must send back.
struct ReviewSetting: Equatable, Sendable {
    var frequency: Components.Schemas.ReviewFrequency
    /// Nil means the last day of the plan week.
    var day: Components.Schemas.Weekday?
    var revision: Int
}

protocol ReviewSettingsServing: Sendable {
    func load() async throws -> ReviewSetting
    func save(_ setting: ReviewSetting) async throws -> ReviewSetting
}

/// Calls the endpoints through a client that carries the user's token (`AuthMiddleware`).
struct APIReviewService: ReviewServing, ReviewSettingsServing {
    let client: Client

    func review(planId: String, weekIndex: Int, today: String) async throws -> Components.Schemas.WeeklyReview? {
        let output = try await call { try await client.getWeeklyReview(path: .init(planId: planId, weekIndex: weekIndex), query: .init(today: today)) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .notFound: return nil
        case .unauthorized: throw ReviewError.signedOut
        case .undocumented: throw ReviewError.server
        }
    }

    func generate(planId: String, today: String, interview: Components.Schemas.InterviewAnswers?) async throws -> [Components.Schemas.Proposal] {
        let body = Components.Schemas.ProposalGenerateRequest(today: today, interview: interview)
        let output = try await call { try await client.generateProposals(path: .init(planId: planId), body: .json(body)) }
        switch output {
        case .ok(let ok): return try ok.body.json.proposals
        case .badRequest: throw ReviewError.invalid
        case .unauthorized: throw ReviewError.signedOut
        case .notFound: throw ReviewError.notFound
        case .undocumented: throw ReviewError.server
        }
    }

    func pending(planId: String) async throws -> [Components.Schemas.Proposal] {
        let output = try await call { try await client.listProposals(path: .init(planId: planId), query: .init(status: .pending)) }
        switch output {
        case .ok(let ok): return try ok.body.json.proposals
        case .unauthorized: throw ReviewError.signedOut
        case .notFound: throw ReviewError.notFound
        case .undocumented: throw ReviewError.server
        }
    }

    func accept(id: String, includeUserOwned: Bool) async throws -> Components.Schemas.PlanDetail {
        let body = Components.Schemas.ProposalAcceptRequest(includeUserOwned: includeUserOwned)
        let output = try await call { try await client.acceptProposal(path: .init(proposalId: id), body: .json(body)) }
        switch output {
        case .ok(let ok): return try ok.body.json
        case .unauthorized: throw ReviewError.signedOut
        case .notFound: throw ReviewError.notFound
        case .conflict(let conflict): throw Self.conflict(conflict)
        case .undocumented: throw ReviewError.server
        }
    }

    func dismiss(id: String) async throws {
        let output = try await call { try await client.dismissProposal(path: .init(proposalId: id)) }
        switch output {
        case .ok: return
        case .unauthorized: throw ReviewError.signedOut
        case .notFound: throw ReviewError.notFound
        case .conflict(let conflict): throw Self.conflict(conflict)
        case .undocumented: throw ReviewError.server
        }
    }

    /// `stale_proposal` against `proposal_not_pending`, from the problem's type.
    private static func conflict(_ conflict: Components.Responses.Conflict) -> ReviewError {
        let problem = try? conflict.body.application_problem_plus_json
        return problem?._type.hasSuffix("stale_proposal") == true ? .stale : .notPending
    }

    // MARK: Review setting (profile)

    func load() async throws -> ReviewSetting {
        let output = try await call { try await client.getProfile() }
        switch output {
        case .ok(let ok): return Self.setting(try ok.body.json)
        case .unauthorized: throw ReviewError.signedOut
        case .undocumented: throw ReviewError.server
        }
    }

    func save(_ setting: ReviewSetting) async throws -> ReviewSetting {
        // `review` is replaced as a whole object, so the day goes back with the frequency (absent means the plan's last day).
        let update = Components.Schemas.ProfileUpdate(review: .init(frequency: setting.frequency, day: setting.day))
        let output = try await call { try await client.updateProfile(headers: .init(If_hyphen_Match: "\"\(setting.revision)\""), body: .json(update)) }
        switch output {
        case .ok(let ok): return Self.setting(try ok.body.json)
        case .badRequest: throw ReviewError.invalid
        case .unauthorized: throw ReviewError.signedOut
        case .conflict: throw ReviewError.notPending
        case .undocumented: throw ReviewError.server
        }
    }

    private static func setting(_ profile: Components.Schemas.Profile) -> ReviewSetting {
        ReviewSetting(frequency: profile.review.frequency, day: profile.review.day, revision: profile.revision)
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if underlying is CancellationError || Task.isCancelled { throw CancellationError() }
            throw underlying is URLError || (underlying as? SignInError) == .offline ? ReviewError.offline : ReviewError.server
        }
    }
}
