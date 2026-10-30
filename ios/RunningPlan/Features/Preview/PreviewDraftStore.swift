import APIClient
import Foundation

/// A suggested plan and the answers it came from, kept on the device for 24 hours (design §7: the unsaved preview
/// lives on the device, never on the server).
struct SavedPreview: Codable, Equatable {
    var answers: InterviewAnswers
    var draft: Components.Schemas.PlanDraft
    var savedAt: Date
    /// Made once per draft and kept with it, so saving it again (after a lost answer or a relaunch) sends the same
    /// ids and the server replays the create instead of storing a second plan.
    var ids: PlanIDs

    init(answers: InterviewAnswers, draft: Components.Schemas.PlanDraft, savedAt: Date, ids: PlanIDs? = nil) {
        self.answers = answers
        self.draft = draft
        self.savedAt = savedAt
        self.ids = ids ?? .random(sessionCount: draft.sessions.count)
    }
}

/// The client-assigned ids for a saved plan and its sessions, in the draft's session order.
struct PlanIDs: Codable, Equatable {
    var plan: String
    var sessions: [String]

    static func random(sessionCount: Int) -> PlanIDs {
        PlanIDs(plan: newID(), sessions: (0..<sessionCount).map { _ in newID() })
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }
}

protocol PreviewDraftStoring {
    func save(_ preview: SavedPreview)
    /// The saved preview while it is younger than 24 hours; an older one is deleted and nil comes back.
    func load(now: Date) -> SavedPreview?
    func clear()
}

extension PreviewDraftStoring {
    /// Keeps a new draft, with new ids.
    func save(answers: InterviewAnswers, draft: Components.Schemas.PlanDraft, now: Date) {
        save(SavedPreview(answers: answers, draft: draft, savedAt: now))
    }
}

struct PreviewDraftStore: PreviewDraftStoring {
    static let lifetime: TimeInterval = 24 * 60 * 60
    private static let key = "preview.draft"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ preview: SavedPreview) {
        guard let data = try? JSONEncoder().encode(preview) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func load(now: Date) -> SavedPreview? {
        guard let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(SavedPreview.self, from: data) else {
            clear() // nothing there, or something this version cannot read
            return nil
        }
        let age = now.timeIntervalSince(saved.savedAt)
        // A clock set back counts as expired too: the draft's age cannot be trusted.
        guard age >= 0, age < Self.lifetime else {
            clear()
            return nil
        }
        return saved
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
