import APIClient
import SwiftUI

/// The Progress tab: DK-Progress for the saved plan from `GET /v1/plans/{id}/progress`, "Set a goal" when there is no
/// plan, and loading and retry states. Reloads when the tab shows, after any session edit or match, on a new day once
/// the view redraws (the key below), and on pull to refresh.
struct ProgressScreen: View {
    let plans: PlanStore
    let onSetGoal: () -> Void
    /// Shared with Next and Plan (owned by `RootView`).
    let store: ProgressStore

    init(plans: PlanStore, store: ProgressStore, onSetGoal: @escaping () -> Void) {
        self.plans = plans
        self.store = store
        self.onSetGoal = onSetGoal
    }

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                loaded(plan)
            case .loading:
                centred { SwiftUI.ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your plan") }
            case .empty:
                centred {
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
                }
            case .failed(let message):
                retry(message) { await plans.load() }
            }
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder private func loaded(_ plan: Components.Schemas.PlanDetail) -> some View {
        let id = plan.value1.value1.id
        switch store.state {
        case .loaded(let progress):
            ProgressOverview(model: ProgressModel(progress: progress, plan: plan))
                .refreshable { await store.load(planId: id, today: PreviewViewModel.localToday()) }
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
