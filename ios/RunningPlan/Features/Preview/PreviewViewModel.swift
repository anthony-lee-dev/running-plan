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

    /// The start date the user picked, or nil for today. Never after today. The engine builds the plan from the date
    /// it is given (sent as `today`), so a past date back-dates the plan and its earlier sessions show as missed.
    private(set) var startDate: String?

    /// The date the plan is built from.
    var effectiveStart: String { startDate ?? today() }
    /// The latest date the picker offers.
    var latestStart: String { today() }

    init(
        answers: InterviewAnswers,
        startDate: String? = nil,
        generator: PlanGenerating,
        store: PreviewDraftStoring,
        now: @escaping () -> Date = Date.init,
        today: @escaping () -> String = PreviewViewModel.localToday
    ) {
        self.startDate = startDate
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
        if let saved = store.load(now: now()), saved.answers == answers, saved.startDate == startDate {
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

    /// Today or an earlier date (string compare is safe for `YYYY-MM-DD`); a later one is ignored. Rebuilds the plan.
    func setStartDate(_ date: String) async {
        let todayString = today()
        guard date <= todayString else { return }
        let chosen: String? = date == todayString ? nil : date
        guard chosen != startDate else { return }
        startDate = chosen
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
            let draft = try await generator.generate(answers: answers, today: effectiveStart)
            guard mine == generation else { return }
            let preview = SavedPreview(answers: answers, draft: draft, savedAt: now(), startDate: startDate)
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
