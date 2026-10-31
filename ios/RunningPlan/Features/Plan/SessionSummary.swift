import APIClient
import Foundation

/// How a saved session reads on the plan screens: its detail line, effort chip, why, and workout shape.
enum SessionSummary {
    typealias Content = Components.Schemas.SessionContent

    enum Intensity: Equatable {
        case easy, steady, hard, recovery
    }

    /// One step of the workout shape: how hard, and for how long (bars are as wide as their time).
    struct Segment: Equatable {
        let intensity: Intensity
        let seconds: Double
    }

    /// "About 43 min · 6.9 km · fast reps at 5:15–5:30/km", "20 min · strength", "45 min · easy effort".
    static func detail(_ s: Content, withTime: Bool = true) -> String {
        switch s._type {
        case .rest:
            return "Protected. Recovery is part of the plan."
        case .custom:
            let minutes = Int((Double(s.custom?.goal?._type == .time ? s.custom?.goal?.value ?? 0 : 0) / 60).rounded())
            let effort = s.custom?.effort.map { "\($0.rawValue) effort" }
            return [minutes > 0 ? "\(minutes) min" : nil, effort].compactMap { $0 }.joined(separator: " · ")
        case .strength:
            let minutes = max(5, Int((PlanPreview.seconds(of: s) / 300).rounded()) * 5)
            return "\(minutes) min · strength"
        case .easy, .long, .tempo, .intervals:
            var parts: [String] = []
            let minutes = Int((estimatedSeconds(s) / 60).rounded())
            if withTime, minutes > 0 { parts.append("About \(minutes) min") }
            let metres = PlanPreview.metres(of: s)
            if metres > 0 { parts.append("\(PlanPreview.kilometres(metres / 1000)) km") }
            if let target = workTarget(s) {
                parts.append(s._type == .intervals ? "fast reps at \(target)" : target)
            }
            return parts.joined(separator: " · ")
        }
    }

    static func effort(_ s: Content) -> String {
        switch s._type {
        case .intervals: "Hard but controlled"
        case .tempo: "Comfortably hard"
        case .long: "Long and steady"
        case .easy: "Easy"
        case .strength: "Strength"
        case .custom: "Your own"
        case .rest: "Rest"
        }
    }

    static func why(_ s: Content) -> String {
        switch s._type {
        case .intervals: "Why: short fast reps with easy jogs build speed without much strain."
        case .tempo: "Why: comfortably hard running teaches you to hold your pace."
        case .long: "Why: a long, steady run builds the endurance you race on."
        case .strength: "Why: a few minutes of strength keeps your legs and core ready for the running."
        case .custom: "Why: easy cross-training adds fitness without more pounding."
        case .rest: "Why: recovery is when the training sinks in."
        case .easy: "Why: easy miles build your base without strain."
        }
    }

    /// Time for the whole session: time goals as set, distances at the step's pace (the middle of its range), or at
    /// the validators' fallback pace when the step has none.
    static func estimatedSeconds(_ s: Content) -> Double {
        let run = (s.steps ?? []).flatMap(runSteps).reduce(0) { $0 + seconds($1) }
        return run > 0 ? run : PlanPreview.seconds(of: s)
    }

    /// The run's steps in order (repeats spelled out). Empty for strength, rest and cross-training.
    static func shape(_ s: Content) -> [Segment] {
        guard [.easy, .long, .tempo, .intervals].contains(s._type) else { return [] }
        return (s.steps ?? []).flatMap(runSteps).map { step in
            let intensity: Intensity
            switch step.kind {
            case .warmup, .cooldown: intensity = .easy
            case .recovery: intensity = .recovery
            case .work: intensity = s._type == .intervals ? .hard : s._type == .tempo ? .steady : .easy
            }
            return Segment(intensity: intensity, seconds: seconds(step))
        }
    }

    // MARK: Steps

    private static func runSteps(_ step: Components.Schemas.Step) -> [Components.Schemas.RunStep] {
        switch step {
        case .warmup(let s), .work(let s), .recovery(let s), .cooldown(let s): [s]
        case ._repeat(let r): Array(repeating: r.steps, count: r.count).flatMap { $0 }
        case .exercise: []
        }
    }

    private static func seconds(_ step: Components.Schemas.RunStep) -> Double {
        let value = Double(step.goal.value ?? 0)
        switch step.goal._type {
        case .time: return value
        case .open: return 0
        case .distance:
            if case .pace(let pace)? = step.target {
                return value / 1000 * Double(pace.range.minSecPerKm + pace.range.maxSecPerKm) / 2
            }
            return value / 1000 * PlanPreview.fallbackSecondsPerKm
        }
    }

    /// The main work step's target: a pace range or a heart-rate range.
    private static func workTarget(_ s: Content) -> String? {
        let work = (s.steps ?? []).flatMap(runSteps).first { $0.kind == .work && $0.target != nil }
        switch work?.target {
        case .pace(let p)?: return PaceFormat.range(min: p.range.minSecPerKm, max: p.range.maxSecPerKm)
        case .heart_rate(let hr)?: return "\(hr.range.minBpm)–\(hr.range.maxBpm) bpm"
        default: return nil
        }
    }
}
