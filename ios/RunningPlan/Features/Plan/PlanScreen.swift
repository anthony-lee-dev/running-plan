import SwiftUI

/// The Plan tab: DK-Week (opening on this week) and DK-Whole for the saved plan; "Set a goal" when there is none.
struct PlanScreen: View {
    let plans: PlanStore
    let onSetGoal: () -> Void
    var onOpen: (String) -> Void = { _ in }
    var onAdd: (String) -> Void = { _ in }
    /// The week on screen; nil until the user moves, so it follows today.
    @State private var week: Int?
    @State private var mode: PlanMode = .week

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                let schedule = PlanSchedule(plan: plan, today: PreviewViewModel.localToday())
                let shown = min(max(week ?? WeekModel.initialWeek(schedule), 0), max(schedule.weekCount - 1, 0))
                switch mode {
                case .week:
                    WeekView(model: WeekModel(schedule: schedule, week: shown), onMode: { mode = $0 }, onWeek: { week = $0 }, onOpen: onOpen, onAdd: onAdd)
                case .whole:
                    WholeView(model: WholeModel(schedule: schedule), onMode: { mode = $0 }, onWeek: {
                        week = $0
                        mode = .week
                    })
                }
            case .loading:
                centred { ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your plan") }
            case .empty:
                centred {
                    Text("No plan yet.").font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                    Button(action: onSetGoal) {
                        Text("Set a goal")
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.horizontal, 28)
                            .frame(minHeight: 56)
                            .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                    }
                }
            case .failed(let message):
                centred {
                    Text(message).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
                    Button { Task { await plans.load() } } label: {
                        Text("Try again")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.accentText.color)
                            .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // A different plan (a new save) starts again on its own this week.
        .onChange(of: plans.plan?.value1.value1.id) { week = nil }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(AppTab.plan.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier(AppTab.plan.screenIdentifier)
                content()
            }
            .padding(.horizontal, 20)
        }
    }
}
