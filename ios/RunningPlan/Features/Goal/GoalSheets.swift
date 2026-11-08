import APIClient
import SwiftUI

/// "Edit goal": the goal's race date and target time. The distance stays; the interview re-run changes the plan itself.
struct GoalEditSheet: View {
    let goal: Components.Schemas.Goal
    let store: GoalStore
    let onClose: () -> Void
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var hasTime: Bool
    @State private var minutes: Int

    init(goal: Components.Schemas.Goal, store: GoalStore, onClose: @escaping () -> Void) {
        self.goal = goal
        self.store = store
        self.onClose = onClose
        let stored = goal.date.flatMap(Self.parse)
        _hasDate = State(initialValue: stored != nil)
        _date = State(initialValue: stored ?? Calendar.current.date(byAdding: .weekOfYear, value: 12, to: .now) ?? .now)
        _hasTime = State(initialValue: goal.targetTimeSec != nil)
        _minutes = State(initialValue: (goal.targetTimeSec ?? 3000) / 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Edit goal").font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.goalEdit")
                    Spacer()
                    Button("Cancel", action: onClose)
                        .font(.system(size: 16)).foregroundStyle(Palette.muted.color)
                        .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                        .accessibilityIdentifier("goalEdit.cancel")
                }
                Toggle("Race date", isOn: $hasDate).tint(Palette.accent.color).frame(minHeight: Metrics.minTouchTarget)
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("goalEdit.hasDate")
                if hasDate {
                    DatePicker("Race date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(Palette.accentText.color)
                        .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
                        .accessibilityIdentifier("goalEdit.date")
                }
                Toggle("Target time", isOn: $hasTime).tint(Palette.accent.color).frame(minHeight: Metrics.minTouchTarget)
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("goalEdit.hasTime")
                if hasTime {
                    Stepper(value: $minutes, in: 1...1440) {
                        Text("\(minutes) min").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    }
                    .accessibilityIdentifier("goalEdit.minutes")
                }
                Text("This changes the goal's date and time only. To change the distance or reshape the weeks, re-run the interview.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                if let error = store.goalError {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("goalEdit.error")
                }
                Button {
                    Task { if await store.editGoal(date: hasDate ? Self.format(date) : nil, targetMinutes: hasTime ? minutes : nil) { onClose() } }
                } label: {
                    Text("Save goal")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .disabled(store.busy)
                .accessibilityIdentifier("goalEdit.save")
            }
            .padding(20)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// `YYYY-MM-DD` in the user's own calendar, never through a time zone shift.
    static func format(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func parse(_ text: String) -> Date? {
        let pieces = text.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }
}

/// The interview re-run's proposal: the same cards the weekly review shows. Nothing changes until the user accepts.
struct RerunProposalsSheet: View {
    let store: GoalStore
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Your new plan").font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("screen.goalProposals")
                    Spacer()
                    Button("Done", action: onClose)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                        .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                        .accessibilityIdentifier("goalProposals.done")
                }
                Text("Your answers rebuild the weeks after this one. Nothing changes until you accept.")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                if store.proposals.proposals.isEmpty, store.proposals.applied.isEmpty {
                    Text("Nothing to change. Your plan stays as it is.").font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                } else {
                    ProposalList(store: store.proposals, today: PreviewViewModel.localToday())
                }
            }
            .padding(20)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
