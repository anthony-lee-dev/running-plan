import SwiftUI

/// Stand-in for a tab until its screen task lands (see docs/backlog.md). On Next it shows the saved plan's week, or
/// "Set a goal" when there is no plan, until the Next screen (task 3.5) replaces it.
struct PlaceholderScreen: View {
    let tab: AppTab
    let plans: PlanStore
    let onSetGoal: () -> Void

    var body: some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(tab.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier(tab.screenIdentifier)
                if tab == .next { next }
            }
            .padding(.horizontal, 20)
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder private var next: some View {
        switch plans.state {
        case .loading:
            ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your plan")
        case .empty:
            // Empty state of Next (docs/design-notes.md): the way into the interview.
            Button("Set a goal", action: onSetGoal)
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 28)
                .frame(minHeight: 56)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
        case .loaded(let plan):
            Text(Self.summary(PlanSchedule(plan: plan, today: PreviewViewModel.localToday())))
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.accentText.color)
                .accessibilityIdentifier("next.plan")
        case .failed(let message):
            Text(message).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
            Button("Try again") { Task { await plans.load() } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accentText.color)
                .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    static func summary(_ schedule: PlanSchedule) -> String {
        switch schedule.position {
        case .notStarted(let start): "Your plan starts \(PlanPreview.shortDate(start))"
        case .week(let index): "Week \(index + 1) of \(schedule.weekCount)"
        case .finished: "Your plan is finished"
        }
    }
}
