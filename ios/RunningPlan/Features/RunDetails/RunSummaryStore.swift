import APIClient
import Foundation
import Observation

/// The written summary on Run details (issue #132): shows what the server has at once (stored AI text, or the template), asks for
/// the AI text once when the server says it can, and swaps it in. Every failure keeps what is shown: the card never errors at the
/// user, and there is no refresh (the text changes only when the run's data does).
@MainActor
@Observable
final class RunSummaryStore {
    private(set) var result: RunSummaryResult?

    private let service: RunSummaryServing

    init(service: RunSummaryServing) {
        self.service = service
    }

    /// Only a running workout that is not ignored has a summary; anything else would only waste a request.
    static func applies(to activity: Components.Schemas.Activity) -> Bool {
        activity.value1.workoutType == .running && activity.value2.disposition != .ignored
    }

    func open(activityId: String, today: String) async {
        do {
            let first = try await service.summary(activityId: activityId, today: today)
            result = first
            guard first.canGenerate else { return }
            // One ask per open. A 429, an offline phone or a server fault keeps the template already shown.
            if let written = try? await service.generate(activityId: activityId, today: today) { result = written }
        } catch {
            // Nothing shown: a run the server does not know, signed out, or offline.
        }
    }
}

/// The "AI run summaries" switch in Goal and settings. On by default; the server holds it (shared with the web app).
@MainActor
@Observable
final class AISummarySwitch {
    private(set) var isOn: Bool?
    private(set) var saving = false
    private(set) var error: String?

    private let service: RunSummaryServing

    init(service: RunSummaryServing) {
        self.service = service
    }

    func load() async {
        if let on = try? await service.aiEnabled() { isOn = on }
    }

    func set(_ on: Bool) async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await service.setAIEnabled(on)
            isOn = on
        } catch is CancellationError {
            return
        } catch RunSummaryError.conflict {
            self.error = "Your settings changed somewhere else. We've loaded the latest; try again."
            await load()
        } catch {
            self.error = "We couldn't save that. Check your connection and try again."
            await load()
        }
    }
}
