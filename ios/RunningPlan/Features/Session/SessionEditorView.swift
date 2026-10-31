import APIClient
import SwiftUI

/// DK-Editor: title, type, the watch steps (repeats with a − / + stepper), notes. Save sends only what changed; saving
/// marks the session as the user's. Steps open a small editor for their goal and target, where they also move up or
/// down and are removed (the board's drag handle becomes Move up / Move down there, and VoiceOver actions).
struct SessionEditorView: View {
    enum Mode: Equatable {
        case edit
        case create
    }

    let mode: Mode
    /// The plan's dates the session may move to, first and last.
    let span: ClosedRange<String>
    /// Validator notices about this session, from the plan's current warnings.
    var headsUp: [String] = []
    let onCancel: () -> Void
    /// Returns a sentence when the save failed.
    let onSave: (SessionDraft) async -> String?
    var onDelete: (() async -> String?)?

    @State var draft: SessionDraft
    @State private var editing: StepPath?
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    struct StepPath: Identifiable, Hashable {
        let index: Int
        let child: Int?
        var id: String { "\(index).\(child ?? -1)" }
    }

    private static let types: [(Components.Schemas.SessionType, String)] = [
        (.easy, "Easy"), (.long, "Long"), (.intervals, "Intervals"), (.tempo, "Tempo"), (.strength, "Strength"), (.custom, "Custom"), (.rest, "Rest"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Title") {
                        TextField("", text: $draft.title, prompt: Text("Name this session").foregroundStyle(Palette.muted.color))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink.color)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.goalTrack.color, lineWidth: 1))
                            .accessibilityIdentifier("editor.title")
                    }
                    field("Type") { typeChips }
                    field("Day") { dayPicker }
                    if draft.isCustom {
                        CustomFields(custom: $draft.custom)
                    } else if draft.isRun || draft.isStrength {
                        stepsSection
                    }
                    if !headsUp.isEmpty { headsUpCard }
                    field("Notes") {
                        TextField("", text: $draft.notes, prompt: Text("Anything to remember on the day").foregroundStyle(Palette.muted.color), axis: .vertical)
                            .lineLimit(2...6)
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.ink.color)
                            .padding(16)
                            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.goalTrack.color, lineWidth: 1))
                            .accessibilityIdentifier("editor.notes")
                    }
                    ForEach(draft.problems, id: \.self) { problem in
                        Text(problem).font(.system(size: 14)).foregroundStyle(Palette.accentText.color)
                    }
                    if let error {
                        Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("editor.error")
                    }
                    Text("Saving marks this session as yours. Suggested changes will leave it alone.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                    if onDelete != nil {
                        Button("Delete session", role: .destructive) { confirmDelete = true }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.accentText.color)
                            .frame(minHeight: Metrics.minTouchTarget)
                            .accessibilityIdentifier("editor.delete")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .sheet(item: $editing) { path in
            StepEditorSheet(draft: $draft, path: path, onDone: { editing = nil })
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) { Task { await delete() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.editor")
    }

    private var topBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.system(size: 17))
                .foregroundStyle(Palette.muted.color)
                .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
            Spacer()
            Text(mode == .edit ? "Edit session" : "Add a session")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                Task { await save() }
            } label: {
                if saving {
                    ProgressView().tint(Palette.accentText.color)
                } else {
                    Text("Save").font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Palette.accentText.color)
            .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
            .disabled(saving || !draft.problems.isEmpty)
            .opacity(draft.problems.isEmpty ? 1 : 0.4)
            .accessibilityIdentifier("editor.save")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted.color)
            content()
        }
    }

    private var typeChips: some View {
        FlowRows(spacing: 10) {
            ForEach(Self.types, id: \.0) { type, title in
                let selected = draft.type == type
                Button { draft.setType(type) } label: {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink.color)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(selected ? Palette.accentSoft.color : Palette.card.color, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? Palette.accentBorder.color : Palette.goalTrack.color, lineWidth: selected ? 2 : 1))
                        .contentShape(Capsule())
                }
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var dayPicker: some View {
        DatePicker(
            "Day",
            selection: Binding(get: { Self.date(draft.date) }, set: { draft.date = Self.string($0) }),
            in: Self.date(span.lowerBound)...Self.date(span.upperBound),
            displayedComponents: .date
        )
        .labelsHidden()
        .tint(Palette.accentText.color)
        .accessibilityLabel("Day")
    }

    /// The picker works in the device's calendar: a local date is noon on that day there, and reads back the same way.
    static func date(_ text: String) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) ?? Date()
    }

    static func string(_ date: Date) -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 1970, p.month ?? 1, p.day ?? 1)
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.isStrength ? "Exercises" : "Steps").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted.color)
                Spacer()
                if let totals = draft.totals {
                    Text(totals).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.muted.color)
                }
            }
            ForEach(Array(draft.steps.enumerated()), id: \.offset) { index, step in
                stepView(step, at: index)
            }
            HStack(spacing: 10) {
                dashed(draft.isStrength ? "+ Add exercise" : "+ Add step", id: "editor.addStep") { draft.addStep() }
                if draft.isRun { dashed("+ Add repeat", id: "editor.addRepeat") { draft.addRepeat() } }
            }
        }
    }

    @ViewBuilder private func stepView(_ step: Components.Schemas.Step, at index: Int) -> some View {
        switch step {
        case ._repeat(let group):
            VStack(spacing: 8) {
                HStack {
                    Text("Repeat").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Spacer()
                    HStack(spacing: 0) {
                        stepperButton("minus", label: "Fewer repeats", enabled: group.count > SessionDraft.repeatCounts.lowerBound) { draft.changeCount(at: index, by: -1) }
                        Text("\(group.count)×").font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                            .frame(minWidth: 40)
                            .accessibilityLabel("\(group.count) repeats")
                        stepperButton("plus", label: "More repeats", enabled: group.count < SessionDraft.repeatCounts.upperBound) { draft.changeCount(at: index, by: 1) }
                    }
                    .background(Palette.goalCard.color, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.leading, 6)
                .accessibilityElement(children: .contain)
                .accessibilityActions { moveActions(index) }
                ForEach(Array(group.steps.enumerated()), id: \.offset) { child, run in
                    runRow(run, path: StepPath(index: index, child: child))
                }
                if group.steps.count < SessionDraft.maxRepeatSteps {
                    Button("+ Add step to repeat") { draft.addStep(toRepeatAt: index) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accentText.color)
                        .frame(minHeight: Metrics.minTouchTarget)
                }
                Button("Remove repeat") { draft.remove(at: index) }
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted.color)
                    .frame(minHeight: Metrics.minTouchTarget)
            }
            .padding(10)
            .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 22))
        case .exercise(let e):
            row(title: ExerciseLibrary.name(e.exerciseId), detail: SessionSheetModel.exerciseDetail(e), value: "\(e.sets)×", path: StepPath(index: index, child: nil))
        case .warmup(let r), .work(let r), .recovery(let r), .cooldown(let r):
            runRow(r, path: StepPath(index: index, child: nil))
        }
    }

    private func runRow(_ r: Components.Schemas.RunStep, path: StepPath) -> some View {
        row(title: StepFormat.title(r.kind, in: draft.type), detail: StepFormat.target(r.target, kind: r.kind), value: StepFormat.goal(r.goal), path: path)
    }

    private func row(title: String, detail: String, value: String, path: StepPath) -> some View {
        Button { editing = path } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.ink.color)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Palette.goalCard.color, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(PaceFormat.spoken(detail))")
        .accessibilityHint("Edit this step")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions { if path.child == nil { moveActions(path.index) } }
    }

    @ViewBuilder private func moveActions(_ index: Int) -> some View {
        if index > 0 { Button("Move up") { draft.move(from: index, to: index - 1) } }
        if index < draft.steps.count - 1 { Button("Move down") { draft.move(from: index, to: index + 1) } }
    }

    private func stepperButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink.color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private func dashed(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink.color)
                .frame(maxWidth: .infinity, minHeight: 50)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.restBorder.color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
        }
        .disabled(draft.steps.count >= SessionDraft.maxSteps)
        .accessibilityIdentifier(id)
    }

    private var headsUpCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heads up").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.amberTitle.color)
            ForEach(headsUp, id: \.self) { line in
                Text(line).font(.system(size: 15)).foregroundStyle(Palette.amberText.color)
            }
            Text("You can still save any change.").font(.system(size: 15)).foregroundStyle(Palette.amberText.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amberSoft.color, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func save() async {
        saving = true
        error = nil
        error = await onSave(draft)
        saving = false
    }

    private func delete() async {
        guard let onDelete else { return }
        saving = true
        error = await onDelete()
        saving = false
    }
}

