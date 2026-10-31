import APIClient
import SwiftUI

/// One step of the editor: its kind, goal and target (a run step) or exercise, sets and reps (strength), plus moving
/// and removing it. Changes apply to the draft as they are made; Done closes the sheet.
struct StepEditorSheet: View {
    @Binding var draft: SessionDraft
    let path: SessionEditorView.StepPath
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let run = draft.runStep(path.index, child: path.child) {
                    RunStepFields(step: Binding(get: { run }, set: { draft.setRunStep(path.index, child: path.child, $0) }), inRepeat: path.child != nil)
                } else if path.child == nil, draft.steps.indices.contains(path.index), case .exercise(let e) = draft.steps[path.index] {
                    ExerciseFields(step: Binding(get: { e }, set: { draft.steps[path.index] = .exercise($0) }))
                }
                Section {
                    if canMove(by: -1) { Button("Move up") { move(by: -1) } }
                    if canMove(by: 1) { Button("Move down") { move(by: 1) } }
                    if canRemove {
                        Button("Remove step", role: .destructive) {
                            if let child = path.child { draft.removeChild(path.index, at: child) } else { draft.remove(at: path.index) }
                            onDone()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg.color.ignoresSafeArea())
            .navigationTitle("Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("step.done") }
            }
        }
        .tint(Palette.accentText.color)
        .preferredColorScheme(.dark)
    }

    private var siblings: Int {
        guard path.child != nil, draft.steps.indices.contains(path.index), case ._repeat(let g) = draft.steps[path.index] else { return draft.steps.count }
        return g.steps.count
    }

    private var position: Int { path.child ?? path.index }

    private func canMove(by delta: Int) -> Bool { (0..<siblings).contains(position + delta) }

    private var canRemove: Bool { path.child == nil || siblings > 1 }

    private func move(by delta: Int) {
        if let child = path.child { draft.moveChild(path.index, from: child, to: child + delta) } else { draft.move(from: path.index, to: path.index + delta) }
        onDone()
    }
}

private struct RunStepFields: View {
    @Binding var step: Components.Schemas.RunStep
    let inRepeat: Bool

    private enum TargetKind: String, CaseIterable { case none, effort, pace }

    private var targetKind: TargetKind {
        switch step.target {
        case .effort?: .effort
        case .pace?: .pace
        default: .none
        }
    }

    var body: some View {
        Section("Kind") {
            Picker("Kind", selection: $step.kind) {
                if !inRepeat { Text("Warm-up").tag(Components.Schemas.RunStep.kindPayload.warmup) }
                Text("Work").tag(Components.Schemas.RunStep.kindPayload.work)
                Text("Recovery").tag(Components.Schemas.RunStep.kindPayload.recovery)
                if !inRepeat { Text("Cool-down").tag(Components.Schemas.RunStep.kindPayload.cooldown) }
            }
            .pickerStyle(.segmented)
        }
        Section("Goal") {
            Picker("Goal", selection: Binding(get: { step.goal._type }, set: { setGoal($0) })) {
                Text("Time").tag(Components.Schemas.StepGoal._typePayload.time)
                Text("Distance").tag(Components.Schemas.StepGoal._typePayload.distance)
                Text("Open").tag(Components.Schemas.StepGoal._typePayload.open)
            }
            .pickerStyle(.segmented)
            if step.goal._type != .open { GoalValueField(goal: $step.goal) }
        }
        Section("Target") {
            Picker("Target", selection: Binding(get: { targetKind }, set: { setTarget($0) })) {
                Text("None").tag(TargetKind.none)
                Text("Effort").tag(TargetKind.effort)
                Text("Pace").tag(TargetKind.pace)
            }
            .pickerStyle(.segmented)
            switch step.target {
            case .effort(let e)?:
                Picker("Effort", selection: Binding(get: { e.effort }, set: { step.target = .effort(.init(_type: .effort, effort: $0)) })) {
                    Text("Easy").tag(Components.Schemas.Effort.easy)
                    Text("Moderate").tag(Components.Schemas.Effort.moderate)
                    Text("Hard").tag(Components.Schemas.Effort.hard)
                }
            case .pace(let p)?:
                PaceField(label: "Fastest", seconds: Binding(get: { p.range.minSecPerKm }, set: { setPace(min: $0, max: p.range.maxSecPerKm) }))
                PaceField(label: "Slowest", seconds: Binding(get: { p.range.maxSecPerKm }, set: { setPace(min: p.range.minSecPerKm, max: $0) }))
            default:
                EmptyView()
            }
        }
    }

