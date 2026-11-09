import APIClient
import SwiftUI

/// The Progress tab: DK-Progress for the saved plan from `GET /v1/plans/{id}/progress`, "Set a goal" when there is no
/// plan, and loading and retry states. The store is shared and loaded by `RootView` (after any session edit or match,
/// and on a new day once the view redraws; see `refreshKey`); this screen also reloads on pull to refresh.
struct ProgressScreen: View {
    let plans: PlanStore
    let onSetGoal: () -> Void
    /// Shared with Next and Plan (owned by `RootView`).
    let store: ProgressStore
    /// Where the imported runs come from for "Your running" (issue #137).
    let inbox: InboxStore

    init(plans: PlanStore, store: ProgressStore, inbox: InboxStore, onSetGoal: @escaping () -> Void) {
        self.plans = plans
        self.store = store
        self.inbox = inbox
        self.onSetGoal = onSetGoal
    }

    /// The run totals for the calendar week and month, once the runs are loaded; nil before (nothing is guessed).
    private func runningCard(planWeek: RunningStatsModel.PlanWeek?) -> AnyView {
        // Signed out, the store may still hold the last account's runs: show none of them.
        guard inbox.allRunsLoaded, plans.isSignedIn else { return AnyView(EmptyView()) }
        return AnyView(RunningStatsCard(totals: RunTotals(activities: inbox.allRuns, today: PreviewViewModel.localToday()), planWeek: planWeek))
    }

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                loaded(plan)
            case .loading:
                centred { SwiftUI.ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your plan") }
            case .empty:
                // A runner with no plan still sees what they ran: the totals sit under "Set a goal".
                if inbox.allRunsLoaded && !inbox.allRuns.isEmpty && plans.isSignedIn {
                    ZStack {
                        Palette.bg.color.ignoresSafeArea()
                        ScrollView {
                            VStack(spacing: 20) {
                                Text(AppTab.progress.title)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(Palette.ink.color)
                                    .accessibilityIdentifier(AppTab.progress.screenIdentifier)
                                setGoal
                                runningCard(planWeek: nil)
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                        }
                    }
                } else {
                    centred { setGoal }
                }
            case .failed(let message):
                retry(message) { await plans.load() }
            }
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // The runs behind "Your running": read when the tab shows and again when the plan, the day or a match changes.
        .task(id: runsKey) { if plans.isSignedIn { await inbox.loadAllRuns() } }
    }

    private var runsKey: String {
        (plans.plan.map { Self.refreshKey($0) } ?? "none") + "|\(plans.isSignedIn)"
    }

    @ViewBuilder private var setGoal: some View {
        Text("Set a goal and your progress shows here.")
            .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
        Button(action: onSetGoal) {
            Text("Set a goal")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 28)
                .frame(minHeight: 56)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        if !plans.isSignedIn { SignInLink() }
    }

    @ViewBuilder private func loaded(_ plan: Components.Schemas.PlanDetail) -> some View {
        let id = plan.value1.value1.id
        switch store.state {
        case .loaded(let progress):
            let schedule = PlanSchedule(plan: plan, today: progress.asOf)
            let planWeek = RunningStatsModel.planWeek(schedule: schedule, done: DistanceDone(progress: progress, schedule: schedule))
            ProgressOverview(model: ProgressModel(progress: progress, plan: plan), footer: runningCard(planWeek: planWeek))
                .refreshable {
                    await store.load(planId: id, today: PreviewViewModel.localToday())
                    await inbox.loadAllRuns()
                }
        case .loading:
            centred { SwiftUI.ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your progress") }
        case .failed(let message):
            retry(message) {
                await plans.load()
                if let current = plans.plan?.value1.value1.id { await store.load(planId: current, today: PreviewViewModel.localToday()) }
            }
        }
    }

    /// Changes with the plan, the local day and any session's revision, so an edit, a match or a check-in refreshes.
    static func refreshKey(_ plan: Components.Schemas.PlanDetail) -> String {
        let revisions = plan.value2.sessions.map { "\($0.value1.id):\($0.value1.revision)" }.joined(separator: ",")
        return "\(plan.value1.value1.id)|\(PreviewViewModel.localToday())|\(revisions)"
    }

    private func retry(_ message: String, action: @escaping () async -> Void) -> some View {
        centred {
            Text(message).font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Palette.muted.color)
            SignInAgainButton(message: message)
            Button { Task { await action() } } label: {
                Text("Try again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accentText.color)
                    .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(AppTab.progress.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier(AppTab.progress.screenIdentifier)
                content()
            }
            .padding(.horizontal, 20)
        }
    }
}
