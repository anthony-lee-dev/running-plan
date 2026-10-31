import APIClient
import Foundation

/// The curated strength library's names, mirroring `EXERCISES` in `api/src/domain/strength.ts` (keep the two in step).
enum ExerciseLibrary {
    struct Exercise: Equatable, Identifiable {
        let id: String
        let name: String
        /// Reps per set, or a hold in seconds.
        let reps: Int?
        let holdSec: Int?
    }

    static let all: [Exercise] = [
        .init(id: "bodyweight-squat", name: "Bodyweight squat", reps: 12, holdSec: nil),
        .init(id: "reverse-lunge", name: "Reverse lunge", reps: 10, holdSec: nil),
        .init(id: "glute-bridge", name: "Glute bridge", reps: 12, holdSec: nil),
        .init(id: "step-up", name: "Step-up", reps: 10, holdSec: nil),
        .init(id: "calf-raise", name: "Single-leg calf raise", reps: 12, holdSec: nil),
        .init(id: "bird-dog", name: "Bird dog", reps: 10, holdSec: nil),
        .init(id: "plank", name: "Plank", reps: nil, holdSec: 30),
        .init(id: "side-plank", name: "Side plank", reps: nil, holdSec: 25),
        .init(id: "goblet-squat", name: "Goblet squat", reps: 12, holdSec: nil),
        .init(id: "dumbbell-rdl", name: "Dumbbell Romanian deadlift", reps: 12, holdSec: nil),
        .init(id: "split-squat", name: "Dumbbell split squat", reps: 10, holdSec: nil),
        .init(id: "dumbbell-calf-raise", name: "Dumbbell calf raise", reps: 15, holdSec: nil),
        .init(id: "farmer-carry", name: "Farmer carry", reps: nil, holdSec: 40),
    ]

    /// The exercise's name; an id the app does not know (a newer server) shows as itself.
    static func name(_ id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    /// A new exercise step for the library entry: three sets of its usual reps or hold, 45 s rest, easy.
    static func step(_ exercise: Exercise) -> Components.Schemas.ExerciseStep {
        .init(kind: .exercise, exerciseId: exercise.id, sets: 3, reps: exercise.reps, durationSec: exercise.holdSec, restSec: 45, effort: .easy)
    }
}

/// Steps in the formats a watch workout builder uses: durations as `m:ss`, distances in metres or km, paces as
/// `5:15–5:30/km`.
enum StepFormat {
    /// `10:00`, `2:05`, `1:02:05`.
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return "\(s / 3600):" + String(format: "%02d:%02d", s % 3600 / 60, s % 60) }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// `600 m`, `5 km`, `1.25 km`.
    static func distance(_ metres: Int) -> String {
        if metres < 1000 { return "\(metres) m" }
        let km = Double(metres) / 1000
        var text = String(format: "%.2f", km)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) km"
    }

    static func goal(_ goal: Components.Schemas.StepGoal) -> String {
        switch goal._type {
        case .time: clock(goal.value ?? 0)
        case .distance: distance(goal.value ?? 0)
        case .open: "Open"
        }
    }

    /// What the board calls each step: the work step is named for the session (fast reps, tempo, easy running).
    static func title(_ kind: Components.Schemas.RunStep.kindPayload, in type: Components.Schemas.SessionType) -> String {
        switch kind {
        case .warmup: "Warm-up"
        case .cooldown: "Cool-down"
        case .recovery: "Easy jog"
        case .work:
            switch type {
            case .intervals: "Fast"
            case .tempo: "Tempo"
            case .long: "Long run"
            default: "Easy run"
            }
        }
    }

    static func effortWord(_ effort: Components.Schemas.Effort) -> String {
        switch effort {
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .hard: "Hard"
        }
    }

    /// The target line: `Pace 5:15–5:30/km`, `Easy effort · 6:25–7:10/km`, `Recover, no pace target`.
    static func target(_ target: Components.Schemas.StepTarget?, kind: Components.Schemas.RunStep.kindPayload) -> String {
        switch target {
        case .pace(let p)?:
            let range = PaceFormat.range(min: p.range.minSecPerKm, max: p.range.maxSecPerKm)
            return kind == .work ? "Pace \(range)" : "Easy effort · \(range)"
        case .heart_rate(let hr)?:
            return "Heart rate \(hr.range.minBpm)–\(hr.range.maxBpm) bpm"
        case .effort(let e)?:
            return kind == .recovery ? "Recover, no pace target" : "\(effortWord(e.effort)) effort"
        default: // no target
            return kind == .recovery ? "Recover, no pace target" : "No target"
        }
    }

}
