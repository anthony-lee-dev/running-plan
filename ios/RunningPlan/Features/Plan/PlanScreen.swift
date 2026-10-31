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
    @State private var confirmDelete = false
    @State private var deleteError: String?

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Week only: the whole-plan list is a fixed layout and the row would cover its last weeks on a short screen.
            if plans.plan != nil, mode == .week { deleteRow }
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // A different plan (a new save) starts again on its own this week.
        .onChange(of: plans.plan?.value1.value1.id) { week = nil }
    }

    /// Interim until Goal and settings (3.7): a small confirmed "Delete plan" under the plan.
    private var deleteRow: some View {
        VStack(spacing: 4) {
            if let deleteError {
                Text(deleteError)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.muted.color)
                    .accessibilityIdentifier("plan.delete.error")
            }
            Button {
                deleteError = nil
                confirmDelete = true
            } label: {
                Text("Delete plan")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.muted.color)
                    .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("plan.delete")
            .confirmationDialog("Delete this plan?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Yes, delete it", role: .destructive) {
                    Task { deleteError = await plans.deletePlan() }
                }
                Button("Keep plan", role: .cancel) {}
            } message: {
                Text("This removes the plan and all its sessions. You can set a new goal afterwards.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .background(Palette.bg.color)
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
