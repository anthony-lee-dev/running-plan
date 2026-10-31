import APIClient
import Foundation

/// Everything DK-Session shows for one saved session: a spec sheet for entering the workout on a watch (design §8.4).
struct SessionSheetModel: Equatable {
    struct StepRow: Equatable {
        let number: Int
        let title: String
        let target: String
        let value: String
        let intensity: SessionSummary.Intensity
    }

    enum Row: Equatable {
        case step(StepRow)
        case repeatGroup(count: Int, steps: [StepRow])
    }

    struct Exercise: Equatable {
        let name: String
        let detail: String
    }

    let id: String
    let revision: Int
    let eyebrow: String
    let title: String
    let time: String?
    let distance: String?
    let effort: String
    let shape: [SessionSummary.Segment]
    let why: String
    /// Watch steps in builder order, repeats grouped. Empty for strength and rest.
    let rows: [Row]
    /// The strength checklist.
    let exercises: [Exercise]
    let notes: String?
    let isYours: Bool
    let isSkipped: Bool
    let isDone: Bool
    let isRest: Bool
    /// The back link: "Today" for today's session, else "Week".
    let backLabel: String
    /// The whole workout as text, for another watch's workout builder.
    let text: String

    init(schedule: PlanSchedule, session: Components.Schemas.Session) {
        let s = session.value2
        id = session.value1.id
        revision = session.value1.revision
        let week = schedule.week(of: s.date)
        eyebrow = "\(NextModel.weekday(s.date)), \(PlanPreview.shortDate(s.date))" + (week >= 0 ? " · Week \(week + 1)" : "")
        title = s.title ?? SessionSummary.effort(s)
        effort = SessionSummary.effort(s)
        shape = SessionSummary.shape(s)
        why = SessionSummary.why(s)
        notes = s.notes.flatMap { $0.isEmpty ? nil : $0 }
        isYours = s.owner == .user
        isSkipped = s.status == .skipped
        isDone = s.status == .done
        isRest = s._type == .rest
        backLabel = s.date == schedule.today ? "Today" : "Week"

        switch s._type {
        case .rest:
            time = nil
        case .custom:
            time = s.custom?.goal.flatMap { $0._type == .time ? $0.value : nil }.map { "~\(Int((Double($0) / 60).rounded())) min" }
        case .strength:
            time = "~\(max(5, Int((PlanPreview.seconds(of: s) / 300).rounded()) * 5)) min"
        case .easy, .long, .tempo, .intervals:
            let minutes = Int((SessionSummary.estimatedSeconds(s) / 60).rounded())
            time = minutes > 0 ? "~\(minutes) min" : nil
        }
        let metres = s._type == .custom ? Double(s.custom?.goal?._type == .distance ? s.custom?.goal?.value ?? 0 : 0) : PlanPreview.metres(of: s)
        distance = metres > 0 ? "~\(PlanPreview.kilometres(metres / 1000)) km" : nil

        rows = Self.rows(s)
        exercises = (s.steps ?? []).compactMap { step in
            guard case .exercise(let e) = step else { return nil }
            return Exercise(name: ExerciseLibrary.name(e.exerciseId), detail: Self.exerciseDetail(e))
        }
        text = Self.text(title: title, eyebrow: eyebrow, rows: rows, exercises: exercises, notes: notes)
    }

    /// `3 × 12 · rest 0:45 · easy`, `4 × 0:30 · light dumbbells`.
    static func exerciseDetail(_ e: Components.Schemas.ExerciseStep) -> String {
        var parts = ["\(e.sets) × " + (e.reps.map(String.init) ?? e.durationSec.map(StepFormat.clock) ?? "")]
        if let rest = e.restSec, rest > 0 { parts.append("rest \(StepFormat.clock(rest))") }
        if let effort = e.effort { parts.append(effort.rawValue) }
        if let note = e.loadNote, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    static func intensity(_ kind: Components.Schemas.RunStep.kindPayload, in type: Components.Schemas.SessionType) -> SessionSummary.Intensity {
        switch kind {
        case .warmup, .cooldown: .easy
        case .recovery: .recovery
        case .work: type == .intervals ? .hard : type == .tempo ? .steady : .easy
        }
    }

    private static func rows(_ s: Components.Schemas.SessionContent) -> [Row] {
        if s._type == .custom, let custom = s.custom {
            let label = custom.activityLabel.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? s.title ?? "Your session"
            let target = custom.effort.map { "\(StepFormat.effortWord($0)) effort" } ?? "Your own pace"
            return [.step(StepRow(number: 1, title: label, target: target, value: custom.goal.map(StepFormat.goal) ?? "Open", intensity: custom.effort == .hard ? .hard : .easy))]
        }
        var number = 0
        func row(_ step: Components.Schemas.RunStep) -> StepRow {
            number += 1
            return StepRow(
                number: number, title: StepFormat.title(step.kind, in: s._type), target: StepFormat.target(step.target, kind: step.kind),
                value: StepFormat.goal(step.goal), intensity: intensity(step.kind, in: s._type)
            )
        }
        return (s.steps ?? []).compactMap { step in
            switch step {
            case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r): .step(row(r))
            case ._repeat(let group): .repeatGroup(count: group.count, steps: group.steps.map(row))
            case .exercise: nil
            }
        }
    }

    private static func text(title: String, eyebrow: String, rows: [Row], exercises: [Exercise], notes: String?) -> String {
        func line(_ r: StepRow) -> String {
            "\(r.number). \(r.title): \(r.value), \(r.target.prefix(1).lowercased() + r.target.dropFirst())"
        }
        var lines = [title, eyebrow, ""]
        for row in rows {
            switch row {
            case .step(let r): lines.append(line(r))
            case .repeatGroup(let count, let steps):
                lines.append("Repeat \(count)×:")
                lines += steps.map { "  " + line($0) }
            }
        }
        lines += exercises.map { "☐ \($0.name): \($0.detail)" }
        if let notes { lines += ["", "Notes: \(notes)"] }
        return lines.joined(separator: "\n")
    }
}