/// A custom (cross-training) session: activity, a time or distance goal, and an effort level (design §5).
private struct CustomFields: View {
    @Binding var custom: Components.Schemas.CustomDetails

    private var goalType: Components.Schemas.StepGoal._typePayload { custom.goal?._type ?? .open }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted.color)
            TextField("", text: Binding(get: { custom.activityLabel ?? "" }, set: { custom.activityLabel = $0.isEmpty ? nil : String($0.prefix(40)) }),
                      prompt: Text("Cycling, swimming…").foregroundStyle(Palette.muted.color))
                .font(.system(size: 16))
                .foregroundStyle(Palette.ink.color)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Activity")
            Picker("Goal", selection: Binding(get: { goalType }, set: { setGoalType($0) })) {
                Text("Time").tag(Components.Schemas.StepGoal._typePayload.time)
                Text("Distance").tag(Components.Schemas.StepGoal._typePayload.distance)
                Text("Open").tag(Components.Schemas.StepGoal._typePayload.open)
            }
            .pickerStyle(.segmented)
            if goalType != .open {
                GoalValueField(goal: Binding(get: { custom.goal ?? .init(_type: .open) }, set: { custom.goal = $0 }))
            }
            Picker("Effort", selection: Binding(get: { custom.effort ?? .easy }, set: { custom.effort = $0 })) {
                Text("Easy").tag(Components.Schemas.Effort.easy)
                Text("Moderate").tag(Components.Schemas.Effort.moderate)
                Text("Hard").tag(Components.Schemas.Effort.hard)
            }
            .pickerStyle(.segmented)
        }
    }

    private func setGoalType(_ type: Components.Schemas.StepGoal._typePayload) {
        switch type {
        case .open: custom.goal = .init(_type: .open)
        case .time: custom.goal = .init(_type: .time, value: 1800)
        case .distance: custom.goal = .init(_type: .distance, value: 10000)
        }
    }
}

