import SwiftUI

/// The Next tab: DK-Next for the saved plan, "Set a goal" when there is none, and loading and retry states.
struct NextScreen: View {
    let plans: PlanStore
    /// Distance done on the week card; the one store the Progress tab uses.
    var progress: ProgressStore?
    let onSetGoal: () -> Void
    var onOpen: (String) -> Void = { _ in }
    var onMove: (String) -> Void = { _ in }
    var inboxCount = 0
    var onInbox: () -> Void = {}
    var onRuns: () -> Void = {}
    /// The weekly review store: its card shows when a review is waiting.
    var review: ReviewStore?
    var onReview: () -> Void = {}
    /// Where the one-time watch card and Watch settings come from; nil in previews and tests.
    var watchSync: WatchSyncModel?
    /// The runs behind the "Done today" card and its check-in (issue #186); nil in previews and tests.
    var inbox: InboxStore?
    /// The after-run check-in opened from the card.
    @State private var checkIn: InboxStore.CheckInTarget?
    /// "Not this session" is on its way to the server, and what went wrong if it failed.
    @State private var unmatching = false
    @State private var matchError: String?
    @State private var showWatchSettings = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            switch plans.state {
            case .loaded(let plan):
                NextView(
                    model: NextModel(schedule: PlanSchedule(plan: plan, today: PreviewViewModel.localToday()), progress: progress?.loaded), onSetGoal: onSetGoal,
                    onOpen: onOpen, onEasier: makeEasier, onMove: onMove, inboxCount: inboxCount, onInbox: onInbox, onRuns: onRuns,
                    reviewCard: review?.model, onReview: onReview,
                    offerWatch: watchSync?.shouldOfferTurnOn == true,
                    onWatchTurnOn: {
                        Task { await watchSync?.turnOn(sessions: plan.value2.sessions, today: PreviewViewModel.localToday()) }
                    },
                    onWatchNotNow: { Task { await watchSync?.markAsked() } },
                    onWatchSettings: { showWatchSettings = true },
                    matched: inbox?.matchedToday(today: PreviewViewModel.localToday()),
                    onFeel: { id in checkIn = inbox?.checkInTarget(sessionId: id) },
                    onNotThisSession: notThisSession,
                    matchBusy: unmatching, matchError: matchError,
                    busy: busy, error: error
                )
                .sheet(isPresented: $showWatchSettings) {
                    if let watchSync { WatchSettingsSheet(sync: watchSync, plans: plans, onClose: { showWatchSettings = false }) }
                }
                .fullScreenCover(item: $checkIn) { target in
                    CheckInScreen(plans: plans, target: target, backTitle: "Next", onClose: { saved in
                        if saved { inbox?.markCheckedIn(target.id) }
                        checkIn = nil
                    })
                }
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
                    if !plans.isSignedIn { SignInLink() }
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

    /// Not this session: takes the run off the session. The run returns to the inbox and the session to planned, so
    /// the card goes on its own.
    private func notThisSession(_ id: String) {
        guard let inbox, !unmatching else { return }
        unmatching = true
        matchError = nil
        Task {
            matchError = await inbox.unmatch(sessionId: id)
            unmatching = false
        }
    }

    /// Make it easier: the Easier quick adjustment, straight to the API.
    private func makeEasier(_ id: String) {
        guard let session = plans.plan?.value2.sessions.first(where: { $0.value1.id == id && $0.value1.deletedAt == nil }),
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