    private func setGoal(_ type: Components.Schemas.StepGoal._typePayload) {
        switch type {
        case .open: step.goal = .init(_type: .open)
        case .time: step.goal = .init(_type: .time, value: 600)
        case .distance: step.goal = .init(_type: .distance, value: 1000)
        }
    }

    private func setTarget(_ kind: TargetKind) {
        switch kind {
        case .none: step.target = nil
        case .effort: step.target = .effort(.init(_type: .effort, effort: .easy))
        case .pace: step.target = .pace(.init(_type: .pace, range: .init(minSecPerKm: 360, maxSecPerKm: 400)))
        }
    }

    /// Keeps the faster end first, as the API requires.
    private func setPace(min a: Int, max b: Int) {
        step.target = .pace(.init(_type: .pace, range: .init(minSecPerKm: Swift.min(a, b), maxSecPerKm: Swift.max(a, b))))
    }
}

/// A pace per km on minute and second wheels, kept within 2:00 to 20:00. Writes only when a wheel moves.
private struct PaceField: View {
    let label: String
    @Binding var seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
            TwoWheelDial(
                firstLabel: "\(label) pace minutes", firstRange: Array(DialValues.paceMinutes),
                firstSelection: Binding(get: { DialValues.paceMinutes(seconds) }, set: { set(DialValues.pace(minutes: $0, seconds: DialValues.paceSecondsPart(seconds))) }),
                firstUnit: "min",
                secondLabel: "\(label) pace seconds", secondRange: Array(0...59),
                secondSelection: Binding(get: { DialValues.paceSecondsPart(seconds) }, set: { set(DialValues.pace(minutes: DialValues.paceMinutes(seconds), seconds: $0)) }),
                secondUnit: "sec /km", secondFormat: { String(format: "%02d", $0) },
                identifier: "pace.\(label.lowercased())")
        }
    }

    private func set(_ value: Int) { if value != seconds { seconds = value } }
}

private struct ExerciseFields: View {
    @Binding var step: Components.Schemas.ExerciseStep

    var body: some View {
        Section("Exercise") {
            Picker("Exercise", selection: Binding(get: { step.exerciseId }, set: { setExercise($0) })) {
                ForEach(ExerciseLibrary.all) { Text($0.name).tag($0.id) }
                if !ExerciseLibrary.all.contains(where: { $0.id == step.exerciseId }) { Text(step.exerciseId).tag(step.exerciseId) }
            }
            Stepper("Sets: \(step.sets)", value: $step.sets, in: 1...10)
            if let reps = step.reps {
                Stepper("Reps: \(reps)", value: Binding(get: { reps }, set: { step.reps = $0 }), in: 1...100)
            } else {
                Stepper("Hold: \(StepFormat.clock(step.durationSec ?? 30))", value: Binding(get: { step.durationSec ?? 30 }, set: { step.durationSec = $0 }), in: 5...600, step: 5)
            }
            Stepper("Rest: \(StepFormat.clock(step.restSec ?? 0))", value: Binding(get: { step.restSec ?? 0 }, set: { step.restSec = $0 }), in: 0...600, step: 15)
            Picker("Effort", selection: Binding(get: { step.effort ?? .easy }, set: { step.effort = $0 })) {
                Text("Easy").tag(Components.Schemas.Effort.easy)
                Text("Moderate").tag(Components.Schemas.Effort.moderate)
                Text("Hard").tag(Components.Schemas.Effort.hard)
            }
            TextField("Load note (optional)", text: Binding(get: { step.loadNote ?? "" }, set: { step.loadNote = $0.isEmpty ? nil : String($0.prefix(100)) }))
        }
    }

    /// A new exercise takes its usual reps or hold; sets, rest and effort stay.
    private func setExercise(_ id: String) {
        guard let exercise = ExerciseLibrary.all.first(where: { $0.id == id }) else { return }
        step.exerciseId = id
        step.reps = exercise.reps
        step.durationSec = exercise.holdSec
    }
}
