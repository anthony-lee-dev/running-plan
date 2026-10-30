import SwiftUI

/// The interview, one question per screen (DK-Interview). Fonts are the system ones until the screen-font task.
struct InterviewView: View {
    @State private var flow: InterviewFlow
    let onFinish: (InterviewAnswers, _ blankPlan: Bool) -> Void
    let onClose: () -> Void

    @MainActor
    init(
        flow: InterviewFlow? = nil,
        onFinish: @escaping (InterviewAnswers, _ blankPlan: Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        _flow = State(initialValue: flow ?? InterviewFlow())
        self.onFinish = onFinish
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(flow.question.title)
                            .font(.system(size: 34, weight: .bold))
                            .tracking(-0.7)
                            .foregroundStyle(Palette.ink.color)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("screen.interview")
                        Text(flow.question.subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.muted.color)
                    }
                    .padding(.top, 8)
                    answerArea
                    Text("Your answers stay on this phone until you choose to save your plan. No account needed yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted.color)
                }
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: flow.isFinished) { _, finished in
            if finished { onFinish(flow.answers, flow.wantsBlankPlan) }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if flow.canGoBack { flow.back() } else { onClose() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: Metrics.minTouchTarget, height: Metrics.minTouchTarget)
            }
            .foregroundStyle(Palette.ink.color)
            .accessibilityLabel("Back")
            .padding(.leading, -10)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: flow.progress)
                    .tint(Palette.accentBorder.color)
                    .accessibilityHidden(true)
                Text(flow.progressLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted.color)
            }

            Button("Skip") { flow.skip() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.muted.color)
                .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                flow.next()
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
            .disabled(!flow.canContinue)
            .opacity(flow.canContinue ? 1 : 0.4)

            Button("I'd rather build my own plan") { flow.buildOwnPlan() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.muted.color)
                .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    // MARK: Answers

    @ViewBuilder private var answerArea: some View {
        switch flow.question {
        case .goalDistance:
            VStack(spacing: 12) {
                ForEach(GoalDistance.allCases) { distance in
                    OptionCard(
                        big: distance.shortLabel, title: distance.title, detail: distance.typicalWeeks,
                        selected: flow.isAnswered(.goalDistance) && flow.answers.goal.distance == distance
                    ) { flow.setDistance(distance) }
                }
            }
        case .goalDateAndTime:
            GoalDateAndTimeInput(flow: flow)
        case .recentResult:
            VStack(spacing: 12) {
                ForEach(GoalDistance.allCases) { distance in
                    OptionCard(
                        big: nil, title: distance == .halfMarathon ? "Half marathon" : distance.shortLabel, detail: nil,
                        selected: flow.recentDistance == distance
                    ) { flow.setRecentResult(distance: distance) }
                }
                NumberInput(label: "Time", unit: "min", value: flow.recentMinutes, start: 30, range: 2...480) {
                    flow.setRecentResult(minutes: $0)
                }
            }
        case .weeklyDistance:
            NumberInput(label: "Per week", unit: "km", value: flow.answers.weeklyDistanceM.map { $0 / 1000 }, start: 20, range: 0...200) {
                flow.setWeeklyKm($0)
            }
        case .longestRun:
            NumberInput(label: "Longest run", unit: "km", value: flow.answers.longestRunM.map { $0 / 1000 }, start: 8, range: 0...50) {
                flow.setLongestRunKm($0)
            }
        case .history:
            choices(RunningHistory.allCases, title: \.title, selected: flow.answers.runningHistory) { flow.setHistory($0) }
        case .runsAndDays:
            RunsAndDaysInput(flow: flow)
        case .longRunDay:
            WeekdayGrid(selected: flow.answers.longRunDay.map { [$0] } ?? []) { flow.setLongRunDay($0) }
        case .pain:
            VStack(spacing: 12) {
                OptionCard(big: nil, title: "No", detail: nil, selected: flow.answers.pain == false) { flow.setPain(false) }
                OptionCard(big: nil, title: "Yes", detail: "We'll pick the cautious plan", selected: flow.answers.pain == true) {
                    flow.setPain(true)
                }
            }
        case .strength:
            choices(StrengthChoice.allCases, title: \.title, selected: flow.answers.strength.map {
                $0.enabled ? StrengthChoice(rawValue: $0.equipment ?? "") : StrengthChoice.none
            } ?? nil) { flow.setStrength($0) }
        case .targetDisplay:
            choices(TargetDisplay.allCases, title: \.title, selected: flow.answers.targetDisplay) { flow.setTargetDisplay($0) }
        case .heartRate:
            NumberInput(label: "Max heart rate", unit: "bpm", value: flow.answers.heartRate?.maxBpm, start: 180, range: 100...230) {
                flow.setMaxHeartRate($0)
            }
        }
    }

    private func choices<T: Identifiable & Equatable>(
        _ options: [T], title: KeyPath<T, String>, selected: T?, pick: @escaping (T) -> Void
    ) -> some View {
        VStack(spacing: 12) {
            ForEach(options) { option in
                OptionCard(big: nil, title: option[keyPath: title], detail: nil, selected: option == selected) { pick(option) }
            }
        }
    }
}

