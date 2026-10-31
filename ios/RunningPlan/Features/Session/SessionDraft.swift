import APIClient
import Foundation

/// DK-Editor's working copy of a session. Keeps to the server's rules (`parseSteps` in `api/src/domain/plan-input.ts`):
/// at most 50 steps, repeats of 2 to 30 holding 1 to 10 run steps and never nested, exercise steps only in strength,
/// no steps in a custom session.
struct SessionDraft: Equatable {
    typealias Step = Components.Schemas.Step
    typealias SessionType = Components.Schemas.SessionType

    var date: String
    var title: String
    private(set) var type: SessionType
    var steps: [Step]
    var notes: String
    /// Used only when `type` is custom.
    var custom: Components.Schemas.CustomDetails

    static let maxSteps = 50
    static let repeatCounts = 2...30
    static let maxRepeatSteps = 10

    init(_ s: Components.Schemas.SessionContent) {
        date = s.date
        title = s.title ?? ""
        type = s._type
        steps = s.steps ?? []
        notes = s.notes ?? ""
        custom = s.custom ?? Self.defaultCustom
    }

    /// A new session the user adds: an easy run of 5 km at an easy effort.
    static func new(date: String) -> SessionDraft {
        SessionDraft(.init(date: date, _type: .easy, steps: defaultSteps(for: .easy)))
    }

    static let defaultCustom = Components.Schemas.CustomDetails(goal: .init(_type: .time, value: 1800), effort: .easy)

    private enum Kind { case run, strength, custom, rest }

    private static func kind(_ type: SessionType) -> Kind {
        switch type {
        case .custom: .custom
        case .strength: .strength
        case .rest: .rest
        case .easy, .long, .tempo, .intervals: .run
        }
    }

    private static func defaultSteps(for type: SessionType) -> [Step] {
        switch kind(type) {
        case .run: [.work(.init(kind: .work, goal: .init(_type: .distance, value: 5000), target: easyEffort))]
        case .strength: ["bodyweight-squat", "glute-bridge", "plank"].compactMap { id in ExerciseLibrary.all.first { $0.id == id } }.map { .exercise(ExerciseLibrary.step($0)) }
        case .custom, .rest: []
        }
    }

    static let easyEffort = Components.Schemas.StepTarget.effort(.init(_type: .effort, effort: .easy))

    /// Runs keep their steps when they change kind; going to or from strength, custom or rest starts afresh, as the
    /// server does (`applySessionUpdate`).
    mutating func setType(_ new: SessionType) {
        guard new != type else { return }
        if Self.kind(new) != Self.kind(type) { steps = Self.defaultSteps(for: new) }
        type = new
    }

    var isRun: Bool { Self.kind(type) == .run }
    var isStrength: Bool { type == .strength }
    var isCustom: Bool { type == .custom }

    // MARK: Steps

    mutating func addStep() {
        guard steps.count < Self.maxSteps else { return }
        if isStrength {
            steps.append(.exercise(ExerciseLibrary.step(ExerciseLibrary.all[0])))
        } else if isRun {
            steps.append(.work(.init(kind: .work, goal: .init(_type: .time, value: 600), target: Self.easyEffort)))
        }
    }

    mutating func addRepeat() {
        guard isRun, steps.count < Self.maxSteps else { return }
        steps.append(._repeat(.init(kind: ._repeat, count: 4, steps: [
            .init(kind: .work, goal: .init(_type: .distance, value: 400), target: .effort(.init(_type: .effort, effort: .hard))),
            .init(kind: .recovery, goal: .init(_type: .time, value: 120), target: Self.easyEffort),
        ])))
    }

    mutating func addStep(toRepeatAt index: Int) {
        guard steps.indices.contains(index), case ._repeat(var group) = steps[index], group.steps.count < Self.maxRepeatSteps else { return }
        group.steps.append(.init(kind: .recovery, goal: .init(_type: .time, value: 60), target: Self.easyEffort))
        steps[index] = ._repeat(group)
    }

    func repeatCount(at index: Int) -> Int? {
        guard steps.indices.contains(index), case ._repeat(let group) = steps[index] else { return nil }
        return group.count
    }

    mutating func changeCount(at index: Int, by delta: Int) {
        guard steps.indices.contains(index), case ._repeat(var group) = steps[index] else { return }
        group.count = min(max(group.count + delta, Self.repeatCounts.lowerBound), Self.repeatCounts.upperBound)
        steps[index] = ._repeat(group)
    }

    mutating func move(from: Int, to: Int) {
        guard steps.indices.contains(from), steps.indices.contains(to), from != to else { return }
        let step = steps.remove(at: from)
        steps.insert(step, at: to)
    }

    mutating func remove(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
    }

    /// Removes a step inside a repeat; the last one stays (a repeat holds at least one).
    mutating func removeChild(_ index: Int, at child: Int) {
        guard steps.indices.contains(index), case ._repeat(var group) = steps[index], group.steps.indices.contains(child), group.steps.count > 1 else { return }
        group.steps.remove(at: child)
        steps[index] = ._repeat(group)
    }

