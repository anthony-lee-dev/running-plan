import APIClient
import Foundation
import Observation

/// Where DK-Preview gets its plan: a saved draft that is still fresh, or a new one from the generate endpoint.
@MainActor
@Observable
final class PreviewViewModel {
    enum State: Equatable {
        case loading
        case loaded(PlanPreview)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var answers: InterviewAnswers
    /// The draft on screen with its stored ids; what Save sends.
    private(set) var current: SavedPreview?

    private let generator: PlanGenerating
    private let store: PreviewDraftStoring
    private let now: () -> Date
    private let today: () -> String
    /// A newer request makes an older one's answer stale, so only the latest may update the screen.
    private var generation = 0

    init(
        answers: InterviewAnswers,
        generator: PlanGenerating,
        store: PreviewDraftStoring,
        now: @escaping () -> Date = Date.init,
        today: @escaping () -> String = PreviewViewModel.localToday
    ) {
        self.answers = answers
        self.generator = generator
        self.store = store
        self.now = now
        self.today = today
    }

    /// The user's local calendar date, `YYYY-MM-DD`.
    static func localToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Shows the saved draft when it is for these answers and under 24 hours old; otherwise asks for a new one.
    func load() async {
        if let saved = store.load(now: now()), saved.answers == answers {
            current = saved
            state = .loaded(PlanPreview(draft: saved.draft))
            return
        }
        await generate()
    }

    /// Changing an answer regenerates the plan.
    func regenerate(with newAnswers: InterviewAnswers) async {
        answers = newAnswers
        await generate()
    }

    func retry() async {
        await generate()
    }

    private func generate() async {
        generation += 1
        let mine = generation
        state = .loading
        current = nil
        do {
            let draft = try await generator.generate(answers: answers, today: today())
            guard mine == generation else { return }
            let preview = SavedPreview(answers: answers, draft: draft, savedAt: now())
            store.save(preview)
            current = preview
            state = .loaded(PlanPreview(draft: draft))
        } catch is CancellationError {
            return // the screen went away; nothing to show
        } catch {
            guard mine == generation else { return }
            state = .failed(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        switch error as? PreviewError {
        case .noPlanFits(let text): text
        case .tooManyRequests: "Too many tries just now. Please wait a little and try again."
        case .invalidAnswers: "Some of your answers don't look right. Change an answer and try again."
        case .offline: "We couldn't reach the server. Check your connection and try again."
        case .server, nil: "Something went wrong making your plan. Please try again."
        }
    }
}
