import SwiftUI

/// The Next tab: DK-Next for the saved plan, "Set a goal" when there is none, and loading and retry states.
struct NextScreen: View {
    let plans: PlanStore
    let onSetGoal: () -> Void

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                NextView(model: NextModel(schedule: PlanSchedule(plan: plan, today: PreviewViewModel.localToday())), onSetGoal: onSetGoal)
            case .loading:
                centred { ProgressView().tint(Palette.accentText.color).accessibilityLabel("Loading your plan") }
            case .empty:
                // Empty state of Next (docs/design-notes.md): the way into the interview.
                centred {
                    Button(action: onSetGoal) {
                        // The frame inside the label, so the whole button is tappable.
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
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(AppTab.next.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier(AppTab.next.screenIdentifier)
                content()
            }
            .padding(.horizontal, 20)
        }
    }
}
