import SwiftUI

/// The Next tab: DK-Next for the saved plan, "Set a goal" when there is none, and loading and retry states.
struct NextScreen: View {
    let plans: PlanStore
    let onSetGoal: () -> Void
    var onOpen: (String) -> Void = { _ in }
    var onMove: (String) -> Void = { _ in }
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                NextView(
                    model: NextModel(schedule: PlanSchedule(plan: plan, today: PreviewViewModel.localToday())), onSetGoal: onSetGoal,
                    onOpen: onOpen, onEasier: makeEasier, onMove: onMove, busy: busy, error: error
                )
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

    /// Make it easier: the Easier quick adjustment, straight to the API.
    private func makeEasier(_ id: String) {
        guard let session = plans.plan?.value2.sessions.first(where: { $0.value1.id == id }),
              let update = QuickAdjustment.easier.update(for: session.value2) else { return }
        busy = true
        error = nil
        Task {
            error = await plans.apply([SessionEdit(sessionId: id, revision: session.value1.revision, update: update)])
            busy = false
        }
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