/// A time (minute and second wheels) or distance (whole-km and hundredths wheels) dial for a goal. It reads the goal
/// directly and writes only when a wheel moves, so opening a step never changes it.
struct GoalValueField: View {
    @Binding var goal: Components.Schemas.StepGoal

    var body: some View {
        Group {
            switch goal._type {
            case .time:
                TwoWheelDial(
                    firstLabel: "Minutes", firstRange: Array(0...DialValues.maxMinutes),
                    firstSelection: Binding(get: { DialValues.minutes(value) }, set: { set(DialValues.time(minutes: $0, seconds: DialValues.secondsPart(value))) }),
                    firstUnit: "min",
                    secondLabel: "Seconds", secondRange: Array(0...59),
                    secondSelection: Binding(get: { DialValues.secondsPart(value) }, set: { set(DialValues.time(minutes: DialValues.minutes(value), seconds: $0)) }),
                    secondUnit: "sec", secondFormat: { String(format: "%02d", $0) },
                    identifier: "goal.time")
            case .distance:
                TwoWheelDial(
                    firstLabel: "Kilometres", firstRange: Array(0...DialValues.maxKm),
                    firstSelection: Binding(get: { DialValues.km(value) }, set: { set(DialValues.distance(km: $0, keepingFractionOf: value)) }),
                    firstUnit: "",
                    secondLabel: "Fraction of a kilometre", secondRange: Array(0...99),
                    secondSelection: Binding(get: { DialValues.hundredths(value) }, set: { set(DialValues.distance(hundredths: $0, keepingKmOf: value)) }),
                    secondUnit: "km", secondFormat: { String(format: ".%02d", $0) },
                    identifier: "goal.distance")
            case .open:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
    }

    private var value: Int { goal.value ?? 0 }

    private func set(_ value: Int) {
        if value != goal.value { goal = .init(_type: goal._type, value: value) }
    }
}

/// Lays chips out in rows that wrap, like the board's type chips.
struct FlowRows: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