    mutating func moveChild(_ index: Int, from: Int, to: Int) {
        guard steps.indices.contains(index), case ._repeat(var group) = steps[index],
              group.steps.indices.contains(from), group.steps.indices.contains(to), from != to else { return }
        let step = group.steps.remove(at: from)
        group.steps.insert(step, at: to)
        steps[index] = ._repeat(group)
    }

    /// The run step at `index` (or inside the repeat at `index`), for the step editor.
    func runStep(_ index: Int, child: Int?) -> Components.Schemas.RunStep? {
        guard steps.indices.contains(index) else { return nil }
        switch (steps[index], child) {
        case (.warmup(let r), nil), (.work(let r), nil), (.recovery(let r), nil), (.cooldown(let r), nil): return r
        case (._repeat(let g), let c?) where g.steps.indices.contains(c): return g.steps[c]
        default: return nil
        }
    }

    mutating func setRunStep(_ index: Int, child: Int?, _ step: Components.Schemas.RunStep) {
        guard steps.indices.contains(index) else { return }
        if let child {
            guard case ._repeat(var group) = steps[index], group.steps.indices.contains(child) else { return }
            group.steps[child] = step
            steps[index] = ._repeat(group)
        } else {
            switch step.kind {
            case .warmup: steps[index] = .warmup(step)
            case .work: steps[index] = .work(step)
            case .recovery: steps[index] = .recovery(step)
            case .cooldown: steps[index] = .cooldown(step)
            }
        }
    }

    // MARK: Checks and totals

    /// What stops a save, in plain words. Empty when the session can be saved.
    var problems: [String] {
        var found: [String] = []
        if isRun && steps.isEmpty { found.append("Add at least one step.") }
        if isStrength && steps.isEmpty { found.append("Add at least one exercise.") }
        if isRun && !steps.allSatisfy(Self.hasGoalValues) { found.append("Give every step a time or distance, or make it open.") }
        if isCustom, let goal = custom.goal, goal._type != .open, (goal.value ?? 0) < 1 {
            found.append("Give the session a time or distance.")
        }
        if steps.count > Self.maxSteps { found.append("A session holds at most \(Self.maxSteps) steps.") }
        if title.trimmingCharacters(in: .whitespaces).count > 80 { found.append("Keep the title to 80 characters.") }
        return found
    }

    /// A time or distance goal needs a value of at least 1 (the API's minimum); an open goal has none.
    private static func hasGoalValues(_ step: Step) -> Bool {
        func ok(_ r: Components.Schemas.RunStep) -> Bool { r.goal._type == .open || (r.goal.value ?? 0) >= 1 }
        switch step {
        case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r): return ok(r)
        case ._repeat(let g): return g.steps.allSatisfy(ok)
        case .exercise: return true
        }
    }

    /// "Total ~44 min · ~6.9 km" for runs; nil otherwise.
    var totals: String? {
        guard isRun else { return nil }
        let s = content(owner: nil)
        let minutes = Int((SessionSummary.estimatedSeconds(s) / 60).rounded())
        let metres = PlanPreview.metres(of: s)
        let parts = [minutes > 0 ? "~\(minutes) min" : nil, metres > 0 ? "~\(PlanPreview.kilometres(metres / 1000)) km" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : "Total " + parts.joined(separator: " · ")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func content(owner: Components.Schemas.SessionContent.ownerPayload?) -> Components.Schemas.SessionContent {
        .init(
            date: date, _type: type, title: trimmedTitle.isEmpty ? nil : trimmedTitle, status: owner == nil ? nil : .planned, owner: owner,
            steps: isCustom ? nil : steps, custom: isCustom ? custom : nil, notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
    }

    // MARK: Requests

    /// Only the fields that changed; nil when nothing did. Steps are sent whole (`steps` replaces the list).
    func update(from original: Components.Schemas.SessionContent) -> Components.Schemas.SessionUpdate? {
        var update = Components.Schemas.SessionUpdate()
        var clear: [Components.Schemas.SessionUpdate.clearPayloadPayload] = []
        if date != original.date { update.date = date }
        if type != original._type { update._type = type }
        if trimmedTitle != (original.title ?? "") {
            if trimmedTitle.isEmpty { clear.append(.title) } else { update.title = trimmedTitle }
        }
        if trimmedNotes != (original.notes ?? "") {
            if trimmedNotes.isEmpty { clear.append(.notes) } else { update.notes = trimmedNotes }
        }
        if isCustom {
            if custom != original.custom || type != original._type { update.custom = custom }
        } else if steps != (original.steps ?? []) || Self.kind(type) != Self.kind(original._type) {
            update.steps = steps
        }
        if !clear.isEmpty { update.clear = clear }
        return update == Components.Schemas.SessionUpdate() ? nil : update
    }

    /// A new session: always the user's own.
    func create(id: String) -> Components.Schemas.SessionCreate {
        .init(value1: content(owner: .user), value2: .init(id: id))
    }
}