// MARK: - Components

/// Option card from docs/design-notes.md: `card` fill, 2 pt `line` border, 76 pt tall; selected uses `accent-soft`.
struct OptionCard: View {
    let big: String?
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if let big {
                    Text(big)
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 76, alignment: .leading)
                        .foregroundStyle(Palette.ink.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    if let detail {
                        Text(detail).font(.system(size: 13))
                            .foregroundStyle(selected ? Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0xA6 / 255) : Palette.muted.color)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.accentText.color)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(selected ? Palette.accentSoft.color : Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? Palette.accentBorder.color : Palette.line.color, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(big ?? title)
        .accessibilityLabel([big, title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A stepper that starts empty: the user opts in with "Start at", so a suggested number is never taken as an answer.
struct NumberInput: View {
    let label: String
    let unit: String
    let value: Int?
    let start: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        Group {
            if let value {
                Stepper(value: Binding(get: { value }, set: { onChange($0) }), in: range) { amount(String(value)) }
            } else {
                HStack {
                    amount("—")
                    Spacer()
                    Button("Start at \(start)") { onChange(start) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accentText.color)
                        .frame(minHeight: Metrics.minTouchTarget)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 76)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line.color, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(value.map { "\(label), \($0) \(unit)" } ?? "\(label), not set")
    }

    private func amount(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text(unit).font(.system(size: 16)).foregroundStyle(Palette.muted.color)
        }
        .foregroundStyle(Palette.ink.color)
    }
}

struct WeekdayGrid: View {
    let selected: [Weekday]
    let toggle: (Weekday) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Weekday.allCases) { day in
                let on = selected.contains(day)
                Button { toggle(day) } label: {
                    Text(day.title)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
                        .foregroundStyle(Palette.ink.color)
                        .background(on ? Palette.accentSoft.color : Palette.card.color, in: Capsule())
                        .overlay(Capsule().stroke(on ? Palette.accentText.color : Palette.line.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct RunsAndDaysInput: View {
    let flow: InterviewFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(3...5, id: \.self) { runs in
                    let on = flow.answers.runsPerWeek == runs
                    Button("\(runs)") { flow.setRunsPerWeek(runs) }
                        .font(.system(size: 22, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Palette.ink.color)
                        .background(on ? Palette.accentSoft.color : Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Palette.accentText.color : Palette.line.color, lineWidth: 2))
                        .accessibilityLabel("\(runs) runs a week")
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("Days you can't run (up to \(InterviewFlow.maxUnavailableDays))")
                .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            WeekdayGrid(selected: flow.answers.unavailableDays ?? []) { flow.toggleUnavailable($0) }
        }
    }
}

struct GoalDateAndTimeInput: View {
    let flow: InterviewFlow
    @State private var date: Date

    init(flow: InterviewFlow) {
        self.flow = flow
        let stored = flow.answers.goal.date.flatMap { Self.parse($0) }
        _date = State(initialValue: stored ?? Calendar.current.date(byAdding: .weekOfYear, value: 12, to: .now) ?? .now)
    }

    var body: some View {
        VStack(spacing: 12) {
            Toggle("I have a goal date", isOn: Binding(
                get: { flow.answers.goal.date != nil },
                set: { flow.setGoalDate($0 ? Self.format(date) : nil) }
            ))
            .tint(Palette.accent.color)
            .padding(.horizontal, 18).frame(minHeight: 60)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            if flow.answers.goal.date != nil {
                DatePicker("Goal date", selection: Binding(get: { date }, set: { date = $0; flow.setGoalDate(Self.format($0)) }),
                           in: Date.now..., displayedComponents: .date)
                    .padding(.horizontal, 18).frame(minHeight: Metrics.minTouchTarget)
            }
            Toggle("I have a goal time", isOn: Binding(
                get: { flow.answers.goal.targetTimeSec != nil },
                set: { flow.setGoalTimeMinutes($0 ? defaultMinutes : nil) }
            ))
            .tint(Palette.accent.color)
            .padding(.horizontal, 18).frame(minHeight: 60)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            if let seconds = flow.answers.goal.targetTimeSec {
                NumberInput(label: "Goal time", unit: "min", value: seconds / 60, start: seconds / 60, range: 10...360) { flow.setGoalTimeMinutes($0) }
            }
        }
        .foregroundStyle(Palette.ink.color)
    }

    private var defaultMinutes: Int {
        switch flow.answers.goal.distance {
        case .fiveK: 30
        case .tenK: 60
        case .halfMarathon: 130
        }
    }

    private static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A local calendar date, `YYYY-MM-DD`, in the user's time zone.
    private static func format(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
